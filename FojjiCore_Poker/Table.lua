-- The table: a lobby the host invites people to, and then the game itself for 2 to 9 players.
--
-- The host keeps the one true order of moves. Everyone else sends their move to the host, the host
-- checks it with the engine, numbers it and sends it to the whole table, and every client applies the
-- same numbered moves in the same order. When the whole table is in the host's group, one group
-- message reaches everyone; otherwise the host whispers each player (whispers only ever arrive from
-- guild and group members).
--
-- Nothing here draws anything: Poker.lua sets T.cb and paints.
--   T.cb.onChange(why, text)   the lobby or the game changed. why: "lobby" "start" "sync" "resume"
--                              "me" "foe" (a move; text is the move) "pending" "end" "leave"
--   T.cb.onInvite(offer)       someone invited us: offer = { id, host, opts, t }
--   T.cb.onNote(text)          something worth a line in the lobby ("Bob said no.")
--   T.cb.onClosed(text)        the lobby we were in went away
--   T.cb.onTick()              every few seconds while a game is going
--   T.cb.options()             the options a new table starts with
--
-- On the wire (kind "PKT", every message "sub~id~..."):
--   I~id~opts   invite (host -> player)          J~id   join (player -> host)     D~id   no thanks
--   L~id~opts~names  the lobby (host -> table)   Q~id   I'm leaving (player -> host)
--   X~id~why    the table closed, or you can't sit at it (host -> player or table)
--   T~id~n~opts~names~snapshot  the whole game after n moves (host -> player): the start, or a catch-up
--   M~id~n~seat~move  move n (host -> table)     A~id~n~move  my move, made after move n (player -> host)
--   P~id~n      where are we? I have n moves (-1: still in the lobby) (player -> host)
local _, ns = ...
local Addon = FojjiCoreNS
local Games = Addon and Addon.Games
if not (Games and Games.Base and Games.Base.Comm) then return end
local FDJ = Games.Base
local Engine = ns.Engine

local T = { cb = {}, offers = {} }
ns.Table = T

local KIND = "PKT"
local MAX = Engine.MAX_SEATS
local INVITE_TIME = 90
local RESUME_TIME = 30 * 60
local GROUP = { PARTY = true, RAID = true, INSTANCE_CHAT = true }
local same, key = Games.Same, Games.Key

local function me() return Games.Wire(FDJ.PlayerName()) end
local function short(n) return n and Games.Name(n) or "?" end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function newId() return tostring(math.random(100000, 999999)) end
local function call(name, ...)
    local fn = T.cb[name]
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok and Addon.Report then Addon.Report(err) end
end
local function db()
    FojjiCorePokerDB = type(FojjiCorePokerDB) == "table" and FojjiCorePokerDB or {}
    return FojjiCorePokerDB
end

local function split(text)
    local t = {}
    for n in tostring(text or ""):gmatch("[^,]+") do t[#t + 1] = n end
    return t
end
local function seatOf(names, name)
    for i, n in ipairs(names or {}) do if same(n, name) then return i end end
    return nil
end
T.SeatOf = seatOf

-- only whisper someone we can see is around: a whisper to an offline player prints an error in chat
local function reachable(name)
    if not name then return false end
    if Games.Near(name) or Games.Near(short(name)) then return true end
    if IsInGuild and IsInGuild() and GetGuildRosterInfo then
        for i = 1, (tonumber(GetNumGuildMembers and GetNumGuildMembers()) or 0) do
            local n, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if type(n) == "string" and online and same(n, name) then return true end
        end
    end
    return false
end
T.Reachable = reachable

local function pack(sub, id, ...)
    local parts = { sub, id }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, "~")
end
local function whisper(target, text)
    if target and not same(target, me()) then FDJ.Comm.Send(KIND, text, "WHISPER", target) end
