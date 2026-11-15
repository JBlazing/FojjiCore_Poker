-- A small stand-in for the WoW client, enough to load FojjiCore Games' Duel/Comm code and this addon
-- into separate "clients" inside one Lua 5.1 state (each client is its own global environment).
--
--   local Mock = dofile("tests/wow_mock.lua")
--   local world = Mock.World()
--   local a = world:Client("Alice", { "Bob" })   -- name, the people it can see (party/guild)
--   world:Run(seconds)                           -- runs timers and delivers whispers
--
-- Widget methods: anything starting with a capital letter that isn't modelled is a no-op, so the
-- addon's own fields (lowercase) still read as nil.
local Mock = {}

local GAMES = (os.getenv("FOJJI_ADDONS") or "D:/Games/World of Warcraft/_forever_/Interface/AddOns") .. "/"
local GAMES_FILES = { "Base/Init.lua", "Base/Kit.lua", "Base/Comm.lua", "Games.lua", "GamesUI.lua", "Duel.lua", "Scores.lua" }
local OUR_FILES = { "Eval.lua", "Engine.lua", "Poker.lua" }
Mock.GAMES = GAMES

local function noop() end

-- ---------------------------------------------------------------- widgets
local M = {}
local function widget(kind, name, parent)
    local w = { _kind = kind, _name = name, _parent = parent, _shown = true, _scripts = {}, _hooks = {},
        _w = 0, _h = 0, _enabled = true, _min = 0, _max = 0, _value = 0, _text = "" }
    return setmetatable(w, M)
end
M.__index = function(t, k)
    local m = rawget(M, k)
    if m then return m end
    if type(k) == "string" and k:match("^[A-Z]") then return noop end
    return nil
end
local function fire(self, script, ...)
    local fn = self._scripts[script]
    if fn then fn(self, ...) end
    for _, h in ipairs(self._hooks[script] or {}) do h(self, ...) end
end
M.Fire = fire
function M:SetScript(s, fn) self._scripts[s] = fn end
function M:GetScript(s) return self._scripts[s] end
function M:HookScript(s, fn)
    self._hooks[s] = self._hooks[s] or {}
    table.insert(self._hooks[s], fn)
end
function M:Show() if not self._shown then self._shown = true fire(self, "OnShow") end end
function M:Hide() if self._shown then self._shown = false fire(self, "OnHide") end end
function M:SetShown(on) if on then self:Show() else self:Hide() end end
function M:IsShown() return self._shown end
function M:IsVisible()
    if not self._shown then return false end
    if self._parent and self._parent.IsVisible then return self._parent:IsVisible() end
    return true
end
function M:GetName() return self._name end
function M:GetParent() return self._parent end
function M:SetParent(p) self._parent = p end
function M:GetObjectType() return self._kind end
function M:IsObjectType(k) return self._kind == k end
function M:SetSize(w, h) self._w, self._h = w or self._w, h or self._h end
function M:SetWidth(w) self._w = w end
function M:SetHeight(h) self._h = h end
function M:GetWidth() return self._w end
function M:GetHeight() return self._h end
function M:GetSize() return self._w, self._h end
function M:GetFrameLevel() return 1 end
function M:GetFrameStrata() return "MEDIUM" end
function M:GetEffectiveScale() return 1 end
function M:GetScale() return 1 end
function M:GetAlpha() return 1 end
function M:GetCenter() return 0, 0 end
function M:GetLeft() return 0 end
function M:GetRight() return 0 end
function M:GetTop() return 0 end
function M:GetBottom() return 0 end
function M:GetNumPoints() return 0 end
function M:IsMouseOver() return false end
function M:HasFocus() return false end
function M:IsPlaying() return false end
function M:IsEnabled() return self._enabled end
function M:Enable() if not self._enabled then self._enabled = true fire(self, "OnEnable") end end
function M:Disable() if self._enabled then self._enabled = false fire(self, "OnDisable") end end
function M:SetEnabled(on) if on then self:Enable() else self:Disable() end end
function M:SetText(t) self._text = t == nil and "" or tostring(t) if self._kind == "EditBox" then fire(self, "OnTextChanged", false) end end
function M:SetFormattedText(f, ...) self._text = f:format(...) end
function M:GetText() return self._text end
function M:GetStringWidth() return #(self._text or "") * 6 end
function M:GetUnboundedStringWidth() return #(self._text or "") * 6 end
function M:GetStringHeight() return 12 end
function M:GetNumber() return tonumber(self._text) or 0 end
function M:SetMinMaxValues(a, b)
    self._min, self._max = a, b
    local v = math.max(a, math.min(b, self._value))
    if v ~= self._value then self._value = v fire(self, "OnValueChanged", v, false) end
