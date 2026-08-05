# Roadmap — native macOS app

> Status as of **2026-08-05**: the SwiftUI menu-bar app in [`app/`](../app) now
> builds a real signed, sandboxed `.app` (`make app`), and the architecture gate
> has been run against a live dish rather than argued about — a sandboxed bundle
> **can** reach `192.168.100.1`, through both candidate network stacks.
>
> The same spike killed the subprocess bridge: sandboxed, the app cannot execute
> the CLI at all. So Phase 3 (in-process engine) moves from optimisation to
> prerequisite, and the `internal/model` + `internal/service` split that feeds it
> is the critical path.
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
| Live data | **bridge only**, and the bridge is dead under the sandbox — see the gate result |
| `.app` bundle / Info.plist / entitlements / signing | **done** — `make app`, ad-hoc signed, sandboxed |
| `internal/model` + `internal/service` split | **not started** |
| Sandbox, local-network TCC, `SMAppService` | **exercised** — reachability passes, login item reachable |
| Tests (Go or Swift) | **Go: energy/stats/ring/store. Swift: 11, incl. a golden fixture** |

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
applies to **both** options.

### Gate result (2026-08-05): reachability passes, on both stacks

Run it yourself: `make app && open -W .build/DishWatch.app --env
DISHWATCH_NETPROBE=~/Library/Containers/com.faeton.dishwatch/Data/netprobe.txt`
(`app/Sources/DishWatch/NetProbe.swift`).

The probe opens the dish port two ways in the same process, under the same
signature, because the two options reach the network through different stacks:
`NWConnection`, which is what Local Network TCC is built around and what a pure
Swift client would use, and a raw `connect(2)`, which is what Go's net package
does inside a `c-archive`. A disagreement between them *would have been* the
decision.

| Configuration | `NWConnection` | BSD socket |
|---|---|---|
| unbundled binary | connected | connected |
| bundle, unsandboxed, LaunchServices | connected | connected |
| **bundle, sandboxed, LaunchServices** | **connected** | **connected** |

Launching via `open` matters and is not a detail: run the bundle's Mach-O from
a shell and Terminal becomes the *responsible process* for TCC, so the app can
inherit a grant Terminal already holds and report a success that predicts
nothing. The probe reports which case it was in, and the table above is the
self-responsible one.

**Two honest caveats.** No Local Network permission prompt appeared, and no
`kTCCServiceLocalNetwork` row exists for the app — but that service lives in
the root-owned system TCC database, so whether a grant was recorded silently or
the prompt simply doesn't fire for unicast TCP to a private address on macOS
26.5.2 is not something this spike can distinguish. Either way the **first-run
prompt path is still unexercised**, so the engine must keep the retry/backoff
and visible permission state the App Review checklist calls for. And this is one
machine on one OS version; it is evidence, not a guarantee.

**So the architecture question is no longer gated on reachability.** Neither
option is blocked, which means the choice falls back to the ordinary trade —
one implementation of the energy integrator versus a smaller always-on process
— rather than to a risk. Option A's code-reuse argument now wins by default,
because the thing that could have vetoed it didn't. Confirming it end to end
still wants the real `c-archive` linked in, since a raw socket is a proxy for
Go's net stack rather than Go's net stack itself.

### What the same spike *did* kill: the subprocess bridge

Sandboxed, the app cannot find or execute the CLI at all — `PROBE ERR
binaryNotFound`, even with `DISHWATCH_BIN` pointing at an absolute path.
Verified as an A/B with only `com.apple.security.app-sandbox` flipped and
everything else — same binary, same hardened runtime, same ad-hoc signature —
held constant.

That promotes Phase 3 from optimisation to prerequisite. Killing the subprocess
was previously justified by the 696 ms poll cost; it is now the only way any
App Store build works at all, under either option. The bridge remains fine for
unsandboxed development and nothing else.

Do not finish Swift features or polish UI before that. Do not extract the Go
core "for dishkit" before it either — extract it because the CLI needs it (it
does), which is true under both options.

## Revised phases