end
-- to everyone at the table but me (and anyone in skip, keyed by name)
local function broadcast(names, text, skip)
    local others = {}
    for _, n in ipairs(names or {}) do
        if not same(n, me()) and not (skip and skip[key(n)]) then others[#others + 1] = n end
    end
    if #others == 0 then return end
    local channel = FDJ.GroupChannel()
    local grouped = channel ~= nil
    for _, n in ipairs(others) do
        if not (Games.Near(n) or Games.Near(short(n))) then grouped = false break end
    end
    if grouped then
        FDJ.Comm.Send(KIND, text, channel)
        return
    end
    for _, n in ipairs(others) do
        if reachable(n) then whisper(n, text) end
    end
end

-- ---------------------------------------------------------------- state
-- T.lobby: { id, host, players = { names }, opts, invited = { [key] = name }, joining, heardAt }
-- T.game:  { id, host, names = { seat -> name }, opts, match, n (moves so far), me (my seat),
--            pending = { n, text, at, tries } (my move on its way to the host), ended ("closed" / "left"),
--            heardAt, movedAt, away = { [key] = true } (left: no more messages for them) }
function T.Over(g)
    g = g or T.game
    return not g or g.ended ~= nil or g.match.over == true
end
function T.Playing() return T.game ~= nil and not T.Over() end
function T.IsHost()
    local s = T.lobby or T.game
    return s ~= nil and same(s.host, me())
end
function T.Me() return me() end

local function save()
    local g, d = T.game, db()
    if not g or T.Over(g) then d.live = nil return end
    d.live = { id = g.id, host = g.host, names = table.concat(g.names, ","), opts = g.opts, n = g.n,
        snap = Engine.Snapshot(g.match), t = time() }
end

local function stateFor(g)
    return pack("T", g.id, g.n, g.opts, table.concat(g.names, ","), Engine.Snapshot(g.match))
end
local function sendLobby()
    local L = T.lobby
    if not L then return end
    broadcast(L.players, pack("L", L.id, L.opts, table.concat(L.players, ",")))
end

-- a copy of the whole game from the host (the start, a catch-up, or after a reload)
local function adopt(id, host, n, opts, namesText, snap)
    local names = split(namesText)
    local seat = seatOf(names, me())
    if not seat or #names < 2 or #names > MAX then return false end
    local m = Engine.FromSnapshot(snap, id)
    if not m or m.seats ~= #names then return false end
    local g = T.game
    local fresh = not (g and g.id == id)
    if fresh then
        g = { id = id, host = host, names = names, opts = opts, me = seat, away = {} }
        T.game, T.lobby = g, nil
    end
    g.match, g.n = m, n
    if g.pending and g.pending.n < n then g.pending = nil end
    g.heardAt, g.movedAt = GetTime(), GetTime()
    save()
    call("onChange", fresh and "start" or "sync")
    return true
end

local pingAt = -60
local function askHost(soon)
    local g, L = T.game, T.lobby
    local host = (g and g.host) or (L and L.host)
    if not host or T.IsHost() then return end
    if GetTime() - pingAt < (soon and 5 or 15) then return end
    if not reachable(host) then return end
    pingAt = GetTime()
    local id = (g and g.id) or L.id
    whisper(host, pack("P", id, g and g.n or -1))
end

-- the host: one move into the game, numbered, and out to the table
local function hostApply(seat, text)
    local g = T.game
    local ok, err = Engine.Apply(g.match, seat, text)
    if not ok then return false, err end
    g.n = g.n + 1
    g.movedAt = GetTime()
    save()
    broadcast(g.names, pack("M", g.id, g.n, seat, text), g.away)
    call("onChange", seat == g.me and "me" or "foe", text)
    return true
end

-- ---------------------------------------------------------------- the lobby
local function defaultOpts()
    local fn = T.cb.options
    return fn and fn() or "NL,100,0"
end

-- opens a table with us as the host
function T.Open(opts)
    if T.Playing() then return false, "You're already playing at a table." end
    if T.lobby then
        if T.IsHost() then return true end
        T.Leave()
    end
    T.game = nil
    T.lobby = { id = newId(), host = me(), players = { me() }, opts = opts or defaultOpts(), invited = {} }
    call("onChange", "lobby")
    return true
end

function T.SetOpts(opts)
    local L = T.lobby
    if not (L and T.IsHost()) or L.opts == opts then return end
    L.opts = opts
    sendLobby()
    call("onChange", "lobby")
end

function T.Invite(name)
    name = Games.Wire(trim(name))
    if not name or name == "" then return false, "Type a name, or pick someone from the lists." end
    if same(name, me()) then return false, "That's you." end
    if T.Playing() then return false, "You're already playing at a table." end
    if not T.lobby then T.Open() end
    local L = T.lobby
    if not T.IsHost() then return false, "Only the host can invite people." end
    if seatOf(L.players, name) then return false, short(name) .. " is already at the table." end
    if #L.players >= MAX then return false, "The table is full: nine players." end
    if not reachable(name) then return false, short(name) .. " isn't online in your group or guild." end
    L.invited[key(name)] = name
    whisper(name, pack("I", L.id, L.opts))
    call("onChange", "lobby")
    return true
end

-- everyone in the group who isn't at the table yet; returns how many were asked
function T.InviteGroup()
    local units = {}
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    else
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    local n = 0
    for _, u in ipairs(units) do
        if UnitExists and UnitExists(u) and not (UnitIsUnit and UnitIsUnit(u, "player")) then
            local name = Games.UnitFullName and Games.UnitFullName(u) or UnitName(u)
            if type(name) == "string" and T.Invite(name) then n = n + 1 end
        end
    end
    return n
end

function T.Offer(host)
    local k = key(host)
    local o = k and T.offers[k]
    if o and GetTime() - o.t > INVITE_TIME then
        T.offers[k] = nil
        o = nil
    end
    return o
end
-- the freshest invite still open
function T.LatestOffer()
    local best
    for k in pairs(T.offers) do
        local o = T.Offer(k)
        if o and (not best or o.t > best.t) then best = o end
    end
    return best
end

function T.Accept(host)
    local o = T.Offer(host)
    if not o then return false, "That invite has run out." end
    if T.Playing() then return false, "Leave the table you're at first." end
    if T.lobby then T.Leave() end
    T.game = nil
    T.offers[key(o.host)] = nil
    T.lobby = { id = o.id, host = o.host, players = { o.host, me() }, opts = o.opts, invited = {},
        joining = true, heardAt = GetTime(), joinedAt = GetTime() }
    whisper(o.host, pack("J", o.id))
    call("onChange", "lobby")
    return true
end
function T.Decline(host)
    local o = T.Offer(host)
    if not o then return false end
    T.offers[key(o.host)] = nil
    whisper(o.host, pack("D", o.id))
    return true
end

-- the host: everyone in the lobby gets a seat (in a random order) and the first hand starts
function T.Start()
    local L = T.lobby
    if not (L and T.IsHost()) then return false, "Only the host can start." end
    if #L.players < 2 then return false, "Invite at least one more player." end
    local names = {}
    for i, n in ipairs(L.players) do names[i] = n end
    for i = #names, 2, -1 do
        local j = math.random(i)
        names[i], names[j] = names[j], names[i]
    end
    local m = Engine.NewMatch(L.opts, L.id, #names)
    local g = { id = L.id, host = L.host, names = names, opts = m.optsText, match = m, n = 0,
        me = seatOf(names, me()), away = {}, movedAt = GetTime(), heardAt = GetTime() }
    T.game, T.lobby = g, nil
    save()
    broadcast(names, stateFor(g))
    call("onChange", "start")
    return true
end

-- leaves the lobby or the table (the host leaving closes it for everyone)
function T.Leave()
    local L = T.lobby
    if L then
        if T.IsHost() then broadcast(L.players, pack("X", L.id, "closed")) else whisper(L.host, pack("Q", L.id)) end
        T.lobby = nil
    end
    local g = T.game
    if g then
        local host = T.IsHost()
        if host then
            if not T.Over(g) then
                broadcast(g.names, pack("X", g.id, "closed"), g.away)
                g.ended = "closed"
            end
            T.lastGame = g
        elseif not g.ended then
            -- also when we're out and only watching: the host stops sending us the moves
            whisper(g.host, pack("Q", g.id))
            if not g.match.over then g.ended = "left" end
        end
        T.game = nil
        save()
    end
    call("onChange", "leave")
end

-- ---------------------------------------------------------------- the game
-- my own move: the host applies it straight away, everyone else sends it to the host and waits
function T.Act(text)
    local g = T.game
    if not T.Playing() then return false, "no game" end
    if T.IsHost() then return hostApply(g.me, text) end
    if g.pending then return false, "waiting on the host" end
    -- try it on a copy first, so a move the host would refuse never leaves
    local probe = Engine.FromSnapshot(Engine.Snapshot(g.match), g.id)
    if not probe then return false, "lost track of the game" end
    local ok, err = Engine.Apply(probe, g.me, text)
    if not ok then return false, err end
    g.pending = { n = g.n, text = text, at = GetTime(), tries = 1 }
    whisper(g.host, pack("A", g.id, g.n, text))
    call("onChange", "pending")
    return true
end

-- the host: takes a player who stopped answering out of the game
function T.Remove(seat)
    local g = T.game
    if not (T.Playing() and T.IsHost()) or seat == g.me then return false end
    return hostApply(0, "O" .. seat)
end

-- ---------------------------------------------------------------- messages
local handlers = {}

handlers.I = function(id, rest, who, channel)
    if channel ~= "WHISPER" then return end
    local o = { id = id, host = who, opts = Engine.OptsText(Engine.ParseOpts(rest)), t = GetTime() }
    T.offers[key(who)] = o
    call("onInvite", o)
end

handlers.J = function(id, _, who)
    if not T.IsHost() then return end
    local L, g = T.lobby, T.game
    if L and L.id == id then
        if not seatOf(L.players, who) then
            if not L.invited[key(who)] then return end
            if #L.players >= MAX then whisper(who, pack("X", id, "full")) return end
            L.players[#L.players + 1] = who
            L.invited[key(who)] = nil
            call("onChange", "lobby")
        end
        sendLobby()
    elseif g and g.id == id then
        if seatOf(g.names, who) then whisper(who, stateFor(g)) else whisper(who, pack("X", id, "started")) end
    end
end

handlers.D = function(id, _, who)
    local L = T.lobby
    if not (L and L.id == id and T.IsHost() and L.invited[key(who)]) then return end
    L.invited[key(who)] = nil
    call("onNote", short(who) .. " said no this time.")
    call("onChange", "lobby")
end

handlers.L = function(id, rest, who)
    local L = T.lobby
    if not (L and L.id == id and same(who, L.host)) or T.IsHost() then return end
    local opts, names = rest:match("^([^~]*)~(.*)$")
    if not opts then return end
    local list = split(names)
    if not seatOf(list, me()) then
        -- a group message from before the host got our join: wait for the next one
        if L.joining then return end
        T.lobby = nil
        call("onClosed", "You're no longer at " .. short(who) .. "'s table.")
        call("onChange", "lobby")
        return
    end
    L.players, L.opts, L.heardAt, L.joining = list, Engine.OptsText(Engine.ParseOpts(opts)), GetTime(), nil
    call("onChange", "lobby")
end

handlers.Q = function(id, _, who)
    if not T.IsHost() then return end
    local L, g = T.lobby, T.game
    if L and L.id == id then
        local i = seatOf(L.players, who)
        if i and i > 1 then
            table.remove(L.players, i)
            call("onNote", short(who) .. " left the table.")
            sendLobby()
            call("onChange", "lobby")
        end
    elseif g and g.id == id then
        local seat = seatOf(g.names, who)
        if not seat then return end
        g.away[key(who)] = true
        local h = g.match.hand
        if not T.Over(g) and not g.match.out[seat] and not (h.left and h.left[seat]) then hostApply(0, "O" .. seat) end
    end
end

local CLOSED = {
    full = "That table is full.",
    started = "That table has already started.",
}
handlers.X = function(id, rest, who)
    for k, o in pairs(T.offers) do
        if o.id == id and same(o.host, who) then T.offers[k] = nil end
    end
    local L, g = T.lobby, T.game
    if L and L.id == id and same(who, L.host) and not T.IsHost() then
        T.lobby = nil
        call("onClosed", CLOSED[rest] or (short(who) .. " closed the table."))
        call("onChange", "lobby")
    elseif g and g.id == id and same(who, g.host) and not T.IsHost() and not T.Over(g) then
        g.ended = "closed"
        save()
        call("onChange", "end")
    end
end

handlers.T = function(id, rest, who)
    local n, opts, names, snap = rest:match("^(%d+)~([^~]*)~([^~]*)~(.*)$")
    n = tonumber(n)
    if not n then return end
    local g, L = T.game, T.lobby
    if g and g.id == id then
        if not same(who, g.host) or T.IsHost() or n <= g.n then return end
    elseif L and L.id == id then
        if not same(who, L.host) then return end
    elseif T.Playing() or L then
        return
    elseif not seatOf(split(names), me()) then
        return
    end
    adopt(id, who, n, opts, names, snap)
end

handlers.M = function(id, rest, who)
    local g = T.game
    if not (g and g.id == id) then
        local L = T.lobby
        -- the game started without us hearing about it
        if L and L.id == id and same(who, L.host) then askHost(true) end
        return
    end
    if not same(who, g.host) or T.IsHost() then return end
    local n, seat, text = rest:match("^(%d+)~(%d+)~(.*)$")
    n, seat = tonumber(n), tonumber(seat)
    if not n then return end
    g.heardAt = GetTime()
    if n == g.n + 1 then
        local ok = not g.match.over and Engine.Apply(g.match, seat, text)
        if not ok then askHost(true) return end
        g.n = n
        g.movedAt = GetTime()
        if g.pending and g.pending.n < n then g.pending = nil end
        save()
        call("onChange", seat == g.me and "me" or "foe", text)
    elseif n > g.n + 1 then
        askHost(true)
    end
end

handlers.A = function(id, rest, who)
    local g = T.game
    if not (g and g.id == id and T.IsHost()) or T.Over(g) then return end
    local seat = seatOf(g.names, who)
    local n, text = rest:match("^(%d+)~(.*)$")
    n = tonumber(n)
    if not (seat and n) then return end
    if n ~= g.n then
        -- they missed something (or this is a copy of a move we already have): catch them up
        if n < g.n then whisper(who, stateFor(g)) end
        return
    end
    if Engine.Expect(g.match) ~= seat then return end
    if not hostApply(seat, text) then whisper(who, stateFor(g)) end
end

handlers.P = function(id, rest, who)
    if not T.IsHost() then return end
    local n = tonumber(rest) or -1
    local L = T.lobby
    if L and L.id == id then
        if seatOf(L.players, who) then
            whisper(who, pack("L", L.id, L.opts, table.concat(L.players, ",")))
        else
            whisper(who, pack("X", id, "closed"))
        end
        return
    end
    local g = (T.game and T.game.id == id and T.game) or (T.lastGame and T.lastGame.id == id and T.lastGame)
    if g and seatOf(g.names, who) then
        if g.ended == "closed" then whisper(who, pack("X", id, "closed"))
        elseif n < g.n then whisper(who, stateFor(g)) end
    elseif not g then
        whisper(who, pack("X", id, "closed"))
    end
end

FDJ:On("FDJ_COMM", function(kind, payload, who, channel)
    if kind ~= KIND or type(payload) ~= "string" or type(who) ~= "string" then return end
    if channel ~= "WHISPER" and not GROUP[channel] then return end
    local sub, id, rest = payload:match("^(%u)~(%d+)~?(.*)$")
    local fn = sub and handlers[sub]
    if not fn then return end
    who = Games.Wire(who)
    if same(who, me()) then return end
    local ok, err = pcall(fn, id, rest or "", who, channel)
    if not ok and Addon.Report then Addon.Report(err) end
end)

-- ---------------------------------------------------------------- the heartbeat
-- Every few seconds: re-send a move the host hasn't confirmed, ask the host to catch us up when it's
-- been quiet, and let Poker.lua run the deal.
local function tick()
    C_Timer.After(4, tick)
    local now = GetTime()
    local L = T.lobby
    if L and not T.IsHost() then
        if L.joining then
            if now - L.joinedAt > 60 then
                T.lobby = nil
                call("onClosed", short(L.host) .. " didn't answer.")
                call("onChange", "lobby")
            elseif now - L.heardAt > 6 and reachable(L.host) then
                L.heardAt = now
                whisper(L.host, pack("J", L.id))
            end
        elseif now - L.heardAt > 20 then
            askHost()
        end
    end
    local g = T.game
    if g and not T.Over(g) then
        if not T.IsHost() then
            local p = g.pending
            if p and now - p.at > 8 then
                if p.tries >= 6 then
                    g.pending = nil -- give up; the player can try again
                    call("onChange", "sync")
                elseif reachable(g.host) then
                    p.at, p.tries = now, p.tries + 1
                    whisper(g.host, pack("A", g.id, p.n, p.text))
                end
            end
            if now - (g.heardAt or 0) > 20 then askHost() end
        end
        call("onTick")
    end
end
C_Timer.After(4, tick)

-- ---------------------------------------------------------------- after a reload or a logout
FDJ:On("PLAYER_LOGIN", function()
    local live = db().live
    if type(live) ~= "table" or not live.id then return end
    if time() - (tonumber(live.t) or 0) > RESUME_TIME then db().live = nil return end
    local names = split(live.names)
    local m = Engine.FromSnapshot(live.snap, live.id)
    local seat = seatOf(names, me())
    if not (m and seat and m.seats == #names) then db().live = nil return end
    T.game = { id = tostring(live.id), host = live.host, names = names, opts = live.opts, match = m,
        n = tonumber(live.n) or 0, me = seat, away = {}, heardAt = GetTime(), movedAt = GetTime(), resumed = true }
    call("onChange", "resume")
    -- a little later, once the guild and group lists have loaded
    C_Timer.After(8, function()
        if T.game and T.game.id == tostring(live.id) and not T.IsHost() then askHost(true) end
    end)
end)

return T
