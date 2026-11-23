-- The rules of a poker table for 2 to 9 players: blinds, betting, side pots, the deal and the
-- showdown. Pure Lua with no game client calls, so the tests run it outside WoW.
--
-- Every player runs this same engine on the same messages in the same order (the host puts them in
-- order, see Table.lua), so everyone always agrees on the state. Seats are 1..N in the order the host
-- seated everyone. The button starts on seat 1 and moves to the next player with chips each hand.
-- With three or more players the two seats after the button post the blinds and the seat after the
-- big blind acts first. Heads-up (two players left), the button posts the small blind and acts first
-- before the flop and last after it.
--
-- Messages (each one is a move, sent by whoever Engine.Expect says):
--   K<hex>   the big blind commits to a secret        (phase "commit")
--   S<n>     the button answers with its own number   (phase "seed")
--   R<text>  the big blind reveals the secret: the deck is now shuffled from both
--   Z        the big blind lost its secret (a crash): commit again
--   F  X  C  B<to>   fold, check, call, bet or raise to <to> (this street's total)
--   W        the player to act starts on their time bank (the turn doesn't change)
--   O<seat>  (from seat 0, the host) that player left the table: they fold, and their chips leave too
--   U<seat><secs>  (from seat 0, the host) the player to act used this many seconds of their time bank
--   T<seat>  (from seat 0, the host) the player to act ran out of time: they check if they can, else fold
--
-- The clock: each decision has a shot clock of SHOT_CLOCK seconds. After that, a player who has
-- started on their time bank (W) gets whatever is left of it; the bank lasts the whole game. Only the
-- host keeps time (Table.lua): it charges the bank (U) and times players out (T), so everyone agrees.
--
-- The shuffle can't be steered by either dealer: the secret is fixed (committed) before the other
-- number is known, and the other number is chosen without knowing the secret. It is not a hidden
-- deck: once the secret is revealed every client could work out every card. The addon only ever
-- shows your own cards, plus the others' at a showdown. Play chips only.
local _, ns = ...
ns = ns or {}
local Engine = {}
ns.Engine = Engine
local Eval = ns.Eval

local floor, min, max = math.floor, math.min, math.max

Engine.UNIT = 20 -- the first big blind; stacks are counted in these
Engine.MAX_SEATS = 9
Engine.SHOT_CLOCK = 24  -- seconds for each decision
Engine.TIME_BANK = 120  -- extra seconds each player has for the whole game
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

-- ---------------------------------------------------------------- seats
local function copy(t, n)
    local c = {}
    for i = 1, n do c[i] = t[i] end
    return c
end
-- the first seat after `from` (going round the table, `from` itself last) that passes ok(i)
local function after(m, from, ok)
    local N = m.seats
    for d = 1, N do
        local i = (from - 1 + d) % N + 1
        if ok(i) then return i end
    end
    return nil
end
-- the same, but `from` itself first
local function atOrAfter(m, from, ok)
    return after(m, (from - 2) % m.seats + 1, ok)
end
Engine.After = after

-- in the hand and not folded
local function live(h, i) return h.inHand[i] and not h.folded[i] end
-- still able to bet: in the hand, not folded, chips behind
local function canAct(m, h, i) return live(h, i) and m.stacks[i] > 0 end
local function highBet(m, h)
    local hi = 0
    for i = 1, m.seats do if h.bet[i] > hi then hi = h.bet[i] end end
    return hi
end
local function sumBets(m, h)
    local s = 0
    for i = 1, m.seats do s = s + h.bet[i] end
    return s
end
local function countLive(m, h)
    local n, last = 0, nil
    for i = 1, m.seats do if live(h, i) then n, last = n + 1, i end end
    return n, last
end
Engine.Live = live

-- ---------------------------------------------------------------- the match
local function post(m, h, seat, amount)
    local a = min(amount, m.stacks[seat])
    m.stacks[seat] = m.stacks[seat] - a
    h.bet[seat] = h.bet[seat] + a
    h.total[seat] = h.total[seat] + a
    return a
end

-- who runs the deal: the big blind commits, the button answers (the next players along stand in for
-- anyone who has left the table)
local function pickDealers(m, h)
    local function here(i) return h.inHand[i] and not m.out[i] end
    h.committer = atOrAfter(m, h.bbSeat, here)
    h.answerer = h.committer and atOrAfter(m, h.button, function(i) return here(i) and i ~= h.committer end)
end

-- out[i]: nil while seat i is playing, "bust" or "left" once it isn't; place[i]: where it finished;
-- bank[i]: seconds of time bank left (a full bank when nil)
function Engine.StartHand(m, n, stacks, button, out, place, bank)
    local N = m.seats
    m.stacks = copy(stacks, N)
    m.out = copy(out or {}, N)
    m.place = copy(place or {}, N)
    m.bank = {}
    for i = 1, N do
        m.bank[i] = max(0, min(Engine.TIME_BANK, floor(tonumber(bank and bank[i]) or Engine.TIME_BANK)))
    end
    local sb, bb = Engine.Blinds(m.opts, n)
    local h = { n = n, button = button, sb = sb, bb = bb, phase = "commit", log = {},
        startStacks = copy(stacks, N), startOut = copy(m.out, N), startPlace = copy(m.place, N),
        startBank = copy(m.bank, N), turn = 0,
        bet = {}, total = {}, acted = {}, actedAt = {}, folded = {}, inHand = {}, holes = {}, said = {},
        pot = 0, street = 0, lastRaise = bb, raises = 0, board = {} }
    local players = 0
    for i = 1, N do
        h.bet[i], h.total[i], h.acted[i], h.actedAt[i], h.holes[i] = 0, 0, false, 0, {}
        h.inHand[i] = not m.out[i]
        h.folded[i] = false
        if h.inHand[i] then players = players + 1 end
    end
    h.players = players
    local function inHand(i) return h.inHand[i] end
    if players == 2 then
        h.sbSeat = button
        h.bbSeat = after(m, button, inHand)
    else
        h.sbSeat = after(m, button, inHand)
        h.bbSeat = after(m, h.sbSeat, inHand)
    end
    m.hand = h
    post(m, h, h.sbSeat, sb)
    post(m, h, h.bbSeat, bb)
    pickDealers(m, h)
    return h
end

function Engine.NewMatch(optsText, salt, seats)
    local o = Engine.ParseOpts(optsText)
    seats = max(2, min(Engine.MAX_SEATS, floor(tonumber(seats) or 2)))
    local start = o.stackBB * Engine.UNIT
    local m = { opts = o, optsText = Engine.OptsText(o), salt = tostring(salt or ""), start = start, seats = seats, burned = 0 }
    local stacks = {}
    for i = 1, seats do stacks[i] = start end
    Engine.StartHand(m, 1, stacks, 1, {}, {})
    return m
end

function Engine.Cards(m) return m.opts.variant == "PLO" and 4 or 2 end
function Engine.BoardShown(h)
    if h.result and h.result.showdown then return 5 end
    return ({ [0] = 0, 3, 4, 5 })[h.street] or 0
end
-- every chip at the table: stacks, bets and the pot (and nothing a leaver took away)
function Engine.Chips(m)
    local s = 0
    for i = 1, m.seats do s = s + m.stacks[i] end
    local h = m.hand
    if not m.over and h and h.phase ~= "done" then s = s + h.pot + sumBets(m, h) end
    return s
end
function Engine.Pot(m, h)
    h = h or m.hand
    return h.pot + sumBets(m, h)
end
function Engine.HighBet(m, h) return highBet(m, h or m.hand) end

-- who must send the next message, and what kind: "K" "S" "R" (the deal) or "A" (a betting action)
function Engine.Expect(m)
    if m.over then return nil end
    local h = m.hand
    if h.phase == "commit" then return h.committer, "K" end
    if h.phase == "seed" then return h.answerer, "S" end
    if h.phase == "reveal" then return h.committer, "R" end
    if h.phase == "bet" and h.toAct then return h.toAct, "A" end
    return nil
end

-- does this seat still have to act on this street
local function needs(m, h, i)
    if not canAct(m, h, i) then return false end
    if h.bet[i] < highBet(m, h) then return true end
    if h.acted[i] then return false end
    -- hasn't acted yet: only worth it if someone else could still answer a bet
    for j = 1, m.seats do
        if j ~= i and canAct(m, h, j) then return true end
    end
    return false
end

local function finishHand(m, h, result)
    local N = m.seats
    h.phase, h.result, h.toAct = "done", result, nil
    h.endStacks = copy(m.stacks, N)
    m.last = h
    -- who is out after this hand: the best place goes to whoever started it with more chips
    local gone = {}
    for i = 1, N do
        if not m.out[i] and m.stacks[i] == 0 then gone[#gone + 1] = i end
    end
    local alive = 0
    for i = 1, N do if not m.out[i] and m.stacks[i] > 0 then alive = alive + 1 end end
    table.sort(gone, function(a, b)
        -- leaving places below going bust, and leaving later places above leaving earlier
        local la, lb = h.left and h.left[a], h.left and h.left[b]
        if (la ~= nil) ~= (lb ~= nil) then return lb ~= nil end
        if la and lb then return la > lb end
        if h.startStacks[a] ~= h.startStacks[b] then return h.startStacks[a] > h.startStacks[b] end
        return a < b
    end)
    for k, i in ipairs(gone) do
        m.place[i] = alive + k
        m.out[i] = (h.left and h.left[i]) and "left" or "bust"
    end
    if alive <= 1 then
        m.over = true
        for i = 1, N do
            if not m.out[i] then m.winner, m.place[i] = i, 1 end
        end
        m.hand = h
        return
    end
    local btn = after(m, h.button, function(i) return not m.out[i] end)
    Engine.StartHand(m, h.n + 1, m.stacks, btn, m.out, m.place, m.bank)
end

-- everyone else folded (or left): the last one standing takes every chip in the middle
local function winByFold(m, h, folder)
    local _, w = countLive(m, h)
    h.pot = h.pot + sumBets(m, h)
    for i = 1, m.seats do h.bet[i] = 0 end
    h.toAct = nil
    local won = {}
    for i = 1, m.seats do won[i] = 0 end
    if w then
        m.stacks[w] = m.stacks[w] + h.pot
        won[w] = h.pot
    else
        m.burned = m.burned + h.pot
    end
    finishHand(m, h, { winner = w or 0, won = won, pot = h.pot, fold = folder,
        pots = { { amount = h.pot, winners = { w } } } })
end

-- seats in the order chips are handed out: left of the button first
local function fromButton(m, h, set)
    local list = {}
    for d = 1, m.seats do
        local i = (h.button - 1 + d) % m.seats + 1
        if set[i] then list[#list + 1] = i end
    end
    return list
end

local function showdown(m, h)
    local N = m.seats
    local ev = m.opts.variant == "PLO" and Eval.Omaha or Eval.Holdem
    local board = {}
    for i = 1, 5 do board[i] = h.board[i] end
    local scores, best, names = {}, {}, {}
    local levels, seen = {}, {}
    for i = 1, N do
        if live(h, i) then
            scores[i], best[i] = ev(h.holes[i], board)
            names[i] = Eval.Name(scores[i])
            local c = h.total[i]
            if c > 0 and not seen[c] then seen[c], levels[#levels + 1] = true, c end
        end
    end
    table.sort(levels)
    local won = {}
    for i = 1, N do won[i] = 0 end
    -- one pot per all-in level: the main pot first, then the side pots
    local pots, prev = {}, 0
    for k, v in ipairs(levels) do
        local amount = 0
        for i = 1, N do
            local c = h.total[i]
            local top = k == #levels and c or min(c, v) -- the last pot takes anything left over
            amount = amount + max(0, top - min(c, prev))
        end
        local top, winners = nil, {}
        for i = 1, N do
            if live(h, i) and h.total[i] >= v then
                if not top or scores[i] > top then top, winners = scores[i], { [i] = true }
                elseif scores[i] == top then winners[i] = true end
            end
        end
        local order = fromButton(m, h, winners)
        if amount > 0 and #order > 0 then
            local share = floor(amount / #order)
            local odd = amount - share * #order
            for j, i in ipairs(order) do
                -- the odd chips go one each to the winners nearest the button's left
                won[i] = won[i] + share + (j <= odd and 1 or 0)
            end
            local p = pots[#pots]
            -- a pot with the same winners as the one before it is the same pot as far as anyone can see
            if p and table.concat(p.winners, ",") == table.concat(order, ",") then
                p.amount = p.amount + amount
            else
                pots[#pots + 1] = { amount = amount, winners = order }
            end
        end
        prev = v
    end
    local total = 0
    for i = 1, N do
        m.stacks[i] = m.stacks[i] + won[i]
        total = total + won[i]
    end
    local main = pots[1] and pots[1].winners or {}
    finishHand(m, h, { winner = #main == 1 and main[1] or 0, won = won, pot = total, pots = pots, showdown = true,
        allin = h.allin, runFrom = h.runFrom, scores = scores, best = best, names = names })
end

local begin
local function endStreet(m, h)
    local N = m.seats
    h.toAct = nil
    -- the part of a bet nobody could match goes back
    local top, topSeat, second = -1, nil, 0
    for i = 1, N do
        local b = h.bet[i]
        if b > top then top, topSeat, second = b, i, max(second, top)
        elseif b > second then second = b end
    end
    if topSeat and top > second then
        local d = top - second
        m.stacks[topSeat] = m.stacks[topSeat] + d
        h.bet[topSeat], h.total[topSeat] = h.bet[topSeat] - d, h.total[topSeat] - d
        h.refund = { seat = topSeat, amount = d }
    end
    h.pot = h.pot + sumBets(m, h)
    for i = 1, N do h.bet[i] = 0 end
    if h.street == 3 then return showdown(m, h) end
    local able = 0
    for i = 1, N do if canAct(m, h, i) then able = able + 1 end end
    if able <= 1 then
        -- how much of the board was out when the betting stopped (the window deals the rest slowly)
        h.runFrom = Engine.BoardShown(h)
        h.street, h.allin = 3, true
        return showdown(m, h)
    end
    h.street = h.street + 1
    h.lastRaise, h.raises, h.said = h.bb, 0, {}
    for i = 1, N do h.acted[i], h.actedAt[i] = false, 0 end
    begin(m, h, h.button)
end
-- the first seat after `from` that has to act, or the end of the street
begin = function(m, h, from)
    if countLive(m, h) <= 1 then return winByFold(m, h, h.last and h.last.seat) end
    local i = after(m, from, function(s) return needs(m, h, s) end)
    if i then
        -- a new decision: a fresh shot clock, and no time bank running yet
        h.toAct, h.turn, h.banking = i, h.turn + 1, nil
    else
        endStreet(m, h)
    end
end

-- an id for the decision being made; it changes whenever a new one starts (and the clock restarts)
function Engine.TurnKey(m)
    local h = m.hand
    if m.over or h.phase ~= "bet" or not h.toAct then return nil end
    return h.n .. ":" .. h.turn
end

-- What the player to act may do:
--   { seat, toCall, fold = bool, check = bool, call = chips or nil, minTo, maxTo, bet = bool (no bet yet), allinTo }
-- minTo/maxTo are "raise to" totals for this street; nil when no raise is possible.
function Engine.Legal(m)
    if m.over then return nil end
    local h = m.hand
    if h.phase ~= "bet" or not h.toAct then return nil end
    local i = h.toAct
    local st = m.stacks
    local high = highBet(m, h)
    local toCall = max(0, high - h.bet[i])
    local L = { seat = i, toCall = toCall, fold = toCall > 0, check = toCall == 0,
        call = toCall > 0 and min(toCall, st[i]) or nil, allinTo = h.bet[i] + st[i] }
    -- the most anyone else could still put in on this street: no point betting past that
    local others = nil
    for j = 1, m.seats do
        if j ~= i and canAct(m, h, j) then others = max(others or 0, h.bet[j] + st[j]) end
    end
    -- a raise all-in for less than a full raise doesn't let those who already acted raise again
    local open = not h.acted[i] or h.actedAt[i] < h.raises
    if others and open and st[i] > toCall then
        local maxTo = min(h.bet[i] + st[i], others)
        if m.opts.variant == "PLO" then
            maxTo = min(maxTo, high + h.pot + sumBets(m, h) + toCall)
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
    local kind = msg:sub(1, 1)
    if msg == "W" then
        if h.banking then return false, "already on the time bank" end
        if (m.bank[seat] or 0) <= 0 then return false, "no time bank left" end
        h.banking = true
        return true
    end
    if kind == "F" then
        if not L.fold then return false, "nothing to fold to" end
        h.folded[seat] = true
        h.said[seat] = { "fold" }
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
        local high = highBet(m, h)
        post(m, h, seat, to - h.bet[seat])
        if to - high >= h.lastRaise then
            h.lastRaise = to - high
            h.raises = h.raises + 1
        end
        h.said[seat] = { L.bet and "bet" or "raise", to, allin = m.stacks[seat] == 0 }
    else
        return false, "unknown action"
    end
    h.acted[seat] = true
    h.actedAt[seat] = h.raises
    h.last = { seat = seat, kind = kind }
    begin(m, h, seat)
    return true
end

-- a player left the table (or the host removed them): they fold, and the chips in front of them go
-- with them; anything they already put in stays in the pot
local function leave(m, h, s)
    if not (s and s >= 1 and s <= m.seats) or m.out[s] or (h.left and h.left[s]) then return false, "not at the table" end
    h.left = h.left or {}
    local order = 0
    for _ in pairs(h.left) do order = order + 1 end
    h.left[s] = order + 1
    m.burned = m.burned + m.stacks[s]
    m.stacks[s] = 0
    local wasLive = live(h, s)
    if wasLive then
        h.folded[s] = true
        h.said[s] = { "left" }
    end
    if h.phase == "bet" then
        if countLive(m, h) <= 1 then
            winByFold(m, h, s)
        elseif h.toAct == s or not (h.toAct and needs(m, h, h.toAct)) then
            begin(m, h, h.toAct or s)
        end
    else
        -- before the cards are out: the deal goes on with whoever is still here
        if countLive(m, h) <= 1 then
            winByFold(m, h, s)
        elseif s == h.committer or s == h.answerer then
            h.commit, h.seedB, h.phase = nil, nil, "commit"
            local keep = m.out[s]
            m.out[s] = "left" -- only for picking the dealers
            pickDealers(m, h)
            m.out[s] = keep
        end
    end
    return true
end

-- the host charges the player to act for time they took from their bank: "U<seat><secs>"
local function useBank(m, h, msg)
    local s, secs = msg:match("^U(%d)(%d+)$")
    s, secs = tonumber(s), tonumber(secs)
    if not (s and secs and secs > 0) then return false, "bad time bank message" end
    if h.phase ~= "bet" or h.toAct ~= s or not h.banking then return false, "not on the time bank" end
    m.bank[s] = max(0, m.bank[s] - secs)
    return true
end

-- the player to act ran out of time: a check if that's free, otherwise a fold. A bank that was
-- running is all used up.
local function timeOut(m, h, msg)
    local s = tonumber(msg:match("^T(%d)$"))
    if not s then return false, "bad time out" end
    if h.phase ~= "bet" or h.toAct ~= s then return false, "not their turn" end
    -- the bank goes first: the fold can end the hand, and the next one starts from these banks
    local had = m.bank[s]
    if h.banking then m.bank[s] = 0 end
    local L = Engine.Legal(m)
    local ok, err = bettingAction(m, h, s, L and L.check and "X" or "F")
    if not ok then
        m.bank[s] = had
        return false, err
    end
    if h.said[s] then h.said[s].timeout = true end
    return true
end

-- Applies one message from a seat (0 for the host's own messages). Returns true, or false and why
-- (the state is then unchanged).
function Engine.Apply(m, seat, msg)
    if m.over then return false, "match over" end
    msg = tostring(msg or "")
    local h = m.hand
    local kind = msg:sub(1, 1)
    if seat == 0 then
        local ok, err
        if kind == "O" then
            local s = tonumber(msg:match("^O(%d)$"))
            if not s then return false, "unknown table message" end
            ok, err = leave(m, h, s)
        elseif kind == "U" then
            ok, err = useBank(m, h, msg)
        elseif kind == "T" then
            ok, err = timeOut(m, h, msg)
        else
            return false, "unknown table message"
        end
        if not ok then return false, err end
        h.log[#h.log + 1] = msg
        return true
    end
    local wantSeat, wantKind = Engine.Expect(m)
    if seat ~= wantSeat then return false, "out of turn" end
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
            -- one card at a time round the table, starting left of the button, as a dealer would
            local at = 0
            for c = 1, k do
                for _, i in ipairs(fromButton(m, h, h.inHand)) do
                    at = at + 1
                    h.holes[i][c] = deck[at]
                end
            end
            for i = 1, 5 do h.board[i] = deck[at + i] end
            h.phase = "bet"
            -- before the flop the player after the big blind starts (heads-up that's the button)
            begin(m, h, h.bbSeat)
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
--   "P3;opts;seats;<hand>;<last hand>"   with each hand "n;button;stacks;places;banks;msgs"
-- places: "-" for a seat still playing, "5" for one that went bust in 5th, "L4" for one that left in 4th
local function seatsText(m, out, place)
    local t = {}
    for i = 1, m.seats do
        t[i] = not out[i] and "-" or ((out[i] == "left" and "L" or "") .. tostring(place[i] or 0))
    end
    return table.concat(t, ",")
end
local function handText(m, h)
    if not h then return "0;0;;;;" end
    return ("%d;%d;%s;%s;%s;%s"):format(h.n, h.button, table.concat(h.startStacks, ","),
        seatsText(m, h.startOut, h.startPlace), table.concat(h.startBank, ","), table.concat(h.log, ","))
end
local SEAT0 = { O = true, U = true, T = true } -- the host's own messages
local function replay(m, n, button, stacksText, seatText, bankText, msgs)
    local stacks, out, place, bank = {}, {}, {}, {}
    for v in stacksText:gmatch("[^,]+") do stacks[#stacks + 1] = tonumber(v) end
    for v in bankText:gmatch("[^,]+") do bank[#bank + 1] = tonumber(v) end
    if #bank ~= m.seats then return false end
    local i = 0
    for v in seatText:gmatch("[^,]+") do
        i = i + 1
        if v ~= "-" then
            out[i] = v:sub(1, 1) == "L" and "left" or "bust"
            place[i] = tonumber((v:gsub("^L", ""))) or 0
        end
    end
    if #stacks ~= m.seats or i ~= m.seats then return false end
    if not (button >= 1 and button <= m.seats) then return false end
    Engine.StartHand(m, n, stacks, button, out, place, bank)
    for msg in tostring(msgs or ""):gmatch("[^,]+") do
        local seat = SEAT0[msg:sub(1, 1)] and 0 or Engine.Expect(m)
        if not seat or not Engine.Apply(m, seat, msg) then return false end
    end
    return true
end
function Engine.Snapshot(m)
    return ("P3;%s;%d;%s;%s"):format(m.optsText, m.seats, handText(m, not m.over and m.hand or nil), handText(m, m.last))
end
function Engine.FromSnapshot(text, salt)
    local H = "(%d+);(%d+);([^;]*);([^;]*);([^;]*);([^;]*)"
    local opts, seats, n, b, s, p, k, msgs, ln, lb, ls, lp, lk, lmsgs = tostring(text or ""):match(
        "^P3;([^;]*);(%d+);" .. H .. ";" .. H .. "$")
    if not opts then return nil end
    local m = Engine.NewMatch(opts, salt, tonumber(seats))
    if m.seats ~= tonumber(seats) then return nil end
    n, ln = tonumber(n), tonumber(ln)
    -- the burned chips aren't kept: Chips() counts what is at the table, which is all anyone needs
    if ln > 0 and not replay(m, ln, tonumber(lb), ls, lp, lk, lmsgs) then return nil end
    if n > 0 then
        if m.over then return nil end -- the last hand ended the match, so there is no hand after it
        local last = m.last
        if not replay(m, n, tonumber(b), s, p, k, msgs) then return nil end
        if m.last == nil then m.last = last end
    elseif not m.over then
        return nil
    end
    return m
end

-- a line for the hand history: "Raise to 120"
function Engine.Said(said)
    if not said then return nil end
    local k, amt = said[1], said[2]
    local a = said.allin and " (all-in)" or ""
    if said.timeout then return k == "check" and "Check (out of time)" or "Fold (out of time)" end
    if k == "fold" then return "Fold" end
    if k == "left" then return "Left" end
    if k == "check" then return "Check" end
    if k == "call" then return "Call" .. a end
    if k == "bet" then return "Bet " .. amt .. a end
    if k == "raise" then return "Raise to " .. amt .. a end
    return nil
end

-- "1st", "2nd", "3rd", "4th"
function Engine.Ordinal(n)
    n = tonumber(n) or 0
    local s = "th"
    if n % 100 < 11 or n % 100 > 13 then s = ({ "st", "nd", "rd" })[n % 10] or "th" end
    return n .. s
end

return Engine
