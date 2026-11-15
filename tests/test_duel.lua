-- Two clients play whole matches through the real FojjiCore Duel/Comm code and this addon's window.
-- Run from the repo root:  lua tests/test_duel.lua
-- Needs FojjiCore_Games installed (FOJJI_ADDONS = the AddOns folder; defaults to the _forever_ client).
local Mock = dofile("tests/wow_mock.lua")

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. msg) end
end

math.randomseed(tonumber(os.getenv("POKER_SEED")) or 7)
local function rng(n) return math.random(n) end

-- the player whose turn it is clicks something in the action bar
local function act(c)
    local bar = c.PK._win().bar
    local r = rng(100)
    if bar.fold:IsShown() and r <= 10 then bar.fold:Click() return end
    if bar.raise:IsShown() and r <= 30 then
        -- mostly small and pot-sized raises; now and then all the way
        if bar.sizing:IsShown() then bar.presets[rng(20) == 1 and 5 or rng(4)]:Click() end
        bar.raise:Click()
        return
    end
    bar.call:Click()
end

local function state(c)
    local m, s = c.PK._state()
    return m, s
end
local function myAction(c)
    local m, s = state(c)
    if not (m and s and not m.over and not s.over) then return false end
    local who, kind = c.ns.Engine.Expect(m)
    return who == (s.first and 1 or 2) and kind == "A"
end

local function newMatch(opts, drop)
    local world = Mock.World()
    local a = world:Client("Alice", { "Bob" })
    local b = world:Client("Bob", { "Alice" })
    a.env.FojjiCorePokerDB = opts
    a.PK.Show()
    b.PK.Show()
    check(a.PK.Challenge("Bob"), "challenge sent")
    world:Run(1)
    check(b.PK.Duel:Accept("Alice"), "Bob has an invite to accept")
    world:Run(3)
    world.drop = drop or 0
    return world
end

-- plays until the match is over; `during(step, world)` may meddle
local function play(world, label, during)
    for step = 1, 40000 do
        world:Run(0.5)
        for _, name in ipairs({ "Alice", "Bob" }) do
            local c = world:Find(name)
            if c and myAction(c) then act(c) end
        end
        if during then during(step, world) end
        local ma, sa = state(world:Find("Alice"))
        local mb, sb = state(world:Find("Bob"))
        if ma and mb and ma.over and mb.over then
            world.drop = 0
            -- long enough for a match-ending all-in to be played out before the result card
            world:Run(15)
            return step
        end
    end
    check(false, label .. ": match never finished")
end

local function verify(world, label)
    local a, b = world:Find("Alice"), world:Find("Bob")
    local ma, sa = state(a)
    local mb, sb = state(b)
    check(ma and mb, label .. ": both have a match")
    if not (ma and mb) then return end
    check(ma.over and mb.over, label .. ": both see the match over")
    check(ma.winner == mb.winner, label .. ": both agree who won")
    local E = a.ns.Engine
    check(E.Snapshot(ma) == E.Snapshot(mb), label .. ": both have the same final position")
    check(ma.stacks[1] + ma.stacks[2] == ma.start * 2, label .. ": no chips made or lost")
    check(#a.reports == 0 and #b.reports == 0, label .. ": no errors reported: " .. table.concat(a.reports, " | ") .. table.concat(b.reports, " | "))
    local da, dbb = a.env.FojjiCorePokerDB, b.env.FojjiCorePokerDB
    check(da.w + da.l == 1 and dbb.w + dbb.l == 1, label .. ": the match is in both records once")
    check(da.w == dbb.l, label .. ": one player won and the other lost")
    local win = a.PK._win()
    check(win.result:IsOpen(), label .. ": the result card is up")
    print(("%s: %d hands, seat %d won, %d whispers (%d dropped)"):format(label, ma.hand.n, ma.winner, world.sent, world.dropped))
end

-- 1. plain No-Limit Hold'em
do
    local world = newMatch({ variant = "NL", stackBB = 30, level = 0 })
    local m = state(world:Find("Alice"))
    check(m and m.opts.variant == "NL" and m.start == 600, "options reached the match")
    play(world, "NL")
    verify(world, "NL")
end

-- 2. Pot-Limit Omaha with rising blinds, and one whisper in ten lost
do
    local world = newMatch({ variant = "PLO", stackBB = 50, level = 10 }, 0.1)
    play(world, "PLO lossy")
    verify(world, "PLO lossy")
end

-- 3. Alice reloads her UI twice during the match
do
    local world = newMatch({ variant = "NL", stackBB = 200, level = 0 })
    local reloads = 0
    local first = 3 + rng(12)
    play(world, "reload", function(step, w)
        local m = state(w:Find("Alice"))
        -- once during the first hands (deal or betting), once when hand 3 has started
        if m and not m.over and ((reloads == 0 and step >= first) or (reloads == 1 and m.hand.n >= 3)) then
            local old = w:Find("Alice")
            local saved = old:Saved()
            old.dead = true
            w:Run(1)
            local fresh = w:Client("Alice", { "Bob" }, saved)
            reloads = reloads + 1
            local m = state(fresh)
            check(m ~= nil, "after a reload the match comes back from saved variables")
            fresh.PK.Show()
        end
    end)
    local m = state(world:Find("Alice"))
    check(reloads == 2 or (m and m.over and m.hand.n < 3), "reloaded twice (or the match ended before hand 3): " .. reloads)
    verify(world, "reload")
end

-- 4. giving up
do
    local world = newMatch({ variant = "PLO", stackBB = 100, level = 0 })
    world:Run(10)
    local a = world:Find("Alice")
    a.PK.GiveUp()
    world:Run(3)
    local ma, mb = state(a), state(world:Find("Bob"))
    check(ma.over and mb.over, "give up ends the match on both sides")
    local _, sa = state(a)
    check(ma.winner ~= (sa.first and 1 or 2), "the one who gave up lost")
    check(ma.winner == mb.winner, "both agree on the winner after giving up")
    -- rematch: Bob offers, Alice accepts
    world:Find("Bob").PK.Rematch()
    world:Run(1)
    check(a.PK.Duel:Accept("Bob"), "Alice gets the rematch offer")
    world:Run(3)
    local m2, s2 = state(a)
    check(m2 and not m2.over and s2 and not s2.over, "the rematch has started")
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
