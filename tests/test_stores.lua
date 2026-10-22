-- Stores: one per host; written to all, read from the newest; resume after a reload.
dofile("tests/harness.lua")

local lib = newSession("GlassPanel")
WoW.map({ [1] = { id = 901, name = "Alpha" }, [2] = { id = 902, name = "Beta" } }, { [2] = { 1, 2 } })
local a, b = { routes = { ["901>902"] = { base = 80 } } }, { flight = "the host's own key" }
lib:AddStore(a)
lib:AddStore(b)
eq(#lib.stores, 2, "two hosts, two stores")
eq(b.flight, "the host's own key", "the host's other keys are left alone")

-- A landing goes to every store.
WoW.now, WoW.serverTime = 1000, 600000
takeOff(2)
eq(lib:Current().total, 80, "read from the store that has it")
check(type(a.current) == "table" and type(b.current) == "table", "the flight is saved in both")
WoW.now = 1085
landNow()
eq(a.routes["901>902"].base, 85, "learned into the first")
eq(b.routes["901>902"].base, 85, "...and the second")
eq(b.routes["901>902"].baseAt, 600000, "...stamped")

-- Reading takes the newest entry across the stores.
a.routes["901>902"] = { base = 70, baseAt = 700000 }
b.routes["901>902"] = { base = 99, baseAt = 650000 }
takeOff(2)
eq(lib:Current().total, 70, "the newest entry wins")
landNow()
a.routes["901>902"] = { base = 70 }   -- no stamp (written before stamps): oldest
b.routes["901>902"] = { base = 99, baseAt = 1 }
takeOff(2)
eq(lib:Current().total, 99, "a stamped entry beats an unstamped one")
landNow()
-- Stamps are per kind (Codex on #2): A's newer Frequent Flier landing doesn't
-- make its older base time win over B's newer one.
a.routes["901>902"] = { base = 70, baseAt = 100, fast = 60, fastAt = 200 }
b.routes["901>902"] = { base = 80, baseAt = 150 }
takeOff(2)
eq(lib:Current().total, 80, "the newest base time, whatever the fast one's stamp")
landNow()
-- ...and the mirror: a newer base landing doesn't make an older fast time win.
a.routes["901>902"] = { base = 70, baseAt = 300, fast = 60, fastAt = 100 }
b.routes["901>902"] = { fast = 50, fastAt = 200 }
WoW.frequentFlier = 1
takeOff(2)
eq(lib:Current().total, 50, "the newest fast time, whatever the base one's stamp")
landNow()
WoW.frequentFlier = 0
a.routes["901>902"] = { base = 70, at = 300 }   -- a lone `at` (written by an early copy) counts for both
b.routes["901>902"] = { base = 80, baseAt = 150 }
takeOff(2)
eq(lib:Current().total, 70, "a lone at stamps the base time too")
landNow()
-- A Frequent Flier landing stamps only its own kind.
WoW.frequentFlier = 1
WoW.now, WoW.serverTime = 1500, 900000
takeOff(2)
WoW.now = 1560
landNow()
eq(a.routes["901>902"].fastAt, 900000, "a fast landing stamps fastAt")
eq(a.routes["901>902"].baseAt, nil, "...and leaves the base stamp alone")
eq(b.routes["901>902"].baseAt, 150, "...in every store")
WoW.frequentFlier = 0
eq(lib:LearnedCount(), 1, "a path in both stores counts once")

-- A store added mid-flight gets the flight saved too.
WoW.now = 2000
takeOff(2)
local c = {}
lib:AddStore(c)
eq(type(c.current), "table", "added mid-flight: saved there too")
landNow()

-- A /reload mid-flight: a new session resumes from the stores, from server time.
a.routes["901>902"] = { base = 90, at = 800000 }
WoW.now, WoW.serverTime = 3000, 800100
takeOff(2)
local saved = a.current
eq(saved.at, 800100, "saved at takeoff, in server time")
lib = newSession("GlassPanel")
WoW.now, WoW.serverTime = 50, 800130
WoW.taxi.onTaxi = true
local a2 = { routes = a.routes, current = saved }
lib:AddStore(a2)
eq(lib:Current(), nil, "nothing resumes before the world is entered")
WoW.fire("PLAYER_ENTERING_WORLD")
local cur = lib:Current()
check(cur and cur.resumed, "reloaded on the taxi: resumed")
eq(cur.start, 20, "30 s in, by server time")
eq(cur.total, 90, "its time")
WoW.now = 110
landNow()
eq(a2.routes["901>902"].base, 90, "a resumed flight teaches nothing")

-- A host loaded on demand, after the world (Codex on #2): its store is the
-- first, the library's frame never heard PLAYER_ENTERING_WORLD, and the
-- flight in the air resumes at once.
lib = newSession()
WoW.inWorld = true
WoW.taxi.onTaxi = true
local late = { current = { route = { keys = { 901, 902 }, names = { "Alpha", "Beta" } }, at = WoW.serverTime - 10 } }
lib:AddStore(late)
cur = lib:Current()
check(cur and cur.to == "Beta" and cur.resumed, "in the world already: the save resumes on adding the store")
landNow()
-- Loaded on demand after PLAYER_LOGIN but before the world (a /reload mid-flight,
-- Codex's follow-up on #2): the taxi state isn't ready (reads off the taxi), so
-- nothing resumes yet and the saved flight is kept for the world entry.
lib = newSession()
WoW.inWorld = false   -- logged in, not in the world yet
WoW.taxi.onTaxi = false
local early = { current = { route = { keys = { 901, 902 }, names = { "Alpha", "Beta" } }, at = WoW.serverTime - 10 } }
lib:AddStore(early)
eq(lib:Current(), nil, "before the world: nothing resumes")
check(type(early.current) == "table", "...and the saved flight is kept")
WoW.inWorld, WoW.taxi.onTaxi = true, true
WoW.fire("PLAYER_ENTERING_WORLD")
cur = lib:Current()
check(cur and cur.to == "Beta" and cur.resumed, "at world entry it resumes, route and all")
landNow()
-- Before login (a store added at ADDON_LOADED, the usual case) nothing resumes until the world.
lib = newSession()
WoW.taxi.onTaxi = true
lib:AddStore({ current = { route = { keys = { 901, 902 }, names = { "Alpha", "Beta" } }, at = WoW.serverTime } })
eq(lib:Current(), nil, "before login: nothing yet")
WoW.fire("PLAYER_ENTERING_WORLD")
check(lib:Current() ~= nil, "then the world resumes it")
landNow()

-- A stale save, a corrupt one, or off the taxi: no resume.
lib = newSession()
local s = { current = { route = { keys = { 901, 902 }, names = { "A", "B" } }, at = WoW.serverTime - 99999 } }
lib:AddStore(s)
WoW.taxi.onTaxi = true
WoW.fire("PLAYER_ENTERING_WORLD")
cur = lib:Current()
check(cur and cur.to == nil, "a stale save: a flight, route unknown")
landNow()
lib = newSession()
s = { current = { route = { keys = { 901 }, names = { "A" } }, at = WoW.serverTime } }
lib:AddStore(s)
WoW.taxi.onTaxi = true
WoW.fire("PLAYER_ENTERING_WORLD")
cur = lib:Current()
check(cur and cur.to == nil, "a corrupt route: route unknown")
landNow()
lib = newSession()
s = { current = { route = { keys = { 901, 902 }, names = { "A", "B" } }, at = WoW.serverTime } }
lib:AddStore(s)
WoW.taxi.onTaxi = false
WoW.fire("PLAYER_ENTERING_WORLD")
eq(lib:Current(), nil, "off the taxi: none")
eq(s.current, nil, "...and the save is dropped")
eq(#lib.errors, 0, "no errors caught")
done("test_stores")
