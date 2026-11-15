-- The rules of a heads-up match: blinds, betting, the deal and the showdown. Pure Lua with no game
-- client calls, so the tests run it outside WoW.
--
-- Both players run this same engine on the same messages in the same order, so both always agree on
-- the state. Seats: 1 is the player who moved first in the duel session, 2 the other. The button
-- (who is also the small blind) is seat 1 on odd hands and seat 2 on even hands.
--
-- Messages (each one is a duel move, sent by whoever Engine.Expect says):
--   K<hex>   the big blind commits to a secret        (phase "commit")
--   S<n>     the button answers with its own number   (phase "seed")
--   R<text>  the big blind reveals the secret: the deck is now shuffled from both
--   Z        the big blind lost its secret (a crash): commit again
--   F  X  C  B<to>   fold, check, call, bet or raise to <to> (this street's total)
--
-- The shuffle can't be steered by either player: the secret is fixed (committed) before the other
-- number is known, and the other number is chosen without knowing the secret. It is not a hidden
-- deck: once the secret is revealed both clients could work out every card. The addon only ever
-- shows your own cards, plus the other player's at a showdown. Play chips only.
local _, ns = ...
ns = ns or {}
local Engine = {}
ns.Engine = Engine
local Eval = ns.Eval

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

Engine.UNIT = 20 -- the first big blind; stacks are counted in these
local LEVELS = { 20, 30, 40, 60, 80, 100, 150, 200, 300, 400, 600, 800, 1000, 1500, 2000, 3000, 4000,
    6000, 8000, 10000, 15000, 20000, 30000, 40000, 60000, 80000, 100000 }
Engine.VARIANTS = { NL = "No-Limit Hold'em", PLO = "Pot-Limit Omaha" }

-- ---------------------------------------------------------------- options
-- "NL,100,0": variant, starting stack in big blinds, hands per blind level (0 = the blinds never go up)
function Engine.ParseOpts(text)
    local var, stack, level = tostring(text or ""):match("^(%u+),(%d+),(%d+)$")
    if not Engine.VARIANTS[var or ""] then var = "NL" end
    stack = max(10, min(500, tonumber(stack) or 100))
    level = max(0, min(200, tonumber(level) or 0))
    return { variant = var, stackBB = stack, level = level }
end
function Engine.OptsText(o) return ("%s,%d,%d"):format(o.variant, o.stackBB, o.level) end
function Engine.Describe(text)
    local o = Engine.ParseOpts(text)
    local blinds = o.level > 0 and (", blinds up every %d hands"):format(o.level) or ""
    return ("%s, %d big blinds%s"):format(Engine.VARIANTS[o.variant], o.stackBB, blinds)
end
function Engine.Blinds(o, n)
    local i = o.level > 0 and floor((n - 1) / o.level) + 1 or 1
    local bb = LEVELS[min(i, #LEVELS)]
    return bb / 2, bb
end
-- hands left at this blind level (nil when the blinds are fixed)
function Engine.HandsToLevel(o, n)
    if o.level <= 0 then return nil end
    return o.level - (n - 1) % o.level
end

-- ---------------------------------------------------------------- hashing and the shuffle
-- Arithmetic only (no bit library), and every product stays well under 2^53.
local P1, P2, PM = 2147483629, 2147483587, 2147483647
local function mulmod(a, b, p)
    local hi, lo = floor(b / 65536), b % 65536
    return ((a * hi % p) * 65536 + a * lo) % p
end
function Engine.Hash(text)
    text = tostring(text)
    local h1, h2 = 1234567, 7654321
    for round = 1, 3 do
        for i = 1, #text do
            local b = text:byte(i)
            h1 = mulmod((h1 + b + 1) % P1, (h1 + 40503 + i * 3 + round) % P1, P1)
            h2 = mulmod((h2 + b * 7 + 3) % P2, (h2 + 9973 + i + round * 5) % P2, P2)
            h1 = (h1 + floor(h2 / 7)) % P1
            h2 = (h2 + floor(h1 / 3) + b) % P2
        end
    end
    return ("%08x%08x"):format(h1, h2), h1, h2
end
function Engine.Commit(secret, salt, n)
    return (Engine.Hash(secret .. "#" .. tostring(salt) .. "#" .. tostring(n)))
end
function Engine.Shuffle(seed)
    local s = floor(tonumber(seed) or 1) % (PM - 1) + 1
    local deck = {}
    for i = 1, 52 do deck[i] = i end
    for i = 52, 2, -1 do
        s = s * 16807 % PM
        local j = floor((s - 1) / (PM - 1) * i) + 1
        deck[i], deck[j] = deck[j], deck[i]
    end
    return deck
end
local function deckFor(m, h)
    local _, a, b = Engine.Hash(h.secret .. ":" .. h.seedB .. ":" .. tostring(m.salt) .. ":" .. h.n)
    return Engine.Shuffle(a * 7 + b)
end

-- ---------------------------------------------------------------- the match
local function post(m, h, seat, amount)
    local a = min(amount, m.stacks[seat])
    m.stacks[seat] = m.stacks[seat] - a
    h.bet[seat] = h.bet[seat] + a
    h.total[seat] = h.total[seat] + a
    return a
end

function Engine.StartHand(m, n, s1, s2)
    m.stacks = { s1, s2 }
    local sb, bb = Engine.Blinds(m.opts, n)
    local btn = (n - 1) % 2 + 1
    local h = { n = n, button = btn, sb = sb, bb = bb, phase = "commit", log = {}, startStacks = { s1, s2 },
        bet = { 0, 0 }, total = { 0, 0 }, pot = 0, acted = { false, false }, street = 0, lastRaise = bb,
        holes = { {}, {} }, board = {}, said = {} }
    m.hand = h
    post(m, h, btn, sb)
    post(m, h, 3 - btn, bb)
    return h
end

function Engine.NewMatch(optsText, salt)
    local o = Engine.ParseOpts(optsText)
    local start = o.stackBB * Engine.UNIT
    local m = { opts = o, optsText = Engine.OptsText(o), salt = tostring(salt or ""), start = start }
    Engine.StartHand(m, 1, start, start)
    return m
end

function Engine.Cards(m) return m.opts.variant == "PLO" and 4 or 2 end
function Engine.BoardShown(h)
    if h.result and h.result.showdown then return 5 end
    return ({ [0] = 0, 3, 4, 5 })[h.street] or 0
end

-- who must send the next message, and what kind: "K" "S" "R" (the deal) or "A" (a betting action)
function Engine.Expect(m)
    if m.over then return nil end
    local h = m.hand
    if h.phase == "commit" then return 3 - h.button, "K" end
    if h.phase == "seed" then return h.button, "S" end
    if h.phase == "reveal" then return 3 - h.button, "R" end
    if h.phase == "bet" and h.toAct then return h.toAct, "A" end
    return nil
end

-- does this seat still have to act on this street
local function needs(m, h, i)
    local o = 3 - i
    if m.stacks[i] == 0 then return false end
    if h.bet[i] < h.bet[o] then return true end
    return not h.acted[i] and m.stacks[o] > 0
end

local function finishHand(m, h, result)
    h.phase, h.result, h.toAct = "done", result, nil
    h.endStacks = { m.stacks[1], m.stacks[2] }
    m.last = h
    if m.stacks[1] == 0 or m.stacks[2] == 0 then
        m.over = true
        m.winner = m.stacks[1] > 0 and 1 or 2
        m.hand = h
        return
    end
    Engine.StartHand(m, h.n + 1, m.stacks[1], m.stacks[2])
end

local function showdown(m, h)
    local ev = m.opts.variant == "PLO" and Eval.Omaha or Eval.Holdem
    local board = {}
    for i = 1, 5 do board[i] = h.board[i] end
    local s1, b1 = ev(h.holes[1], board)
    local s2, b2 = ev(h.holes[2], board)
    local won = { 0, 0 }
    local winner
    if s1 > s2 then winner = 1 elseif s2 > s1 then winner = 2 else winner = 0 end
    if winner == 0 then
        local half = floor(h.pot / 2)
        won[1], won[2] = half, half
        -- the odd chip goes to the player out of position (the big blind)
        won[3 - h.button] = won[3 - h.button] + (h.pot - 2 * half)
    else
        won[winner] = h.pot
    end
    m.stacks[1], m.stacks[2] = m.stacks[1] + won[1], m.stacks[2] + won[2]
    finishHand(m, h, { winner = winner, won = won, pot = h.pot, showdown = true, allin = h.allin, runFrom = h.runFrom,
        scores = { s1, s2 }, best = { b1, b2 }, names = { Eval.Name(s1), Eval.Name(s2) } })
end

local begin
local function endStreet(m, h)
    h.toAct = nil
    local b1, b2 = h.bet[1], h.bet[2]
    if b1 ~= b2 then
        -- the part of a bet the all-in player couldn't match goes back
        local hi = b1 > b2 and 1 or 2
        local d = abs(b1 - b2)
        m.stacks[hi] = m.stacks[hi] + d
        h.bet[hi], h.total[hi] = h.bet[hi] - d, h.total[hi] - d
        h.refund = { seat = hi, amount = d }
    end
    h.pot = h.pot + h.bet[1] + h.bet[2]
    h.bet = { 0, 0 }
    if h.street == 3 then return showdown(m, h) end
    if m.stacks[1] == 0 or m.stacks[2] == 0 then
        -- how much of the board was out when the betting stopped (the window deals the rest slowly)
        h.runFrom = Engine.BoardShown(h)
        h.street, h.allin = 3, true
        return showdown(m, h)
    end
    h.street = h.street + 1
    h.acted, h.lastRaise, h.said = { false, false }, h.bb, {}
    begin(m, h, 3 - h.button)
end
begin = function(m, h, first)
    if needs(m, h, first) then h.toAct = first
    elseif needs(m, h, 3 - first) then h.toAct = 3 - first
    else endStreet(m, h) end
end

-- What the player to act may do:
--   { seat, toCall, fold = bool, check = bool, call = chips or nil, minTo, maxTo, bet = bool (no bet yet), allinTo }
-- minTo/maxTo are "raise to" totals for this street; nil when no raise is possible.
function Engine.Legal(m)
    if m.over then return nil end
    local h = m.hand
    if h.phase ~= "bet" or not h.toAct then return nil end
    local i = h.toAct
    local o = 3 - i
    local st = m.stacks
    local toCall = max(0, h.bet[o] - h.bet[i])
    local L = { seat = i, toCall = toCall, fold = toCall > 0, check = toCall == 0,
        call = toCall > 0 and min(toCall, st[i]) or nil, allinTo = h.bet[i] + st[i] }
    if st[o] > 0 and st[i] > toCall then
        local high = max(h.bet[1], h.bet[2])
        local maxTo = min(h.bet[i] + st[i], h.bet[o] + st[o])
        if m.opts.variant == "PLO" then
            maxTo = min(maxTo, high + h.pot + h.bet[1] + h.bet[2] + toCall)
        end
        if maxTo > high then
            L.minTo, L.maxTo = min(high + h.lastRaise, maxTo), maxTo
            L.bet = high == 0
        end
    end
    return L
end

local function bettingAction(m, h, seat, msg)
    local L = Engine.Legal(m)
    if not L or L.seat ~= seat then return false, "not your turn" end
    local o = 3 - seat
    local kind = msg:sub(1, 1)
    if kind == "F" then
        if not L.fold then return false, "nothing to fold to" end
        h.said[seat] = { "fold" }
        h.pot = h.pot + h.bet[1] + h.bet[2]
        h.bet = { 0, 0 }
        m.stacks[o] = m.stacks[o] + h.pot
        local won = { 0, 0 }
        won[o] = h.pot
        finishHand(m, h, { winner = o, won = won, pot = h.pot, fold = seat })
        return true
    elseif kind == "X" then
        if not L.check then return false, "can't check" end
        h.said[seat] = { "check" }
    elseif kind == "C" then
        if not L.call then return false, "nothing to call" end
        post(m, h, seat, L.call)
        h.said[seat] = { "call", h.bet[seat], allin = m.stacks[seat] == 0 }
    elseif kind == "B" then
        local to = tonumber(msg:match("^B(%d+)$"))
        if not (to and L.minTo and to >= L.minTo and to <= L.maxTo) then return false, "bad amount" end
        local high = max(h.bet[1], h.bet[2])
        post(m, h, seat, to - h.bet[seat])
        if to - high >= h.lastRaise then h.lastRaise = to - high end
        h.said[seat] = { L.bet and "bet" or "raise", to, allin = m.stacks[seat] == 0 }
    else
        return false, "unknown action"
    end
    h.acted[seat] = true
    h.last = { seat = seat, kind = kind }
    if needs(m, h, o) then h.toAct = o
    elseif needs(m, h, seat) then h.toAct = seat
    else endStreet(m, h) end
    return true
end

-- Applies one message from a seat. Returns true, or false and why (the state is then unchanged).
function Engine.Apply(m, seat, msg)
    if m.over then return false, "match over" end
    msg = tostring(msg or "")
    local wantSeat, wantKind = Engine.Expect(m)
    if seat ~= wantSeat then return false, "out of turn" end
    local h = m.hand
    local kind = msg:sub(1, 1)
    if wantKind == "K" then
        local c = msg:match("^K(%x+)$")
        if not c or #c ~= 16 then return false, "bad commit" end
        h.commit, h.phase = c:lower(), "seed"
    elseif wantKind == "S" then
        local n = msg:match("^S(%d+)$")
        if not n or #n > 10 then return false, "bad seed" end
        h.seedB, h.phase = n, "reveal"
    elseif wantKind == "R" then
        if kind == "Z" and msg == "Z" then
            h.commit, h.seedB, h.phase = nil, nil, "commit"
        else
            local secret = msg:match("^R([%w%.]+)$")
            if not secret or #secret > 40 then return false, "bad reveal" end
            if Engine.Commit(secret, m.salt, h.n) ~= h.commit then
                m.cheat = true
                return false, "reveal doesn't match the commit"
            end
            h.secret = secret
            local deck = deckFor(m, h)
            local k = Engine.Cards(m)
            for i = 1, k do
                h.holes[1][i] = deck[i]
                h.holes[2][i] = deck[k + i]
            end
            for i = 1, 5 do h.board[i] = deck[2 * k + i] end
            h.phase = "bet"
            begin(m, h, h.button)
        end
    else
        local ok, err = bettingAction(m, h, seat, msg)
        if not ok then return false, err end
    end
    h.log[#h.log + 1] = msg
    return true
end

-- ---------------------------------------------------------------- snapshots
-- Everything needed to rebuild the match: the options, the current hand's start and messages, and
-- the last finished hand the same way (so its result can still be shown). The secret for a hand
-- that hasn't been revealed is never in here; only messages already sent are.
--   "P1;opts;n;s1;s2;msgs;lastN;ls1;ls2;lastMsgs"
local function replay(m, n, s1, s2, msgs)
    Engine.StartHand(m, n, s1, s2)
    for msg in tostring(msgs or ""):gmatch("[^,]+") do
        local seat = Engine.Expect(m)
        if not seat or not Engine.Apply(m, seat, msg) then return false end
    end
    return true
end
function Engine.Snapshot(m)
    local h, l = m.hand, m.last
    local cur = (not m.over and h) and ("%d;%d;%d;%s"):format(h.n, h.startStacks[1], h.startStacks[2], table.concat(h.log, ",")) or "0;0;0;"
    local last = l and ("%d;%d;%d;%s"):format(l.n, l.startStacks[1], l.startStacks[2], table.concat(l.log, ",")) or "0;0;0;"
    return ("P1;%s;%s;%s"):format(m.optsText, cur, last)
end
function Engine.FromSnapshot(text, salt)
    local opts, n, s1, s2, msgs, ln, l1, l2, lmsgs =
        tostring(text or ""):match("^P1;([^;]*);(%d+);(%d+);(%d+);([^;]*);(%d+);(%d+);(%d+);([^;]*)$")
    if not opts then return nil end
    local m = Engine.NewMatch(opts, salt)
    n, ln = tonumber(n), tonumber(ln)
    if ln > 0 and not replay(m, ln, tonumber(l1), tonumber(l2), lmsgs) then return nil end
    if n > 0 then
        local last = m.last
        if not replay(m, n, tonumber(s1), tonumber(s2), msgs) then return nil end
        if m.last == nil then m.last = last end
    elseif not m.over then
        return nil
    end
    return m
end

-- a line for the hand history: "raises to 120"
function Engine.Said(said)
    if not said then return nil end
    local k, amt = said[1], said[2]
    local a = said.allin and " (all-in)" or ""
    if k == "fold" then return "Fold" end
    if k == "check" then return "Check" end
    if k == "call" then return "Call" .. a end
    if k == "bet" then return "Bet " .. amt .. a end
    if k == "raise" then return "Raise to " .. amt .. a end
    return nil
end

return Engine
