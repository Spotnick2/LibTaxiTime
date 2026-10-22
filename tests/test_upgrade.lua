-- Upgrading in place (EMBEDDED-LIBRARIES section 5). r1 has no released
-- predecessor, so a synthetic newer copy (the current source as MINOR 2, with
-- a marker function and Changed counted) loads over the current one.
dofile("tests/harness.lua")

local function newer(minor)
    return function(file, src)
        src = src:gsub('local MAJOR, MINOR = "LibTaxiTime%-1%.0", 1', 'local MAJOR, MINOR = "LibTaxiTime-1.0", ' .. minor)
        if file == "LibTaxiTime.lua" then
            src = src:gsub("\nlib%.fileMinors%.LibTaxiTime = MINOR",
                "\nfunction impl.Probe() return MINOR end\nlib.fileMinors.LibTaxiTime = MINOR")
        end
        return src
    end
end

-- A newer copy over a flight in the air: the flight, the stores and the
-- hooks survive; the newer code runs; nothing is installed twice.
local lib = newSession("GlassPanel")
WoW.map({ [1] = { id = 901, name = "Alpha" }, [2] = { id = 902, name = "Beta" } }, { [2] = { 1, 2 } })
local store = { routes = { ["901>902"] = { base = 90 } } }
lib:AddStore(store)
local yards = lib.YARDS
WoW.now = 1000
takeOff(2)
local lib2 = loadCopy("GlassUnitFrames", newer(2))
check(lib2 == lib, "LibStub hands the newer copy the same table")
eq(select(2, LibStub:GetLibrary("LibTaxiTime-1.0")), 2, "MINOR 2 is active")
eq(lib.fileMinors.LibTaxiTime, 2, "the tracker file is the newer one")
eq(lib.fileMinors.Routes, 2, "the routes file too")
check(lib.YARDS == yards, "lib.YARDS is filled in place")
eq(lib.YARDS["23>25"], 3304, "...with the routes")
eq(lib.impl.Probe(), 2, "the newer code is installed")
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
eq(older.fileMinors.LibTaxiTime, 2, "an older copy installs nothing")
eq(lib.impl.Probe(), 2, "the newer code stays")

-- The same copy twice changes nothing either.
lib = newSession()
local impl1 = lib.impl.Tick
loadCopy("SecondHost")
check(lib.impl.Tick == impl1, "an equal copy loading twice installs nothing")

-- A newer copy that breaks partway: the entry point says so (rule 6).
lib = newSession()
pcall(loadCopy, "Broken", function(file, src)
    src = newer(3)(file, src)
    if file == "Routes.lua" then src = 'error("cut short")\n' .. src end
    return src
end)
local ok, err = pcall(lib.AddStore, lib, {})
check(not ok and tostring(err):find("didn't load completely", 1, true), "an incomplete newer copy fails loudly")
done("test_upgrade")
