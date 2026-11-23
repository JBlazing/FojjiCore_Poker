-- Plain Lua 5.1 tests for Eval.lua and Engine.lua. Run from the repo root:  lua tests/test_engine.lua
local ADDON = "FojjiCore_Poker/"
local ns = {}
for _, f in ipairs({ "Eval.lua", "Engine.lua" }) do
    local chunk = assert(loadfile(ADDON .. f))
    chunk("FojjiCore_Poker", ns)
end
local Eval, Engine = ns.Eval, ns.Engine

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. msg) end
end
local function eq(a, b, msg) check(a == b, ("%s (got %s, want %s)"):format(msg, tostring(a), tostring(b))) end
local function cards(text)
    local t = {}
    for w in text:gmatch("%S+") do t[#t + 1] = assert(Eval.Parse(w), w) end
    return t
end
local function five(text) return Eval.Five(unpack(cards(text))) end

-- ---------------------------------------------------------------- hand values
local ladder = {
    "As Ks Qs Js Ts", "9h 8h 7h 6h 5h", "5d 4d 3d 2d Ad", "Ac Ad Ah As 2c", "Kc Kd Kh Ks Ac",
    "Qc Qd Qh 2s 2c", "Jc Jd Jh As Ac", "Ah 9h 7h 4h 2h", "Kh Qh Jh 9h 8h", "Ac Kd Qh Js Tc",
    "6c 5d 4h 3s 2c", "5c 4d 3h 2s Ac", "8c 8d 8h Ks 2c", "8c 8d 8h Qs Jc", "Ac Ad Kh Ks 2c",
    "Ac Ad Qh Qs Kc", "Ac Ad Qh Qs Jc", "Kc Kd Qh Qs Ac", "Ac Ad Ks Qd Jh", "Ac Ad Ks Qd Th",
    "Kc Kd As Qd Jh", "Ac Kd Qh Js 9c", "Ac Kd Qh Js 8c", "7c 5d 4h 3s 2c",
}
for i = 1, #ladder - 1 do
    check(five(ladder[i]) > five(ladder[i + 1]), ladder[i] .. " should beat " .. ladder[i + 1])
end
eq(five("As Ks Qs Js Ts"), five("Ah Kh Qh Jh Th"), "suits don't matter")
eq(five("Ac Ad Ah As 2c"), five("2c Ac Ad As Ah"), "order doesn't matter")
eq(Eval.Name(five("As Ks Qs Js Ts")), "Royal flush", "royal name")
eq(Eval.Name(five("5d 4d 3d 2d Ad")), "Straight flush, Five high", "steel wheel name")
eq(Eval.Name(five("5c 4d 3h 2s Ac")), "Straight, Five high", "wheel name")
eq(Eval.Name(five("Qc Qd Qh 2s 2c")), "Full house, Queens over Twos", "boat name")
eq(Eval.Name(five("Ac Ad Qh Qs Kc")), "Two pair, Aces and Queens", "two pair name")
eq(Eval.Name(five("9c 9d Ah Qs Kc")), "Pair of Nines", "pair name")
eq(Eval.Name(five("Ac Jd 8h 4s 2c")), "Ace high", "high card name")

-- the hand you hold right now, street by street
eq(Eval.Current(cards("Kc 7d"), {}), "King high", "preflop high card")
eq(Eval.Current(cards("7c 7d"), {}), "Pair of Sevens", "preflop pair")
eq(Eval.Current(cards("Kc 7d"), cards("Kh 7s 2c")), "Two pair, Kings and Sevens", "flop two pair")
eq(Eval.Current(cards("Kc 7d"), cards("Kh 7s 2c 7h")), "Full house, Sevens over Kings", "turn boat")
eq(Eval.Current(cards("Ah Kh 2c 3d"), {}, true), "Ace high", "omaha preflop high")
eq(Eval.Current(cards("9h 9d 2c 2d"), {}, true), "Pair of Nines", "omaha preflop pair")
eq(Eval.Current(cards("Ah Kd 2c 3d"), cards("Qh Jh Th"), true), "Straight, Ace high", "omaha uses two hole cards")
eq(Eval.Current(cards("Ah 4c 5c 6c"), cards("Kh Qh Jh"), true), "Ace high", "omaha needs two hole cards for a flush")
eq(Eval.Current({}, {}), "", "no cards yet")

-- every one of the 2,598,960 five-card hands gets a category with the right frequency
do
    local count = {}
    for a = 1, 48 do for b = a + 1, 49 do for c = b + 1, 50 do for d = c + 1, 51 do for e = d + 1, 52 do
        local cat = Eval.Category(Eval.Five(a, b, c, d, e))
        count[cat] = (count[cat] or 0) + 1
    end end end end end
    local want = { [0] = 1302540, 1098240, 123552, 54912, 10200, 5108, 3744, 624, 40 }
    for cat = 0, 8 do eq(count[cat], want[cat], "category " .. cat .. " count") end
end

-- hold'em: best five of seven
do
    local s, best = Eval.Holdem(cards("Ah Kh"), cards("Qh Jh Th 2c 3d"))
    eq(Eval.Name(s), "Royal flush", "holdem royal")
    eq(#best, 5, "best has five cards")
    s = Eval.Holdem(cards("2c 3d"), cards("Ah Kh Qh Jh Th"))
    eq(Eval.Name(s), "Royal flush", "holdem board plays")
end

-- omaha: exactly two from the hand, three from the board
do
    local s = Eval.Omaha(cards("Ah 2c 3d 4s"), cards("Kh Qh Jh Th 9c"))
    check(Eval.Category(s) ~= 8, "omaha: one heart in hand can't make a flush")
    eq(Eval.Name(s), "Ace high", "omaha: AKQJT would need four board cards")
    s = Eval.Omaha(cards("Ah 2h 3d 4s"), cards("Kh Qh Jh Tc 9c"))
    eq(Eval.Name(s), "Flush, Ace high", "omaha: two hearts in hand make the flush")
    s = Eval.Omaha(cards("2c 3d 4s 7h"), cards("As Ac Ad Ah Kc"))
    check(Eval.Category(s) < 7, "omaha: board quads don't play")
    s = Eval.Omaha(cards("Ac Kc Qd Jd"), cards("Ah Ad 2s 3s 9h"))
    eq(Eval.Name(s), "Three of a kind, Aces", "omaha: one ace in hand plus two on board")
end

-- ---------------------------------------------------------------- hashing and shuffling
eq(Engine.Hash("hello"), Engine.Hash("hello"), "hash is repeatable")
check(Engine.Hash("hello") ~= Engine.Hash("hellp"), "hash changes with input")
eq(#Engine.Hash("x"), 16, "hash is 16 hex digits")
do
    local deck = Engine.Shuffle(123456)
    local seen = {}
    for _, c in ipairs(deck) do seen[c] = true end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    eq(n, 52, "shuffle is a permutation")
    local other = Engine.Shuffle(123457)
    local same = 0
    for i = 1, 52 do if deck[i] == other[i] then same = same + 1 end end
    check(same < 10, "neighbouring seeds give different decks")
end

-- ---------------------------------------------------------------- the engine
local function deal(m, secret, seedB)
    local h = m.hand
    assert(Engine.Apply(m, h.committer, "K" .. Engine.Commit(secret, m.salt, h.n)))
    assert(Engine.Apply(m, h.answerer, "S" .. seedB))
    assert(Engine.Apply(m, h.committer, "R" .. secret))
end
local function act(m, seat, msg)
    local ok, err = Engine.Apply(m, seat, msg)
    check(ok, ("seat %d %s: %s"):format(seat, msg, tostring(err)))
end

do -- heads-up: blinds, the minimum raise and the big blind's option
    local m = Engine.NewMatch("NL,100,0", "t1")
    eq(m.seats, 2, "two seats by default")
    eq(m.hand.button, 1, "seat 1 has the button first")
    eq(m.hand.bet[1], 10, "heads-up the button posts the small blind")
    eq(m.hand.bet[2], 20, "other seat posts the big blind")
    eq(m.hand.committer, 2, "the big blind commits")
    eq(m.hand.answerer, 1, "the button answers")
    deal(m, "abc", "42")
    local L = Engine.Legal(m)
    eq(L.seat, 1, "button acts first preflop")
    eq(L.call, 10, "button calls 10 more")
    eq(L.minTo, 40, "min raise preflop is to 2 big blinds")
    eq(L.maxTo, 2000, "NL max is the stack")
    act(m, 1, "C")
    L = Engine.Legal(m)
    eq(L.seat, 2, "big blind gets the option")
    check(L.check, "big blind may check")
    act(m, 2, "X")
    eq(m.hand.street, 1, "flop after check")
    eq(Engine.Legal(m).seat, 2, "big blind acts first after the flop")
    eq(Engine.Legal(m).minTo, 20, "min bet is a big blind")
    check(not Engine.Apply(m, 1, "X"), "out of turn is refused")
    check(not Engine.Apply(m, 2, "B19"), "below the min bet is refused")
    act(m, 2, "B50")
    L = Engine.Legal(m)
    eq(L.minTo, 100, "raise must be at least the last bet")
    act(m, 1, "B150")
    eq(Engine.Legal(m).minTo, 250, "re-raise must be at least the last raise")
    act(m, 2, "F")
    eq(m.hand.n, 2, "a fold starts the next hand")
    eq(m.last.result.winner, 1, "the button won")
    eq(Engine.Chips(m), 4000, "chips are kept")
    eq(m.hand.button, 2, "the button moves")
end

do -- pot limit sizes
    local m = Engine.NewMatch("PLO,100,0", "t2")
    deal(m, "s3cret", "7")
    eq(#m.hand.holes[1], 4, "omaha deals four cards")
    local L = Engine.Legal(m)
    eq(L.maxTo, 60, "pot raise from the small blind is to 3 big blinds")
    act(m, 1, "B60")
    L = Engine.Legal(m)
    eq(L.maxTo, 180, "pot re-raise: 60 to call, pot 120 after the call, to 180")
    act(m, 2, "C")
    eq(m.hand.pot, 120, "pot after the call")
    L = Engine.Legal(m)
    eq(L.maxTo, 120, "pot bet on the flop is the pot")
end

do -- an all-in for less is refunded, and the board runs out
    local m = Engine.NewMatch("NL,10,0", "t3")
    deal(m, "x1", "1")
    act(m, 1, "B200")
    act(m, 2, "C")
    check(m.last.result.showdown, "all-in goes to showdown")
    eq(m.last.result.pot, 400, "both stacks in the pot")
    check(m.over or Engine.Chips(m) == 400, "chips kept after all-in")
    eq(m.last.result.runFrom, 0, "a preflop all-in runs out the whole board")
    eq(Engine.BoardShown(m.last), 5, "the engine still deals all five at once")
end

do -- an all-in on the flop remembers that three cards were out
    local m = Engine.NewMatch("NL,10,0", "t3b")
    deal(m, "x1", "1")
    act(m, 1, "C")
    act(m, 2, "X")
    eq(m.hand.street, 1, "on the flop")
    act(m, 2, "B180")
    act(m, 1, "C")
    eq(m.last.result.runFrom, 3, "runout starts after the flop")
end

do -- an all-in called on the river is a plain showdown, nothing to run out
    local m = Engine.NewMatch("NL,10,0", "t3c")
    deal(m, "x1", "1")
    act(m, 1, "C")
    act(m, 2, "X")
    for _ = 1, 2 do
        act(m, 2, "X")
        act(m, 1, "X")
    end
    eq(m.hand.street, 3, "on the river")
    act(m, 2, "B180")
    act(m, 1, "C")
    check(m.last.result.showdown and m.last.result.runFrom == nil, "no runout after river betting")
end

do -- a short big blind
    local m = Engine.NewMatch("NL,10,0", "t4")
    Engine.StartHand(m, 2, { 385, 15 }, 2, {}, {}) -- seat 2 has the button: posts 10 of its 15
    deal(m, "x2", "9")
    local L = Engine.Legal(m)
    eq(L.seat, 2, "short button acts")
    eq(L.call, 5, "only 5 left to call with")
    check(L.minTo == nil, "can't raise with nothing behind")
    act(m, 2, "C")
    check(m.last and m.last.n == 2 and m.last.result.showdown, "short stack all-in runs out")
    eq(m.last.result.pot, 30, "only matched chips are in the pot")
end

do -- a wrong reveal is refused
    local m = Engine.NewMatch("NL,100,0", "t5")
    assert(Engine.Apply(m, 2, "K" .. Engine.Commit("right", m.salt, 1)))
    assert(Engine.Apply(m, 1, "S5"))
    check(not Engine.Apply(m, 2, "Rwrong"), "a reveal that doesn't match is refused")
    check(Engine.Apply(m, 2, "Z"), "the big blind can start the deal again")
    eq(m.hand.phase, "commit", "back to the commit")
end

do -- blind levels
    local o = Engine.ParseOpts("NL,100,10")
    local sb, bb = Engine.Blinds(o, 10)
    eq(bb, 20, "level 1 for ten hands")
    sb, bb = Engine.Blinds(o, 11)
    eq(bb, 30, "level 2 from hand 11")
    eq(sb, 15, "small blind is half")
end

-- ---------------------------------------------------------------- more than two players
do -- six-handed: positions, order of play, and the button moving on
    local m = Engine.NewMatch("NL,100,0", "m1", 6)
    local h = m.hand
    eq(h.button, 1, "button on seat 1")
    eq(h.sbSeat, 2, "small blind left of the button")
    eq(h.bbSeat, 3, "big blind after that")
    eq(h.bet[2], 10, "small blind posted")
    eq(h.bet[3], 20, "big blind posted")
    eq(h.committer, 3, "the big blind commits")
    eq(h.answerer, 1, "the button answers")
    deal(m, "six", "1")
    for i = 1, 6 do eq(#h.holes[i], 2, "seat " .. i .. " has two cards") end
    local seen = {}
    for i = 1, 6 do for _, c in ipairs(h.holes[i]) do check(not seen[c], "no card dealt twice") seen[c] = true end end
    for _, c in ipairs(h.board) do check(not seen[c], "board cards aren't in anyone's hand") seen[c] = true end
    eq(Engine.Legal(m).seat, 4, "under the gun acts first")
    act(m, 4, "F")
    act(m, 5, "C")
    act(m, 6, "B60")
    eq(Engine.Legal(m).seat, 1, "the button is next")
    act(m, 1, "F")
    act(m, 2, "C")
    act(m, 3, "C")
    eq(Engine.Legal(m).seat, 5, "the limper must answer the raise")
    act(m, 5, "C")
    eq(h.street, 1, "on to the flop")
    eq(h.pot, 240, "four players in for 60")
    eq(Engine.Legal(m).seat, 2, "after the flop the first player left of the button starts")
    for _, s in ipairs({ 2, 3, 5, 6 }) do act(m, s, "X") end
    eq(h.street, 2, "checked round to the turn")
    act(m, 2, "B100")
    act(m, 3, "F")
    act(m, 5, "F")
    act(m, 6, "F")
    eq(m.last.result.winner, 2, "the bettor takes it")
    eq(m.last.result.won[2], 340, "the pot plus the uncalled bet back")
    eq(Engine.Chips(m), 6 * 2000, "chips are kept")
    eq(m.hand.button, 2, "the button moves one seat")
    eq(m.hand.sbSeat, 3, "and the blinds with it")
end

do -- side pots: a short all-in can only win what it matched
    local m = Engine.NewMatch("NL,100,0", "m2", 3)
    -- seat 2 (small blind) is short: 200 chips; seats 1 and 3 have plenty
    Engine.StartHand(m, 1, { 3000, 200, 3000 }, 1, {}, {})
    local h = m.hand
    deal(m, "pots", "5")
    -- rig the cards: seat 2 makes a wheel, seat 1 a pair of kings, seat 3 nothing
    h.holes[1] = { 13, 26 }         -- Kh Kd
    h.holes[2] = { 1, 14 }          -- Ah Ad
    h.holes[3] = { 7, 21 }          -- 7h 8d
    h.board = { 2, 16, 30, 44, 11 } -- 2h 3d 4s 5c Jh
    act(m, 1, "B1000")
    act(m, 2, "C") -- all-in for 200
    act(m, 3, "C")
    eq(h.street, 1, "two players still betting, so the flop comes")
    for _ = 1, 3 do
        act(m, 3, "X")
        act(m, 1, "X")
    end
    local r = m.last.result
    check(r.showdown, "a showdown")
    eq(#r.pots, 2, "a main pot and a side pot")
    eq(r.pots[1].amount, 600, "the main pot is 200 from each")
    eq(r.pots[1].winners[1], 2, "the short stack wins the main pot")
    eq(r.pots[2].amount, 1600, "the side pot is the rest")
    eq(r.pots[2].winners[1], 1, "the kings win the side pot")
    eq(m.stacks[2], 600, "the short stack tripled up")
    eq(Engine.Chips(m), 6200, "chips are kept")
end

do -- a full table of nine
    local m = Engine.NewMatch("PLO,50,0", "m3", 9)
    deal(m, "nine", "9")
    local seen, n = {}, 0
    for i = 1, 9 do
        for _, c in ipairs(m.hand.holes[i]) do
            check(not seen[c], "no card twice at nine-handed omaha")
            seen[c], n = true, n + 1
        end
    end
    eq(n, 36, "nine players get four cards each")
    eq(Engine.NewMatch("NL,100,0", "x", 12).seats, 9, "no more than nine seats")
end

do -- a short all-in raise doesn't reopen the betting
    local m = Engine.NewMatch("NL,100,0", "m4", 3)
    Engine.StartHand(m, 1, { 2000, 2000, 130 }, 1, {}, {})
    deal(m, "short", "3")
    act(m, 1, "B100")
    act(m, 2, "C")
    -- seat 3 (big blind) has 130 in all: all-in to 130 is less than a full raise (to 180)
    local L = Engine.Legal(m)
    eq(L.maxTo, 130, "the big blind can only go all-in to 130")
    act(m, 3, "B130")
    L = Engine.Legal(m)
    eq(L.seat, 1, "back to the first raiser")
    eq(L.call, 30, "who may call the extra 30")
    check(L.minTo == nil, "but not raise again")
end

do -- leaving the table
    local m = Engine.NewMatch("NL,100,0", "m5", 4)
    deal(m, "bye", "4")
    -- under the gun is seat 4; seat 2 (small blind) leaves out of turn
    check(not Engine.Apply(m, 0, "O9"), "no such seat")
    act(m, 0, "O2")
    eq(m.stacks[2], 0, "their chips leave with them")
    check(m.hand.folded[2], "and their hand is folded")
    eq(Engine.Legal(m).seat, 4, "the player to act is still to act")
    act(m, 4, "F")
    act(m, 1, "F")
    eq(m.last.result.winner, 3, "the big blind wins the blinds")
    eq(m.out[2], "left", "the leaver is out")
    eq(m.place[2], 4, "and finishes last")
    eq(m.hand.button, 3, "the button skips the empty seat")
    check(not m.hand.inHand[2], "nobody deals to an empty seat")
    -- the next deal: the big blind leaves after committing, so somebody else deals
    local h = m.hand
    assert(Engine.Apply(m, h.committer, "K" .. Engine.Commit("q", m.salt, h.n)))
    local was = h.committer
    act(m, 0, "O" .. was)
    eq(h.phase, "commit", "the deal starts again")
    check(h.committer ~= was and h.committer ~= nil, "with someone still here")
    check(not Engine.Apply(m, 0, "O" .. was), "you can only leave once")
end

do -- everyone else leaves: the one still sitting wins
    local m = Engine.NewMatch("NL,100,0", "m6", 3)
    act(m, 0, "O1")
    act(m, 0, "O2")
    check(m.over, "the match is over")
    eq(m.winner, 3, "the one still sitting wins")
    eq(m.place[3], 1, "first place")
    eq(m.place[2], 2, "leaving later places higher")
    eq(m.place[1], 3, "the first to leave is last")
    local back = Engine.FromSnapshot(Engine.Snapshot(m), m.salt)
    check(back and back.over and back.winner == 3 and back.place[1] == 3, "a finished match comes back from a snapshot")
end

do -- the shot clock and the time bank
    local m = Engine.NewMatch("NL,100,0", "clock", 3)
    for i = 1, 3 do eq(m.bank[i], Engine.TIME_BANK, "everyone starts with a full time bank") end
    check(not Engine.TurnKey(m), "no clock while the cards are being dealt")
    deal(m, "c1", 11)
    local h = m.hand
    local first = h.toAct
    local key = Engine.TurnKey(m)
    check(key ~= nil, "a clock once someone has to act")
    check(not Engine.Apply(m, 0, "U" .. first .. "10"), "no charge before the bank is started")
    check(not Engine.Apply(m, first == 1 and 2 or 1, "W"), "only the player to act can start a bank")
    act(m, first, "W")
    check(h.banking, "the bank is running")
    eq(h.toAct, first, "starting the bank doesn't pass the turn")
    eq(Engine.TurnKey(m), key, "or restart the clock")
    check(not Engine.Apply(m, first, "W"), "a bank can only be started once a decision")
    act(m, 0, "U" .. first .. "30")
    eq(m.bank[first], Engine.TIME_BANK - 30, "30 seconds come off the bank")
    act(m, first, "C")
    check(Engine.TurnKey(m) ~= key, "the next decision gets a fresh clock")
    check(not h.banking, "and no bank running")
    -- running out of time with a bet to face: a fold, and a running bank is gone
    local second = h.toAct
    act(m, second, "W")
    act(m, 0, "T" .. second)
    check(h.folded[second], "running out of time facing a bet folds")
    check(h.said[second].timeout, "marked as out of time")
    eq(m.bank[second], 0, "the bank that was running is used up")
    eq(Engine.Said(h.said[second]), "Fold (out of time)", "the history says so")
    check(not Engine.Apply(m, second, "W"), "a player who isn't to act can't start a bank")
    -- the big blind's option: out of time is a check, and without a bank running the bank stays
    local bb = h.toAct
    eq(bb, h.bbSeat, "the big blind is left with the option")
    local had = m.bank[bb]
    act(m, 0, "T" .. bb)
    check(not h.folded[bb] and h.street == 1, "out of time with nothing to call checks, and the flop comes")
    eq(m.bank[bb], had, "a bank that wasn't running is kept")
    check(not Engine.Apply(m, 0, "T" .. second), "only the player to act can run out of time")
    -- banks carry on to the next hand, and through a snapshot
    local back = Engine.FromSnapshot(Engine.Snapshot(m), m.salt)
    check(back and Engine.Snapshot(back) == Engine.Snapshot(m), "a snapshot with clock moves comes back the same")
    eq(back and back.bank[first], Engine.TIME_BANK - 30, "the bank comes back from a snapshot")
    eq(back and back.bank[second], 0, "an empty bank comes back empty")
    while m.hand == h and not m.over do
        local L = Engine.Legal(m)
        act(m, h.toAct, L.check and "X" or "F")
    end
    check(m.hand ~= h, "on to the next hand")
    eq(m.bank[first], Engine.TIME_BANK - 30, "the bank lasts the whole game")
    eq(m.hand.startBank[second], 0, "the next hand starts from what's left")
    deal(m, "c2", 12)
    local p = m.hand.toAct
    if m.bank[p] == 0 then check(not Engine.Apply(m, p, "W"), "no bank left, no bank to start") end
    back = Engine.FromSnapshot(Engine.Snapshot(m), m.salt)
    check(back and Engine.Snapshot(back) == Engine.Snapshot(m), "the next hand's banks survive a snapshot")
end

-- ---------------------------------------------------------------- random matches on two clients
local rnd = 12345
local function rand(n)
    rnd = (rnd * 1103515245 + 12345) % 2147483648
    return rnd % n + 1
end
local function randomAction(m)
    local L = Engine.Legal(m)
    local r = rand(10)
    if L.minTo and r <= 3 then
        local span = L.maxTo - L.minTo
        local to = L.minTo + (span > 0 and (rand(span + 1) - 1) or 0)
        if rand(4) == 1 then to = L.maxTo end
        return "B" .. to
    end
    if L.fold and r == 4 then return "F" end
    if L.check then return "X" end
    return "C"
end
for game = 1, 1000 do
    local opts = ({ "NL,20,0", "PLO,20,0", "NL,50,5", "PLO,100,3" })[game % 4 + 1]
    local seats = game % 8 + 2
    local a, b = Engine.NewMatch(opts, "g" .. game, seats), Engine.NewMatch(opts, "g" .. game, seats)
    local total = a.start * seats
    local steps = 0
    while not a.over and steps < 40000 do
        steps = steps + 1
        local seat, kind = Engine.Expect(a)
        local msg
        if rand(400) == 1 then
            -- now and then somebody leaves (or a stale leave arrives for someone already out)
            seat, msg = 0, "O" .. rand(seats)
        elseif kind == "A" and rand(40) == 1 then
            -- the clock: someone runs out of time, starts their bank, or is charged for it
            seat, msg = 0, "T" .. seat
        elseif kind == "A" and not a.hand.banking and a.bank[seat] > 0 and rand(15) == 1 then
            msg = "W"
        elseif kind == "A" and a.hand.banking and rand(3) == 1 then
            seat, msg = 0, "U" .. seat .. rand(40)
        elseif kind == "K" then
            a.secret = "s" .. rand(1e6)
            msg = "K" .. Engine.Commit(a.secret, a.salt, a.hand.n)
        elseif kind == "S" then
            msg = "S" .. rand(2e9)
        elseif kind == "R" then
            msg = rand(50) == 1 and "Z" or ("R" .. a.secret)
        else
            msg = randomAction(a)
        end
        local ok, err = Engine.Apply(a, seat, msg)
        if ok then
            check(Engine.Apply(b, seat, msg), "the other client accepts " .. msg)
        elseif seat ~= 0 then
            check(false, ("game %d: %s refused: %s"):format(game, msg, tostring(err)))
            break
        end
        if Engine.Chips(a) + a.burned ~= total then
            check(false, ("game %d: chips %d + %d ~= %d after %s"):format(game, Engine.Chips(a), a.burned, total, msg))
            break
        end
        local snap = Engine.Snapshot(a)
        if snap ~= Engine.Snapshot(b) then check(false, "clients disagree in game " .. game) break end
        if steps % 7 == 0 or a.over then
            local back = Engine.FromSnapshot(snap, a.salt)
            if not back or Engine.Snapshot(back) ~= snap then
                check(false, ("game %d: snapshot round trip failed at %s"):format(game, snap))
                break
            end
            if a.over and not (back.over and back.winner == a.winner) then
                check(false, ("game %d: the finished match doesn't come back finished"):format(game))
                break
            end
        end
    end
    check(a.over, "game " .. game .. " finished")
    if a.over then
        check(a.winner and a.stacks[a.winner] + a.burned == total, "the winner has every chip still at the table")
        local places = {}
        for i = 1, seats do
            local p = a.place[i]
            check(p and p >= 1 and p <= seats and not places[p], ("game %d: seat %d has a place of its own (%s)"):format(game, i, tostring(p)))
            if p then places[p] = true end
        end
    end
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end

