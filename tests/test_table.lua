    -- Several clients play whole games through the real FojjiCore Comm code, Table.lua and the window.
-- Run from the repo root:  lua tests/test_table.lua
-- Needs FojjiCore_Games installed (FOJJI_ADDONS = the AddOns folder; defaults to the _forever_ client).
local Mock = dofile("tests/wow_mock.lua")

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. msg) end
end

math.randomseed(tonumber(os.getenv("POKER_SEED")) or 7)
local function rng(n) return math.random(n) end

local NAMES = { "Alice", "Bob", "Cara", "Dain", "Edda", "Finn", "Gale", "Hild", "Ivo", "Jory" }

-- the player whose turn it is clicks something in the action bar
local function act(c)
    local bar = c.PK._win().bar
    local r = rng(100)
    if bar.fold:IsShown() and r <= 25 then bar.fold:Click() return end
    if bar.raise:IsShown() and r <= 40 then
        -- mostly small and pot-sized raises; now and then all the way
        if bar.sizing:IsShown() then bar.presets[rng(40) == 1 and 5 or rng(4)]:Click() end
        bar.raise:Click()
        return
    end
    bar.call:Click()
end

local function state(c) return c.PK._state() end
local function myAction(c)
    local g = state(c)
    if not (g and g.match and not g.match.over and not g.ended and not g.pending) then return false end
    local who, kind = c.ns.Engine.Expect(g.match)
    return who == g.me and kind == "A"
end