| Phase | Work | Gate |
|-------|------|------|
| ~~**0**~~ | ~~Correctness: state transaction lock, energy bootstrap, characterization tests~~ | **done** |
| ~~**1**~~ | ~~Real `.app` bundle~~ | **done** — `make app` |
| ~~**2**~~ | ~~**Decision spike** — sandboxed local-network reachability~~ | **done — passes on both stacks** |
| **3** | Persistent engine behind `DishProvider`; delete the subprocess | **Now a prerequisite, not an optimisation** — the bridge cannot work sandboxed |
| **4** | Adaptive polling, split RPCs, idle cost near zero | |
| **5** | Contract hardening: `schemaVersion`, strict decode, golden fixtures shared by Go and Swift | Precondition for the `Observed` row below |
| **5a** | Metric presentation per [macos-ui.md](macos-ui.md) — session footer, peaks over means | Needs 5, or a zero-default carve-out |
| **6** | Store prep: trademark/disclaimer copy, privacy label, screenshots, 1024 icon, privacy policy URL | |
| **7** | Submission + App Review | |
| **8** | *(optional)* notarized direct build via `cmd/dishwatchd`; Windows tray | |

Phase 3 is now the critical path: nothing sandboxed works until the subprocess
is gone, so the `internal/model` + `internal/service` extraction that feeds it
is the next real work.

## Phase 0 — correctness (do regardless of architecture)

1. **Characterization tests first**, before moving any code: `integrateEnergy`
   (reboot mid-ring, gap > ring, cursor jump, all-zero `powerIn`, first
   observation) and `History.LastN/Latest`. These are pure, error-prone, and
   currently untested. A wrong energy cursor ships silent Wh lies for weeks.
2. **Serialize the whole of `snapshotAndLog`, not just the writes — and note it
   now covers two files.** Both `state.Save` and `SaveStats` use
   temp-plus-rename, which is atomic but not *exclusive*. The bug is that
   load → integrate → save can interleave between processes, so two readers
   consume the same `lastCurrent` cursor and double-count. A lock around each
   write does not fix this; the read-integrate-write sequence must hold it.
   This is live today: the app polls at 1 Hz against the same files the CLI
   uses.

   The session accumulator makes this sharper. `snapshotAndLog` now runs *two*
   independent transactions per poll (`state.json` via `integrateEnergy`, then
   `stats.json` via `integrateStats`), each with its own cursor. Separate
   cursors correctly prevent desync *within* a process when only one file gets
   written — but across processes with no lock they can still diverge, because
   another poll can land between the two transactions. So the lock belongs
   around `snapshotAndLog` as a whole, not around either accumulator
   individually.
3. **First-observation energy bootstrap** — a non-reboot first poll sets the
   cursor but integrates zero history; bootstrap with `min(uptime, ringLen,
   cur)` like the reboot path. Note this is now also a *consistency* fix, not
   just an undercount: `integrateStats` already bootstraps from the ring on
   first observation, so until `integrateEnergy` matches, the first poll
   computes `obsSeconds` and `energyWhSinceBoot` over different sample sets.
4. **Thread `StorageDir`** as a parameter; default `os.UserCacheDir()`. Kills
   the `~/.cache/sl` hardcode. Accept that this ends on-disk state sharing with
   the bash `sl` — under the sandbox it ends anyway.
5. **Extract `internal/model` + `internal/service`** — `Dashboard`,
   `signalScore`, `derivedState`, `integrateEnergy`, bank math. Delete the
   `fillBank`/`pbRenderBank` duplication (~30 lines; don't wait for a grand
   package layout to dedupe it) and the `renderBank` `init()` indirection.
6. **Watch reconnect race** (`watch.go` ~119) — CLI-only pain; fix it here but
   don't let it block the app track.

### Ordering trap: macos-ui.md must not ship before the decoder fix

