# Roadmap — native macOS app

> Status as of **2026-08-04**: a working SwiftUI menu-bar prototype exists in
> [`app/`](../app) with live data via a `dishwatch json` subprocess bridge. The
> Go core has **not** been split yet, and there is **no `.app` bundle**, so
> nothing about sandboxing, signing, or the App Store has been exercised.
>
> This doc supersedes the original "planned, not started" roadmap, whose phase
> order is now obsolete — the UI got built before the core split.

## Goal

A native **macOS menu-bar app** — signal-colored status glyph with a tooltip
(`19ms · 67↓ Mbps`) and a popover dashboard mirroring `sl dash`. **Mac is
priority #1.** Distribution: **Mac App Store first**, notarized direct build
later. Windows is a distant secondary.

## Where we actually are

| Area | State |
|------|-------|
| SwiftUI UI (6 screens, menu bar, pinned panel, settings) | **done** — builds clean, macOS 14+ |
| `DishProvider` protocol seam | **done** — the swap point for any backend |
| Live data | **bridge only** — shells out to `dishwatch json` |
| `.app` bundle / Info.plist / entitlements / signing | **none** |
| `internal/model` + `internal/service` split | **not started** |
| Sandbox, local-network TCC, `SMAppService` | **never exercised** |
| Tests (Go or Swift) | **none** |

### Measurements (2026-08-04, live dish, darwin/arm64)

These are real numbers, not estimates — they drive the plan below.

| Path | Cost |
|------|------|
| `dishwatch json` subprocess (what the app does today, every 1 s) | **696 ms** cold |
| Go core linked as `c-archive`, called from Swift | **61–91 ms** first call |
| `libdishkit.a` | 29 MB |
| Linked Swift probe binary | 12 MB |

The subprocess path pays process spawn + fresh gRPC dial + server reflection on
every tick. Both alternatives below fix that; the gap between them is much
smaller than the gap from where we are.

**c-archive linking gotcha (verified):** you must link `-lresolv`, or you get
`Undefined symbols: _res_9_ninit / _res_9_nclose / _res_9_nsearch` from Go's
resolver. Also, `dishkit` **must live inside the dishwatch module** — Go's
`internal/` rule forbids an external module from importing
`github.com/faeton/dishwatch/internal/...`.

## Open decision: what backs the App Store build?

Two independent reviews split on this, so it is recorded as **open**, to be
settled by an experiment rather than by argument.

**Option A — Go core in-process via `-buildmode=c-archive`** (the original plan)

- *For:* one implementation of transport, reflection decoding, the energy
  integrator, and bank math. Zero risk of the app and CLI computing different
  Wh. Verified to build, link, and run against the live dish at 61–91 ms.
- *Against:* ships the Go runtime + `protoreflect` + gRPC into an always-on
  menu-bar process. cgo/Swift-concurrency glue needs a dedicated worker queue.
  Dual build system. Harder to debug. Universal (arm64 + x86_64) archives must
  be built per-arch and merged.

**Option B — pure Swift client over a vendored `SpaceX.API.Device` proto**

- *For:* idiomatic sandbox/Network behavior, smaller always-on process, no cgo,
  no Go runtime in the menu bar. Proto vendoring is something we want anyway.
- *Against:* reimplements transport, and ports `integrateEnergy` + bank math to
  a second language — the exact drift risk the original architecture existed to
  avoid. Makes proto vendoring a prerequisite rather than an optional cleanup.

**How we decide — the deciding risk is not cgo, it's TCC.** The thing that
actually threatens this app is whether a *sandboxed, signed* `.app` can reach
`192.168.100.1` at all. Local Network permission has a track record of working
in Terminal and silently failing inside a sandboxed bundle, and that risk
applies to **both** options. So:

1. Build the real `.app` bundle first (Phase 1 below).
2. Inside it, spike Option A — time-boxed to one day. Sandboxed, signed,
   entitled, calling the c-archive against a live dish.
3. If local-network works through cgo → **take Option A**; the code-reuse
   argument wins and there is no reason to rewrite the transport.
4. If it fails in ways that are Go-net-stack-specific → **fall back to Option
   B**, and vendor the proto as that track's first task.

Do not finish Swift features or polish UI before this gate. Do not extract the
Go core "for dishkit" before it either — extract it because the CLI needs it
(it does), which is true under both options.

## Revised phases

