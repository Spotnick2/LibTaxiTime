-- harness.lua: assertions, a small Forever client, and the library loader.
-- Run the tests from the repo root (paths are relative). Plain Lua 5.1.
--
-- Every stub below is in the Forever 1.60.1.70532 API dump (functions,
-- events, Structure TaxiNodeInfo); EventRegistry and hooksecurefunc are
-- FrameXML/client globals the addons here already use. Strict globals: a
-- read of anything not stubbed fails, as a missing API would in game.

local passed, failed = 0, 0

function check(cond, msg)
    if cond then passed = passed + 1 else
        failed = failed + 1
        io.write("  FAIL: " .. tostring(msg) .. "\n")
    end
end

function eq(actual, expected, msg)
    check(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

function near(actual, expected, msg, tol)
    check(type(actual) == "number" and math.abs(actual - expected) < (tol or 1e-6),
          string.format("%s: expected ~%s, got %s", msg, tostring(expected), tostring(actual)))
end

function done(name)
    io.write(string.format("%s: %d passed, %d failed\n", name, passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

function readFile(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local s = f:read("*a")
    f:close()
    return (s:gsub("\r\n", "\n"))   -- LF whatever the checkout has (core.autocrlf)
end

-- The Lua files LibTaxiTime-1.0.xml loads, in order (a listed file that's missing fails here).
function xmlScripts()
    local xml = readFile("LibTaxiTime-1.0.xml"):gsub("<!%-%-.-%-%->", "")
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do files[#files + 1] = (file:gsub("\\", "/")) end
    return files
end

--------------------------------------------------------------------------------
-- The client
--------------------------------------------------------------------------------

WoW = {}
local secrets = setmetatable({}, { __mode = "k" })

function WoW.Secret(label)
    local s = newproxy(true)
    local mt = getmetatable(s)
    local function boom() error("secret value used: " .. label, 2) end
    mt.__index, mt.__add, mt.__sub, mt.__lt, mt.__le, mt.__concat, mt.__tostring = boom, boom, boom, boom, boom, boom, boom
    secrets[s] = label
    return s
end

local frames

-- A fresh client: clock, taxi map, perk, frames, timers, the global functions
-- the library hooks (so a dead session's hooks don't chain into this one).
function WoW.reset()
    WoW.now, WoW.serverTime = 1000, 500000
    WoW.taxi = { onTaxi = false, mapID = 1414, nodes = {}, routes = {}, taken = {}, early = 0 }
    WoW.frequentFlier = 0
    WoW.loggedIn = false
    WoW.timers, WoW.tickers = {}, {}
    WoW.callbacks, WoW.triggered = {}, {}
    frames = {}
    function TakeTaxiNode(slot) table.insert(WoW.taxi.taken, slot) end
    function TaxiRequestEarlyLanding() WoW.taxi.early = WoW.taxi.early + 1 end
end

function issecretvalue(v) return secrets[v] ~= nil end
strmatch = string.match
function GetTime() return WoW.now end
function IsLoggedIn() return WoW.loggedIn end
function GetServerTime() return WoW.serverTime end
function UnitOnTaxi(unit)
    if unit ~= "player" then return false end
    if WoW.taxi.onTaxi == "secret" then return WoW.Secret("onTaxi") end
    return WoW.taxi.onTaxi
end
function GetTaxiMapID() return WoW.taxi.mapID end
function TaxiNodeName(slot)
    local n = WoW.taxi.nodes[slot]
    return n and n.name or "INVALID"
end
function GetNumRoutes(slot)
    local r = WoW.taxi.routes[slot]
    return r and #r - 1 or 0
end
function TaxiGetNodeSlot(slot, hop, isSource)
    local r = WoW.taxi.routes[slot]
    return r and r[isSource and hop or hop + 1]
end
C_TaxiMap = { GetAllTaxiNodes = function(uiMapID)
    if uiMapID ~= WoW.taxi.mapID then return {} end
    local out = {}
    for slot, n in pairs(WoW.taxi.nodes) do
        if n.id then out[#out + 1] = { nodeID = n.id, slotIndex = slot, name = n.name } end
    end
    return out
end }
-- Frequent Flier, node 110300 of the Adventure Legacy tree (1188). WoW.frequentFlier:
-- its rank; nil: no such node (ID 0, as the client answers); "secret": a secret rank.
C_Traits = {
    GetConfigIDByTreeID = function(treeID) return treeID == 1188 and 13280556 or nil end,
    GetNodeInfo = function(configID, nodeID)
        if configID ~= 13280556 or nodeID ~= 110300 or WoW.frequentFlier == nil then
            return { ID = 0, activeRank = 0, maxRanks = 0 }
        end
        local rank = WoW.frequentFlier == "secret" and WoW.Secret("rank") or WoW.frequentFlier
        return { ID = 110300, activeRank = rank, maxRanks = 1 }
    end,
}
C_Timer = {
    After = function(s, fn) table.insert(WoW.timers, { s = s, fn = fn }) end,
    NewTicker = function(s, fn)
        local t = { fn = fn, s = s }
        function t:Cancel() self.cancelled = true end
        table.insert(WoW.tickers, t)
        return t
    end,
}
EventRegistry = {}
function EventRegistry:RegisterCallback(event, fn, owner)
    WoW.callbacks[event] = WoW.callbacks[event] or {}
    table.insert(WoW.callbacks[event], { fn, owner })
end
function EventRegistry:TriggerEvent(event, ...)
    table.insert(WoW.triggered, event)
    for _, c in ipairs(WoW.callbacks[event] or {}) do c[1](c[2], ...) end
end
-- Both forms; the library uses the global one.
function hooksecurefunc(t, name, fn)
    if type(t) == "string" then t, name, fn = _G, t, name end
    local orig = t[name]
    rawset(t, name, function(...)
        local r = orig(...)
        fn(...)
        return r
    end)
end
function CreateFrame(kind)
    local f = { _events = {}, _scripts = {} }
    function f:RegisterEvent(e) self._events[e] = true end
    function f:UnregisterEvent(e) self._events[e] = nil end
    function f:SetScript(k, fn) self._scripts[k] = fn end
    table.insert(frames, f)
    return f
end

-- Drive: events to every frame registered for them, due timers, live tickers.
function WoW.fire(event, ...)
    for _, f in ipairs(frames) do
        if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
    end
end
function WoW.flushTimers()
    local run = WoW.timers
    WoW.timers = {}
    for _, t in ipairs(run) do t.fn() end
end
function WoW.fireTickers()
    for _, t in ipairs(WoW.tickers) do if not t.cancelled then t.fn() end end
end
function WoW.frameCount() return #frames end
function WoW.changes()
    local n = 0
    for _, e in ipairs(WoW.triggered) do if e == "LibTaxiTime.Changed" then n = n + 1 end end
    return n
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- One copy of the library, as the client loads it from a host: every file the
-- XML lists, called with (host, ns). `edit(file, src)` may rewrite a source
-- (a synthetic newer copy). Returns the library.
function loadCopy(host, edit)
    for _, file in ipairs(xmlScripts()) do
        local src = readFile(file)
        if edit then src = edit(file, src) end
        local chunk = assert(loadstring(src, "@" .. file))
        chunk(host or "Host", {})
    end
    return LibStub("LibTaxiTime-1.0")
end

-- A fresh session: a fresh client, no LibStub, one copy loaded.
function newSession(host, edit)
    LibStub = nil
    WoW.reset()
    return loadCopy(host, edit)
end

-- Common flying helpers. Nodes: slot -> { id, name }; routes: slot -> slots flown, start first.
function WoW.map(nodes, routes) WoW.taxi.nodes, WoW.taxi.routes = nodes, routes end
function takeOff(slot)
    TakeTaxiNode(slot)
    WoW.taxi.onTaxi = false   -- still false when control goes (EllesmereUI's note)
    WoW.fire("PLAYER_CONTROL_LOST")
    WoW.taxi.onTaxi = true
end
function landNow()
    WoW.taxi.onTaxi = false
    WoW.fire("PLAYER_CONTROL_GAINED")
end

WoW.reset()
local allowNil = { LibStub = true }
setmetatable(_G, { __index = function(_, k)
    if allowNil[k] then return nil end
    error("read of undefined global '" .. tostring(k) .. "' (not stubbed: is it in the API dump?)", 2)
end })
