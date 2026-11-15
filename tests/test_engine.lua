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
    local bbSeat = 3 - h.button
    assert(Engine.Apply(m, bbSeat, "K" .. Engine.Commit(secret, m.salt, h.n)))
    assert(Engine.Apply(m, h.button, "S" .. seedB))
    assert(Engine.Apply(m, bbSeat, "R" .. secret))
end
local function chips(m)
    local h = m.hand
    return m.stacks[1] + m.stacks[2] + (m.over and 0 or (h.pot + h.bet[1] + h.bet[2]))
end

do -- blinds, the minimum raise and the big blind's option
    local m = Engine.NewMatch("NL,100,0", "t1")
    eq(m.hand.button, 1, "seat 1 has the button first")
    eq(m.hand.bet[1], 10, "button posts the small blind")
    eq(m.hand.bet[2], 20, "other seat posts the big blind")
    deal(m, "abc", "42")
    local L = Engine.Legal(m)
    eq(L.seat, 1, "button acts first preflop")
    eq(L.call, 10, "button calls 10 more")
    eq(L.minTo, 40, "min raise preflop is to 2 big blinds")
    eq(L.maxTo, 2000, "NL max is the stack")
    assert(Engine.Apply(m, 1, "C"))
    L = Engine.Legal(m)
    eq(L.seat, 2, "big blind gets the option")
    check(L.check, "big blind may check")
    assert(Engine.Apply(m, 2, "X"))
    eq(m.hand.street, 1, "flop after check")
    eq(Engine.Legal(m).seat, 2, "big blind acts first after the flop")
    eq(Engine.Legal(m).minTo, 20, "min bet is a big blind")
    check(not Engine.Apply(m, 1, "X"), "out of turn is refused")
    check(not Engine.Apply(m, 2, "B19"), "below the min bet is refused")
    assert(Engine.Apply(m, 2, "B50"))
    L = Engine.Legal(m)
    eq(L.minTo, 100, "raise must be at least the last bet")
    assert(Engine.Apply(m, 1, "B150"))
    eq(Engine.Legal(m).minTo, 250, "re-raise must be at least the last raise")
    assert(Engine.Apply(m, 2, "F"))
    eq(m.hand.n, 2, "a fold starts the next hand")
    eq(m.last.result.winner, 1, "the button won")
    eq(m.stacks[1] + m.stacks[2] + m.hand.bet[1] + m.hand.bet[2], 4000, "chips are kept")
    eq(m.hand.button, 2, "the button moves")
end

do -- pot limit sizes
    local m = Engine.NewMatch("PLO,100,0", "t2")
    deal(m, "s3cret", "7")
    eq(#m.hand.holes[1], 4, "omaha deals four cards")
    local L = Engine.Legal(m)
    eq(L.maxTo, 60, "pot raise from the small blind is to 3 big blinds")
    assert(Engine.Apply(m, 1, "B60"))
    L = Engine.Legal(m)
    eq(L.maxTo, 180, "pot re-raise: 60 to call, pot 120 after the call, to 180")
    assert(Engine.Apply(m, 2, "C"))
    eq(m.hand.pot, 120, "pot after the call")
    L = Engine.Legal(m)
    eq(L.maxTo, 120, "pot bet on the flop is the pot")
end

do -- an all-in for less is refunded, and the board runs out
    local m = Engine.NewMatch("NL,10,0", "t3")
    deal(m, "x1", "1")
    assert(Engine.Apply(m, 1, "B200"))
    assert(Engine.Apply(m, 2, "C"))
    check(m.last.result.showdown, "all-in goes to showdown")
    eq(m.last.result.pot, 400, "both stacks in the pot")
    check(m.over or chips(m) == 400, "chips kept after all-in")
    eq(m.last.result.runFrom, 0, "a preflop all-in runs out the whole board")
    eq(Engine.BoardShown(m.last), 5, "the engine still deals all five at once")
end

do -- an all-in on the flop remembers that three cards were out
    local m = Engine.NewMatch("NL,10,0", "t3b")
    deal(m, "x1", "1")
    assert(Engine.Apply(m, 1, "C"))
    assert(Engine.Apply(m, 2, "X"))
    eq(m.hand.street, 1, "on the flop")
    assert(Engine.Apply(m, 2, "B180"))
    assert(Engine.Apply(m, 1, "C"))
    eq(m.last.result.runFrom, 3, "runout starts after the flop")
end

do -- an all-in called on the river is a plain showdown, nothing to run out
    local m = Engine.NewMatch("NL,10,0", "t3c")
    deal(m, "x1", "1")
    assert(Engine.Apply(m, 1, "C"))
    assert(Engine.Apply(m, 2, "X"))
    for _ = 1, 2 do
        assert(Engine.Apply(m, 2, "X"))
        assert(Engine.Apply(m, 1, "X"))
    end
    eq(m.hand.street, 3, "on the river")
    assert(Engine.Apply(m, 2, "B180"))
    assert(Engine.Apply(m, 1, "C"))
    check(m.last.result.showdown and m.last.result.runFrom == nil, "no runout after river betting")
end

do -- a short big blind
    local m = Engine.NewMatch("NL,10,0", "t4")
    m.stacks = { 385, 15 }
    Engine.StartHand(m, 2, 385, 15) -- seat 2 has the button: posts 10 of its 15
    deal(m, "x2", "9")
    local L = Engine.Legal(m)
    eq(L.seat, 2, "short button acts")
    eq(L.call, 5, "only 5 left to call with")
    check(L.minTo == nil, "can't raise with nothing behind")
    assert(Engine.Apply(m, 2, "C"))
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
    local a, b = Engine.NewMatch(opts, "g" .. game), Engine.NewMatch(opts, "g" .. game)
    local total = a.start * 2
    local steps = 0
    while not a.over and steps < 20000 do
        steps = steps + 1
        local seat, kind = Engine.Expect(a)
        local msg
        if kind == "K" then
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
        if not ok then check(false, ("game %d: %s refused: %s"):format(game, msg, tostring(err))) break end
        local ok2 = Engine.Apply(b, seat, msg)
        check(ok2, "the other client accepts " .. msg)
        if chips(a) ~= total then check(false, ("game %d: chips %d ~= %d after %s"):format(game, chips(a), total, msg)) break end
        local snap = Engine.Snapshot(a)
        if snap ~= Engine.Snapshot(b) then check(false, "clients disagree in game " .. game) break end
        if steps % 7 == 0 then
            local back = Engine.FromSnapshot(snap, a.salt)
            if not back or Engine.Snapshot(back) ~= snap then
                check(false, ("game %d: snapshot round trip failed at %s"):format(game, snap))
                break
            end
        end
    end
    check(a.over, "game " .. game .. " finished")
    if a.over then check(a.stacks[a.winner] == total and a.stacks[3 - a.winner] == 0, "winner has every chip") end
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
