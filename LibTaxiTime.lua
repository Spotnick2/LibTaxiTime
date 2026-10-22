-- LibTaxiTime-1.0: how long a flight-master flight takes on WoW: Forever, and
-- where the one in the air is. Embedded through LibStub: every addon that
-- uses it ships a copy, and the newest copy loaded runs (docs: the shared
-- References\Docs\EMBEDDED-LIBRARIES.md). Shared by GlassPanel's Flight plugin
-- and Glass Unit Frames' flight bar.
--
-- The client gives no flight duration. A flight's time, best first:
--   * "learned": this exact path as it was last landed, from the hosts'
--     stores (routes[path], keyed by the node ids along the way, "6>74>71");
--   * "route": the length of its hops (Routes.lua, generated from the
--     client's own TaxiPath tables by Tools/taxi_routes.py) at SPEED;
--     InFlight's measured Classic times give 29.96 yd/s over 266 routes,
--     stdev 0.16; multi-hop routes are the sum of their hops;
--   * "estimate": the other Frequent Flier kind, scaled; or hop by hop (a
--     hop's length, else its landed time: a path newer than Routes.lua mixed
--     with known ones); or any of the above with Frequent Flier unreadable;
--   * none: no total, only the time flown.
-- Frequent Flier (Legacy node 110300, spell 1225490: flight paths 20% faster,
-- per InFlight and EllesmereUI; unmeasured) keeps learned times of its own.
--
-- Lifecycle (built on Forever by EllesmereUI; reviewed on GlassPanel #125):
-- picking a node on the flight map (TakeTaxiNode, hooked, never replaced)
-- records the route; PLAYER_CONTROL_LOST within BOARD seconds starts it
-- (UnitOnTaxi may still read false then), else a look a second later starts
-- a flight with no route if on a taxi (a quest's). A landing is control back
-- (PLAYER_CONTROL_GAINED) and off the taxi in either order, within SETTLE
-- seconds of continuous time off the taxi; only that landing is learned,
-- timed at control back. A 1 s ticker runs only during a flight: SETTLE
-- seconds off the taxi without control back ends it, learning nothing.
-- TaxiRequestEarlyLanding (hooked) drops the total. The flight is saved in
-- every store's `current` (server time), so a /reload mid-flight resumes it;
-- a resumed flight learns nothing, nor does an early landing or an
-- unreadable Frequent Flier.
--
-- Stores: an embedded library has no SavedVariables of its own, so each host
-- hands over a table of its own (lib:AddStore), and the library owns two keys
-- in it: `routes` (`[path] = { base, fast, baseAt, fastAt }`, the At stamps
-- in server time; an entry's lone `at` counts for both kinds) and `current`. A
-- landing is written to every store; a lookup takes the newest time of the
-- kind asked across them, so removing either addon loses nothing. Nothing starts (no frame, hook or event) until
-- the first store is added.
--
-- API (MINOR 1), colon-called:
--   lib:AddStore(tbl) -> true, or false and why. From the host's ADDON_LOADED
--     (its SavedVariables are loaded then); the same table twice is ignored.
--     Added after login (a host loaded on demand), it resumes a flight in the
--     air at once.
--   lib:Current() -> nil off a flight, else a fresh table:
--     { to, from, stops, start, total, source, early, resumed }
--     to/from: node names (nil for an unknown route); stops: every node name
--     on the way, start first (nil for an unknown route); start: GetTime()
--     seconds; total: seconds or nil (unknown, or landing early); it stays
--     the prediction when the flight runs longer; source: "learned", "route",
--     "estimate" or nil; early, resumed: booleans.
--   lib:Last() -> nil, or { to, took } for the last flight that ended.
--   lib:LearnedCount() -> how many paths have a learned time.
--   lib:Forget() -> forgets every learned time (every store).
--   EventRegistry "LibTaxiTime.Changed" () fires when a flight starts, lands,
--   lands early, or its total changes (Forget). Read Current() again then.
--   lib.errors: the last few errors caught in the client's callbacks.

local MAJOR, MINOR = "LibTaxiTime-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.MINOR = MINOR
lib.SPEED = 30            -- yd/s along the path (Tools/taxi_routes.py says how it was fitted)
lib.FF_FACTOR = 1.2       -- Frequent Flier (InFlight's and EllesmereUI's figure, unmeasured)
lib.BOARD = 5             -- seconds from picking a node to losing control
lib.SETTLE = 3            -- seconds a landing waits for its other half
lib.MIN_FLIGHT, lib.MAX_FLIGHT = 5, 3600   -- a learned time outside these is noise
lib.LEGACY_TREE, lib.FF_NODE = 1188, 110300

-- State, reused in place by a newer copy (EMBEDDED-LIBRARIES section 5).
lib.YARDS = lib.YARDS or {}       -- Routes.lua fills it
lib.fileMinors = lib.fileMinors or {}
lib.stores = lib.stores or {}
lib.state = lib.state or {}       -- pending, flight, last, ticker, inWorld
lib.errors = lib.errors or {}
lib.impl = lib.impl or {}
local impl = lib.impl   -- only used while this file loads, to define impl below

local function P(v)
    local is = rawget(_G, "issecretvalue")
    if is and is(v) == true then return nil end
    return v
end

local function finite(v)
    v = P(v)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

-- A client callback's body: a throw is kept in lib.errors, never raised into Blizzard's code.
function impl.Guard(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local e = lib.errors
        e[#e + 1] = tostring(err)
        if #e > 10 then table.remove(e, 1) end
    end
end

function impl.OnTaxi() return P(UnitOnTaxi("player")) == true end

-- Logged in already: a host loaded on demand adds its store after
-- PLAYER_ENTERING_WORLD, which the library's frame (made then) never hears.
function impl.LoggedIn()
    local f = rawget(_G, "IsLoggedIn")
    return type(f) == "function" and P(f()) == true
end

function impl.Changed()
    local R = rawget(_G, "EventRegistry")
    if type(R) == "table" and type(R.TriggerEvent) == "function" then
        R:TriggerEvent("LibTaxiTime.Changed")
    end
end

--------------------------------------------------------------------------------
-- Routes
--------------------------------------------------------------------------------

-- A route is { keys = { node id (or name), ... }, names = { ... } }, start first.
function impl.PathOf(keys, from, to)
    local out = {}
    for i = from or 1, to or #keys do out[#out + 1] = tostring(keys[i]) end
    return table.concat(out, ">")
end

-- Checked whole: a saved route must be one we could have made.
function impl.ValidRoute(r)
    if type(r) ~= "table" or type(r.keys) ~= "table" or type(r.names) ~= "table" then return false end
    local n = #r.keys
    if n < 2 or n > 64 or #r.names ~= n then return false end
    for i = 1, n do
        local k = r.keys[i]
        if not ((type(k) == "number" or type(k) == "string") and type(r.names[i]) == "string") then return false end
    end
    return true
end

-- The flight map's slots to node ids, when the map says (C_TaxiMap's list).
function impl.NodeIds()
    local ids = {}
    local getMap = rawget(_G, "GetTaxiMapID")
    local mapID = type(getMap) == "function" and P(getMap())
    local T = rawget(_G, "C_TaxiMap")
    if type(mapID) ~= "number" or type(T) ~= "table" or type(T.GetAllTaxiNodes) ~= "function" then return ids end
    local ok, nodes = pcall(T.GetAllTaxiNodes, mapID)
    if not ok or type(nodes) ~= "table" then return ids end
    for _, node in ipairs(nodes) do
        local slot, id = P(node.slotIndex), P(node.nodeID)
        if type(slot) == "number" and type(id) == "number" then ids[slot] = id end
    end
    return ids
end

-- The route to `slot` as the flight map draws it (Blizzard's FM_FlightPathDataProvider),
-- or nil when any part of it can't be read.
function impl.ReadRoute(slot)
    local hops = P(GetNumRoutes(slot))
    if type(hops) ~= "number" or hops < 1 then return nil end
    local ids = lib.impl.NodeIds()
    local route = { keys = {}, names = {} }
    local function add(s)
        s = P(s)
        local name = type(s) == "number" and P(TaxiNodeName(s))
        if type(name) ~= "string" or name == "" then return false end
        route.keys[#route.keys + 1] = ids[s] or name
        route.names[#route.names + 1] = name
        return true
    end
    if not add(TaxiGetNodeSlot(slot, 1, true)) then return nil end
    for hop = 1, hops do
        if not add(TaxiGetNodeSlot(slot, hop, false)) then return nil end
    end
    return route
end

-- Frequent Flier bought: true or false; nil when it can't be read.
function impl.FrequentFlier()
    local T = rawget(_G, "C_Traits")
    if type(T) ~= "table" or type(T.GetConfigIDByTreeID) ~= "function" or type(T.GetNodeInfo) ~= "function" then return nil end
    local ok, config = pcall(T.GetConfigIDByTreeID, lib.LEGACY_TREE)
    config = ok and P(config)
    if type(config) ~= "number" then return nil end
    local ok2, node = pcall(T.GetNodeInfo, config, lib.FF_NODE)
    if not ok2 or type(node) ~= "table" or P(node.ID) ~= lib.FF_NODE then return nil end
    local rank = P(node.activeRank)
    if type(rank) ~= "number" then return nil end
    return rank > 0
end

--------------------------------------------------------------------------------
-- Learned times, across the hosts' stores
--------------------------------------------------------------------------------

function impl.Routes(store)
    if type(store.routes) ~= "table" then store.routes = {} end
    return store.routes
end

local function kindOf(fast) return fast and "fast" or "base" end
impl.KindOf = kindOf

-- The newest learned time for `path` of `kind` across the stores, or nil.
function impl.Stored(path, kind)
    local best, bestAt
    for _, store in ipairs(lib.stores) do
        local e = lib.impl.Routes(store)[path]
        local t = type(e) == "table" and finite(e[kind])
        if t and t >= lib.MIN_FLIGHT and t <= lib.MAX_FLIGHT then
            local at = finite(e[kind .. "At"]) or finite(e.at) or 0
            if not bestAt or at > bestAt then best, bestAt = t, at end
        end
    end
    return best
end

-- A learned time for `path` without Frequent Flier, from either kind.
function impl.AsBase(path)
    local t = lib.impl.Stored(path, "base")
    if t then return t end
    t = lib.impl.Stored(path, "fast")
    return t and t * lib.FF_FACTOR
end

-- The route's length in yards from the client's paths, or nil when a hop isn't there.
function impl.YardsOf(route)
    local yards = 0
    for i = 1, #route.keys - 1 do
        local y = lib.YARDS[lib.impl.PathOf(route.keys, i, i + 1)]
        if not y then return nil end
        yards = yards + y
    end
    return yards
end

-- The flight's length in seconds and where it comes from, or nil.
function impl.LengthOf(route, fast)
    local I = lib.impl
    local path = I.PathOf(route.keys)
    if fast ~= nil then
        local t = I.Stored(path, kindOf(fast))
        if t then return t, "learned" end
    end
    local yards = I.YardsOf(route)
    if yards then
        local t = yards / lib.SPEED
        if fast then t = t / lib.FF_FACTOR end
        return t, fast == nil and "estimate" or "route"
    end
    local base = I.AsBase(path)
    if not base and #route.keys > 2 then   -- hop by hop: its length, else its landed time
        base = 0
        for i = 1, #route.keys - 1 do
            local key = I.PathOf(route.keys, i, i + 1)
            local hop = (lib.YARDS[key] and lib.YARDS[key] / lib.SPEED) or I.AsBase(key)
            if not hop then base = nil break end
            base = base + hop
        end
    end
    if not base then return nil end
    return fast and base / lib.FF_FACTOR or base, "estimate"
end

function impl.Learn(fl, took)
    if fl.early or fl.resumed or not fl.route or fl.fast == nil then return end
    if took < lib.MIN_FLIGHT or took > lib.MAX_FLIGHT then return end
    local path = lib.impl.PathOf(fl.route.keys)
    local at = finite(GetServerTime()) or 0
    for _, store in ipairs(lib.stores) do
        local all = lib.impl.Routes(store)
        local entry = type(all[path]) == "table" and all[path] or {}
        entry[kindOf(fl.fast)] = math.floor(took * 10 + 0.5) / 10
        entry[kindOf(fl.fast) .. "At"] = at   -- per kind: a Frequent Flier landing doesn't freshen a base time
        all[path] = entry
    end
end

--------------------------------------------------------------------------------
-- Flights
--------------------------------------------------------------------------------

function impl.SaveCurrent()
    local fl, now = lib.state.flight, P(GetServerTime())
    local saved
    if fl and type(now) == "number" then
        saved = { route = fl.route, at = now - (GetTime() - fl.start), early = fl.early or nil }
    end
    for _, store in ipairs(lib.stores) do store.current = saved end
end

function impl.StartTicker()
    local S = lib.state
    if not S.ticker then S.ticker = C_Timer.NewTicker(1, function() lib.impl.Guard(lib.impl.Tick) end) end
end

function impl.StopTicker()
    local S = lib.state
    if S.ticker then S.ticker:Cancel() end
    S.ticker = nil
end

function impl.Start(route, startedAt, resumed, early)
    local I = lib.impl
    local fast = I.FrequentFlier()
    local total, source
    if route then total, source = I.LengthOf(route, fast) end
    lib.state.flight = { route = route, start = startedAt or GetTime(), total = (not early) and total or nil,
                         source = source, fast = fast, resumed = resumed == true, early = early == true }
    if not resumed then I.SaveCurrent() end
    I.StartTicker()
    I.Changed()
end

-- `at`: when it landed (control back), else now.
function impl.Land(learnIt, at)
    local I, S = lib.impl, lib.state
    local fl = S.flight
    if not fl then return end
    local took = (at or GetTime()) - fl.start
    if learnIt then I.Learn(fl, took) end
    S.last = { to = fl.route and fl.route.names[#fl.route.names], took = took }
    S.flight = nil
    for _, store in ipairs(lib.stores) do store.current = nil end
    I.StopTicker()
    I.Changed()
end

-- The newest saved flight across the stores.
function impl.SavedCurrent()
    local best
    for _, store in ipairs(lib.stores) do
        local c = store.current
        if type(c) == "table" and finite(c.at) and (not best or c.at > best.at) then best = c end
    end
    return best
end

-- After a /reload (or a login) on a taxi: the saved flight, if it's the one
-- still in the air; else a flight with nothing known about it.
function impl.Resume()
    local I = lib.impl
    if lib.state.flight then return end
    if not I.OnTaxi() then
        for _, store in ipairs(lib.stores) do store.current = nil end
        return
    end
    local c, now = I.SavedCurrent(), P(GetServerTime())
    if c and type(now) == "number" and now >= c.at and now - c.at <= lib.MAX_FLIGHT and I.ValidRoute(c.route) then
        I.Start(c.route, GetTime() - (now - c.at), true, c.early == true)
    else
        I.Start(nil, nil, true)
    end
end

function impl.Tick()
    local I, fl = lib.impl, lib.state.flight
    if not fl then I.StopTicker() return end
    if I.OnTaxi() then
        fl.offAt = nil   -- SETTLE counts time off the taxi in one go
    elseif GetTime() - fl.start > 2 then
        local now = GetTime()
        if fl.gainedAt and now - fl.gainedAt <= lib.SETTLE then
            I.Land(true, fl.gainedAt)   -- control came back first: landed then
        elseif not fl.offAt then
            fl.offAt = now              -- control back may still be on its way
        elseif now - fl.offAt >= lib.SETTLE then
            I.Land(false)               -- its landing was missed
        end
    end
end

function impl.OnTakeTaxiNode(slot)
    lib.state.pending = { route = lib.impl.ReadRoute(slot), clicked = GetTime() }
end

function impl.OnEarlyLanding()
    local fl = lib.state.flight
    if not fl or fl.early then return end
    fl.early, fl.total = true, nil
    lib.impl.SaveCurrent()
    lib.impl.Changed()
end

function impl.OnEvent(event)
    local I, S = lib.impl, lib.state
    if event == "PLAYER_CONTROL_LOST" then
        local p = S.pending
        S.pending = nil
        if S.flight then return end
        if p and GetTime() - p.clicked < lib.BOARD then
            I.Start(p.route)
        else
            -- Not picked here (a quest's flight), or no flight at all (a stun): a look in a moment.
            C_Timer.After(1, function()
                lib.impl.Guard(function()
                    if not lib.state.flight and lib.impl.OnTaxi() then lib.impl.Start(nil) end
                end)
            end)
        end
    elseif event == "PLAYER_CONTROL_GAINED" then
        local fl = S.flight
        if not fl then return end
        if I.OnTaxi() then
            fl.gainedAt = GetTime()   -- still reads on the taxi: the ticker lands it from this
        else
            I.Land(true)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        S.inWorld = true
        I.Resume()
    end
end

-- Hooks and events, once per session whatever copy installs them; they call
-- through lib.impl, so a newer copy's code runs (section 5, rule 2).
function impl.Begin()
    if not lib.hooked then
        lib.hooked = true
        for name, field in pairs({ TakeTaxiNode = "OnTakeTaxiNode", TaxiRequestEarlyLanding = "OnEarlyLanding" }) do
            if type(rawget(_G, name)) == "function" then
                hooksecurefunc(name, function(...) lib.impl.Guard(lib.impl[field], ...) end)
            end
        end
    end
    if not lib.frame then
        lib.frame = CreateFrame("Frame")
        lib.frame:SetScript("OnEvent", function(_, event, ...) lib.impl.Guard(lib.impl.OnEvent, event, ...) end)
        lib.frame:RegisterEvent("PLAYER_CONTROL_LOST")
        lib.frame:RegisterEvent("PLAYER_CONTROL_GAINED")
        lib.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    end
end

--------------------------------------------------------------------------------
-- The API
--------------------------------------------------------------------------------

-- Every runtime file of the active MINOR loaded completely (section 5, rule 6).
local function checkLoaded()
    local _, active = LibStub:GetLibrary(MAJOR)
    for _, file in ipairs({ "LibTaxiTime", "Routes" }) do
        if lib.fileMinors[file] ~= active then
            error(MAJOR .. ": " .. file .. ".lua didn't load completely (minor " .. tostring(lib.fileMinors[file])
                  .. ", active " .. tostring(active) .. ")", 3)
        end
    end
end

function lib:AddStore(tbl)
    if self ~= lib then error(MAJOR .. ": call AddStore with a colon", 2) end
    checkLoaded()
    if type(tbl) ~= "table" then return false, "the store must be a table" end
    for _, s in ipairs(lib.stores) do
        if s == tbl then return true end
    end
    lib.stores[#lib.stores + 1] = tbl
    lib.impl.Routes(tbl)
    lib.impl.Begin()
    local fl = lib.state.flight
    if fl then
        lib.impl.SaveCurrent()   -- a store added mid-flight keeps it too
    elseif lib.state.inWorld or lib.impl.LoggedIn() then
        lib.state.inWorld = true
        lib.impl.Resume()        -- a host loaded after the world: it may be on a taxi already
    end
    return true
end

function lib:Current()
    if self ~= lib then error(MAJOR .. ": call Current with a colon", 2) end
    local fl = lib.state.flight
    if not fl then return nil end
    local r = fl.route
    local stops
    if r then
        stops = {}
        for i, n in ipairs(r.names) do stops[i] = n end
    end
    return { to = r and r.names[#r.names], from = r and r.names[1], stops = stops, start = fl.start,
             total = (not fl.early) and fl.total or nil, source = fl.source,
             early = fl.early == true, resumed = fl.resumed == true }
end

function lib:Last()
    if self ~= lib then error(MAJOR .. ": call Last with a colon", 2) end
    local l = lib.state.last
    return l and { to = l.to, took = l.took } or nil
end

function lib:LearnedCount()
    if self ~= lib then error(MAJOR .. ": call LearnedCount with a colon", 2) end
    local seen, n = {}, 0
    for _, store in ipairs(lib.stores) do
        for path, e in pairs(lib.impl.Routes(store)) do
            if not seen[path] and type(e) == "table" and (finite(e.base) or finite(e.fast)) then
                seen[path] = true
                n = n + 1
            end
        end
    end
    return n
end

function lib:Forget()
    if self ~= lib then error(MAJOR .. ": call Forget with a colon", 2) end
    for _, store in ipairs(lib.stores) do store.routes = {} end
    local fl = lib.state.flight
    if fl and fl.route and not fl.early then
        fl.total, fl.source = lib.impl.LengthOf(fl.route, fl.fast)
    end
    lib.impl.Changed()
end

lib.fileMinors.LibTaxiTime = MINOR
