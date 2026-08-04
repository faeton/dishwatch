# Roadmap — native desktop app

> Status: **planned, not started.** This doc captures the agreed architecture and
> phased plan for turning dishwatch into a native menu-bar app. Nothing here is
> implemented yet; the shipping product today is the Go CLI + bash `sl`.

## Goal

A native **macOS menu-bar app** — a signal-colored status dot in the menu bar
with a tooltip (`19ms · 67↓ Mbps`) and a popover dashboard mirroring `sl dash`
(Connection / Signal / Aim / sparklines / Energy + Bank). **Mac is priority #1.**

Distribution: **Mac App Store first, notarized direct/Homebrew-cask build later.**
Windows is a distant secondary (a tray shell over the same core).

## Architecture decision

The Mac App Store requires the **App Sandbox**, which rules out the daemon design
we first considered (no LaunchAgent, no helper binary over a socket, no shared
`~/.cache/sl`). A menu-bar app is already a long-lived process, so we don't need a
separate daemon. The Go core is linked **in-process** as a static library.

```
Dishwatch.app  (sandboxed, SwiftUI MenuBarExtra)
 ├─ SwiftUI UI: signal dot + popover (Swift Charts sparklines)
 └─ libdishkit.a  ← Go core via `go build -buildmode=c-archive`
        wraps internal/{dish,state,geo,model,service}
        exposes C funcs: DishkitPoll(storageDir, addr) → Dashboard JSON, Reboot(), …
```

- One process, one sandbox, no IPC — nothing for App Review to question.
- Launch-at-login via `SMAppService` (macOS 13+, MAS-compatible).
- State lives in the **app container**, not `~/.cache/sl`. Consequence: the
  sandboxed app does **not** share on-disk state with the CLI/bash `sl`.

### Kept daemon-capable

Even though the App Store build is in-process, the core is designed so a future
notarized direct build can run it as a daemon with **no rewrite**. The key is a
single stable `Dashboard` DTO emitted by *both* boundaries:

- now — `DishkitPoll` returns `Dashboard` JSON across the cgo boundary;
- later — `cmd/dishwatchd` emits the same `Dashboard` JSON over a Unix socket.

Both are thin shells over `internal/service`. Design the DTO once, reuse it twice.

## Target package layout

```
internal/
  dish/     keep — gRPC transport + decoders
  state/    keep — storageDir is a PARAM (no hardcoded ~/.cache) + flock
  geo/      keep — async-ify the Reverse call
  model/    NEW — Dashboard DTO (JSON-tagged), SignalScore, derivedState,
                  serviceStatus, energy types. Pure, no io.Writer.
  service/  NEW — Options{StorageDir, DishAddr}
                  PollOnce(ctx, opts) (Dashboard, error)   ← App Store seam
                  Run(ctx, opts, emit func(Dashboard))     ← daemon seam (later)
  ui/       terminal renderer — used by the CLI, discarded by the app
dishkit/    NEW — cgo //export wrappers, built `-buildmode=c-archive`
cmd/
  sl/         thin CLI: service + the existing ui/ ANSI renderer
  dishwatchd/ later, direct build only: service.Run + socket
```

`internal/ui` (terminal ANSI/sparklines/two-column layout, `EOLPadWriter`) is the
only thing the app discards — the *data model* behind it ports; the *layout
engine* does not.

## App Review checklist (macOS App Store)

- **Local Network** — talking to `192.168.100.1` triggers the local-network
  prompt; declare `NSLocalNetworkUsageDescription` + the
  `com.apple.security.network.client` entitlement.
- **Trademark (Guideline 5.2)** — do not name it "Starlink…" or imply official
  SpaceX affiliation. Ship as **Dishwatch**, "an unofficial monitor for Starlink
  dishes," with a disclaimer. Common rejection cause.
- **`reboot` command** — gate behind a deliberate confirm dialog, not a stray
  button.
- **Privacy nutrition label** — disclose that dish coordinates are sent to
  OpenStreetMap/Nominatim for reverse-geocoding. (Location comes from the dish,
  not CoreLocation, so no location entitlement / prompt.)
- **No private APIs / no self-update** — MAS handles updates; strip any
  Sparkle-style update notions.
- **Drop shell-outs** — `networkQuality`/`ping` won't run sandboxed; do RTT
  in-process (`net.DialTimeout` timing) or omit the speed feature in the app.

## Phases

| Phase | Work | Notes |
|-------|------|-------|
| **0** | Extract `internal/model` + `internal/service`; thread `StorageDir`; fix watch race + state flock + energy bootstrap; add tests; `dishkit` c-archive skeleton | Framework-agnostic. Improves the CLI on its own. See [optimizations.md](optimizations.md). |
| **1** | SwiftUI `MenuBarExtra` + popover reading `DishkitPoll`; signal dot; sparklines via Swift Charts | |
| **2** | `SMAppService` login item; App Sandbox + entitlements; trademark/disclaimer; privacy labels | |
| **3** | App Store submission, signing, App Review | |
| **4** | (optional) Vendor the SpaceX proto, drop reflection | Maintainability win. |
| **5** | (optional) Notarized direct build / Homebrew cask via `cmd/dishwatchd` + socket | Reuses the core unchanged. |
| **6** | (optional) Windows tray shell over the same daemon | |

## Phase 0 task order

1. Characterization tests for `integrateEnergy` + `History.LastN/Latest` —
   capture current behavior *before* moving code.
2. `internal/model` — move `signalScore`/`derivedState`/`serviceStatus` + energy
   structs; define the `Dashboard` DTO.
3. `internal/service` — `PollOnce` (absorbs `fetchDash` + `snapshotAndLog` +
   `integrateEnergy`); `Options` with `StorageDir`.
4. Thread `StorageDir` through `state`/`geo` (kill the `CacheDir` hardcode); CLI
   defaults to `os.UserCacheDir()`.
5. Bug fixes: watch.go race → channel-fed reconnect; `state` flock;
   first-observation energy bootstrap.
6. Rewire `cmd/sl` onto `service`; delete the `renderBank` `init()` indirection.
7. `dishkit` skeleton — one `//export DishkitPoll` returning `Dashboard` JSON;
   confirm `c-archive` builds on darwin/arm64. De-risks the app path early.

Steps 1–6 ship value to the CLI on their own (faster, race-free, no energy
double-count). Step 7 proves the App Store seam before any Swift is written.
