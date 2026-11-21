-- Heads-Up Poker for the FojjiCore games menu: No-Limit Hold'em and Pot-Limit Omaha, one on one,
-- over whispers (Games.Duel). The rules live in Engine.lua and Eval.lua; this file is the glue to
-- FojjiCore, the deal handshake, and the window.
--
-- Nothing runs while no match is going. During a match the only timer is a ten-second heartbeat
-- that re-sends a lost message (and asks the other player to catch us up after one went missing).
local ADDON, ns = ...
local Addon = FojjiCoreNS
local Games = Addon and Addon.Games
if not (Games and Games.Register and Games.Duel and Games.Window and Games.HeaderTools and Games.ResultCard
    and Games.PeopleRow and Games.Dress) then
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        DEFAULT_CHAT_FRAME:AddMessage("|cff66b3ffFojjiCore|r Poker needs FojjiCore Games 4.0.52 or newer, so it is switched off.")
    end)
    return
end
local FDJ = Games.Base
local Kit, C = FDJ.Kit, FDJ.Colors
local Engine, Eval = ns.Engine, ns.Eval
local floor, min, max = math.floor, math.min, math.max

local PK = {}
Games.Poker = PK
ns.PK = PK

local KEY = "poker"
local LABEL = "Heads-Up Poker"
local TEX = "Interface\\AddOns\\FojjiCore\\textures\\UI\\"
local MEDIA = Games.Media
local GOLD = Games.Gold or { 1.00, 0.82, 0.20 }
local SOFT = { 0.74, 0.76, 0.80 }
local GREEN = { 0.40, 0.86, 0.52 }
local commas = Games.Commas or function(n) return tostring(n) end

Games.Themes[KEY] = { accent = { 0.38, 0.86, 0.56 }, head = { 0.02, 0.08, 0.05 } }
local snd = Games.Sound(KEY)

local HELP = {
    "Heads-up poker against one friend, for play chips.",
    "No-Limit Hold'em: two cards each, bet any amount up to your stack.",
    "Pot-Limit Omaha: four cards each. Use exactly two of them with three from the board. The biggest bet is the size of the pot.",
    "The button posts the small blind, acts first before the flop and last after it.",
    "Each deck is shuffled from a secret of each player's, so neither can stack it.",
}

-- ---------------------------------------------------------------- saved settings
local function db()
    FojjiCorePokerDB = type(FojjiCorePokerDB) == "table" and FojjiCorePokerDB or {}
    local d = FojjiCorePokerDB
    d.secrets = type(d.secrets) == "table" and d.secrets or {}
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

-- ---------------------------------------------------------------- names
local function short(n) return n and Games.Name(n) or "?" end
local function paintName(n) return "|cff" .. Games.ClassHex(short(n), true) .. short(n) .. "|r" end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ---------------------------------------------------------------- match state
local D, win
local match, session -- the engine state and the duel session it belongs to
local paint, paintLobby -- the window (further down)
local function mySeat() return session and (session.first and 1 or 2) or 1 end
local function live()
    return match ~= nil and session ~= nil and match.sid == session.id and D:Session() == session
end
local function playing() return live() and not match.over and not session.over end
local function myTurn()
    if not playing() then return false end
    local who, kind = Engine.Expect(match)
    return who == mySeat() and kind == "A"
end

