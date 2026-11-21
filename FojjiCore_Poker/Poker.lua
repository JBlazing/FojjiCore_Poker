-- Poker for the FojjiCore games menu: No-Limit Hold'em and Pot-Limit Omaha for 2 to 9 players.
-- The host opens a table, invites people from their group or guild, and starts when 2 to 9 are
-- sitting. The rules live in Engine.lua and Eval.lua, the lobby and the messages in Table.lua; this
-- file runs the deal handshake and draws the window.
--
-- Nothing runs while no game is going. During a game the only timer is Table.lua's heartbeat, which
-- re-sends a lost message and asks the host to catch us up after one went missing.
local ADDON, ns = ...
local Addon = FojjiCoreNS
local Games = Addon and Addon.Games
if not (Games and Games.Register and Games.Window and Games.HeaderTools and Games.ResultCard
    and Games.PeopleRow and Games.Dress and ns.Table) then
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        DEFAULT_CHAT_FRAME:AddMessage("|cff66b3ffFojjiCore|r Poker needs FojjiCore Games 4.0.52 or newer, so it is switched off.")
    end)
    return
end
local FDJ = Games.Base
local Kit, C = FDJ.Kit, FDJ.Colors
local Engine, Eval, T = ns.Engine, ns.Eval, ns.Table
local floor, min, max, cos, sin, rad = math.floor, math.min, math.max, math.cos, math.sin, math.rad

local PK = {}
Games.Poker = PK
ns.PK = PK

local KEY = "poker"
local LABEL = "Poker"
local TEX = "Interface\\AddOns\\FojjiCore\\textures\\UI\\"
local MEDIA = Games.Media
local GOLD = Games.Gold or { 1.00, 0.82, 0.20 }
local SOFT = { 0.74, 0.76, 0.80 }
local GREEN = { 0.40, 0.86, 0.52 }
local commas = Games.Commas or function(n) return tostring(n) end

Games.Themes[KEY] = { accent = { 0.38, 0.86, 0.56 }, head = { 0.02, 0.08, 0.05 } }
local snd = Games.Sound(KEY)

local HELP = {
    "Poker for 2 to 9 friends, for play chips.",
    "Open a table, invite people from your group or guild, and start when everyone is sitting.",
    "No-Limit Hold'em: two cards each, bet any amount up to your stack.",
    "Pot-Limit Omaha: four cards each. Use exactly two of them with three from the board. The biggest bet is the size of the pot.",
    "The two players after the button post the blinds. Heads-up, the button posts the small blind.",
    "Lose every chip and you're out; the last player with chips wins the table.",
    "Each deck is shuffled from a secret of two players', so nobody can stack it.",
}

-- ---------------------------------------------------------------- saved settings
local function db()
    FojjiCorePokerDB = type(FojjiCorePokerDB) == "table" and FojjiCorePokerDB or {}
    local d = FojjiCorePokerDB
    d.secrets = type(d.secrets) == "table" and d.secrets or {}
    d.recent = type(d.recent) == "table" and d.recent or {}
    d.variant = Engine.VARIANTS[d.variant or ""] and d.variant or "NL"
    d.stackBB = tonumber(d.stackBB) or 100
    d.level = tonumber(d.level) or 0
    d.w, d.l = tonumber(d.w) or 0, tonumber(d.l) or 0
    return d
end
local function chosenOpts()
    local d = db()
    return Engine.OptsText({ variant = d.variant, stackBB = d.stackBB, level = d.level })
end
-- people you played with lately (for the Recent list)
local function remember(names)
    local d = db()
    for _, n in ipairs(names) do
        if not Games.Same(n, T.Me()) then
            for i = #d.recent, 1, -1 do if Games.Same(d.recent[i], n) then table.remove(d.recent, i) end end
            table.insert(d.recent, 1, n)
        end
    end
    while #d.recent > 12 do table.remove(d.recent) end
end

-- ---------------------------------------------------------------- names
local function short(n) return n and Games.Name(n) or "?" end
local function paintName(n) return "|cff" .. Games.ClassHex(short(n), true) .. short(n) .. "|r" end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
-- "Full house, Kings over Sevens" -> "Full house"
local function kind(name) return name and (name:match("^([^,]+)") or name) or nil end

-- ---------------------------------------------------------------- game state
local win
local paint, paintLobby -- the window (further down)
local function game() return T.game end
local function mySeat() return T.game and T.game.me end
local function playing() return T.Playing() end
-- I went bust, left, or was taken out, but the game goes on without me
local function iAmOut()
    local g = T.game
    if not g then return false end
    local m = g.match
    local h = m.hand
    return m.out[g.me] ~= nil or (h.left and h.left[g.me] ~= nil) or false
end
local function myTurn()
    local g = T.game
    if not playing() or g.pending then return false end
    local who, k = Engine.Expect(g.match)
    return who == g.me and k == "A"
end
local function nameAt(seat)
    local g = T.game
    return g and g.names[seat]
end

local function openWhenCalm()
    if Games.Fighting() and Games.CombatHideOn() then
        Games.AfterCombat(function() if T.game and not (win and win:IsShown()) then PK.Show() end end)
        return
    end
    PK.Show()
end

-- my result goes in the record once: when the game is won, or as soon as I'm out of it
local function settle()
    local g = T.game
    if not g then return end
    local m = g.match
    local d = db()
    if d.countedId == g.id then return end
    if m.over or m.place[g.me] then
        d.countedId = g.id
        if m.winner == g.me then d.w = d.w + 1 else d.l = d.l + 1 end
        snd.Play("chess-end")
    end
end

