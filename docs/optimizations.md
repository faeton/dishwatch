# Optimizations & known issues

> Working backlog. Original findings from a code review on 2026-06-25; revised
> **2026-08-04** after the macOS app landed and two independent reviews (Codex,
> Grok). Items are grouped by whether they block the app, the CLI, or both.
> Measurements are live-dish numbers on darwin/arm64, not estimates.

## Correctness — fix regardless of architecture

- [x] **The state transaction is not serialized — and it now spans two files.**
  Both `state.Save` and `SaveStats` use temp-plus-rename, which is atomic but
  not *exclusive*. The real bug is that load → integrate → save can interleave
  across processes, so two readers consume the same `lastCurrent` cursor and
  **double-count**. Locking only the writes does not fix it — the whole
  sequence must hold the lock. **This is live now**, not hypothetical: the app
  polls `dishwatch json` at 1 Hz against the same files the CLI uses, so
  running `sl watch` with the app open is enough to corrupt the totals.

  `snapshotAndLog` now performs **two** independent read-integrate-write
  transactions per poll — `state.json` via `integrateEnergy`, then `stats.json`
  via `integrateStats` — each with its own cursor. Independent cursors are the
  right design for crash-safety *within* a process (either file can be written
  without desyncing the other), but across processes they can still diverge,
  because a competing poll can land in the window between the two. The lock
  belongs around `snapshotAndLog` as a unit.
- [x] **First-observation energy undercount** in `dash.go integrateEnergy` —
  narrower than previously described here. `prev == nil` *does* bootstrap (it
  is folded into `reboot`). The actual hole is the final `else` branch: a
  **same-boot snapshot that exists but carries `LastCurrent == 0`** advances
  the cursor and integrates zero joules. That is reachable from a `state.json`
  written by the bash `sl`, or by a Go build predating the energy accumulator.
  Bootstrap it with `min(uptime, ringLen, cur)` like the reboot path.

  It is now a **consistency** bug as well: `integrateStats` bootstraps from the
  ring whenever `Samples == 0`, so in that path session stats fold in ring
  history the energy accumulator skips, and the two cover different sample
  windows. Note the obvious cross-check does **not** work even when they agree:
  `sessPowerAvg` excludes zero-power samples (`PowerSum/PowerCount`) while
  `obsSeconds` counts every sample, so `sessPowerAvg × obsSeconds / 3600` is by
  design not equal to `energyWhSinceBoot`. Don't use it as a test oracle —
  assert the shared bootstrap rule directly instead. Add tests for **both**
  `prev == nil` and existing-snapshot-with-zero-cursor; they are different
  paths and were previously lumped under one "first observation" label.
- [x] **Atomic-rename writes collide under concurrency.** Every writer uses a
  fixed temp name — `p + ".tmp"` in `state.Save` (store.go:108), the events log
  (store.go:287), and `SaveStats` (stats.go). Two processes writing the same
  file at once therefore interleave into the *same* temp path before renaming,
  so "atomic" holds only for a single writer. Use a unique temp name
  (`os.CreateTemp` in the target dir) as well as the transaction lock. All save
  errors are also silently discarded (`_ = state.Save(...)`).
- [ ] **The bash `sl` is a third writer.** `sl` (still in the repo, 41 KB)
  writes the same `~/.cache/sl/state.json` with no lock, so a Go-side `flock`
  coordinates the Go CLI and the app but not bash. Either teach `sl` the lock
  or retire the shared path — the `StorageDir`/`UserCacheDir` move does the
  latter by default.
- [x] **The read side needs the lock too.** `buildDashboard` calls `LoadStats`
  and `state.Load` as two separate reads, so a poll landing between them
  produces a DTO mixing generation N stats with generation N−1 energy. Either
  share the lock on read, or have the transaction hand both snapshots back
  directly (which also fixes `renderEnergy` re-reading what was just written).
- [x] **No tests anywhere.** `integrateEnergy` and `History.LastN/Latest` are
  pure and the most error-prone code in the repo. A wrong cursor ships silent
  Wh lies for weeks with nothing to catch it. Table tests (reboot mid-ring,
  gap > ring, cursor jump, all-zero `powerIn`, first observation) go in
  **before** any extraction — they're what makes the refactor safe.