-- n players; the first is the host. grouped = everyone in one party (group messages); otherwise
-- they only share a guild (whispers)
local function newWorld(n, grouped)
    local world = Mock.World()
    for i = 1, n do
        local others = {}
        for j = 1, n do if j ~= i then others[#others + 1] = NAMES[j] end end
        local c = world:Client(NAMES[i], others, nil, grouped and others or {})
        c.PK.Show()
    end
    return world
end
local function client(world, i) return world:Find(NAMES[i]) end

-- the host opens a table with these options, invites everyone and starts
local function seat(world, n, opts)
    local host = client(world, 1)
    host.env.FojjiCorePokerDB = opts
    check(host.PK.Open(), "the host opens a table")
    for i = 2, n do check(host.PK.Invite(NAMES[i]), "invite " .. NAMES[i]) end
    world:Run(1)
    for i = 2, n do
        local c = client(world, i)
        check(c.PK.Accept(NAMES[1]), NAMES[i] .. " has an invite to accept")
    end
    world:Run(3)
    local _, lobby = state(host)
    check(lobby and #lobby.players == n, ("everyone is in the lobby (%d of %d)"):format(lobby and #lobby.players or 0, n))
    for i = 2, n do
        local _, l = state(client(world, i))
        check(l and #l.players == n, NAMES[i] .. " sees the whole lobby")
    end
    -- the host clicks Start
    local win = host.PK._win()
    win.lobby.go:Click()
    world:Run(3)
    for i = 1, n do
        local g = state(client(world, i))
        check(g and g.match and g.match.seats == n, NAMES[i] .. " is at the table")
    end
end

-- plays until every client still at the table sees the game over; `during(step, world)` may meddle
local function play(world, label, during)
    for step = 1, 60000 do
        world:Run(0.5)
        for _, c in ipairs(world.clients) do
            if not c.dead and myAction(c) then act(c) end
        end
        if during then during(step, world) end
        local done = true
        for _, c in ipairs(world.clients) do
            local g = not c.dead and state(c)
            if g and not (g.match.over or g.ended) then done = false end
        end
        if done then
            world.drop = 0
            -- long enough for a game-ending all-in to be played out before the result card
            world:Run(15)
            return step
        end
    end
    check(false, label .. ": game never finished")
end

local function verify(world, label, n, opts)
    opts = opts or {}
    local host = client(world, 1)
    local E = host.ns.Engine
    local hg = state(host)
    check(hg and hg.match.over, label .. ": the host sees the game over")
    if not hg then return end
    local m = hg.match
    local snap = E.Snapshot(m)
    local wins, total = 0, 0
    for i = 1, n do
        local c = client(world, i)
        local g = c and state(c)
        if g and not opts.skip then
            check(g.match.over, label .. ": " .. NAMES[i] .. " sees the game over")
            check(E.Snapshot(g.match) == snap, label .. ": " .. NAMES[i] .. " has the same final position")
            check(g.match.winner == m.winner, label .. ": everyone agrees who won")
            check(#c.reports == 0, label .. ": no errors for " .. NAMES[i] .. ": " .. table.concat(c.reports, " | "))
            local d = c.env.FojjiCorePokerDB
            check(d.w + d.l == 1, label .. ": the game is in " .. NAMES[i] .. "'s record once")
            wins = wins + d.w
            total = total + 1
            check(c.PK._win().result:IsOpen(), label .. ": " .. NAMES[i] .. " has a result card")
        end
    end
    if not opts.skip then check(wins == 1, label .. ": exactly one winner in the records") end
    -- every chip still at the table is the winner's
    check(m.stacks[m.winner] == E.Chips(m), label .. ": the winner has every chip at the table")
    if not opts.reloaded then
        check(E.Chips(m) + m.burned == m.start * n, label .. ": no chips made or lost")
    end
    local places = {}
    for i = 1, n do
        local p = m.place[i]
        check(p and not places[p], label .. ": seat " .. i .. " has a place of its own")
        if p then places[p] = true end
    end
    print(("%s: %d players, %d hands, %s won, %d messages (%d dropped)"):format(label, n, m.hand.n,
        hg.names[m.winner], world.sent, world.dropped))
end

-- 1. heads-up through the lobby
do
    local world = newWorld(2, true)
    seat(world, 2, { variant = "NL", stackBB = 30, level = 0 })
    local g = state(client(world, 2))
    check(g and g.match.opts.variant == "NL" and g.match.start == 600, "options reached the other player")
    play(world, "heads-up")
    verify(world, "heads-up", 2)
end

-- 2. six players in one group, Omaha with rising blinds, one message in ten lost
do
    local world = newWorld(6, true)
    seat(world, 6, { variant = "PLO", stackBB = 30, level = 10 })
    world.drop = 0.1
    play(world, "six lossy")
    verify(world, "six lossy", 6)
end

-- 3. nine players who only share a guild (every message is a whisper)
do
    local world = newWorld(9, false)
    seat(world, 9, { variant = "NL", stackBB = 20, level = 10 })
    play(world, "nine by whisper")
    verify(world, "nine by whisper", 9)
end

-- 4. five players: a guest reloads twice and the host once
do
    local world = newWorld(5, true)
    seat(world, 5, { variant = "NL", stackBB = 50, level = 10 })
    local reloads = 0
    local function reload(w, i)
        local old = client(w, i)
        local saved = old:Saved()
        old.dead = true
        w:Run(1)
        local fresh = w:Client(NAMES[i], old.party, saved, old.party)
        reloads = reloads + 1
        check(state(fresh) ~= nil, NAMES[i] .. "'s game comes back from saved variables after a reload")
        fresh.PK.Show()
    end
    play(world, "reload", function(step, w)
        local g = state(client(w, 1))
        if not g or g.match.over then return end
        if (reloads == 0 and step == 20) or (reloads == 1 and g.match.hand.n == 3 and step > 40) then reload(w, 3)
        elseif reloads == 2 and g.match.hand.n >= 5 then reload(w, 1) end
    end)
    check(reloads == 3 or state(client(world, 1)).match.hand.n < 5, "reloaded three times (or the game ended early): " .. reloads)
    verify(world, "reload", 5, { reloaded = true })
end

-- 5. leaving: a guest walks out, another stops answering and the host removes them
do
    local world = newWorld(4, true)
    seat(world, 4, { variant = "NL", stackBB = 100, level = 10 })
    world:Run(20)
    local dain = client(world, 4)
    dain.PK.Leave()
    world:Run(3)
    local hg = state(client(world, 1))
    local dSeat
    for i, n in ipairs(hg.names) do if n == "Dain" then dSeat = i end end
    check(hg.match.out[dSeat] == "left" or (hg.match.hand.left and hg.match.hand.left[dSeat]), "the host sees Dain leave")
    check(dain.env.FojjiCorePokerDB.l == 1, "walking out counts as a loss")
    check(state(dain) == nil, "Dain is back at the menu")
    -- Cara's game crashes and she never comes back: play until the table waits on her, then wait it out
    local cara = client(world, 3)
    local cSeat
    for i, n in ipairs(hg.names) do if n == "Cara" then cSeat = i end end
    cara.dead = true
    local removed = false
    play(world, "removal", function(_, w)
        local host = client(w, 1)
        local g = state(host)
        if removed or not g or g.match.over or g.match.out[cSeat] then return end
        if host.ns.Engine.Expect(g.match) == cSeat then
            w:Run(65)
            host.PK.Show()
            local bar = host.PK._win().bar
            check(bar.remove:IsShown(), "after a minute the host can remove Cara")
            -- the confirm dialog is FojjiCore's; call what it would
            check(host.ns.Table.Remove(cSeat), "the host removes Cara")
            removed = true
        end
    end)
    check(removed or state(client(world, 1)).match.over, "Cara was removed (or the game ended first)")
    verify(world, "leaving", 4, { skip = true })
    local m = state(client(world, 1)).match
    check(m.out[dSeat] == "left", "Dain is down as having left")
    local bob = state(client(world, 2))
    check(bob and bob.match.over and client(world, 2).ns.Engine.Snapshot(bob.match) == client(world, 1).ns.Engine.Snapshot(m),
        "Bob saw the same game to the end")
end

-- 6. the host closes the table mid-game
do
    local world = newWorld(3, true)
    seat(world, 3, { variant = "PLO", stackBB = 100, level = 0 })
    world:Run(15)
    client(world, 1).PK.Leave()
    world:Run(3)
    for i = 2, 3 do
        local g = state(client(world, i))
        check(g and g.ended == "closed", NAMES[i] .. " sees the table closed")
        check(client(world, i).PK._win().result:IsOpen(), NAMES[i] .. " gets the closed card")
    end
    check(client(world, 1).env.FojjiCorePokerDB.l == 1, "the host closing a live game counts as their loss")
    for _, c in ipairs(world.clients) do
        check(#c.reports == 0, "closing: no errors for " .. c.name .. ": " .. table.concat(c.reports, " | "))
    end
end

-- 7. the lobby: saying no, leaving, a full table, and options changing
do
    local world = newWorld(10, true)
    local host = client(world, 1)
    host.PK.Open()
    host.PK.Invite("Bob")
    host.PK.Invite("Cara")
    world:Run(1)
    check(client(world, 2).ns.Table.Decline("Alice"), "Bob can say no")
    check(client(world, 3).PK.Accept("Alice"), "Cara joins")
    world:Run(2)
    local _, L = state(host)
    check(#L.players == 2, "Bob isn't seated after saying no")
    check(host.PK.note and host.PK.note:find("Bob"), "the host hears Bob said no")
    -- changing the game reaches the guests
    local win = host.PK._win()
    host.env.FojjiCorePokerDB.variant = "PLO"
    host.ns.Table.SetOpts("PLO,100,0")
    world:Run(2)
    local _, cl = state(client(world, 3))
    check(cl and cl.opts == "PLO,100,0", "Cara sees the new options")
    -- Cara leaves the lobby
    client(world, 3).PK.Leave()
    world:Run(2)
    _, L = state(host)
    check(#L.players == 1, "Cara's seat is free again")
    -- nine is the most
    for i = 2, 9 do host.PK.Invite(NAMES[i]) end
    world:Run(1)
    for i = 2, 9 do client(world, i).PK.Accept("Alice") end
    world:Run(3)
    _, L = state(host)
    check(#L.players == 9, "nine seated")
    check(not host.ns.Table.Invite("Jory"), "a tenth can't be invited")
    check(win.lobby.go:IsEnabled(), "the host can start with nine")
    -- the host closes the lobby: everyone hears
    host.PK.Leave()
    world:Run(2)
    for i = 2, 9 do
        local _, l = state(client(world, i))
        check(l == nil, NAMES[i] .. " is out of the closed lobby")
    end
    -- nobody can start alone
    host.PK.Open()
    check(not host.ns.Table.Start(), "one player can't start")
    check(not win.lobby.go:IsEnabled(), "the Start button waits for a second player")
    for _, c in ipairs(world.clients) do
        check(#c.reports == 0, "lobby: no errors for " .. c.name .. ": " .. table.concat(c.reports, " | "))
    end
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