local function bind(s, m)
    session, match = s, m
    m.sid = s.id
    -- only this match's deal secrets are worth keeping
    local d = db()
    for k in pairs(d.secrets) do
        if k:sub(1, #s.id + 1) ~= s.id .. ":" then d.secrets[k] = nil end
    end
end

local function reachable(name)
    if not name then return false end
    if Games.Near(name) or Games.Near(short(name)) then return true end
    if IsInGuild and IsInGuild() and GetGuildRosterInfo then
        for i = 1, (tonumber(GetNumGuildMembers and GetNumGuildMembers()) or 0) do
            local n, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if type(n) == "string" and online and Games.Same(n, name) then return true end
        end
    end
    return false
end

local function openWhenCalm()
    if Games.Fighting() and Games.CombatHideOn() then
        Games.AfterCombat(function() if live() and not (win and win:IsShown()) then PK.Show() end end)
        return
    end
    PK.Show()
end

-- the match ended by its own rules, by a resignation, or by someone leaving
local function settle()
    if not (match and match.over and session) then return end
    local d = db()
    if d.countedId ~= session.id then
        d.countedId = session.id
        if match.winner == mySeat() then d.w = d.w + 1 else d.l = d.l + 1 end
        snd.Play("chess-end")
    end
    if not session.over then D:Finish(match.winner == mySeat() and "win" or "lose") end
end

-- ---------------------------------------------------------------- the all-in runout
-- When the betting stops early because someone is all-in, the engine deals the rest of the board in
-- one go. The window doesn't: it turns both hands over, drops the flop one card at a time, slides the
-- turn in face down and flips it, then holds on a face-down river before the last flip. Only then
-- does it say who won. The next deal waits for it (see RunLength in drive).
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

local run -- { n = hand number, shown = board cards up, back = newest one face down, done = bool, pop = {} }
local function running(view)
    return run ~= nil and not run.done and view ~= nil and view.n == run.n
end

local function startRun(l, onDone)
    local r = l.result
    local me = { n = l.n, shown = r.runFrom, pop = {}, flipFoe = true }
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

local drive
local alerted
local function afterChange(why, msg)
    if match and match.over then settle() end
    if why == "foe" or why == "me" then
        if msg and msg:find("^[FXCB]") then snd.Play("chess-move") end
        session.movedAt = GetTime()
    end
    -- a hand just finished: a little sound for the pot
    if match and match.last and match.last.n ~= PK.seenHand then
        -- watched it end live (not a reload or a resume), so hand 1 counts too
        local hadSeen = PK.seenHand ~= nil or why == "me" or why == "foe"
        PK.seenHand = match.last.n
        local r = match.last.result
        local won = r and r.winner == mySeat()
        if hadSeen and r and r.showdown and r.runFrom then
            -- an all-in before the river: play the board out, and only cheer at the end
            startRun(match.last, function() if won then snd.Play("deathroll-win") end end)
        elseif hadSeen and won then
            snd.Play("deathroll-win")
        end
    end
    drive()
    if myTurn() then
        local key = session.id .. ":" .. match.hand.n .. ":" .. #match.hand.log
        if alerted ~= key and not (win and win:IsShown()) then
            alerted = key
            FDJ.Print(("Poker: your turn against %s (hand %d). Type /fc poker."):format(paintName(session.foe), match.hand.n))
        end
    end
    if win and win:IsShown() then paint() end
    Games.Notify(KEY)
end

-- applies one of our own messages and sends it
local function send(msg)
    if not playing() then return false end
    local ok, err = Engine.Apply(match, mySeat(), msg)
    if not ok then
        FDJ.Print("Poker: that didn't go through (" .. tostring(err) .. ").")
        return false
    end
    D:Move(msg)
    afterChange("me", msg)
    return true
end

-- The deal handshake runs by itself: whoever the engine is waiting on for K, S or R sends it.
-- After a hand there is a short pause so both players can see how it ended.
local driveKey, driveAt = nil, 0
drive = function()
    if not playing() then return end
    local who, kind = Engine.Expect(match)
    if who ~= mySeat() or kind == "A" then return end
    local h = match.hand
    local key = session.id .. ":" .. h.n .. ":" .. kind .. ":" .. #h.log
    if driveKey == key and GetTime() - driveAt < 8 then return end
    driveKey, driveAt = key, GetTime()
    local wait = 0.3
    if kind == "K" then
        local l = match.last
        if l and l.n == h.n - 1 and #h.log == 0 then
            wait = (l.result and l.result.showdown) and 5 + PK.RunLength(l.result) or 2.5
        else
            wait = h.n == 1 and 1.5 or 0.8
        end
    end
    C_Timer.After(wait, function()
        if driveKey ~= key or not playing() or match.hand ~= h then return end
        local who2, kind2 = Engine.Expect(match)
        if who2 ~= mySeat() or kind2 ~= kind then return end
        -- a whisper to someone offline only prints an error: the heartbeat tries again later
        if not reachable(session.foe) then driveKey = nil return end
        local d = db()
        local slot = session.id .. ":" .. h.n
        if kind == "K" then
            local secret = ("%d.%d.%d"):format(math.random(0, 16777215), math.random(0, 16777215), floor(GetTime() * 1000) % 1000000)
            d.secrets[slot] = secret
            send("K" .. Engine.Commit(secret, match.salt, h.n))
        elseif kind == "S" then
            send("S" .. math.random(1, 2147483000))
        elseif kind == "R" then
            local secret = d.secrets[slot]
            if secret and Engine.Commit(secret, match.salt, h.n) == h.commit then
                send("R" .. secret)
            else
                send("Z") -- the secret was lost (the game closed before it was saved): deal again
            end
        end
    end)
end

-- A whisper can go missing. While we wait on the other player, ask now and then how far they are;
-- whoever is ahead sends the whole position (P = "I'm at move n", T = "here is move n").
local pingAt = 0
local function heartbeat()
    C_Timer.After(10, heartbeat)
    if not playing() then return end
    local who = Engine.Expect(match)
    if who == mySeat() then drive() return end
    if GetTime() - (session.movedAt or 0) < 15 or GetTime() - pingAt < 20 then return end
    if not reachable(session.foe) then return end
    pingAt = GetTime()
    D:Send("P", session.n)
end
C_Timer.After(10, heartbeat)

-- ---------------------------------------------------------------- the duel
D = Games.Duel.Make("PK", LABEL, {
    store = "poker",
    options = chosenOpts,
    describe = function(opts) return Engine.Describe(opts) end,
    onStart = function(s, resumed)
        if not (match and match.sid == s.id) then bind(s, Engine.NewMatch(s.opts, s.id)) else session = s end
        PK.note, PK.seenHand, alerted, run = nil, nil, nil, nil
        if not resumed then
            FDJ.Print(("Heads-up %s with %s has begun. %s"):format(Engine.Describe(s.opts), paintName(s.foe),
                mySeat() == 1 and "You have the button first." or "They have the button first."))
            snd.Play("chess-start")
        end
        if win and win.result and win.result:IsOpen() then win.result:Close() end
        openWhenCalm()
        afterChange("start")
    end,
    onMove = function(s, n, data)
        if not (match and match.sid == s.id) then bind(s, Engine.NewMatch(s.opts, s.id)) end
        session = s
        local ok = not match.over and Engine.Apply(match, 3 - mySeat(), data)
        if not ok then
            -- not a move we can make yet: don't count it, so a fresh copy of the position can fix things
            if s.n == n then s.n = n - 1 end
            if match.cheat then FDJ.Print(("Poker: %s's deal didn't check out. You can leave the match."):format(paintName(s.foe))) end
            return
        end
        afterChange("foe", data)
    end,
    onEnd = function(s, why, mine)
        if not (match and match.sid == s.id) or match.over then return end
        match.over, match.ended = true, why
        match.winner = mine and (3 - mySeat()) or mySeat()
        if not mine then
            FDJ.Print(("Poker: %s %s. You win the match!"):format(paintName(s.foe), why == "resign" and "gave up" or "left"))
        end
        afterChange("end")
    end,
    onGone = function() if win and win:IsShown() then paint() end end,
    onInvite = function(_, state, name)
        PK.note = state == "declined" and (short(name) .. " said no this time.")
            or state == "expired" and (short(name) .. " didn't answer.") or nil
        if win and win:IsShown() then paint() end
    end,
    onMessage = function(s, sub, rest)
        if not (session == s and match and match.sid == s.id) then return end
        if sub == "P" then
            local n = tonumber(rest)
            if not n then return end
            if s.n > n then
                D:Send("T", s.n, Engine.Snapshot(match))
            elseif s.n < n and GetTime() - pingAt > 5 then
                pingAt = GetTime()
                D:Send("P", s.n)
            end
        elseif sub == "T" then
            local n, snap = rest:match("^(%d+)~(.*)$")
            n = tonumber(n)
            if not (n and n > s.n) then return end
            local m = Engine.FromSnapshot(snap, s.id)
            if not m then return end
            bind(s, m)
            s.n = n
            D:Save()
            afterChange("sync")
        end
    end,
    snapshot = function(s)
        if match and match.sid == s.id then return Engine.Snapshot(match) end
        return ""
    end,
    restore = function(s, text)
        local m = Engine.FromSnapshot(text, s.id)
        if not m then return end
        bind(s, m)
        afterChange("sync")
    end,
})
PK.Duel = D

function PK.Challenge(name)
    name = trim(name)
    if name == "" then
        PK.note = "Type a name, or pick someone from the lists."
        if win then paint() end
        return false
    end
    if D:Active() then return false end
    if D:Session() then D:Leave() end
    PK.note = nil
    local ok = D:Challenge(name, chosenOpts())
    if win then paint() end
    return ok
end
function PK.GiveUp()
    if playing() then D:Resign() end
end
function PK.Menu()
    if D:Session() then D:Leave() end
    match, session = nil, nil
    if win then paint() end
    Games.Notify(KEY)
end
function PK.Rematch()
    if D:Rematch() then
        PK.note = "Rematch offered to " .. short(session and session.foe) .. "."
    end
    if win then paint() end
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
local W, H, HEAD, BAR = 640, 540, 38, 104
local TH = H - HEAD - 8 - BAR -- table height

local function newPlate(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(150, 54)
    Games.Panel(p, "dark")
    p.ring = p:CreateTexture(nil, "BACKGROUND", nil, -1)
    p.ring:SetPoint("TOPLEFT", -2, 2)
    p.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    p.ring:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.85)
    p.ring:Hide()
    p.name = Kit.Text(p, 13, C.white)
    p.name:SetPoint("TOPLEFT", 10, -9)
    p.name:SetPoint("RIGHT", -34, 0)
    p.stack = Kit.Text(p, 15, GOLD)
    p.stack:SetPoint("BOTTOMLEFT", 10, 8)
    p.tag = Kit.Text(p, 10, SOFT, "RIGHT")
    p.tag:SetPoint("BOTTOMRIGHT", -9, 10)
    p.button = Games.Chip(p, 20, 20)
    p.button:SetPoint("TOPRIGHT", -7, -7)
    p.button:SetFill(0.95, 0.93, 0.86, 1)
    p.button.text:SetText("D")
    p.button.text:SetTextColor(0.1, 0.1, 0.1)
    p.said = Kit.Text(parent, 12, SOFT, "CENTER")
    p.said:SetPoint("TOP", p, "BOTTOM", 0, -5)
    return p
end
local function newBet(parent)
    local b = Games.Chip(parent, 80, 22)
    b:SetEdge(GOLD[1], GOLD[2], GOLD[3], 0.8)
    b.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    return b
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
    card:SetSize(440, 412)
    card:SetPoint("CENTER")
    Games.Panel(card)
    local function caption(text, y)
        local t = Kit.Text(card, 11, SOFT)
        t:SetPoint("TOPLEFT", 16, y)
        t:SetText(text)
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
            paintLobby()
        end)
        g:SetSize(408, 26)
        g:SetPoint("TOPLEFT", 16, y)
        g:Layout()
        return g
    end
    caption("GAME", -14)
    lobby.variant = picker(-32, { { "NL", "No-Limit Hold'em" }, { "PLO", "Pot-Limit Omaha" } }, "variant")
    caption("STARTING STACK", -68)
    lobby.stack = picker(-86, { { 50, "50 big blinds" }, { 100, "100 big blinds" }, { 200, "200 big blinds" } }, "stackBB")
    caption("BLINDS", -122)
    lobby.level = picker(-140, { { 0, "Never go up" }, { 20, "Up every 20 hands" }, { 10, "Up every 10 hands" } }, "level")
    lobby.summary = Kit.Text(card, 12, C.text)
    lobby.summary:SetPoint("TOPLEFT", 16, -176)
    lobby.summary:SetWidth(408)
    rule(-200)
    caption("CHALLENGE A FRIEND", -212)
    lobby.name = Kit.Input(card, 288, 26, "Their name", nil, function() PK.Challenge(lobby.name:GetText()) end)
    lobby.name:SetPoint("TOPLEFT", 16, -230)
    lobby.challenge = Kit.Button(card, "Challenge", 112, 26, function()
        if D.invite then D:Cancel() paint() else PK.Challenge(lobby.name:GetText()) end
    end, "primary")
    lobby.challenge:SetPoint("TOPRIGHT", -16, -230)
    lobby.people = Games.PeopleRow(card, function(n) lobby.name:SetText(n or "") end, function() return D:Recent() end)
    lobby.people:SetPoint("TOPLEFT", 16, -264)
    lobby.note = Kit.Text(card, 11, SOFT)
    lobby.note:SetPoint("TOPLEFT", 16, -296)
    lobby.note:SetWidth(408)
    lobby.need = Kit.Text(card, 11, SOFT)
    lobby.need:SetPoint("TOPLEFT", 16, -314)
    lobby.need:SetWidth(408)
    lobby.need:SetText("They need FojjiCore Games and FojjiCore Poker too. Play chips only.")
    rule(-338)
    caption("YOUR RECORD", -350)
    lobby.record = Kit.Text(card, 13, C.white)
    lobby.record:SetPoint("TOPLEFT", 16, -368)
    lobby.record:SetWidth(408)
    f.lobby = lobby