- [ ] **watch.go reconnect data race** (~line 119). A background goroutine
  writes `c`/`dialErr` while the main `select` loop reads them; `-race`
  confirms. Fix with a channel-fed reconnect or a mutex. CLI-only — don't let
  it block the app track.

## Contract integrity (app ↔ CLI)

- [x] **The Swift decoder launders drift into fake data.** `DishData.init(from:)`
  fell back per-key to the struct's memberwise defaults — and those defaults
  were the *design mockup numbers*. Decoding
  `{"state":"Connected","pingMs":17.6,"upMbps":0.4}` produced
  `signalScore=86`, `downMbps=142.5`, `uptimeHours=7.3`, `bankPct=78` — shown
  in the UI as live data with the footer still reading "live".

  **Fixed:** the memberwise defaults are now neutral (0 / `""` / `.offline`),
  and the mockup figures moved to `DishData.sample`, which only
  `SampleProvider` and the render harness construct. Sample data and decode
  fallbacks are now separate jobs.

- [ ] **The session block still needs atomic decoding** when the footer is
  built. Neutral defaults fix the all-absent case, but not a partial payload:
  one missing or mistyped `sess*` key while `obsSeconds` is present would
  render `peak ↓0 · 0 W` rather than hiding the row.

  **This blocks [macos-ui.md](macos-ui.md).** That doc's session footer relies
  on zero meaning "fewer than 120 samples — hide the row", and instructs that
  the new `obs*`/`sess*` fields decode "resiliently like the rest". Those two
  cannot both hold: inheriting mockup defaults means a CLI that omits the
  fields renders invented statistics under the label `Observed`, the word the
  doc designates as its honesty claim. Version skew here is expected, not
  theoretical — `LiveProvider` prefers a repo dev build over Homebrew precisely
  because the CLI and app drift. `DishData` currently conflates "sample data"
  with "decode fallback"; the session fields are where that stops being untidy
  and starts being dishonest.

  **Fix: decode the block atomically, fail closed** — a single optional
  `ObservedStats?`, not ten individually-defaulted scalars. Zero defaults per
  field are *not* enough: they handle the all-absent case but still render
  `peak ↓0 · 0 W` if one key is missing or mistyped while `obsSeconds` is
  present. Rule: absent `obsSeconds`, or `< 120`, or any rendered field missing
  or wrong-typed → `nil` → hide the whole footer. `SampleProvider` constructs
  the block explicitly. This is scoped to one struct, so it does **not** have
  to wait on the full strict-decode/`schemaVersion` rework. Also fix
  macos-ui.md's "Files to change" row so it stops saying "like the rest", and
  define the `CompactWidget` cold-start string — `—`, never `peak 0` and never
  a silent fall back to the 60 s mean.
- [ ] **`integrateStats` backfills across gaps, which contradicts what the
  footer claims.** [macos-ui.md](macos-ui.md) lists two invariants that "must
  hold or the word becomes a lie", the second being *"never backfill the dish's
  15-minute ring into the session figures beyond the initial bootstrap."* The
  non-reboot path does exactly that: `n = cur - st.LastCurrent`, and any gap
  **within** the ring is folded in wholesale. Only gaps larger than the ring
  are dropped (`n > ringLen → n = 0`). So quitting DishWatch for ten minutes
  and reopening silently counts ~600 unobserved samples as observed — while the
  footer tooltip reads *"Stats cover time DishWatch was running. Gaps while
  quit are excluded."* That is false for every gap under 15 minutes, which is
  the common case, not an edge case.

  Decide which way to resolve it before shipping the row: either clamp the
  non-reboot fold to samples that postdate `LastTs` (behavior matches the
  claim), or rewrite the copy to admit that up to 15 minutes of dish-recorded
  history is included (claim matches behavior). The current pairing is the one
  combination that isn't defensible, and it undercuts the whole reason the word
  "Observed" was chosen over "Session".
- [x] **`deviceId` is mislabeled.** It's filled from
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
- [x] **Hardcoded developer path.** `~/Sites/dishwatch/bin/dishwatch` is in
  shipped code and ranked *above* Homebrew. The `/bin/zsh -lc` fallback spawns
  a login shell per lookup.
- [x] **Silent sample mode.** Failure to locate the CLI swaps in
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
