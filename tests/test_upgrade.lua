-- Upgrading in place (EMBEDDED-LIBRARIES section 5). The released r1 (frozen
-- in tests/fixtures) loads under the current copy; then a synthetic newer copy
-- (the current source as MINOR 3, with a marker function and Changed counted)
-- loads over the current one.
dofile("tests/harness.lua")

-- The released r1, as a host that shipped it loads it.
local function released(file, src)
    local name = file:match("([^/\\]+)%.lua$")
    if name == "LibTaxiTime" or name == "Routes" then return readFile("tests/fixtures/" .. name .. "-r1.lua") end
    return src
end

-- r1, then the current copy over a flight in the air: the newer routes replace
-- r1's (a route the client dropped is gone), the flight and the store are kept.
local lib = newSession("GlassPanel", released)
eq(select(2, LibStub:GetLibrary("LibTaxiTime-1.0")), 1, "r1 is active")
eq(lib.YARDS["11>21"], 15026, "r1's Undercity > Kargath (70532)")
eq(lib.YARDS["3275>3276"], 1624, "r1 has the Riverglades path")
WoW.map({ [1] = { id = 901, name = "Alpha" }, [2] = { id = 902, name = "Beta" } }, { [2] = { 1, 2 } })
local store = { routes = { ["901>902"] = { base = 90 } } }
lib:AddStore(store)
local yards = lib.YARDS
WoW.now = 1000
takeOff(2)
check(loadCopy("GlassUnitFrames") == lib, "the current copy upgrades r1's table")
eq(select(2, LibStub:GetLibrary("LibTaxiTime-1.0")), 2, "MINOR 2 is active")
eq(lib.fileMinors.LibTaxiTime, 2, "the tracker file is the current one")
eq(lib.fileMinors.Routes, 2, "the routes file too")
check(lib.YARDS == yards, "lib.YARDS is the same table")
eq(lib.ROUTES_BUILD, "1.60.1.70938", "the routes are 70938's")
eq(lib.YARDS["11>21"], 14837, "a changed length is the new one")
eq(lib.YARDS["3275>3276"], nil, "a path the client dropped is gone")
eq(#lib.stores, 1, "the store is kept")
eq(lib:Current().total, 90, "the flight in the air is kept")
eq(WoW.frameCount(), 1, "no second event frame")
eq(lib:AddStore({}), true, "the entry point works after the upgrade")

local function newer(minor)
    return function(file, src)
        src = src:gsub('local MAJOR, MINOR = "LibTaxiTime%-1%.0", 2', 'local MAJOR, MINOR = "LibTaxiTime-1.0", ' .. minor)
        if file == "LibTaxiTime.lua" then
            src = src:gsub("\nlib%.fileMinors%.LibTaxiTime = MINOR",
                "\nfunction impl.Probe() return MINOR end\nlib.fileMinors.LibTaxiTime = MINOR")
        end
        return src
    end
end

-- A newer copy over a flight in the air: the flight, the stores and the
-- hooks survive; the newer code runs; nothing is installed twice.
lib = newSession("GlassPanel")
WoW.map({ [1] = { id = 901, name = "Alpha" }, [2] = { id = 902, name = "Beta" } }, { [2] = { 1, 2 } })
store = { routes = { ["901>902"] = { base = 90 } } }
lib:AddStore(store)
yards = lib.YARDS
WoW.now = 1000
takeOff(2)
local lib2 = loadCopy("GlassUnitFrames", newer(3))
check(lib2 == lib, "LibStub hands the newer copy the same table")
eq(select(2, LibStub:GetLibrary("LibTaxiTime-1.0")), 3, "MINOR 3 is active")
eq(lib.fileMinors.LibTaxiTime, 3, "the tracker file is the newer one")
eq(lib.fileMinors.Routes, 3, "the routes file too")
check(lib.YARDS == yards, "lib.YARDS is filled in place")
eq(lib.YARDS["23>25"], 3304, "...with the routes")
eq(lib.impl.Probe(), 3, "the newer code is installed")
eq(#lib.stores, 1, "the stores are kept")
eq(lib:Current().total, 90, "the flight in the air is kept")
-- The second host adds its store through the newer copy: nothing is installed again.
local guf = {}
eq(lib:AddStore(guf), true, "the entry point works on the newer copy")
eq(type(guf.current), "table", "...and saves the flight in the air there")
eq(WoW.frameCount(), 1, "no second event frame")
-- Hooks and the frame dispatch through lib.impl: the newer code runs, once.
local calls = 0
local orig = lib.impl.OnTakeTaxiNode
lib.impl.OnTakeTaxiNode = function(...) calls = calls + 1; return orig(...) end
landNow()
local before = WoW.changes()
WoW.now = 2000
takeOff(2)
eq(calls, 1, "one hook call per pick: not hooked twice")
eq(WoW.changes(), before + 1, "one Changed per takeoff: one event frame")
WoW.now = 2088
landNow()
eq(guf.routes["901>902"].base, 88, "a landing after the upgrade is learned into the new host's store")
eq(store.routes["901>902"].base, 88, "...and the first host's")

-- An older copy loading after a newer one changes nothing.
local older = loadCopy("OldHost")
eq(older.fileMinors.LibTaxiTime, 3, "an older copy installs nothing")
eq(lib.impl.Probe(), 3, "the newer code stays")

-- The same copy twice changes nothing either.
lib = newSession()
local impl1 = lib.impl.Tick
loadCopy("SecondHost")
check(lib.impl.Tick == impl1, "an equal copy loading twice installs nothing")

-- A newer copy that breaks partway: the entry point says so (rule 6).
lib = newSession()
pcall(loadCopy, "Broken", function(file, src)
    src = newer(4)(file, src)
    if file == "Routes.lua" then src = 'error("cut short")\n' .. src end
    return src
end)
local ok, err = pcall(lib.AddStore, lib, {})
check(not ok and tostring(err):find("didn't load completely", 1, true), "an incomplete newer copy fails loudly")
done("test_upgrade")
