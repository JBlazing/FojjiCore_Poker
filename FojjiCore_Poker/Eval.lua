-- Poker hand evaluation. Pure Lua: no game client calls, so tests can run it outside WoW.
--
-- Cards are numbers 1..52: suit = floor((c - 1) / 13) + 1 (1 Hearts, 2 Diamonds, 3 Spades, 4 Clubs),
-- rank = (c - 1) % 13 + 1 (1 Ace, 2..10, 11 Jack, 12 Queen, 13 King). This is the same order as
-- FojjiCore's card art, so a card number is also its picture.
--
-- A hand score is one number: higher is better, equal is a tie.
--   Eval.Five(c1, c2, c3, c4, c5)  -> score
--   Eval.Holdem(hole, board)       -> score, best5   (best 5 of hole + board)
--   Eval.Omaha(hole, board)        -> score, best5   (exactly 2 of the 4 hole cards + 3 of the board)
--   Eval.Name(score)               -> "Two pair, Aces and Nines"
local _, ns = ...
ns = ns or {}
local Eval = {}
ns.Eval = Eval

local floor = math.floor

local VALUE, SUIT = {}, {}
for c = 1, 52 do
    local r = (c - 1) % 13 + 1
    VALUE[c] = r == 1 and 14 or r
    SUIT[c] = floor((c - 1) / 13) + 1
end
Eval.Value, Eval.Suit = VALUE, SUIT

-- categories
local HIGH, PAIR, TWO_PAIR, TRIPS, STRAIGHT, FLUSH, FULL, QUADS, STRAIGHT_FLUSH = 0, 1, 2, 3, 4, 5, 6, 7, 8
local B1, B2, B3, B4, B5 = 15, 15 ^ 2, 15 ^ 3, 15 ^ 4, 15 ^ 5
local function enc(cat, a, b, c, d, e)
    return cat * B5 + (a or 0) * B4 + (b or 0) * B3 + (c or 0) * B2 + (d or 0) * B1 + (e or 0)
end

local v = {}
local function five(c1, c2, c3, c4, c5)
    v[1], v[2], v[3], v[4], v[5] = VALUE[c1], VALUE[c2], VALUE[c3], VALUE[c4], VALUE[c5]
    for i = 2, 5 do
        local x, j = v[i], i - 1
        while j >= 1 and v[j] < x do
            v[j + 1] = v[j]
            j = j - 1
        end
        v[j + 1] = x
    end
    local a, b, c, d, e = v[1], v[2], v[3], v[4], v[5]
    local s = SUIT[c1]
    local flush = SUIT[c2] == s and SUIT[c3] == s and SUIT[c4] == s and SUIT[c5] == s
    local distinct = a ~= b and b ~= c and c ~= d and d ~= e
    if distinct then
        local high
        if a - e == 4 then high = a elseif a == 14 and b == 5 then high = 5 end
        if high then return enc(flush and STRAIGHT_FLUSH or STRAIGHT, high) end
        if flush then return enc(FLUSH, a, b, c, d, e) end
        return enc(HIGH, a, b, c, d, e)
    end
    -- equal values sit next to each other in the sorted list
    if a == d then return enc(QUADS, a, e) end
    if b == e then return enc(QUADS, b, a) end
    if a == c then
        if d == e then return enc(FULL, a, d) end
        return enc(TRIPS, a, d, e)
    end
    if c == e then
        if a == b then return enc(FULL, c, a) end
        return enc(TRIPS, c, a, b)
    end
    if b == d then return enc(TRIPS, b, a, e) end
    if a == b then
        if c == d then return enc(TWO_PAIR, a, c, e) end
        if d == e then return enc(TWO_PAIR, a, d, c) end
        return enc(PAIR, a, c, d, e)
    end
    if b == c then
        if d == e then return enc(TWO_PAIR, b, d, a) end
        return enc(PAIR, b, a, d, e)
    end
    if c == d then return enc(PAIR, c, a, b, e) end
    return enc(PAIR, d, a, b, c)
end
Eval.Five = five