| Phase | Work | Gate |
|-------|------|------|
| **0** | Correctness: state transaction lock, energy bootstrap, characterization tests, `StorageDir` param | Ships value to the CLI alone |
| **1** | Real `.app` bundle: Info.plist, entitlements, asset catalog, signing, version, working `SMAppService` | Unblocks *everything* below |
| **2** | **Decision spike** — sandboxed local-network reachability, Option A vs B | **Go/no-go on architecture** |
| **3** | Persistent engine behind `DishProvider`; delete the subprocess | |
| **4** | Adaptive polling, split RPCs, idle cost near zero | |
| **5** | Contract hardening: `schemaVersion`, strict decode, golden fixtures shared by Go and Swift | |
| **6** | Store prep: trademark/disclaimer copy, privacy label, screenshots, 1024 icon, privacy policy URL | |
| **7** | Submission + App Review | |
| **8** | *(optional)* notarized direct build via `cmd/dishwatchd`; Windows tray | |

Phase 0 and Phase 1 are independent and can run in parallel.

## Phase 0 — correctness (do regardless of architecture)

1. **Characterization tests first**, before moving any code: `integrateEnergy`
   (reboot mid-ring, gap > ring, cursor jump, all-zero `powerIn`, first
   observation) and `History.LastN/Latest`. These are pure, error-prone, and
   currently untested. A wrong energy cursor ships silent Wh lies for weeks.
2. **Serialize the whole state transaction, not just the write.** `Save` uses
   temp-plus-rename, which is atomic but not exclusive. The bug is that
   load → integrate → save can interleave between processes, so two readers
   consume the same `lastCurrent` cursor and double-count energy. A lock around
   `Save` alone does not fix this; the read-integrate-write sequence must hold
   the lock. This is live today: the app polls at 1 Hz against the same
   `state.json` the CLI uses.
3. **First-observation energy bootstrap** — a non-reboot first poll sets the
   cursor but integrates zero history; bootstrap with `min(uptime, ringLen,
   cur)` like the reboot path.
4. **Thread `StorageDir`** as a parameter; default `os.UserCacheDir()`. Kills
   the `~/.cache/sl` hardcode. Accept that this ends on-disk state sharing with
   the bash `sl` — under the sandbox it ends anyway.
5. **Extract `internal/model` + `internal/service`** — `Dashboard`,
   `signalScore`, `derivedState`, `integrateEnergy`, bank math. Delete the
   `fillBank`/`pbRenderBank` duplication (~30 lines; don't wait for a grand
   package layout to dedupe it) and the `renderBank` `init()` indirection.
6. **Watch reconnect race** (`watch.go` ~119) — CLI-only pain; fix it here but
   don't let it block the app track.

Metric presentation (which statistic, which window, exact label strings) is
settled separately in [macos-ui.md](macos-ui.md) — the Go side already emits the
data; the Swift views have not been updated yet.

## Phase 1 — the `.app` bundle

Currently `app/Package.swift` declares only an `.executable`. Consequences that
are live, not deferred:

- `SMAppService.mainApp.register()` throws without a bundle identifier, and the
  `catch` swallows it — so **"Launch at login" displays ON and does nothing.**
- `Bundle.main.infoDictionary` is nil → Settings shows "DishWatch dev" forever.
- `UserDefaults.standard` keys off the executable name; every setting resets
  when the app is finally bundled. Plan a migration or accept the reset.
- Nothing can be signed, sandboxed, notarized, or submitted.

Pick one packaging approach (Xcode project, `xcodegen`, or a `make app` target
that assembles the bundle around the SwiftPM binary) and add: bundle identity,
`Info.plist` with `LSUIElement` and `NSLocalNetworkUsageDescription`,
`com.apple.security.app-sandbox` + `com.apple.security.network.client`
entitlements, asset catalog with a 1024 icon, and a version string.

Note: MAS and notarized-direct need **different** entitlement sets. Don't
assume one file serves both.

## Phase 3–4 — the engine and its cost

**The API shape in the old roadmap was wrong.** A one-shot
`PollOnce(ctx, opts) → Dashboard` preserves the dial-and-reflect cost on every
call — it just moves it in-process. A long-lived menu-bar app wants a
long-lived connection:

```
Start(options)      → open one client, own the reconnect loop
LatestSnapshot()    → immutable Dashboard, no I/O
Reboot() / SetAnchor(pct, wh)   → serialized mutations
Stop()
```