end

paintLobby = function()
    local f = win
    if not f then return end
    local L, d = f.lobby, db()
    if L.variant.value ~= d.variant then L.variant:Select(d.variant, true) end
    if L.stack.value ~= d.stackBB then L.stack:Select(d.stackBB, true) end
    if L.level.value ~= d.level then L.level:Select(d.level, true) end
    local o = Engine.ParseOpts(chosenOpts())
    local sb, bb = Engine.Blinds(o, 1)
    L.summary:SetText(("Both start with %s chips. Blinds %s / %s."):format(commas(o.stackBB * Engine.UNIT), commas(sb), commas(bb)))
    if D.invite then
        L.note:SetText("Waiting for " .. paintName(D.invite.to) .. " to answer...")
        L.challenge:SetLabel("Cancel")
    else
        L.note:SetText(PK.note or "Pick a friend from your group or guild.")
        L.challenge:SetLabel("Challenge")
    end
    L.challenge:SetWidth(112)
    local total = d.w + d.l
    L.record:SetText(total == 0 and "No matches yet." or ("Won %d  |cffaeb3bc·|r  Lost %d"):format(d.w, d.l))
end

-- the raise amount being picked, as "raise to" this street's total
local amount, amountKey
local function decisionKey() return match and (session.id .. ":" .. match.hand.n .. ":" .. #match.hand.log) end
local function clampAmount(L, v)
    v = floor(tonumber(v) or L.minTo)
    return max(L.minTo, min(L.maxTo, v))
end
local function presetAmount(L, which)
    if which == "min" then return L.minTo end
    if which == "max" then return L.maxTo end
    local h = match.hand
    local high = max(h.bet[1], h.bet[2])
    local potAfterCall = h.pot + h.bet[1] + h.bet[2] + L.toCall
    return clampAmount(L, high + floor(potAfterCall * which + 0.5))
end

local function buildBar(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", -1, 1)
    bar:SetHeight(BAR)
    Kit.Line(bar, "TOP", C.borderDim)
    f.bar = bar

    bar.giveUp = Kit.Button(bar, "Give up", 96, 28, function()
        if playing() then
            Kit.Confirm(("Give up the match against %s?"):format(short(session.foe)), PK.GiveUp)
        else
            PK.Menu()
        end
    end)
    bar.giveUp:SetPoint("BOTTOMLEFT", 12, 12)

    bar.raise = Kit.Button(bar, "Raise", 160, 30, function()
        local L = Engine.Legal(match)
        if L and L.minTo and myTurn() then send("B" .. clampAmount(L, amount)) end
    end, "primary")
    bar.raise:SetPoint("BOTTOMRIGHT", -12, 12)
    bar.call = Kit.Button(bar, "Call", 130, 30, function()
        local L = Engine.Legal(match)
        if L and myTurn() then send(L.check and "X" or "C") end
    end)
    bar.call:SetPoint("RIGHT", bar.raise, "LEFT", -8, 0)
    bar.fold = Kit.Button(bar, "Fold", 96, 30, function()
        local L = Engine.Legal(match)
        if L and L.fold and myTurn() then send("F") end
    end)
    bar.fold:SetPoint("RIGHT", bar.call, "LEFT", -8, 0)

    -- sizing: presets, a slider and the number
    local sizing = CreateFrame("Frame", nil, bar)
    sizing:SetPoint("TOPRIGHT", -12, -10)
    sizing:SetSize(454, 26)
    bar.sizing = sizing
    bar.input = Kit.Input(sizing, 84, 26, "", function(_, text, user)
        if not user then return end
        local L = Engine.Legal(match)
        local v = tonumber(text)
        if L and L.minTo and v then
            amount = clampAmount(L, v)
            if bar.slider then bar.slider.quiet = true bar.slider:SetValue(amount) bar.slider.quiet = false end
            PK.PaintRaise()
        end
    end, function(self)
        local L = Engine.Legal(match)
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
        local L = Engine.Legal(match)
        if not (L and L.minTo) then return end
        self:SetValue(clampAmount(L, (amount or L.minTo) + delta * match.hand.bb))
    end)
    sl:SetScript("OnValueChanged", function(self, v)
        if self.quiet then return end
        local L = Engine.Legal(match)
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
            local L = Engine.Legal(match)
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

local function setEnabled(b, on)
    if b:IsEnabled() ~= on then
        if on then b:Enable() else b:Disable() end
        if b.Paint then b:Paint() end
    end
end

function PK.PaintRaise()
    local bar = win and win.bar
    local L = match and myTurn() and Engine.Legal(match)
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

    -- seats: index 1 is the top of the table (them), 2 the bottom (you)
    f.cards, f.plates, f.bets = {}, {}, {}
    for side = 1, 2 do
        local row = CreateFrame("Frame", nil, t)
        row:SetSize(212, 80)
        if side == 1 then row:SetPoint("TOP", 40, -14) else row:SetPoint("BOTTOM", 40, 14) end
        f.cards[side] = { row = row }
        for i = 1, 4 do f.cards[side][i] = newCard(row) end
        local p = newPlate(t)
        p:SetPoint("RIGHT", row, "LEFT", -18, 0)
        f.plates[side] = p
        f.bets[side] = newBet(t)
    end
    -- your hand so far ("Two pair, Kings and Sevens"), beside your cards while a hand is being bet
    f.myHand = Kit.Text(t, 12, GOLD, "LEFT")
    f.myHand:SetPoint("LEFT", f.cards[2].row, "RIGHT", 14, 0)
    f.myHand:SetWidth(150)
    f.bets[1]:SetPoint("TOP", f.cards[1].row, "BOTTOM", -40, -10)
    f.bets[2]:SetPoint("BOTTOM", f.cards[2].row, "TOP", -40, 10)

    f.board = CreateFrame("Frame", nil, t)
    f.board:SetSize(5 * 56 + 4 * 6, 78)
    f.board:SetPoint("CENTER", 0, 4)
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
    f.status:SetWidth(560)

    buildBar(f)
    buildLobby(f)
    f.result = Games.ResultCard(t)

    Games.HeaderTools(f, { help = HELP, sound = snd })
    f:HookScript("OnShow", function() paint() end)
    Games.Window(f, KEY)
    return f
end

-- lays the hole cards out for 2 (Hold'em) or 4 (Omaha)
local function layoutCards(k)
    if win.laidOut == k then return end
    win.laidOut = k
    local w, h, gap = 58, 80, 6
    if k == 4 then w, h, gap = 50, 70, 4 end
    for side = 1, 2 do
        local set = win.cards[side]
        set.row:SetSize(k * w + (k - 1) * gap, h)
        for i = 1, 4 do
            set[i]:Fit(w, h)
            set[i]:ClearAllPoints()
            set[i]:SetPoint("LEFT", (i - 1) * (w + gap), 0)
        end
    end
end

local function statusFor(view, me)
    local r = view.result
    if not r then return nil end
    local foeName = paintName(session.foe)
    local function who(seat) return seat == me and "You" or foeName end
    if r.fold then
        return ("%s folded. %s %s %s."):format(who(r.fold), who(r.winner), r.winner == me and "win" or "wins", commas(r.pot))
    end
    if r.winner == 0 then
        return ("Split pot: %s each with %s."):format(commas(r.won[me]), r.names[me])
    end
    return ("%s %s %s with %s."):format(who(r.winner), r.winner == me and "win" or "wins", commas(r.pot), r.names[r.winner])
end

paint = function()
    local f = win
    if not f then return end
    local active = live()
    f.lobby:SetShown(not active)
    if not active then
        if f.result:IsOpen() then f.result:Close() end
        paintLobby()
        for side = 1, 2 do
            for i = 1, 4 do f.cards[side][i]:Set(false) end
            f.plates[side]:Hide()
            f.plates[side].said:SetText("")
            f.bets[side]:Hide()
        end
        for i = 1, 5 do f.board[i]:Set(nil) end
        f.pot:SetText("")
        f.status:SetText("")
        f.handInfo:SetText("")
        f.gameInfo:SetText("")
        f.myHand:SetText("")
        f.bar:Hide()
        return
    end
    f.bar:Show()
    local me, foe = mySeat(), 3 - mySeat()
    local seatOf = { foe, me } -- table side -> seat
    local h = match.hand
    local predeal = h.phase == "commit" or h.phase == "seed" or h.phase == "reveal"
    local view = h
    if (match.over or predeal) and match.last then view = match.last end
    local showingLast = view ~= h
    local quit = match.ended == "resign" or match.ended == "leave"
    -- an all-in board still being played out (a match-ending all-in is both last and current hand)
    local rolling = running(view) and view.result ~= nil and not quit
    local k = Engine.Cards(match)
    layoutCards(k)

    local r = view.result
    local dealt = view.phase == "bet" or view.phase == "done"
    local winSet = {}
    if r and r.showdown and not rolling then
        for seat = 1, 2 do
            if r.winner == 0 or r.winner == seat then
                for _, c in ipairs(r.best[seat] or {}) do winSet[c] = true end
            end
        end
    end
    local function look(c, seat)
        if r and r.fold == seat then return "dim" end
        if winSet[c] then return "win" end
        return nil
    end

    -- hole cards
    for side = 1, 2 do
        local seat = seatOf[side]
        local set = f.cards[side]
        local faceUp = seat == me or (r and r.showdown)
        for i = 1, 4 do
            if i > k then
                set[i]:Set(false)
            elseif not dealt then
                set[i]:Set(nil)
            else
                local c = view.holes[seat][i]
                set[i]:Set(faceUp and c or true, look(c, seat))
                -- the runout begins: their hand turns over
                if rolling and run.flipFoe and seat ~= me then set[i]:Land(true) end
            end
        end
    end
    if rolling then run.flipFoe = false end
    -- board
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
    local ev = match.opts.variant == "PLO" and Eval.Omaha or Eval.Holdem
    local upNow = rolling and (run.back and shown - 1 or shown) or 0
    local function soFar(seat)
        if upNow < 3 then return "All-in" end
        local board = {}
        for i = 1, upNow do board[i] = view.board[i] end
        local sc = ev(view.holes[seat], board)
        return sc and Eval.Name(sc) or "All-in"
    end
    -- your own hand while the betting is on (the runout and showdown name hands on the plates)
    local mine = ""
    if not showingLast and not rolling and h.phase == "bet" and h.holes and h.holes[me] then
        local board = {}
        for i = 1, shown do board[i] = h.board[i] end
        mine = Eval.Current(h.holes[me], board, match.opts.variant == "PLO")
    end
    f.myHand:SetText(mine)

    -- plates, bets and what each player last did
    local stacks = showingLast and view.endStacks or match.stacks
    -- the pot isn't pushed until the river is out
    if rolling then stacks = { view.endStacks[1] - r.won[1], view.endStacks[2] - r.won[2] } end
    for side = 1, 2 do
        local seat = seatOf[side]
        local p = f.plates[side]
        p:Show()
        local name = seat == me and short(session.me or FDJ.PlayerName()) or short(session.foe)
        p.name:SetText("|cff" .. Games.ClassHex(name, true) .. name .. "|r")
        p.stack:SetText(commas(stacks[seat]))
        p.button:SetShown(view.button == seat)
        local tag = ""
        if rolling and stacks[seat] == 0 then tag = "ALL-IN"
        elseif not showingLast and stacks[seat] == 0 and not match.over then tag = "ALL-IN"
        elseif not showingLast then tag = view.button == seat and "SB" or "BB" end
        p.tag:SetText(tag)
        p.ring:SetShown(not showingLast and h.phase == "bet" and h.toAct == seat)
        local said
        if rolling then
            said = soFar(seat)
        elseif r and r.showdown then
            said = r.names[seat]
        elseif r and r.fold == seat then
            said = "Fold"
        elseif r and r.winner == seat then
            said = "Wins " .. commas(r.pot)
        else
            said = Engine.Said(view.said and view.said[seat])
        end
        p.said:SetText(said or "")
        local bet = showingLast and 0 or h.bet[seat]
        local b = f.bets[side]
        if bet > 0 then
            b.text:SetText(commas(bet))
            b:SetWidth(max(56, b.text:GetStringWidth() + 20))
            b:Show()
        else
            b:Hide()
        end
    end

    local potNow = showingLast and (r and r.pot or 0) or (h.pot + h.bet[1] + h.bet[2])
    f.pot:SetText(potNow > 0 and ("Pot " .. commas(potNow)) or "")

    local o = match.opts
    f.gameInfo:SetText(Engine.VARIANTS[o.variant])
    local left = Engine.HandsToLevel(o, h.n)
    f.handInfo:SetText(("Hand %d  ·  Blinds %s / %s%s"):format(h.n, commas(h.sb), commas(h.bb),
        left and ("  ·  up in %d"):format(left) or ""))

    -- the line under the board
    local status
    if rolling then
        if upNow < 3 then status = "|cffffd24dAll-in!|r  Here comes the flop..."
        elseif upNow == 3 then status = "The turn..."
        elseif upNow == 4 then status = "|cffffd24dThe river...|r"
        else status = "" end
    elseif match.over then
        local won = match.winner == me
        if quit then
            status = won and (paintName(session.foe) .. (match.ended == "resign" and " gave up." or " left.")) or "You gave up."
        else
            status = statusFor(view, me) or ""
        end
    elseif showingLast then
        status = statusFor(view, me)
    elseif predeal then
        status = "Shuffling..."
    end
    if not status and myTurn() then
        local L0 = Engine.Legal(match)
        status = "|cff66dd88Your turn|r" .. (L0 and L0.toCall > 0 and ("  ·  " .. commas(L0.call) .. " to call") or "")
    end
    if not status and match.cheat then status = "|cffff6b6bThe deal didn't check out.|r" end
    f.status:SetText(status or "")

    -- the action bar
    local bar = f.bar
    local L = myTurn() and Engine.Legal(match)
    local over = match.over or session.over
    bar.giveUp:SetLabel(over and "Menu" or "Give up")
    bar.giveUp:SetWidth(96)
    if L then
        local key = decisionKey()
        if amountKey ~= key then
            amountKey = key
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
            text = PK.note or (session.gone and (short(session.foe) .. " has left.") or "")
        elseif rolling then
            text = "Running it out..."
        elseif predeal then
            text = "Dealing..."
        else
            text = "Waiting for " .. paintName(session.foe) .. "..."
        end
        bar.wait:SetText(text)
    end

    -- the end of the match (after the last runout has been played out)
    if over and f.resultFor ~= session.id and not rolling then
        f.resultFor = session.id
        local won = match.winner == me
        f.result:Open({
            title = won and "You win the match!" or "You lost the match",
            tone = won and "win" or "lose",
            big = won and "Heads-up champion" or ("vs " .. short(session.foe)),
            lines = { ("%d hands of %s"):format(h.n, Engine.VARIANTS[o.variant]),
                won and ("against " .. short(session.foe)) or nil },
            buttons = { { "Menu", PK.Menu }, { "Rematch", PK.Rematch } },
        })
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
    key = KEY, name = LABEL, category = "party", order = 40, players = "2",
    desc = "No-Limit Hold'em or Pot-Limit Omaha, one on one.",
    icon = "Interface\\Icons\\INV_Misc_Coin_02", draw = drawTile, theme = KEY,
    slash = { "poker", "holdem", "plo" },
    open = function(arg)
        PK.Show()
        arg = trim(arg)
        if arg ~= "" and not D:Active() and win and win.lobby then win.lobby.name:SetText(arg) end
    end,
    isOpen = function() return win ~= nil and win:IsShown() end,
    status = function()
        if playing() then
            return { stat = "vs " .. short(session.foe), badge = myTurn() and "turn" or "live" }
        end
        local d = db()
        if d.w + d.l > 0 then return { stat = ("Won %d of %d"):format(d.w, d.w + d.l) } end
        return nil
    end,
})

-- test hooks
function PK._state() return match, session end
function PK._win() return win end