end
function M:GetMinMaxValues() return self._min, self._max end
function M:SetValue(v)
    v = math.max(self._min, math.min(self._max, v))
    self._value = v
    fire(self, "OnValueChanged", v, false)
end
function M:GetValue() return self._value end
function M:GetThumbTexture() self._thumb = self._thumb or widget("Texture", nil, self) return self._thumb end
function M:SetThumbTexture() self:GetThumbTexture() end
function M:CreateTexture() return widget("Texture", nil, self) end
function M:CreateMaskTexture() return widget("Texture", nil, self) end
function M:CreateFontString() return widget("FontString", nil, self) end
function M:CreateAnimationGroup() return widget("AnimationGroup", nil, self) end
function M:CreateAnimation() return widget("Animation", nil, self) end
function M:GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
function M:GetTextColor() return 1, 1, 1, 1 end
function M:GetVertexColor() return 1, 1, 1, 1 end
function M:GetRegions() return end
function M:GetChildren() return end
function M:Click(button) fire(self, "OnClick", button or "LeftButton", false) end

-- ---------------------------------------------------------------- the world: clock, timers, whispers
function Mock.World()
    local world = { now = 1000, timers = {}, clients = {}, seq = 0, drop = 0, log = {}, sent = 0, dropped = 0 }
    function world:After(d, fn, client)
        self.seq = self.seq + 1
        table.insert(self.timers, { t = self.now + math.max(0, tonumber(d) or 0), seq = self.seq, fn = fn, client = client })
    end
    -- runs everything that is due in the next `seconds`, in time order
    function world:Run(seconds, step)
        local stop = self.now + (seconds or 0)
        while true do
            table.sort(self.timers, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.seq < b.seq end)
            local nxt = self.timers[1]
            if not nxt or nxt.t > stop then break end
            table.remove(self.timers, 1)
            self.now = math.max(self.now, nxt.t)
            if not (nxt.client and nxt.client.dead) then nxt.fn() end
            if step then step() end
        end
        self.now = stop
    end
    function world:Find(name)
        for _, c in ipairs(self.clients) do if c.name == name and not c.dead then return c end end
    end

    -- name: this player; friends: names it shares a guild/party with; saved: SavedVariables to load
    function world:Client(name, friends, saved)
        local client = { name = name, world = world, printed = {}, reports = {} }
        local env = setmetatable({}, { __index = _G })
        env._G = env
        client.env = env
        friends = friends or {}
        local function isFriend(n)
            if type(n) ~= "string" then return false end
            n = n:gsub("%-.*$", "")
            for _, f in ipairs(friends) do if f == n then return true end end
            return false
        end

        env.GetTime = function() return world.now end
        env.time = function() return math.floor(world.now) end
        env.GetServerTime = env.time
        env.date = os.date
        env.C_Timer = { After = function(d, fn) world:After(d, fn, client) end,
            NewTicker = function() return { Cancel = noop } end, NewTimer = function() return { Cancel = noop } end }
        env.CreateFrame = function(kind, fname, parent)
            local w = widget(kind, fname, parent)
            if fname then env[fname] = w end
            return w
        end
        env.UIParent = widget("Frame", "UIParent")
        env.WorldFrame = env.UIParent
        env.GameTooltip = widget("GameTooltip", "GameTooltip")
        env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) table.insert(client.printed, tostring(text)) end }
        env.UISpecialFrames = {}
        env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
        env.RAID_CLASS_COLORS = { WARLOCK = { r = 0.53, g = 0.53, b = 0.93 } }
        env.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
        env.GetPhysicalScreenSize = function() return 1920, 1080 end
        env.GetCursorPosition = function() return 0, 0 end
        env.IsShiftKeyDown = function() return false end
        env.IsControlKeyDown = function() return false end
        env.IsAltKeyDown = function() return false end
        env.PlaySound = noop
        env.PlaySoundFile = noop
        env.hooksecurefunc = noop
        env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
        env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
        env.InCombatLockdown = function() return false end
        env.UnitAffectingCombat = function() return false end
        env.UnitName = function(u) if u == "player" then return name end return nil end
        env.UnitFullName = function(u) if u == "player" then return name, "Realm" end return nil end
        env.GetUnitName = function(u) if u == "player" then return name end return nil end
        env.GetRealmName = function() return "Realm" end
        env.GetNormalizedRealmName = function() return "Realm" end
        env.UnitExists = function(u) return u == "player" end
        env.UnitIsPlayer = function() return true end
        env.UnitIsUnit = function(a, b) return a == b end
        env.UnitClass = function() return "Warlock", "WARLOCK" end
        env.UnitInParty = function(n) return isFriend(n) end
        env.UnitInRaid = function() return nil end
        env.IsInGroup = function() return #friends > 0 end
        env.IsInRaid = function() return false end
        env.IsInGuild = function() return true end
        env.GetNumGuildMembers = function() return #friends + 1 end
        env.GetGuildRosterInfo = function(i)
            local n = i == 1 and name or friends[i - 1]
            return n and (n .. "-Realm") or nil, "Member", 1, 60, "Warlock", "", "", "", true, 0, "WARLOCK"
        end
        env.C_GuildInfo = { GuildRoster = noop }
        env.C_ChatInfo = { RegisterAddonMessagePrefix = noop, SendAddonMessage = noop, InChatMessagingLockdown = function() return false end }
        env.Enum = {}

        env.FojjiCoreDB = saved and saved.FojjiCoreDB or {}
        env.FojjiCorePokerDB = saved and saved.FojjiCorePokerDB or nil
        env.FojjiCoreNS = setmetatable({
            Localize = function(fs) return fs end,
            Tr = function(t) return t end,
            ChatPrefix = function() return "FC: " end,
            Report = function(err) table.insert(client.reports, tostring(err)) end,
        }, { __index = function() return nil end })

        local function load(path, addon, ns)
            local chunk = assert(loadfile(path))
            setfenv(chunk, env)
            chunk(addon, ns)
        end
        for _, f in ipairs(GAMES_FILES) do load(GAMES .. "FojjiCore_Games/" .. f, "FojjiCore_Games", {}) end
        local FDJ = env.FojjiCoreNS.GamesBase
        client.FDJ = FDJ
        -- whispers go through the world, a moment later; some may be dropped on purpose
        FDJ.Comm.Send = function(kind, payload, channel, target)
            world.sent = world.sent + 1
            if world.drop > 0 and math.random() < world.drop then world.dropped = world.dropped + 1 return true end
            local to = target and target:gsub("%-.*$", "")
            world:After(0.12, function()
                local other = world:Find(to)
                if other then other.FDJ:Emit("FDJ_COMM", kind, payload, name, channel) end
            end)
            return true
        end
        client.ns = {}
        for _, f in ipairs(OUR_FILES) do load("FojjiCore_Poker/" .. f, "FojjiCore_Poker", client.ns) end
        client.Games = env.FojjiCoreNS.Games
        client.PK = client.Games.Poker
        FDJ:Emit("PLAYER_LOGIN")
        table.insert(world.clients, client)

        -- what /reload keeps
        function client:Saved()
            local function copy(v)
                if type(v) ~= "table" then return v end
                local t = {}
                for k, x in pairs(v) do t[k] = copy(x) end
                return t
            end
            return { FojjiCoreDB = copy(env.FojjiCoreDB), FojjiCorePokerDB = copy(env.FojjiCorePokerDB) }
        end
        return client
    end
    return world
end

return Mock