Polling cadence, per review: **5–15 s idle, 1–2 s while the popover or pinned
panel is visible**, backing off further on Low Power Mode, screen lock, and lid
sleep. Split the RPCs — the icon needs `get_status` only; `get_history` (the
full ring, the real battery cost once dialing is fixed) only when sparklines,
energy, or bank are actually on screen. Geocode off the hot path, cached.
Don't rewrite `state.json` when the cursor hasn't moved.

Target: idle app is invisible in Activity Monitor's Energy tab.

## Phase 5 — stop the contract from drifting

`internal/model.Dashboard` becomes the single behavioral authority; the CLI's
JSON output and the app's backend are both thin adapters over it, never
parallel builders.

**Fix the resilient decoder — it currently launders drift into fake data.**
`DishData.init(from:)` falls back per-key to the struct's memberwise defaults,
and those defaults are the *design mockup numbers*. Verified: decoding
`{"state":"Connected","pingMs":17.6,"upMbps":0.4}` yields `signalScore=86`,
`downMbps=142.5`, `uptimeHours=7.3` — presented in the UI as live, with the
footer still reading "live". Missing fields must degrade to an explicit
unknown, not to 142.5 Mbps.

Also: add a `schemaVersion`; make genuinely-required fields strict; generate
JSON fixtures from Go and decode them in Swift tests; diff Go JSON tags against
Swift `CodingKeys` in CI. Run the same golden scenarios through both
boundaries — connected, disabled, unreachable/stale, reboot, ring gap, missing
history, anchored battery, stale anchor.

**`deviceId` is mislabeled.** It is filled from `DeviceInfo.HardwareVersion`
(`dashboard.go`), the same source as `hardwareShort` — so the popover's
"device ID" is really a hardware model string (`mini1_panda_prod1`). The
decoder in `internal/dish/status.go` does not decode a real device id at all.
Either decode `deviceInfo.id` or rename the field.

## App Review checklist

- **Trademark (5.2) — highest rejection risk.** Ship as **Dishwatch**, "an
  unofficial monitor for Starlink dishes." No SpaceX/Starlink logo or wordmark
  in the icon. Screenshot and description copy matter as much as strings in the
  binary.
- **Local Network.** `NSLocalNetworkUsageDescription` + `network.client` are
  necessary but **not sufficient** — raw TCP to `192.168.x` triggers TCC, and
  Terminal success does not imply `.app` success. Verify whether
  `NSBonjourServices` is also wanted on the target OS. Budget real time for
  "denied and offline forever" debugging. Handle first-run gracefully: the
  first poll may fail while the permission prompt is pending, so the engine
  needs retry/backoff and a visible permission state.
- **Nominatim / privacy label.** Dish coordinates leaving the device must be
  disclosed as location shared with a third party — the fact that coordinates
  come from the dish rather than CoreLocation avoids the *entitlement*, not the
  *label*. OSM's free endpoint expects an identifying User-Agent, caching, and
  ≤1 req/s, and using it from a Store app is ToS-gray. Safest v1: show
  coordinates only, or use `CLGeocoder`, or omit place names — which also
  removes the need for a privacy-policy URL covering third-party transfer.
- **Reboot.** Already behind a confirmation dialog. Consider shipping v1
  without it — it lowers review anxiety about a destructive action.
- **The reviewer will not have a dish.** The offline/empty state must look
  deliberate, not broken. "No dish found at 192.168.100.1" first-run copy is a
  review-critical surface, not a nicety.
- **Silent sample mode is a release hazard.** Today, failure to locate the CLI
  silently swaps in `SampleProvider` — fine in dev, dangerous shipped. Sample
  data must be explicitly labeled or unreachable in release builds.
- **No shell-outs.** `networkQuality` / `ping` cannot run sandboxed; drop them
  from the app path entirely.
- **No self-update.** MAS handles updates.

## Cut before submission

Dev and demo scaffolding that must not ship: `Views/IconCandidates.swift` (only
reachable from the render harness), `Render.swift` itself, the
`simulateBattery` property, the `DISHWATCH_PROBE` path, and the hardcoded
`~/Sites/dishwatch/bin/dishwatch` lookup in `LiveProvider` — which currently
outranks Homebrew.

## Non-code work (calendar time, not coding time)

App Store Connect record, screenshots, 1024 icon, privacy policy URL, export
compliance answers, and — if Nominatim stays — a policy page describing the
third-party transfer.
