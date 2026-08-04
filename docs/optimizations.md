# Optimizations & known issues

> Working backlog. Original findings from a code review on 2026-06-25; revised
> **2026-08-04** after the macOS app landed and two independent reviews (Codex,
> Grok). Items are grouped by whether they block the app, the CLI, or both.
> Measurements are live-dish numbers on darwin/arm64, not estimates.

## Correctness — fix regardless of architecture

- [ ] **The state transaction is not serialized.** `state.Save` uses
  temp-plus-rename, which is atomic but not *exclusive*. The real bug is that
  load → integrate → save can interleave across processes, so two readers
  consume the same `lastCurrent` cursor and **double-count energy**. Locking
  only the write does not fix it — the whole sequence must hold the lock.
  **This is live now**, not hypothetical: the app polls `dishwatch json` at 1 Hz
  against the same `~/.cache/sl/state.json` the CLI uses, so running `sl watch`
  with the app open is enough to corrupt the energy total.
- [ ] **First-observation energy undercount** in `dash.go integrateEnergy`. A
  non-reboot first poll sets the cursor but integrates zero history; bootstrap
  with `min(uptime, ringLen, cur)` like the reboot path does.
- [ ] **No tests anywhere.** `integrateEnergy` and `History.LastN/Latest` are
  pure and the most error-prone code in the repo. A wrong cursor ships silent
  Wh lies for weeks with nothing to catch it. Table tests (reboot mid-ring,
  gap > ring, cursor jump, all-zero `powerIn`, first observation) go in
  **before** any extraction — they're what makes the refactor safe.
- [ ] **watch.go reconnect data race** (~line 119). A background goroutine
  writes `c`/`dialErr` while the main `select` loop reads them; `-race`
  confirms. Fix with a channel-fed reconnect or a mutex. CLI-only — don't let
  it block the app track.

## Contract integrity (app ↔ CLI)

- [ ] **The Swift decoder launders drift into fake data.** `DishData.init(from:)`
  falls back per-key to the struct's memberwise defaults — and those defaults
  are the *design mockup numbers*. Verified: decoding
  `{"state":"Connected","pingMs":17.6,"upMbps":0.4}` produces
  `signalScore=86`, `downMbps=142.5`, `uptimeHours=7.3`, `bankPct=78` — shown
  in the UI as live data with the footer still reading "live". Missing fields
  must degrade to an explicit unknown. Resilient decoding was meant to survive
  firmware changes; as written it hides them.
- [ ] **`deviceId` is mislabeled.** It's filled from
  `DeviceInfo.HardwareVersion` — the same source as `hardwareShort` — so the
  popover's "device ID" is really a hardware model string
  (`mini1_panda_prod1`). `internal/dish/status.go` doesn't decode a real device
  id at all. Decode `deviceInfo.id` or rename the field.
- [ ] **No `schemaVersion`, and the DTO is hand-duplicated** between
  `dashboard.go` and `DishData.swift`. Add a version field, generate JSON
  fixtures from Go and decode them in Swift tests, and diff Go JSON tags
  against Swift `CodingKeys` in CI.
- [ ] **`fillBank` duplicates `pb.go`'s anchor branch** — and says so in a
  comment. ~30 lines; extract the pure functions now rather than waiting on a
  package reorganization.

## Performance

Measured cost of one dashboard snapshot:

| Path | Cost |
|------|------|
| `dishwatch json` subprocess (what the app does today, every 1 s) | **696 ms** cold |
| Go core as `c-archive` called from Swift | **61–91 ms** first call |
| `sl dash` (for reference) | ~210 ms |

- [ ] **Connection reuse is the actual performance problem** — not the poll
  interval, and not which language hosts the client. The 696 ms is dominated by
  process spawn + fresh gRPC dial + server reflection. Fix connection lifetime
  first; a warm client makes 1 s vs 2 s a non-question.
- [ ] **A one-shot `PollOnce` API would preserve the bug.** Whatever backs the
  app must own a long-lived client and reconnect loop, publishing immutable
  snapshots (`Start` / `LatestSnapshot` / `Stop`), not dial per call.
- [ ] **Polling is not adaptive.** Fixed 1 s regardless of whether the popover
  is open or the display is asleep. Should be 5–15 s idle, 1–2 s while the
  popover or pinned panel is visible, backing off further on Low Power Mode,
  screen lock, and lid sleep.
