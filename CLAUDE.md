# CLAUDE.md

Guidance for Claude Code in this repository. The shared rules for every project under
`C:\Projects\WoW` are in `..\CLAUDE.md`; the embedded-library rules this repo follows are
`C:\Projects\WoW\References\Docs\EMBEDDED-LIBRARIES.md` (read it before changing anything that
loads).

## What this is

**LibTaxiTime-1.0**, an embedded LibStub library for **WoW: Forever 1.60.1** (Lua 5.1): how long
a flight-master flight takes, and where the one in the air is. Single owner (Spotnick). Public,
MIT. Consumers: **GlassPanel**'s Flight plugin (`..\GlassPanel\Plugins\Flight`, the pilot: its
CI asserts what its zip holds) and **Glass Unit Frames**' flight bar (GUF #148/#153). Born from
GlassPanel #124 / PR #125, where the timing was built and reviewed (Codex).

## Files

- `LibTaxiTime-1.0.xml`: the entry point. `LibStub\LibStub.lua`, `LibTaxiTime.lua`, `Routes.lua`.
  No TOC: the library is never packaged on its own.
- `LibTaxiTime.lua`: the tracker and the API. **Claims the version** (`MAJOR, MINOR`). Its header
  is the reference for the timing rules and the API.
- `Routes.lua`: **generated**, never edited. The flown length of every flight path in yards,
  `lib.YARDS["from>to"]` (TaxiNodes ids), filled in place. Installs only for its own MINOR, once.
- `Tools/taxi_routes.py`: the generator (standard library only). Reads
  `..\References\Forever\db\forever-taxi{path,pathnode,nodes}-<build>.csv` (wago.tools exports,
  product `wow_classic_beta`) and takes MINOR from `LibTaxiTime.lua`. Boats and zeppelins (stops,
  flags, continent changes) are left out. `--check` compares without writing.
- `Tools/deploy.ps1 -Addon <Name>`: a dev copy into `<AddOns>\<Name>\Libs\LibTaxiTime-1.0`.
- `tests/`: plain Lua 5.1 (`harness.lua` is the client: strict globals, stubs from the dump),
  `pwsh tests\run.ps1` on Windows, CI's `check.yml` on Linux.

## The contract (MINOR 1)

Colon-called (a dot call errors): `lib:AddStore(tbl)`, `lib:Current()`, `lib:Last()`,
`lib:LearnedCount()`, `lib:Forget()`; EventRegistry `"LibTaxiTime.Changed"` `()`. Shapes and
meanings are in `LibTaxiTime.lua`'s header. Store keys the library owns: `routes`
(`[path] = { base, fast, baseAt, fastAt }`, a stamp per kind; a lone `at` from an early copy counts for both) and `current` (`{ route = { keys, names }, at, early }`). `AddStore` after login (`IsLoggedIn()`: a host loaded on demand) resumes a flight in the air at once.
**Within MAJOR 1 the API only grows**: never remove, rename or change the meaning of a function,
field, key, event or source name (`"learned"`, `"route"`, `"estimate"`). GlassPanel's own
`GlassPanel.Flight` (API 1) passes this shape through to GUF.

## Timing facts (offline; confirm in game, then write them to the porting guide)

- **No client duration API.** Time = path length / `SPEED` (30 yd/s). Fitted: InFlight's
  measured Classic times (`..\References\Addons\MapMinimap\InFlightTaxiTimer`, MIT) against
  these lengths give 29.96 yd/s median over 266 direct routes, stdev 0.16; 2-hop routes 0.2 s
  median off; RestedXP's "Forever" table (CC BY-NC-SA: a check only, never shipped) is the same
  data. Multi-hop = the sum of hops.
- **Frequent Flier**: Legacy tree 1188, node 110300 (spell 1225490), 20% faster (InFlight,
  EllesmereUI). `ID ~= 110300` or a secret rank: unknown (an estimate, nothing learned).
- **Lifecycle** (EllesmereUI's on Forever; Codex-reviewed on GlassPanel #125): see the header.
  `UnitOnTaxi` may read false at `PLAYER_CONTROL_LOST`; a landing is control back plus off the
  taxi in either order within `SETTLE` of continuous time off the taxi.
- Unmeasured: all of the above on Forever itself; node ids from `C_TaxiMap.GetAllTaxiNodes`.

## On a new client build (new zones bring new flight paths)

Download `TaxiPath`, `TaxiPathNode` and `TaxiNodes` for the build
(`https://wago.tools/db2/<Table>/csv?build=<build>&product=wow_classic_beta`) into
`..\References\Forever\db\forever-taxi{path,pathnode,nodes}-<build>.csv`, run
`python Tools\taxi_routes.py` (newest build there), and diff `Routes.lua`. A changed `Routes.lua`
is a behaviour change: raise MINOR (in `LibTaxiTime.lua`, then regenerate so `Routes.lua`
follows). Until a path is baked in, a landing learns it.

## Upgrading in place (EMBEDDED-LIBRARIES section 5)

- State lives on `lib` and is reused in place (`lib.x = lib.x or {}`): `stores`, `state`
  (pending, flight, last, ticker, inWorld), `YARDS`, `errors`, `fileMinors`.
- **Installed once, dispatching at call time**: the `TakeTaxiNode` / `TaxiRequestEarlyLanding`
  hooks (`lib.hooked`), the one event frame (`lib.frame`), the ticker and timers all call through
  `lib.impl`. Never capture an impl function in a closure that outlives the load.
- Completion markers: `lib.fileMinors.LibTaxiTime` and `.Routes` on each file's last line;
  `AddStore` errors unless both equal the active MINOR.
- r1 has no predecessor: `tests/test_upgrade.lua` loads a synthetic MINOR 2 over it. From r2 on,
  freeze each release as `tests/fixtures/<File>-rN.lua` and load it under the current copy.

## Toolchain

Lua 5.1 at `C:\Program Files (x86)\Lua\5.1\` (`lua.exe`, `luac.exe`). `pwsh tests\run.ps1`.
**Mutation-test a new test.** Shell edits on Windows: a heredoc may eat a backslash (a `\t` in a
path became a tab once); prefer the Edit tool for text with backslashes.

## Workflow

Issue → branch → PR → review (`/codex-consult`, launched by the owner) → the owner squash-merges.
Never commit to `main`. **Raise MINOR for every behaviour change, in the same PR**, and tag the
merge commit `rN` (`rN` == MINOR); never move or reuse a tag. Consumers bump their pin only in a
release they make anyway.