-- ---------------------------------------------------------------- the all-in runout
-- When the betting stops early because everyone is all-in, the engine deals the rest of the board in
-- one go. The window doesn't: it turns every hand still in over, drops the flop one card at a time,
-- slides the turn in face down and flips it, then holds on a face-down river before the last flip.
-- Only then does it say who won. The next deal waits for it (see RunLength in drive).
-- Each step: seconds after the previous one, how many board cards show, and whether the newest is
-- still face down.
local function runSteps(from)
    local steps = {}
    if from < 3 then
        steps[#steps + 1] = { 2.0, 1 }
        steps[#steps + 1] = { 0.3, 2 }
        steps[#steps + 1] = { 0.3, 3 }
    end
    if from < 4 then
        steps[#steps + 1] = { 1.8, 4, true }
        steps[#steps + 1] = { 0.9, 4 }
    end
    steps[#steps + 1] = { 1.8, 5, true }
    steps[#steps + 1] = { 2.2, 5 } -- the long one
    steps[#steps + 1] = { 1.2, "done" }
    return steps
end
function PK.RunLength(r)
    if not (r and r.showdown and r.runFrom) then return 0 end
    local t = 0
    for _, s in ipairs(runSteps(r.runFrom)) do t = t + s[1] end
    return t
end

local run -- { id, n = hand number, shown = board cards up, back = newest one face down, done = bool, pop = {} }
local function running(view)
    local g = T.game
    return run ~= nil and not run.done and view ~= nil and g ~= nil and run.id == g.id and view.n == run.n
end

local function startRun(l, onDone)
    local r = l.result
    local me = { id = T.game.id, n = l.n, shown = r.runFrom, pop = {}, flip = true }
    run = me
    local steps = runSteps(r.runFrom)
    local i = 1
    local function step()
        if run ~= me then return end
        local s = steps[i]
        i = i + 1
        if s[2] == "done" then
            me.done = true
            if onDone then onDone() end
        else
            local fresh = s[2] ~= me.shown or (me.back and not s[3])
            me.shown, me.back = s[2], s[3]
            if fresh and s[2] > 0 then
                me.pop[s[2]] = true
                snd.Play("chess-move")
            end
        end
        if win and win:IsShown() then paint() end
        if steps[i] then C_Timer.After(steps[i][1], step) end
    end
    if win and win:IsShown() then paint() end
    C_Timer.After(steps[1][1], step)
end

-- ---------------------------------------------------------------- the deal
-- The deal handshake runs by itself: whoever the engine is waiting on for K, S or R sends it.
-- After a hand there is a short pause so everyone can see how it ended.
local driveKey, driveAt = nil, 0
local function drive()
    local g = T.game
    if not playing() or g.pending then return end
    local who, k = Engine.Expect(g.match)
    if who ~= g.me or k == "A" then return end
    local m = g.match
    local h = m.hand
    local dkey = g.id .. ":" .. h.n .. ":" .. k .. ":" .. #h.log
    if driveKey == dkey and GetTime() - driveAt < 8 then return end
    driveKey, driveAt = dkey, GetTime()
    local wait = 0.3
    if k == "K" then
        local l = m.last
        if l and l.n == h.n - 1 and #h.log == 0 then
            wait = (l.result and l.result.showdown) and 5 + PK.RunLength(l.result) or 2.5
        else
            wait = h.n == 1 and 1.5 or 0.8
        end
    end
    C_Timer.After(wait, function()
        if driveKey ~= dkey or T.game ~= g or not playing() or g.match.hand ~= h or g.pending then return end
        local who2, k2 = Engine.Expect(g.match)
        if who2 ~= g.me or k2 ~= k then return end
        -- a whisper to someone offline only prints an error: the heartbeat tries again later
        if not T.IsHost() and not T.Reachable(g.host) then driveKey = nil return end
        local d = db()
        local slot = g.id .. ":" .. h.n
        if k == "K" then
            local secret = ("%d.%d.%d"):format(math.random(0, 16777215), math.random(0, 16777215), floor(GetTime() * 1000) % 1000000)
            d.secrets[slot] = secret
            T.Act("K" .. Engine.Commit(secret, m.salt, h.n))
        elseif k == "S" then
            T.Act("S" .. math.random(1, 2147483000))
        elseif k == "R" then
            local secret = d.secrets[slot]
            if secret and Engine.Commit(secret, m.salt, h.n) == h.commit then
                T.Act("R" .. secret)
            else
                T.Act("Z") -- the secret was lost (the game closed before it was saved): deal again
            end
        end
    end)
end

local seenHand, seenGame, alerted
local function afterChange(why, text)
    local g = T.game
    if not g then
        run = nil
        if win and win:IsShown() then paint() end
        Games.Notify(KEY)
        return
    end
    if seenGame ~= g.id then
        -- a different game: forget the last one's runout and sounds, keep only this game's secrets
        seenGame, seenHand, alerted, run = g.id, nil, nil, nil
        local d = db()
        for k in pairs(d.secrets) do
            if k:sub(1, #g.id + 1) ~= g.id .. ":" then d.secrets[k] = nil end
        end
        remember(g.names)
        if win and win.result and win.result:IsOpen() then win.result:Close() end
    end
    local m = g.match
    settle()
    if (why == "foe" or why == "me") and text and text:find("^[FXCB]") then snd.Play("chess-move") end
    -- a hand just finished: a little sound for the pot
    if m.last and m.last.n ~= seenHand then
        -- watched it end live (not a reload or a catch-up), so hand 1 counts too
        local live = seenHand ~= nil or why == "me" or why == "foe"
        seenHand = m.last.n
        local r = m.last.result
        local won = r and r.won and (r.won[g.me] or 0) > 0
        if live and r and r.showdown and r.runFrom then
            -- an all-in before the river: play the board out, and only cheer at the end
            startRun(m.last, function() if won then snd.Play("deathroll-win") end end)
        elseif live and won then
            snd.Play("deathroll-win")
        end
    end
    drive()
    if myTurn() then
        local akey = g.id .. ":" .. m.hand.n .. ":" .. #m.hand.log
        if alerted ~= akey and not (win and win:IsShown()) then
            alerted = akey
            FDJ.Print(("Poker: your turn (hand %d). Type /fc poker."):format(m.hand.n))
        end
    end
    if win and win:IsShown() then paint() end
    Games.Notify(KEY)
end

-- ---------------------------------------------------------------- the table's callbacks
PK.note = nil
T.cb.options = chosenOpts
T.cb.onChange = function(why, text)
    if why == "start" then
        local g = T.game
        local others = #g.names - 1
        FDJ.Print(("Poker: %s has begun with %d %s. %s"):format(Engine.Describe(g.opts), others,
            others == 1 and "other player" or "other players", T.IsHost() and "You're the host." or ""))
        snd.Play("chess-start")
        PK.note = nil
        afterChange(why, text)
        openWhenCalm()
        return
    end
    if why == "resume" then
        local g = T.game
        local function toast()
            if T.game ~= g or T.Over(g) then return end
            Kit.Toast("Your game of |cffffd100Poker|r is still going.", {
                { "Open", function() if T.game == g then PK.Show() end end },
            }, 40)
        end
        if Games.Fighting() then Games.AfterCombat(toast) else toast() end
    end
    if why == "end" then
        local g = T.game
        if g and g.ended == "closed" then
            FDJ.Print(("Poker: %s closed the table."):format(paintName(g.host)))
        end
    end
    afterChange(why, text)
end
T.cb.onTick = function()
    drive()
    -- the host's "Remove" button appears after a long wait, so repaint now and then
    if win and win:IsShown() and T.IsHost() then paint() end
end
T.cb.onNote = function(text)
    PK.note = text
    if win and win:IsShown() then paint() end
end
T.cb.onClosed = function(text)
    PK.note = text
    FDJ.Print("Poker: " .. text)
    if win and win:IsShown() then paint() end
end

local function showInvite(o)
    if T.Offer(o.host) ~= o or o.toast then return end
    o.toast = Kit.Toast(o.text, {
        { "Decline", function() T.Decline(o.host) if win and win:IsShown() then paint() end end },
        { "Join", function() PK.Accept(o.host) end },
    }, 60)
end
T.cb.onInvite = function(o)
    o.text = ("%s invites you to a table of |cffffd100Poker|r (%s)."):format(paintName(o.host), Engine.Describe(o.opts))
    FDJ.Print(o.text .. " Type |cffffd100/fc poker|r to answer.")
    if win and win:IsShown() then paint() end
    if Games.Fighting() then Games.AfterCombat(function() showInvite(o) end) return end
    showInvite(o)
end

-- ---------------------------------------------------------------- what the buttons do
local function report(ok, why)
    if not ok and why then PK.note = why end
    if win and win:IsShown() then paint() end
    return ok
end
function PK.Open()
    PK.note = nil
    return report(T.Open(chosenOpts()))
end
function PK.Invite(name)
    PK.note = nil
    local ok, why = T.Invite(name)
    if ok then PK.note = "Invite sent to " .. short(Games.Wire(trim(name))) .. "." end
    if ok and win and win.lobby then win.lobby.name:SetText("") end
    return report(ok, why)
end
function PK.InviteGroup()
    local n = T.InviteGroup()
    PK.note = n > 0 and ("Invited %d from your group."):format(n) or "Nobody else in your group to invite."
    return report(n > 0)
end
function PK.Start() return report(T.Start()) end
function PK.Accept(host)
    local o = T.Offer(host)
    if o and o.toast and o.toast.Dismiss then o.toast.Dismiss() end
    PK.note = nil
    local ok, why = T.Accept(host)
    if ok then PK.Show() end
    return report(ok, why)
end
-- leaves the lobby or the table; walking out of a game you're still in counts as a loss
function PK.Leave()
    local g = T.game
    if g and playing() and not iAmOut() then
        local d = db()
        if d.countedId ~= g.id then
            d.countedId = g.id
            d.l = d.l + 1
        end
    end
    T.Leave()
    PK.note = nil
    if win and win:IsShown() then paint() end
    Games.Notify(KEY)
end
PK.Menu = PK.Leave
PK.GiveUp = PK.Leave
-- after a game: a new table with the same people invited
function PK.NewTable()
    local g = T.game
    local names = g and g.names or {}
    T.Leave()
    T.Open(chosenOpts())
    local asked = 0
    for _, n in ipairs(names) do
        if not Games.Same(n, T.Me()) and T.Invite(n) then asked = asked + 1 end
    end
    PK.note = asked > 0 and ("Invited the %d from last game."):format(asked) or nil
    if win and win:IsShown() then paint() end
end

-- ---------------------------------------------------------------- cards
local CARD_U = 186 / 256
local function art(t, i)
    local a = i <= 35 and 1 or 2
    local k = (i - 1) % 35
    local col, row = k % 7, floor(k / 7)
    t:SetTexture(TEX .. "cards-" .. a)
    t:SetTexCoord(col * 144 / 1024, (col + 1) * 144 / 1024, row * 200 / 1024, (row + 1) * 200 / 1024)
end
-- the shadow and glow pictures are 256 square with the card drawn 150 x 206 inside them
local function around(t, f, grow, dx, dy)
    local w, h = f:GetSize()
    local sx, sy = w / 150, h / 206
    grow = grow or 0
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", f, "TOPLEFT", -34 * sx - grow + (dx or 0), 24 * sy + grow + (dy or 0))
    t:SetSize(256 * sx + 2 * grow, 256 * sy + 2 * grow)
end
local function newCard(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(58, 80)
    f.shadow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.shadow:SetTexture(TEX .. "card-shadow")
    f.shadow:SetAlpha(0.55)
    f.slot = f:CreateTexture(nil, "BORDER")
    f.slot:SetAllPoints()
    f.slot:SetTexture(TEX .. "card-slot")
    f.slot:SetTexCoord(0, CARD_U, 0, 1)
    f.slot:SetAlpha(0.45)
    f.art = f:CreateTexture(nil, "ARTWORK")
    f.art:SetAllPoints()
    f.glow = f:CreateTexture(nil, "OVERLAY", nil, 6)
    f.glow:SetTexture(TEX .. "card-glow")
    f.glow:SetBlendMode("ADD")
    f.glow:SetVertexColor(1, 0.82, 0.36, 0.9)
    f.glow:Hide()
    f.dim = f:CreateTexture(nil, "OVERLAY", nil, 7)
    f.dim:SetAllPoints()
    f.dim:SetColorTexture(0, 0, 0, 0.5)
    f.dim:Hide()
    -- a card landing (the runout): it fades in under a quick gold flash
    f.flash = f:CreateTexture(nil, "OVERLAY", nil, 5)
    f.flash:SetTexture(TEX .. "card-glow")
    f.flash:SetBlendMode("ADD")
    f.flash:SetVertexColor(1, 0.9, 0.55, 1)
    f.flash:Hide()
    f.landing = f:CreateAnimationGroup()
    local fade = f.landing:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.22)
    fade:SetSmoothing("OUT")
    f.flashing = f.flash:CreateAnimationGroup()
    local burn = f.flashing:CreateAnimation("Alpha")
    burn:SetFromAlpha(1)
    burn:SetToAlpha(0)
    burn:SetDuration(0.7)
    burn:SetSmoothing("IN")
    f.flashing:SetScript("OnFinished", function() f.flash:Hide() end)
    -- big: a flip worth a bigger flash
    function f:Land(big)
        self.landing:Stop()
        self.landing:Play()
        self.flashing:Stop()
        burn:SetFromAlpha(big and 1 or 0.55)
        self.flash:Show()
        self.flashing:Play()
    end
    function f:Fit(w, h)
        self:SetSize(w, h)
        around(self.shadow, self, 0, 1, -2)
        around(self.glow, self, 3)
        around(self.flash, self, 6)
    end
    -- c: a card number (face up), true (face down), nil (an empty spot), false (nothing at all)
    -- look: "win" (glowing) or "dim"
    function f:Set(c, look)
        if c == false then self:Hide() return end
        self:Show()
        if c == nil then
            self.art:Hide()
            self.shadow:Hide()
            self.slot:Show()
        else
            self.slot:Hide()
            self.shadow:Show()
            self.art:Show()
            if self.shown ~= c then art(self.art, c == true and 53 or c) end
        end
        self.shown = c
        self.glow:SetShown(look == "win" and c ~= nil)
        self.dim:SetShown(look == "dim" and c ~= nil)
    end
    f:Fit(58, 80)
    return f
end

-- ---------------------------------------------------------------- the window
local W, H, HEAD, BAR = 900, 640, 38, 104
local TH = H - HEAD - 8 - BAR -- table height
local RX, RY = 345, 178        -- the ellipse the other seats sit on, from the middle of the felt
local ME_Y = -185              -- your own cards, near the bottom edge
-- where the other seats go for each table size, as angles (degrees, 90 is the top). The first is the
-- player on your left, then round the table the way the deal goes.
local ANGLES = {
    [2] = { 90 },
    [3] = { 150, 30 },
    [4] = { 180, 90, 0 },
    [5] = { 200, 130, 50, -20 },
    [6] = { 205, 145, 90, 35, -25 },
    [7] = { 210, 160, 115, 65, 20, -30 },
    [8] = { 215, 170, 128, 90, 52, 10, -35 },
    [9] = { 218, 180, 140, 105, 75, 40, 0, -38 },
}

local function newPlate(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(150, 50)
    Games.Panel(p, "dark")
    p.ring = p:CreateTexture(nil, "BACKGROUND", nil, -1)
    p.ring:SetPoint("TOPLEFT", -2, 2)
    p.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    p.ring:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.85)
    p.ring:Hide()
    p.name = Kit.Text(p, 12, C.white)
    p.name:SetPoint("TOPLEFT", 9, -8)
    p.name:SetPoint("RIGHT", -30, 0)
    p.stack = Kit.Text(p, 14, GOLD)
    p.stack:SetPoint("BOTTOMLEFT", 9, 7)
    p.tag = Kit.Text(p, 10, SOFT, "RIGHT")
    p.tag:SetPoint("BOTTOMRIGHT", -8, 9)
    p.button = Games.Chip(p, 18, 18)
    p.button:SetPoint("TOPRIGHT", -6, -6)
    p.button:SetFill(0.95, 0.93, 0.86, 1)
    p.button.text:SetText("D")
    p.button.text:SetTextColor(0.1, 0.1, 0.1)
    -- ring colours: green for whoever is to act, gold for a pot's winner
    function p:Ring(color)
        if not color then self.ring:Hide() return end
        self.ring:SetColorTexture(color[1], color[2], color[3], 0.85)
        self.ring:Show()
    end
    return p
end
local function newBet(parent)
    local b = Games.Chip(parent, 80, 22)
    b:SetEdge(GOLD[1], GOLD[2], GOLD[3], 0.8)
    b.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    return b
end

-- a seat: the name plate, the hole cards and the chips bet this street
local function newSeat(parent, mine)
    local s = { mine = mine }
    s.frame = CreateFrame("Frame", nil, parent)
    s.frame:SetSize(150, 84)
    s.plate = newPlate(s.frame)
    s.row = CreateFrame("Frame", nil, s.frame)
    s.cards = {}
    for i = 1, 4 do s.cards[i] = newCard(s.row) end
    s.bet = newBet(parent)
    return s
end

local function buildLobby(f)
    local lobby = CreateFrame("Frame", nil, f)
    lobby:SetPoint("TOPLEFT", 1, -(HEAD + 1))
    lobby:SetPoint("BOTTOMRIGHT", -1, 1)
    lobby:SetFrameLevel(f:GetFrameLevel() + 40)
    lobby:EnableMouse(true)
    local shade = lobby:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.6)
    local card = CreateFrame("Frame", nil, lobby)
    card:SetSize(560, 490)
    card:SetPoint("CENTER")
    Games.Panel(card)
    local CW = 528
    local function caption(text, y)
        local t = Kit.Text(card, 11, SOFT)
        t:SetPoint("TOPLEFT", 16, y)
        t:SetText(text)
        return t
    end
    local function rule(y)
        local t = card:CreateTexture(nil, "ARTWORK")
        t:SetPoint("TOPLEFT", 16, y)
        t:SetPoint("TOPRIGHT", -16, y)
        t:SetHeight(1)
        t:SetColorTexture(C.borderDim[1], C.borderDim[2], C.borderDim[3], 1)
    end
    local function picker(y, defs, field)
        local g = Kit.Segmented(card, defs, function(k)
            db()[field] = k
            T.SetOpts(chosenOpts())
            paintLobby()
        end)
        g:SetSize(CW, 26)
        g:SetPoint("TOPLEFT", 16, y)
        g:Layout()
        return g
    end
    -- the game: pickers for the host (or before there's a table), the host's choice for a guest
    lobby.captions = {
        caption("GAME", -14),
        caption("STARTING STACK", -68),
        caption("BLINDS", -122),
    }
    lobby.variant = picker(-32, { { "NL", "No-Limit Hold'em" }, { "PLO", "Pot-Limit Omaha" } }, "variant")
    lobby.stack = picker(-86, { { 50, "50 big blinds" }, { 100, "100 big blinds" }, { 200, "200 big blinds" } }, "stackBB")
    lobby.level = picker(-140, { { 0, "Never go up" }, { 20, "Up every 20 hands" }, { 10, "Up every 10 hands" } }, "level")
    lobby.chosen = Kit.Text(card, 14, C.white)
    lobby.chosen:SetPoint("TOPLEFT", 16, -36)
    lobby.chosen:SetWidth(CW)
    lobby.summary = Kit.Text(card, 12, C.text)
    lobby.summary:SetPoint("TOPLEFT", 16, -176)
    lobby.summary:SetWidth(CW)
    rule(-198)

    -- who is sitting: nine seats in three columns
    lobby.tableCap = caption("THE TABLE", -210)
    lobby.count = Kit.Text(card, 11, SOFT, "RIGHT")
    lobby.count:SetPoint("TOPRIGHT", -16, -210)
    lobby.seats = {}
    for i = 1, Engine.MAX_SEATS do
        local t = Kit.Text(card, 12, C.white)
        local col, row = (i - 1) % 3, floor((i - 1) / 3)
        t:SetPoint("TOPLEFT", 16 + col * 178, -230 - row * 20)
        t:SetWidth(172)
        lobby.seats[i] = t
    end
    rule(-296)

    -- inviting
    lobby.inviteCap = caption("INVITE FRIENDS", -308)
    lobby.name = Kit.Input(card, 288, 26, "Their name", nil, function() PK.Invite(lobby.name:GetText()) end)
    lobby.name:SetPoint("TOPLEFT", 16, -326)
    lobby.invite = Kit.Button(card, "Invite", 100, 26, function() PK.Invite(lobby.name:GetText()) end)
    lobby.invite:SetPoint("LEFT", lobby.name, "RIGHT", 8, 0)
    lobby.group = Kit.Button(card, "Invite group", 124, 26, function() PK.InviteGroup() end)
    lobby.group:SetPoint("TOPRIGHT", -16, -326)
    lobby.people = Games.PeopleRow(card, function(n) lobby.name:SetText(n or "") end, function() return db().recent end)
    lobby.people:SetPoint("TOPLEFT", 16, -360)
    lobby.note = Kit.Text(card, 11, SOFT)
    lobby.note:SetPoint("TOPLEFT", 16, -392)
    lobby.note:SetWidth(CW - 110)
    lobby.join = Kit.Button(card, "Join", 96, 24, function()
        local o = T.LatestOffer()
        if o then PK.Accept(o.host) end
    end, "primary")
    lobby.join:SetPoint("TOPRIGHT", -16, -388)
    lobby.need = Kit.Text(card, 11, SOFT)
    lobby.need:SetPoint("TOPLEFT", 16, -412)
    lobby.need:SetWidth(CW)
    lobby.need:SetText("Everyone needs FojjiCore Games and FojjiCore Poker. Play chips only.")
    rule(-434)

    lobby.record = Kit.Text(card, 12, C.white)
    lobby.record:SetPoint("BOTTOMLEFT", 16, 20)
    lobby.go = Kit.Button(card, "Open a table", 150, 28, function()
        if T.lobby and T.IsHost() then PK.Start() elseif not T.lobby then PK.Open() end
    end, "primary")
    lobby.go:SetPoint("BOTTOMRIGHT", -16, 14)
    lobby.leave = Kit.Button(card, "Close table", 110, 28, function() PK.Leave() end)
    lobby.leave:SetPoint("RIGHT", lobby.go, "LEFT", -8, 0)
    f.lobby = lobby
end

local function setEnabled(b, on)
    if b:IsEnabled() ~= on then
        if on then b:Enable() else b:Disable() end
        if b.Paint then b:Paint() end
    end
end

paintLobby = function()
    local f = win
    if not f then return end
    local L, d = f.lobby, db()
    local lob = T.lobby
    local host = lob == nil or T.IsHost()
    -- the game being set up
    for _, c in ipairs(L.captions) do c:SetShown(host) end
    L.variant:SetShown(host)
    L.stack:SetShown(host)
    L.level:SetShown(host)
    L.chosen:SetShown(not host)
    if host then
        if L.variant.value ~= d.variant then L.variant:Select(d.variant, true) end
        if L.stack.value ~= d.stackBB then L.stack:Select(d.stackBB, true) end
        if L.level.value ~= d.level then L.level:Select(d.level, true) end
    end
    local opts = lob and lob.opts or chosenOpts()
    local o = Engine.ParseOpts(opts)
    local sb, bb = Engine.Blinds(o, 1)
    if not host then
        L.chosen:SetText(("%s's table\n\n|cffd8dbe0%s|r"):format(paintName(lob.host), Engine.Describe(opts)))
    end
    L.summary:SetText(("Everyone starts with %s chips. Blinds %s / %s."):format(commas(o.stackBB * Engine.UNIT), commas(sb), commas(bb)))

    -- the seats
    local players = lob and lob.players or {}
    for i = 1, Engine.MAX_SEATS do
        local n = players[i]
        if n then
            L.seats[i]:SetText(("%d  %s%s"):format(i, paintName(n), i == 1 and "  |cffaeb3bc(host)|r" or ""))
        elseif lob then
            L.seats[i]:SetText(("|cff5f636b%d  open seat|r"):format(i))
        else
            L.seats[i]:SetText(i == 1 and "|cffaeb3bcOpen a table, then invite up to eight friends.|r" or "")
        end
    end
    local waiting = 0
    if lob and lob.invited then for _ in pairs(lob.invited) do waiting = waiting + 1 end end
    L.count:SetText(lob and (("%d of %d seated%s"):format(#players, Engine.MAX_SEATS,
        waiting > 0 and ("  ·  %d invited"):format(waiting) or "")) or "")

    -- inviting is for the host (inviting before there's a table opens one)
    L.inviteCap:SetShown(host)
    L.name:SetShown(host)
    L.invite:SetShown(host)
    L.group:SetShown(host)
    L.people:SetShown(host)
    setEnabled(L.group, FDJ.GroupChannel() ~= nil)

    local offer = not lob and T.LatestOffer()
    L.join:SetShown(offer and true or false)
    if offer then
        L.note:SetText(("%s invited you (%s)."):format(paintName(offer.host), Engine.Describe(offer.opts)))
    elseif lob and lob.joining then
        L.note:SetText("Joining " .. paintName(lob.host) .. "'s table...")
    elseif lob and not host then
        L.note:SetText(PK.note or ("Waiting for " .. paintName(lob.host) .. " to start the game..."))
    else
        L.note:SetText(PK.note or (lob and "Invite friends, then start with 2 to 9 players." or "Pick a game and open a table."))
    end

    -- the big buttons
    if not lob then
        L.go:SetLabel("Open a table")
        L.go:Show()
        setEnabled(L.go, true)
        L.leave:Hide()
    elseif host then
        L.go:SetLabel(#players >= 2 and ("Start: %d players"):format(#players) or "Start")
        L.go:Show()
        setEnabled(L.go, #players >= 2)
        L.leave:SetLabel("Close table")
        L.leave:Show()
    else
        L.go:Hide()
        L.leave:SetLabel("Leave")
        L.leave:Show()
    end
    L.go:SetWidth(150)
    L.leave:SetWidth(110)
    local total = d.w + d.l
    L.record:SetText(total == 0 and "|cffaeb3bcNo games yet.|r" or ("Won %d  |cffaeb3bc·|r  Lost %d"):format(d.w, d.l))
end

-- the raise amount being picked, as "raise to" this street's total
local amount, amountKey
local function decisionKey()
    local g = T.game
    return g and (g.id .. ":" .. g.match.hand.n .. ":" .. #g.match.hand.log)
end
local function clampAmount(L, v)
    v = floor(tonumber(v) or L.minTo)
    return max(L.minTo, min(L.maxTo, v))
end
local function presetAmount(L, which)
    if which == "min" then return L.minTo end
    if which == "max" then return L.maxTo end
    local m = T.game.match
    local high = Engine.HighBet(m)
    local potAfterCall = Engine.Pot(m) + L.toCall
    return clampAmount(L, high + floor(potAfterCall * which + 0.5))
end
local function legal() return T.game and Engine.Legal(T.game.match) end
local function act(text)
    local ok, why = T.Act(text)
    if not ok and why then FDJ.Print("Poker: that didn't go through (" .. tostring(why) .. ").") end
    return ok
end

local function buildBar(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", -1, 1)
    bar:SetHeight(BAR)
    Kit.Line(bar, "TOP", C.borderDim)
    f.bar = bar

    bar.giveUp = Kit.Button(bar, "Leave", 96, 28, function()
        local g = T.game
        if playing() and not iAmOut() then
            local text = T.IsHost() and "Leave and close the table for everyone?" or "Leave the table? Your chips leave with you."
            Kit.Confirm(text, PK.Leave)
        else
            PK.Leave()
        end
    end)
    bar.giveUp:SetPoint("BOTTOMLEFT", 12, 12)
    -- the host can take out a player who stopped answering
    bar.remove = Kit.Button(bar, "Remove", 150, 28, function()
        local g = T.game
        local seat = g and Engine.Expect(g.match)
        if not (seat and seat ~= g.me and T.IsHost()) then return end
        Kit.Confirm(("Take %s out of the game? Their chips leave the table."):format(short(g.names[seat])), function()
            T.Remove(seat)
        end)
    end)
    bar.remove:SetPoint("LEFT", bar.giveUp, "RIGHT", 8, 0)
    bar.remove:Hide()

    bar.raise = Kit.Button(bar, "Raise", 160, 30, function()
        local L = legal()
        if L and L.minTo and myTurn() then act("B" .. clampAmount(L, amount)) end
    end, "primary")
    bar.raise:SetPoint("BOTTOMRIGHT", -12, 12)
    bar.call = Kit.Button(bar, "Call", 130, 30, function()
        local L = legal()
        if L and myTurn() then act(L.check and "X" or "C") end
    end)
    bar.call:SetPoint("RIGHT", bar.raise, "LEFT", -8, 0)
    bar.fold = Kit.Button(bar, "Fold", 96, 30, function()
        local L = legal()
        if L and L.fold and myTurn() then act("F") end
    end)
    bar.fold:SetPoint("RIGHT", bar.call, "LEFT", -8, 0)

    -- sizing: presets, a slider and the number
    local sizing = CreateFrame("Frame", nil, bar)
    sizing:SetPoint("TOPRIGHT", -12, -10)
    sizing:SetSize(454, 26)
    bar.sizing = sizing
    bar.input = Kit.Input(sizing, 84, 26, "", function(_, text, user)
        if not user then return end
        local L = legal()
        local v = tonumber(text)
        if L and L.minTo and v then
            amount = clampAmount(L, v)
            if bar.slider then bar.slider.quiet = true bar.slider:SetValue(amount) bar.slider.quiet = false end
            PK.PaintRaise()
        end
    end, function(self)
        local L = legal()
        if L and L.minTo then
            amount = clampAmount(L, self:GetText())
            self:SetText(tostring(amount))
            PK.PaintRaise()
        end
    end)
    bar.input:SetPoint("RIGHT", 0, 0)
    bar.input:SetNumeric(true)
    local sl = CreateFrame("Slider", nil, sizing)
    sl:SetOrientation("HORIZONTAL")
    sl:SetSize(120, 16)
    sl:SetPoint("RIGHT", bar.input, "LEFT", -12, 0)
    sl:SetHitRectInsets(0, 0, -6, -6)
    local track = sl:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    track:SetColorTexture(C.borderDim[1], C.borderDim[2], C.borderDim[3], 1)
    sl:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = sl:GetThumbTexture()
    thumb:SetSize(10, 18)
    thumb:SetVertexColor(GREEN[1], GREEN[2], GREEN[3], 1)
    sl:SetMinMaxValues(0, 1)
    sl:SetValueStep(1)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
    sl:EnableMouseWheel(true)
    sl:SetScript("OnMouseWheel", function(self, delta)
        local L = legal()
        if not (L and L.minTo) then return end
        self:SetValue(clampAmount(L, (amount or L.minTo) + delta * T.game.match.hand.bb))
    end)
    sl:SetScript("OnValueChanged", function(self, v)
        if self.quiet then return end
        local L = legal()
        if not (L and L.minTo) then return end
        amount = clampAmount(L, floor(v + 0.5))
        bar.input:SetText(tostring(amount))
        PK.PaintRaise()
    end)
    bar.slider = sl
    local presets = { { "Min", "min" }, { "½ Pot", 0.5 }, { "¾ Pot", 0.75 }, { "Pot", 1 }, { "Max", "max" } }
    bar.presets = {}
    local prev
    for i = #presets, 1, -1 do
        local p = presets[i]
        local b = Kit.Button(sizing, p[1], 42, 24, function()
            local L = legal()
            if not (L and L.minTo) then return end
            amount = presetAmount(L, p[2])
            sl.quiet = true
            sl:SetValue(amount)
            sl.quiet = false
            bar.input:SetText(tostring(amount))
            PK.PaintRaise()
        end, "flat")
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("RIGHT", sl, "LEFT", -12, 0) end
        prev = b
        bar.presets[i] = b
    end

    bar.wait = Kit.Text(bar, 13, SOFT, "RIGHT")
    bar.wait:SetPoint("BOTTOMRIGHT", -16, 20)
end

function PK.PaintRaise()
    local bar = win and win.bar
    local L = myTurn() and legal()
    if not (bar and L and L.minTo) then return end
    local a = clampAmount(L, amount)
    local word = a == L.allinTo and "All-in" or (L.bet and "Bet" or "Raise to")
    bar.raise:SetLabel(word .. " " .. commas(a))
    bar.raise:SetWidth(160)
end

local function build()
    local f = Kit.Window("FojjiCorePoker", LABEL, W, H)
    Games.Dress(f, KEY)
    f:SetFrameStrata("DIALOG")
    win = f
    snd.frame = f

    -- the felt
    local t = CreateFrame("Frame", nil, f)
    t:SetPoint("TOPLEFT", 10, -(HEAD + 8))
    t:SetPoint("TOPRIGHT", -10, -(HEAD + 8))
    t:SetHeight(TH - 4)
    local felt = t:CreateTexture(nil, "BACKGROUND")
    felt:SetAllPoints()
    felt:SetTexture(MEDIA .. "sol-felt")
    felt:SetTexCoord(0, 1, 0.12, 0.88)
    Kit.Edge(t, { 0, 0, 0 }, 0.6)
    f.felt = t

    f.handInfo = Kit.Text(t, 11, SOFT)
    f.handInfo:SetPoint("TOPLEFT", 12, -10)
    f.gameInfo = Kit.Text(t, 11, SOFT, "RIGHT")
    f.gameInfo:SetPoint("TOPRIGHT", -12, -10)

    -- the seats: your own (big cards at the bottom) and up to eight others round the table
    f.mine = newSeat(t, true)
    f.others = {}
    for i = 1, Engine.MAX_SEATS - 1 do f.others[i] = newSeat(t, false) end
    -- your hand so far ("Two pair, Kings and Sevens"), beside your cards while a hand is being bet
    f.myHand = Kit.Text(t, 12, GOLD, "LEFT")
    f.myHand:SetWidth(170)

    f.board = CreateFrame("Frame", nil, t)
    f.board:SetSize(5 * 56 + 4 * 6, 78)
    f.board:SetPoint("CENTER", 0, 20)
    for i = 1, 5 do
        local c = newCard(f.board)
        c:Fit(56, 78)
        c:SetPoint("LEFT", (i - 1) * 62, 0)
        f.board[i] = c
    end
    f.pot = Kit.Text(t, 14, GOLD, "CENTER")
    f.pot:SetPoint("BOTTOM", f.board, "TOP", 0, 8)
    f.status = Kit.Text(t, 13, C.white, "CENTER")
    f.status:SetPoint("TOP", f.board, "BOTTOM", 0, -8)
    f.status:SetWidth(520)

    buildBar(f)
    buildLobby(f)
    f.result = Games.ResultCard(t)

    Games.HeaderTools(f, { help = HELP, sound = snd })
    f:HookScript("OnShow", function() paint() end)
    Games.Window(f, KEY)
    return f
end

-- places every seat for a table of n with you at the bottom, and sizes the cards for k hole cards
local function layoutSeats(n, k, me)
    local lkey = n .. ":" .. k .. ":" .. me
    if win.laidOut == lkey then return end
    win.laidOut = lkey
    local t = win.felt
    -- yours: the plate on the left of big cards
    local s = win.mine
    local w, h, gap = 58, 80, 6
    if k == 4 then w, h, gap = 50, 70, 4 end
    local rowW = k * w + (k - 1) * gap
    s.row:SetParent(t)
    s.row:ClearAllPoints()
    s.row:SetSize(rowW, h)
    s.row:SetPoint("CENTER", t, "CENTER", 0, ME_Y)
    for i = 1, 4 do
        s.cards[i]:Fit(w, h)
        s.cards[i]:ClearAllPoints()
        s.cards[i]:SetPoint("LEFT", (i - 1) * (w + gap), 0)
    end
    s.plate:SetParent(t)
    s.plate:ClearAllPoints()
    s.plate:SetPoint("RIGHT", s.row, "LEFT", -10, 0)
    s.bet:ClearAllPoints()
    s.bet:SetPoint("BOTTOM", s.row, "TOP", 0, 12)
    win.myHand:ClearAllPoints()
    win.myHand:SetPoint("LEFT", s.row, "RIGHT", 12, 0)
    -- everyone else: smaller cards above the plate; a crowded table gets smaller ones still
    local cw, ch = 40, 56
    if n > 4 then cw, ch = 30, 42 end
    local angles = ANGLES[n] or {}
    for i, o in ipairs(win.others) do
        local a = angles[i]
        o.frame:SetShown(a ~= nil)
        o.bet:Hide()
        if a then
            local x, y = RX * cos(rad(a)), RY * sin(rad(a))
            o.frame:ClearAllPoints()
            o.frame:SetSize(150, 50 + ch - 8)
            o.frame:SetPoint("CENTER", t, "CENTER", x, y)
            o.plate:ClearAllPoints()
            o.plate:SetPoint("BOTTOM", o.frame, "BOTTOM", 0, 0)
            local cg = 3
            o.row:ClearAllPoints()
            o.row:SetSize(k * cw + (k - 1) * cg, ch)
            o.row:SetPoint("BOTTOM", o.plate, "TOP", 0, -8)
            o.row:SetFrameLevel(o.plate:GetFrameLevel() - 1)
            for c = 1, 4 do
                o.cards[c]:Fit(cw, ch)
                o.cards[c]:ClearAllPoints()
                o.cards[c]:SetPoint("LEFT", (c - 1) * (cw + cg), 0)
            end
            -- the chips go between the seat and the middle of the table
            o.bet:ClearAllPoints()
            o.bet:SetPoint("CENTER", t, "CENTER", x * 0.6, y * 0.55)
        end
    end
end

-- the seat widgets for a seat number (you are always the one at the bottom)
local function seatWidgets(seat)
    local g = T.game
    local n = g.match.seats
    local p = (seat - g.me) % n
    if p == 0 then return win.mine end
    return win.others[p]
end

local function shortSaid(said)
    if not said then return nil end
    local k, amt = said[1], said[2]
    if said.allin then return "All-in" end
    if k == "fold" then return "Fold" end
    if k == "left" then return "Left" end
    if k == "check" then return "Check" end
    if k == "call" then return "Call" end
    if k == "bet" then return "Bet " .. commas(amt) end
    if k == "raise" then return "Raise " .. commas(amt) end
    return nil
end

local function who(seat, me)
    return seat == me and "You" or paintName(nameAt(seat))
end
local function joinNames(seats, me)
    local parts = {}
    for i, s in ipairs(seats) do parts[i] = who(s, me) end
    if #parts <= 1 then return parts[1] or "" end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end
local function statusFor(view, me)
    local r = view.result
    if not r then return nil end
    if not r.showdown then
        local w = r.winner
        if not w or w == 0 then return "" end
        return ("%s %s %s."):format(who(w, me), w == me and "win" or "wins", commas(r.pot))
    end
    local parts = {}
    for i, p in ipairs(r.pots or {}) do
        local ws = p.winners
        local what = commas(p.amount)
        if #r.pots > 1 then what = (i == 1 and "the main pot" or "a side pot") .. " (" .. what .. ")" end
        local hand = r.names[ws[1]] or ""
        if #ws == 1 then
            parts[#parts + 1] = ("%s %s %s with %s"):format(who(ws[1], me), ws[1] == me and "win" or "wins", what, hand)
        else
            parts[#parts + 1] = ("%s split %s with %s"):format(joinNames(ws, me), what, hand)
        end
    end
    return table.concat(parts, ".  ") .. "."
end

local function clearTable(f)
    if f.result:IsOpen() then f.result:Close() end
    f.mine.plate:Hide()
    f.mine.row:Hide()
    f.mine.bet:Hide()
    for _, o in ipairs(f.others) do
        o.frame:Hide()
        o.bet:Hide()
    end
    for i = 1, 5 do f.board[i]:Set(nil) end
    f.pot:SetText("")
    f.status:SetText("")
    f.handInfo:SetText("")
    f.gameInfo:SetText("")
    f.myHand:SetText("")
    f.bar:Hide()
end

paint = function()
    local f = win
    if not f then return end
    local g = T.game
    f.lobby:SetShown(g == nil)
    if not g then
        clearTable(f)
        paintLobby()
        return
    end
    f.bar:Show()
    f.mine.plate:Show()
    f.mine.row:Show()
    local m = g.match
    local me, N = g.me, m.seats
    local h = m.hand
    local predeal = h.phase == "commit" or h.phase == "seed" or h.phase == "reveal"
    local view = h
    if (m.over or predeal) and m.last then view = m.last end
    local showingLast = view ~= h
    local closed = g.ended ~= nil
    -- an all-in board still being played out (a match-ending all-in is both last and current hand)
    local rolling = running(view) and view.result ~= nil and not closed
    local k = Engine.Cards(m)
    layoutSeats(N, k, me)

    local r = view.result
    local dealt = view.phase == "bet" or view.phase == "done"
    -- the main pot's winning cards glow
    local winSet = {}
    if r and r.showdown and not rolling and r.pots and r.pots[1] then
        for _, seat in ipairs(r.pots[1].winners) do
            for _, c in ipairs(r.best[seat] or {}) do winSet[c] = true end
        end
    end

    -- the board
    local shown = dealt and Engine.BoardShown(view) or 0
    if rolling then shown = run.shown end
    for i = 1, 5 do
        local c = i <= shown and view.board[i] or nil
        local back = rolling and run.back and i == shown
        f.board[i]:Set(back and true or c, c and winSet[c] and "win" or nil)
        if rolling and run.pop[i] then
            run.pop[i] = nil
            -- the turn and river flipping over get the big flash
            f.board[i]:Land(i >= 4 and not back)
        end
    end
    -- during the runout, each player's hand so far ("Pair of Kings") from the cards face up
    local ev = m.opts.variant == "PLO" and Eval.Omaha or Eval.Holdem
    local upNow = rolling and (run.back and shown - 1 or shown) or 0
    local function soFar(seat)
        if upNow < 3 then return "All-in" end
        local board = {}
        for i = 1, upNow do board[i] = view.board[i] end
        local sc = ev(view.holes[seat], board)
        return sc and kind(Eval.Name(sc)) or "All-in"
    end
    -- your own hand while the betting is on
    local mine = ""
    if not showingLast and not rolling and h.phase == "bet" and h.inHand[me] and not h.folded[me] then
        local board = {}
        for i = 1, shown do board[i] = h.board[i] end
        mine = Eval.Current(h.holes[me], board, m.opts.variant == "PLO")
    end
    f.myHand:SetText(mine)

    -- the seats
    local stacks = showingLast and view.endStacks or m.stacks
    if rolling then
        -- the pot isn't pushed until the river is out
        stacks = {}
        for i = 1, N do stacks[i] = view.endStacks[i] - (r.won[i] or 0) end
    end
    for seat = 1, N do
        local s = seatWidgets(seat)
        local p = s.plate
        local name = nameAt(seat)
        p.name:SetText(paintName(name))
        p.button:SetShown(view.button == seat and view.inHand[seat])
        local out = view.startOut[seat]
        local left = view.left and view.left[seat]
        local folded = view.folded[seat]
        local live = view.inHand[seat] and not folded
        local won = r and not rolling and (r.won[seat] or 0) > 0
        if out then
            p.stack:SetText(out == "left" and "Left" or "Out")
            p.tag:SetText(view.startPlace[seat] and Engine.Ordinal(view.startPlace[seat]) or "")
            p:SetAlpha(0.4)
        else
            p.stack:SetText(left and "Left" or commas(stacks[seat]))
            local tag
            if rolling and live then tag = soFar(seat)
            elseif r and r.showdown and live then tag = kind(r.names[seat])
            elseif won and not r.showdown then tag = "Wins " .. commas(r.won[seat])
            elseif left then tag = "Left"
            elseif folded then tag = "Fold"
            else tag = shortSaid(view.said[seat]) end
            if not tag and not showingLast then
                if stacks[seat] == 0 and live then tag = "All-in"
                elseif seat == view.sbSeat then tag = "SB"
                elseif seat == view.bbSeat then tag = "BB" end
            end
            p.tag:SetText(tag or "")
            p:SetAlpha((folded or left) and 0.55 or 1)
        end
        if won then p:Ring(GOLD)
        elseif not showingLast and h.phase == "bet" and h.toAct == seat then p:Ring(GREEN)
        else p:Ring(nil) end

        -- hole cards: yours face up; everyone still in at a showdown (or an all-in runout) face up too
        local faceUp = seat == me or (r and r.showdown and live)
        for i = 1, 4 do
            local card = s.cards[i]
            if i > k or out or not view.inHand[seat] then
                card:Set(false)
            elseif not dealt then
                card:Set(nil)
            elseif folded and seat ~= me then
                card:Set(false)
            else
                local c = view.holes[seat][i]
                local look = folded and "dim" or (winSet[c] and "win" or nil)
                card:Set(faceUp and c or true, look)
                -- the runout begins: their hands turn over
                if rolling and run.flip and seat ~= me and live then card:Land(true) end
            end
        end

        local bet = (showingLast or out) and 0 or h.bet[seat]
        if bet > 0 then
            s.bet.text:SetText(commas(bet))
            s.bet:SetWidth(max(56, s.bet.text:GetStringWidth() + 20))
            s.bet:Show()
        else
            s.bet:Hide()
        end
    end
    if rolling then run.flip = false end

    local potNow = showingLast and (r and r.pot or 0) or Engine.Pot(m)
    f.pot:SetText(potNow > 0 and ("Pot " .. commas(potNow)) or "")

    local o = m.opts
    local players = 0
    for i = 1, N do if not m.out[i] then players = players + 1 end end
    f.gameInfo:SetText(("%s  ·  %d of %d left"):format(Engine.VARIANTS[o.variant], players, N))
    local togo = Engine.HandsToLevel(o, h.n)
    f.handInfo:SetText(("Hand %d  ·  Blinds %s / %s%s"):format(h.n, commas(h.sb), commas(h.bb),
        togo and ("  ·  up in %d"):format(togo) or ""))

    -- the line under the board
    local out = iAmOut()
    local status
    if rolling then
        if upNow < 3 then status = "|cffffd24dAll-in!|r  Here comes the flop..."
        elseif upNow == 3 then status = "The turn..."
        elseif upNow == 4 then status = "|cffffd24dThe river...|r"
        else status = "" end
    elseif g.ended == "closed" then
        status = paintName(g.host) .. " closed the table."
    elseif m.over then
        local base = statusFor(view, me)
        status = base and base ~= "" and base or (who(m.winner, me) .. (m.winner == me and " win the table!" or " wins the table!"))
    elseif showingLast then
        status = statusFor(view, me)
    elseif predeal then
        status = "Shuffling..."
    end
    if not status and myTurn() then
        local L0 = legal()
        status = "|cff66dd88Your turn|r" .. (L0 and L0.toCall > 0 and ("  ·  " .. commas(L0.call) .. " to call") or "")
    end
    if not status and m.cheat then status = "|cffff6b6bThe deal didn't check out.|r" end
    f.status:SetText(status or "")

    -- the action bar
    local bar = f.bar
    local over = T.Over(g)
    local L = myTurn() and legal()
    bar.giveUp:SetLabel((over or out) and "Menu" or "Leave")
    bar.giveUp:SetWidth(96)
    -- the host's way out of a player who stopped answering
    local stuck = not over and T.IsHost() and Engine.Expect(m)
    if stuck and stuck ~= me and GetTime() - (g.movedAt or GetTime()) > 60 then
        bar.remove:SetLabel("Remove " .. short(nameAt(stuck)))
        bar.remove:SetWidth(150)
        bar.remove:Show()
    else
        bar.remove:Hide()
    end
    if L then
        local dkey = decisionKey()
        if amountKey ~= dkey then
            amountKey = dkey
            amount = L.minTo
        end
        bar.wait:Hide()
        bar.fold:SetShown(L.fold)
        bar.call:Show()
        if L.check then
            bar.call:SetLabel("Check")
        else
            bar.call:SetLabel((L.call == stacks[me] and "All-in " or "Call ") .. commas(L.call))
        end
        bar.call:SetWidth(130)
        setEnabled(bar.call, true)
        setEnabled(bar.fold, L.fold)
        if L.minTo then
            amount = clampAmount(L, amount)
            bar.raise:Show()
            setEnabled(bar.raise, true)
            local spread = L.maxTo > L.minTo
            bar.sizing:SetShown(spread)
            if spread then
                bar.slider.quiet = true
                bar.slider:SetMinMaxValues(L.minTo, L.maxTo)
                bar.slider:SetValue(amount)
                bar.slider.quiet = false
                if not bar.input:HasFocus() then bar.input:SetText(tostring(amount)) end
            end
            PK.PaintRaise()
        else
            bar.raise:Hide()
            bar.sizing:Hide()
        end
    else
        bar.fold:Hide()
        bar.call:Hide()
        bar.raise:Hide()
        bar.sizing:Hide()
        bar.wait:Show()
        local text = ""
        if over then
            text = PK.note or ""
        elseif out then
            text = ("You finished %s. Watching the rest..."):format(Engine.Ordinal(m.place[me] or N))
        elseif g.pending then
            text = "Sending..."
        elseif rolling then
            text = "Running it out..."
        elseif predeal then
            text = "Dealing..."
        else
            local seat = Engine.Expect(m)
            text = seat and ("Waiting for " .. paintName(nameAt(seat)) .. "...") or ""
        end
        bar.wait:SetText(text)
    end

    -- the end of the game for me (after the last runout has been played out)
    if not rolling and f.resultFor ~= g.id and (m.over or out or closed) then
        f.resultFor = g.id
        local won = m.winner == me
        local place = m.place[me]
        local lines = { ("%d hands of %s"):format(view.n, Engine.VARIANTS[o.variant]), ("%d players"):format(N) }
        if closed and not m.over then
            f.result:Open({ title = "The table closed", tone = "lose", big = "", lines = { paintName(g.host) .. " left." },
                buttons = { { "Menu", PK.Menu }, { "New table", PK.NewTable } } })
        elseif won then
            f.result:Open({ title = "You win the table!", tone = "win", big = "Champion", lines = lines,
                buttons = { { "Menu", PK.Menu }, { "New table", PK.NewTable } } })
        elseif m.over then
            f.result:Open({ title = ("You finished %s"):format(Engine.Ordinal(place or N)), tone = "lose",
                big = Engine.Ordinal(place or N) .. " of " .. N, lines = lines,
                buttons = { { "Menu", PK.Menu }, { "New table", PK.NewTable } } })
        else
            -- out, but the others play on
            f.result:Open({ title = ("You finished %s"):format(Engine.Ordinal(place or N)), tone = "lose",
                big = Engine.Ordinal(place or N) .. " of " .. N, lines = lines,
                buttons = { { "Watch", function() end }, { "Leave", PK.Menu } } })
        end
    end
end

-- ---------------------------------------------------------------- opening, the menu tile
function PK.Show()
    if not win then build() end
    win:Show()
    paint()
end
function PK.Toggle()
    if win and win:IsShown() then win:Hide() else PK.Show() end
end

local function drawTile(t, size)
    if t.pokerArt then return end
    t.pokerArt = true
    local s = (size or 40) / 40
    for i, c in ipairs({ 27, 39 }) do -- the Ace and King of spades
        local tex = t:CreateTexture(nil, "ARTWORK", nil, i)
        art(tex, c)
        tex:SetSize(19 * s, 26 * s)
        tex:SetPoint("CENTER", (i == 1 and -5 or 5) * s, (i == 1 and 1 or -1) * s)
    end
end

Games.Register({
    key = KEY, name = LABEL, category = "party", order = 40, players = "2-9",
    desc = "No-Limit Hold'em or Pot-Limit Omaha for 2 to 9 friends.",
    icon = "Interface\\Icons\\INV_Misc_Coin_02", draw = drawTile, theme = KEY,
    slash = { "poker", "holdem", "plo" },
    -- /fc poker opens the window; /fc poker <name> invites them to your table
    open = function(arg)
        PK.Show()
        arg = trim(arg)
        if arg ~= "" and not playing() then PK.Invite(arg) end
    end,
    isOpen = function() return win ~= nil and win:IsShown() end,
    status = function()
        local g = T.game
        if playing() then
            local left = 0
            for i = 1, g.match.seats do if not g.match.out[i] then left = left + 1 end end
            return { stat = ("%d players"):format(left), badge = myTurn() and "turn" or "live" }
        end
        if T.lobby then return { stat = ("Table: %d seated"):format(#T.lobby.players), badge = "live" } end
        if T.LatestOffer() then return { stat = "Invited", badge = "turn" } end
        local d = db()
        if d.w + d.l > 0 then return { stat = ("Won %d of %d"):format(d.w, d.w + d.l) } end
        return nil
    end,
})

-- test hooks
function PK._state() return T.game, T.lobby end
function PK._win() return win end