- [ ] **`get_history` is fetched every tick.** The full ring is the dominant
  battery and CPU cost once dialing is fixed. The menu-bar icon needs
  `get_status` only; fetch history only when sparklines, energy, or bank are on
  screen.
- [ ] **`state.json` is rewritten every poll** even when the cursor hasn't
  moved. Skip the write when nothing changed.
- [ ] **`geo.Reverse` blocks the render path** (`dash.go` ~368). Nominatim can
  take 3 s and stalls the watch spinner. Geocode async, cached, off the hot
  path; show coordinates until the label arrives. Location should be fetched
  once per process / on bootcount change — never per tick.
- [ ] **`renderEnergy` re-reads `state.json`** that `snapshotAndLog` just wrote
  — pass the snapshot through.
- [ ] **`grpc.DialContext` + `WithBlock` are deprecated** → `grpc.NewClient`
  with a 200–500 ms LAN timeout. `grpcreflect` client is never closed (minor
  leak in watch mode).
- [ ] **Vendor the `SpaceX.API.Device` proto.** Drops reflection and the
  `protojson` → `json` double-hop in `client.go Call()`. Optional if the app
  stays on the Go core; **a prerequisite** if the app goes pure Swift. Keep the
  "decode only rendered fields / ignore unknowns" discipline — firmware updates
  add and rename fields.

## Swift app

- [ ] **Blocking I/O inside `async`.** `LiveProvider.run` does
  `readDataToEndOfFile()` + `waitUntilExit()` synchronously, tying up a
  cooperative-pool thread for ~700 ms per poll. No timeout — a hung dish leaks
  processes. Cancellation can't interrupt it, so changing the refresh interval
  mid-poll briefly runs two `dishwatch json` processes, both writing state.
- [ ] **Hardcoded developer path.** `~/Sites/dishwatch/bin/dishwatch` is in
  shipped code and ranked *above* Homebrew. The `/bin/zsh -lc` fallback spawns
  a login shell per lookup.
- [ ] **Silent sample mode.** Failure to locate the CLI swaps in
  `SampleProvider` with no visible signal — fine in dev, dangerous shipped.
- [ ] **Dead battery workflow.** `BatterySetupSheet`'s "Start tracking" only
  calls `dismiss()`; "Calibrate" has no action at all. The primary interaction
  of the battery feature does nothing.
- [ ] **Strict concurrency is off** (`swiftLanguageModes: [.v5]` on Swift 6
  tools), with two `@unchecked Sendable` classes covering for it. Turning it on
  now is far cheaper than after the backend swap.
- [ ] **Continuous re-render.** The header clock formats `.second()`, so that
  view invalidates every second independent of polling; `MenuBarLabel` re-runs
  `ImageRenderer` on every data change. Measure in Instruments before shipping
  something that runs 24/7.
- [ ] **No Swift tests.** `DishData` decoding, `bankTimeLeftText`, and the
  state→color mapping are pure and trivially testable.

## Cross-platform

- [ ] **Cache dir** — `~/.cache/sl` is hardcoded; `os.UserCacheDir()` is correct
  everywhere. This ends on-disk state sharing with the bash `sl` on macOS —
  acceptable, and unavoidable once the app is sandboxed into its own container.
  **Stop designing as if the app and CLI cohere**: under MAS they cannot.
- [ ] **Speed test** — `networkQuality` is macOS-only, `ping -W` differs across
  BSD/GNU/Windows, and neither runs sandboxed. Abstract behind an
  `internal/speed` interface; do LAN RTT in Go, or drop it from the app path.

## Build notes (verified 2026-08-04)

- `-buildmode=c-archive` builds cleanly with the full gRPC + reflection
  dependency tree: 29 MB `.a`, 12 MB linked Swift binary.
- **Linking requires `-lresolv`**, or you get `Undefined symbols:
  _res_9_ninit / _res_9_nclose / _res_9_nsearch` from Go's resolver.
- `dishkit` **must live inside the dishwatch module** — Go's `internal/` rule
  forbids an external module from importing
  `github.com/faeton/dishwatch/internal/...`. The repo-root `dishkit/`
  placement in the roadmap is required, not stylistic.