-- best 5 of any 5 or more cards
function Eval.Holdem(hole, board)
    local cards = {}
    for _, c in ipairs(hole) do cards[#cards + 1] = c end
    for _, c in ipairs(board) do cards[#cards + 1] = c end
    local n = #cards
    if n < 5 then return nil end
    local best, bi = -1, nil
    for i = 1, n - 4 do
        for j = i + 1, n - 3 do
            for k = j + 1, n - 2 do
                for l = k + 1, n - 1 do
                    for m = l + 1, n do
                        local sc = five(cards[i], cards[j], cards[k], cards[l], cards[m])
                        if sc > best then best, bi = sc, { cards[i], cards[j], cards[k], cards[l], cards[m] } end
                    end
                end
            end
        end
    end
    return best, bi
end

-- exactly two hole cards and three board cards
function Eval.Omaha(hole, board)
    local nh, nb = #hole, #board
    if nh < 2 or nb < 3 then return nil end
    local best, bi = -1, nil
    for i = 1, nh - 1 do
        for j = i + 1, nh do
            for a = 1, nb - 2 do
                for b = a + 1, nb - 1 do
                    for c = b + 1, nb do
                        local sc = five(hole[i], hole[j], board[a], board[b], board[c])
                        if sc > best then best, bi = sc, { hole[i], hole[j], board[a], board[b], board[c] } end
                    end
                end
            end
        end
    end
    return best, bi
end

local ONE = { [2] = "Two", [3] = "Three", [4] = "Four", [5] = "Five", [6] = "Six", [7] = "Seven", [8] = "Eight",
    [9] = "Nine", [10] = "Ten", [11] = "Jack", [12] = "Queen", [13] = "King", [14] = "Ace" }
local MANY = { [2] = "Twos", [3] = "Threes", [4] = "Fours", [5] = "Fives", [6] = "Sixes", [7] = "Sevens", [8] = "Eights",
    [9] = "Nines", [10] = "Tens", [11] = "Jacks", [12] = "Queens", [13] = "Kings", [14] = "Aces" }
Eval.RankName, Eval.RankPlural = ONE, MANY

function Eval.Category(score) return floor(score / B5) end

function Eval.Name(score)
    if type(score) ~= "number" or score < 0 then return "" end
    local cat = floor(score / B5)
    local a, b = floor(score / B4) % 15, floor(score / B3) % 15
    if cat == STRAIGHT_FLUSH then
        if a == 14 then return "Royal flush" end
        return ("Straight flush, %s high"):format(ONE[a])
    elseif cat == QUADS then return ("Four of a kind, %s"):format(MANY[a])
    elseif cat == FULL then return ("Full house, %s over %s"):format(MANY[a], MANY[b])
    elseif cat == FLUSH then return ("Flush, %s high"):format(ONE[a])
    elseif cat == STRAIGHT then return ("Straight, %s high"):format(ONE[a])
    elseif cat == TRIPS then return ("Three of a kind, %s"):format(MANY[a])
    elseif cat == TWO_PAIR then return ("Two pair, %s and %s"):format(MANY[a], MANY[b])
    elseif cat == PAIR then return ("Pair of %s"):format(MANY[a])
    end
    return ("%s high"):format(ONE[a])
end

-- What a player holds right now, by name, for any street. Before the flop only the hole cards count,
-- so the answer is a pair or a high card (in Omaha, the best two of the four).
function Eval.Current(hole, board, omaha)
    if type(hole) ~= "table" or #hole < 2 then return "" end
    board = board or {}
    if #board >= 3 then
        local sc = (omaha and Eval.Omaha or Eval.Holdem)(hole, board)
        return sc and Eval.Name(sc) or ""
    end
    local high, pair, seen = 0, 0, {}
    for _, c in ipairs(hole) do
        local x = VALUE[c]
        if x then
            if seen[x] and x > pair then pair = x end
            seen[x] = true
            if x > high then high = x end
        end
    end
    if pair > 0 then return ("Pair of %s"):format(MANY[pair]) end
    return high > 0 and ("%s high"):format(ONE[high]) or ""
end

-- "As", "Td", "9c": handy for tests and for the hand history
local RCH = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K" }
local SCH = { "h", "d", "s", "c" }
function Eval.Short(c)
    if type(c) ~= "number" or c < 1 or c > 52 then return "??" end
    return RCH[(c - 1) % 13 + 1] .. SCH[floor((c - 1) / 13) + 1]
end
function Eval.Parse(text)
    local r, s = tostring(text):match("^(%w)(%a)$")
    if not r then return nil end
    local ri, si
    for i, ch in ipairs(RCH) do if ch == r:upper() then ri = i end end
    for i, ch in ipairs(SCH) do if ch == s:lower() then si = i end end
    if not (ri and si) then return nil end
    return (si - 1) * 13 + ri
end

return Eval