Metric presentation — which statistic, which window, exact label strings — is
settled separately in [macos-ui.md](macos-ui.md). The Go side already emits the
data (gated on `Stats.Ready()`, ≥120 samples; **zero is the contract for "not
enough data, hide the footer"**). The Swift views have not been updated yet.

**Implementing that doc as written would make the `Observed` row lie.** It says
to add the `obs*`/`sess*` fields so they "decode resiliently like the rest" —
but "like the rest" means falling back to `DishData`'s memberwise defaults,
which are the *design mockup numbers*. Two things then break at once:

1. The zero-means-hide cue is destroyed — a missing field decodes to a nonzero
   default, so the footer renders.
2. It renders **fabricated session statistics under the word "Observed"**,
   which macos-ui.md explicitly designates as the disclaimer that carries the
   whole honesty claim.

This is not hypothetical version skew: `app/README.md` already warns that a
Homebrew `dishwatch` predating the `json` command won't work, and
`LiveProvider` deliberately prefers a repo dev build over Homebrew *because*
the two drift. An older CLI omitting `sess*` is exactly the expected failure.

Sample data and decode fallbacks are two different jobs that `DishData`
conflates; the session fields are where that becomes dishonest rather than
merely untidy.

**Fix: decode the block atomically and fail closed** — one optional
`ObservedStats?` rather than ten individually-defaulted scalars. Per-field zero
defaults are not enough; they cover the all-absent case but still render
`peak ↓0 · 0 W` when a single key is missing while `obsSeconds` is present.
Absent `obsSeconds`, or `< 120`, or any rendered field missing or wrong-typed →
`nil` → hide the footer. `SampleProvider` builds the block explicitly. Scoped
to one struct, so it does not block on the full Phase 5 rework.

One more thing must be settled before this row ships:

- **`CompactWidget` cold start is unspecified.** Define the not-ready string —
  `—`, never `peak 0`, and never a silent fall back to the 60 s mean.

*(Settled: the ring-fold vs "gaps while quit are excluded" contradiction. The
code was right — folding forward from the cursor is what lets a slow poll
cadence describe the interval between polls, which Phase 4 depends on. The copy
moved. See [macos-ui.md](macos-ui.md#why-the-word-is-observed).)*

## Phase 1 — the `.app` bundle — **done**

`app/Makefile` assembles the bundle around the SwiftPM binary. Not an Xcode
project and not `xcodegen`: the app is one executable target with no
storyboards, build phases or dependencies, so a project file would be hundreds
of lines of generated XML whose only job is to copy three files and run
`codesign`. Revisit if a widget extension or XPC service ever appears.

```
make app                 # build, assemble, ad-hoc sign, sandboxed
make app SANDBOX=0       # the spike's control — one bit changed
make app CODESIGN_ID=... # sign with a real identity
make run                 # build and launch
make icon                # regenerate AppIcon.icns from the app's own glyph
make test                # 11 Swift tests
```

What it produces: `com.faeton.dishwatch`, `LSUIElement`, a real version from
`git describe` (`0.1.2 (44)`, where the build number is the commit count),
`NSLocalNetworkUsageDescription`, sandbox + `network.client` entitlements, a
1024 icon, hardened runtime, and an ad-hoc signature — which is enough to make
the sandbox and TCC real on this machine, though not to distribute.

Everything that was live-broken is fixed and verified from inside the bundle:

- **"Launch at login" no longer lies.** It threw on every toggle without a
  bundle identifier, and the `catch` swallowed it, so the switch showed ON
  having done nothing. It now reverts itself and says why. `SMAppService` is
  reachable from the bundle; it reports `notFound` while the app lives in
  `.build/`, which is expected — login items must register from a stable
  install location. Recheck after the first real install.
- **Version.** `dev` → `0.1.2 (44)`.
- `UserDefaults` moves from the executable name to the bundle id, so dev
  settings reset once. Accepted rather than migrated: the app has never
  shipped, so the only affected defaults are a developer's own.

Two things the icon is not: it is generated from the app's own `DishArcGlyph`
via `make icon`, so icon and menu bar cannot drift, and it carries **no
Starlink or SpaceX mark** — Guideline 5.2 is the highest rejection risk and the
icon is the most conspicuous place to trip it. It is a functional placeholder;
replacing it is a design decision, not a blocker.

MAS and notarized-direct still need **different** entitlement sets — the Store
injects `application-identifier` and `team-identifier`, both requiring a real
team ID, and direct-notarized wants the hardened runtime as a codesign flag.
`Resources/DishWatch.entitlements` is dev/spike only. Don't assume one file
serves all three.

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
reachable from the render harness), `Render.swift` itself (including the
`DISHWATCH_APPICON` mode — `make icon` is a build-time tool, not a runtime
feature), `NetProbe.swift`, the `simulateBattery` property, and the
`DISHWATCH_PROBE` path. The hardcoded `~/Sites/dishwatch/bin/dishwatch` lookup
in `LiveProvider` is already behind `#if DEBUG`, and `LiveProvider` itself goes
away with Phase 3.

## Non-code work (calendar time, not coding time)

App Store Connect record, screenshots, 1024 icon, privacy policy URL, export
compliance answers, and — if Nominatim stays — a policy page describing the
third-party transfer.
