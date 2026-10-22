-- The tracker: where a flight's time comes from, takeoff, landing, resume.
dofile("tests/harness.lua")

local lib = newSession()
eq(lib.fileMinors.LibTaxiTime, 1, "the tracker file loaded")
eq(lib.fileMinors.Routes, 1, "the routes file loaded")
check(lib.YARDS["23>25"] == 3304, "Routes.lua fills lib.YARDS (Orgrimmar > Crossroads)")
eq(WoW.frameCount(), 0, "nothing starts before a store is added")

-- Dot calls are refused (the colon is the contract).
check(not pcall(lib.AddStore, {}), "AddStore needs a colon")
local ok, why = lib:AddStore("nope")
check(not ok and why, "a store must be a table")

local store = {}
eq(lib:AddStore(store), true, "a store")
eq(type(store.routes), "table", "the library owns `routes` in it")
eq(WoW.frameCount(), 1, "one event frame once a store is there")
eq(lib:AddStore(store), true, "the same store twice is ignored")
eq(#lib.stores, 1, "...kept once")
eq(lib:Current(), nil, "off a flight: nil")

-- Nodes with ids Routes.lua doesn't have: only landings time them.
WoW.map({ [1] = { id = 901, name = "Alpha, Somewhere" }, [2] = { id = 902, name = "Beta, Elsewhere" },
          [3] = { id = 903, name = "Gamma, Far Away" } },
        { [2] = { 1, 2 }, [3] = { 1, 2, 3 } })

-- A first flight on an unknown path: no total; learned at landing.
WoW.now = 1000
takeOff(2)
local cur = lib:Current()
check(cur ~= nil, "control lost right after a pick: a flight")
eq(cur.to, "Beta, Elsewhere", "its destination")
eq(cur.from, "Alpha, Somewhere", "where from")
eq(#cur.stops, 2, "every stop, start first")
eq(cur.start, 1000, "start in GetTime() seconds")
eq(cur.total, nil, "unknown: no total")
eq(cur.source, nil, "...and no source")
eq(WoW.changes(), 1, "takeoff is said")
cur.to = "changed"
eq(lib:Current().to, "Beta, Elsewhere", "Current() is a copy")
eq(type(store.current), "table", "the flight is saved for a reload")
WoW.now = 1090.04
landNow()
eq(lib:Current(), nil, "landed")
eq(store.routes["901>902"].base, 90, "learned, to a tenth")
eq(store.routes["901>902"].baseAt, 500000, "...stamped with server time, for its kind")
eq(store.current, nil, "nothing to resume")
eq(WoW.changes(), 2, "the landing is said")
local last = lib:Last()
check(last and last.to == "Beta, Elsewhere" and math.abs(last.took - 90.04) < 1e-6, "Last() remembers it")
eq(lib:LearnedCount(), 1, "one path learned")

-- Again: the learned time.
WoW.now = 2000
takeOff(2)
cur = lib:Current()
eq(cur.total, 90, "learned: its time")
eq(cur.source, "learned", "...from a landing")
landNow()

-- A path never flown: hop by hop from learned hops, an estimate.
store.routes["902>903"] = { base = 60 }
takeOff(3)
cur = lib:Current()
eq(cur.total, 150, "two learned hops added")
eq(cur.source, "estimate", "...an estimate")
WoW.now = 2140
landNow()
eq(store.routes["901>902>903"].base, 140, "the whole path is learned on its own")

-- Frequent Flier keeps its own times; the other kind is scaled and estimated.
WoW.frequentFlier = 1
WoW.now = 3000
takeOff(2)
cur = lib:Current()
near(cur.total, 90 / 1.2, "the base time, 20% faster")
eq(cur.source, "estimate", "...estimated")
WoW.now = 3072
landNow()
eq(store.routes["901>902"].fast, 72, "learned as its own kind")
eq(store.routes["901>902"].base, 90, "...the other kept")
takeOff(2)
eq(lib:Current().source, "learned", "exact for its kind")
landNow()
WoW.frequentFlier = "secret"
WoW.now = 3200
takeOff(3)
eq(lib:Current().source, "estimate", "an unreadable perk: an estimate")
WoW.now = 3300
landNow()
eq(store.routes["901>902>903"].base, 140, "...and nothing learned")
WoW.frequentFlier = 0

-- From the first flight: the client's path lengths at 30 yd/s.
WoW.map({ [1] = { id = 23, name = "Orgrimmar, Durotar" }, [2] = { id = 25, name = "Crossroads, The Barrens" },
          [3] = { id = 77, name = "Camp Taurajo, The Barrens" }, [4] = { id = 904, name = "Riverlands Post" } },
        { [2] = { 1, 2 }, [3] = { 1, 2, 3 }, [4] = { 1, 2, 4 } })
WoW.now = 4000
takeOff(2)
cur = lib:Current()
near(cur.total, 3304 / 30, "never flown: the route's length at 30 yd/s")
eq(cur.source, "route", "...from the client's paths")
landNow()
takeOff(3)
near(lib:Current().total, (3304 + 2705) / 30, "two hops: their lengths added")
landNow()
WoW.frequentFlier = 1
store.routes["23>25>77"] = nil
takeOff(3)
near(lib:Current().total, (3304 + 2705) / 30 / 1.2, "Frequent Flier: 20% faster")
landNow()
WoW.frequentFlier = 0
-- A path newer than Routes.lua, landed once, mixed with a known hop.
store.routes["25>904"] = { base = 40 }
takeOff(4)
cur = lib:Current()
near(cur.total, 3304 / 30 + 40, "a known hop's length plus a new hop's landed time")
eq(cur.source, "estimate", "...an estimate")
landNow()

-- Overtime: the total stays the prediction.
WoW.map({ [1] = { id = 901, name = "Alpha" }, [2] = { id = 902, name = "Beta" } }, { [2] = { 1, 2 } })
store.routes["901>902"] = { base = 90 }
WoW.now = 5000
takeOff(2)
WoW.now = 5100
WoW.fireTickers()
eq(lib:Current().total, 90, "past the prediction, the total is unchanged")
landNow()

-- A stale pick doesn't start a flight; a flight not picked here is noticed a second later.
WoW.now = 6000
TakeTaxiNode(2)
WoW.now = 6010
WoW.taxi.onTaxi = false
WoW.fire("PLAYER_CONTROL_LOST")
eq(lib:Current(), nil, "a pick 10 s old doesn't start a flight")
WoW.flushTimers()
eq(lib:Current(), nil, "...and off the taxi a second later, still none")
WoW.fire("PLAYER_CONTROL_GAINED")
WoW.fire("PLAYER_CONTROL_LOST")
WoW.taxi.onTaxi = true
WoW.flushTimers()
cur = lib:Current()
check(cur and cur.to == nil and cur.total == nil, "on the taxi a second later: a flight, route unknown")
-- Its landing missed: off the taxi for SETTLE s without control back ends it.
WoW.taxi.onTaxi = false
WoW.now = 6030
WoW.fireTickers()
check(lib:Current() ~= nil, "just off the taxi: control back may still come")
WoW.now = 6033
WoW.fireTickers()
eq(lib:Current(), nil, "off the taxi for 3 s without control back: ended")

-- A normal landing is learned whichever half the client says first.
store.routes["901>902"] = nil
WoW.now = 6100
takeOff(2)
WoW.now = 6150
WoW.taxi.onTaxi = false
WoW.fireTickers()
check(lib:Current() ~= nil, "off the taxi before control back: still pending")
WoW.now = 6151
WoW.fire("PLAYER_CONTROL_GAINED")
eq(store.routes["901>902"].base, 51, "control back: learned, timed then")
store.routes["901>902"] = nil
WoW.now = 6200
takeOff(2)
WoW.now = 6260
WoW.fire("PLAYER_CONTROL_GAINED")
check(lib:Current() ~= nil, "control back still on the taxi: not landed yet")
WoW.now = 6261
WoW.taxi.onTaxi = false
WoW.fireTickers()
eq(lib:Current(), nil, "off the taxi at the next tick: landed")
eq(store.routes["901>902"].base, 60, "...learned, timed at control back")
-- A moment off the taxi mid-flight doesn't shorten the real landing's wait.
store.routes["901>902"] = nil
WoW.now = 6300
takeOff(2)
WoW.now = 6310
WoW.taxi.onTaxi = false
WoW.fireTickers()
WoW.now = 6311
WoW.taxi.onTaxi = true
WoW.fireTickers()
WoW.now = 6370
WoW.taxi.onTaxi = false
WoW.fireTickers()
check(lib:Current() ~= nil, "an earlier moment off the taxi doesn't count")
WoW.now = 6371
WoW.fire("PLAYER_CONTROL_GAINED")
eq(store.routes["901>902"].base, 71, "...and the landing is learned")

-- Early landing: no total, nothing learned.
WoW.now = 7000
takeOff(2)
local before = WoW.changes()
TaxiRequestEarlyLanding()
eq(WoW.taxi.early, 1, "the request still reaches the client")
cur = lib:Current()
check(cur.early and cur.total == nil, "landing early: no total")
eq(WoW.changes(), before + 1, "...said")
WoW.now = 7050
landNow()
eq(store.routes["901>902"].base, 71, "an early landing teaches nothing")

-- Forget: every learned time, and the flight's total again.
WoW.now = 7100
takeOff(2)
lib:Forget()
eq(next(store.routes), nil, "forgotten")
eq(lib:Current().total, nil, "the flight's total is recomputed")
landNow()

-- Unreadable taxi flag: not on the taxi (nothing throws).
WoW.taxi.onTaxi = "secret"
WoW.fire("PLAYER_ENTERING_WORLD")
eq(lib:Current(), nil, "a secret taxi flag reads as not on a taxi")
WoW.taxi.onTaxi = false
eq(#lib.errors, 0, "no errors caught")
done("test_tracker")
