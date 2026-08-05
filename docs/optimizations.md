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
- [x] **The bash `sl` was a third writer.** `sl` writes the same
  `~/.cache/sl/state.json`, so a Go-side `flock` coordinated the Go CLI and the
  app but not bash. Taught it the lock rather than retiring the shared path:
  the two implementations agree on the schema field by field and share the
  energy accumulator's semantics, so splitting the directory now would orphan
  existing totals for no gain while the sandbox is still going to end sharing
  later anyway.

  macOS ships no `flock(1)`, and this matters — a `mkdir`- or `shlock`-style
  lock would serialize `sl` against itself and nothing else, which is worse
  than no lock because it looks like coordination. `/usr/bin/lockf` uses
  "BSD-style locking as described in flock(2)" and can lock an inherited
  descriptor, so the lock outlives the helper and spans a shell critical
  section. Verified in both directions with the real binaries against the real
  `.lock`: `sl dash` blocks 2.3 s on a Go-held lock, `dishwatch dash` blocks
  2.1 s on a bash-held one. Missing `lockf` degrades to unlocked, matching
  `lock_other.go`.

  **The bigger find was next to it: `sl` wrote state.json with a truncating
  `>` redirect.** The file is zero bytes from open until `printf` runs, and a
  reader polling against that writer caught it empty on **2980 of 9961 reads**
  — 30%, not a narrow race. Go's `state.Load` reads an empty file as "no prior
  snapshot", which sends `integrateEnergy` down the bootstrap path: seeded with
  a real 14.45 Wh total, one poll landing in that window rewrote it as 5.99 Wh,
  silently and indistinguishably from a reboot. Now temp-plus-rename, measured
  at 0 empty reads in 424815. The `pb` anchor write had the same redirect and
  additionally read `energyWh` outside any lock, which would pin a bank
  percentage to a total that had already moved; both fixed.

  Correcting an overclaim while here: two unlocked polls reading the same
  cursor do **not** double-count. Each writes an absolute total, so the loser's
  contribution is dropped rather than added, and since `energyWh` and
  `lastCurrent` share a file they rewind together into a still-consistent pair
  that the next poll re-integrates back into place. What the lock actually buys
  is skew between state.json and stats.json — which advance separately, are
  printed on one line as "obs 21m 8s @ 22.7 W", and are never reconciled — plus
  the permanent undercount when a rewind lands further back than the ring.
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
- [x] **watch.go reconnect data race.** A background goroutine wrote
  `c`/`dialErr` while the main `select` loop and the render goroutine read
  them. Fixed by making the loop the sole owner: reconnects hand their result
  back over an unbuffered channel, and the render goroutine gets a snapshot of
  the client rather than the variable.

  Two things showed up while reproducing it. First, the loop spawned a dial
  goroutine on *every* failed frame, so a dish that stays down accumulates one
  per second — and the races `-race` actually reported were write/write between
  two of those reconnect goroutines, not between reconnect and render. One dial
  in flight at a time now. Second, a client the reconnect installed could be
  overwritten by the loop's own lazy re-dial with nobody closing it; that lazy
  branch was unreachable anyway (a nil client always routes through `dialErr`
  to the error path) and is gone. The unbuffered channel means a dial that
  finishes after the user quits closes its own client instead of leaking it.

  Verified with a flapping TCP proxy in front of the real dish — 1.2 s up,
  1.2 s down, cutting live connections on the way down — so reconnects succeed
  while a fetch is in flight, which is the interleaving the bug needed. Over
  20 s: old binary 2 data races at `watch.go:124-125`, fixed binary 0.

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
  to wait on the full strict-decode/`schemaVersion` rework.

  **Done.** `ObservedStats` is a struct of non-optional `let`s, which makes the
  synthesised `Decodable` strict; it decodes from the same top-level container
  as `DishData` because the keys are flat, and `decode(from:)` maps any throw
  to `nil`. `sessDropAvg` is deliberately not decoded at all — macos-ui.md
  rules it out of the UI, so no view can reach for it by accident.

  This also brought the first Swift tests into the repo: 11 of them, including
  a golden fixture captured from `dishwatch json` against the live dish (device
  id redacted), which is the cheap half of the Phase 5 contract work — it
  catches a Go JSON tag and a Swift `CodingKey` drifting apart, which
  hand-written fixtures cannot. Both guards were negative-controlled: making
  one field optional (exactly the "resilient like the rest" shape the doc
  originally proposed) fails `testEveryKeyIsRequired` and
  `testOneMissingKeyDropsTheWholeBlock`; dropping the readiness gate fails
  `testBelowReadinessThresholdIsNil`.

  One honest note: the finiteness half of `isPresentable` is currently
  unreachable via JSON, since `JSONDecoder` rejects an out-of-range literal
  first. It is kept for the Phase 3 in-process provider, which will build the
  struct from arithmetic rather than a document, and is commented as such.

  Still open from this item: macos-ui.md's "Files to change" row is fixed, but
  the `CompactWidget` cold-start string is not — define it as `—`, never
  `peak 0` and never a silent fall back to the 60 s mean. That lands with the
  footer UI in Phase 5a.
- [x] **`integrateStats` folds across gaps, which contradicted what the footer
  claimed.** The non-reboot path is `n = cur - st.LastCurrent`, so any gap
  **within** the ring was folded in wholesale while the tooltip read *"Stats
  cover time DishWatch was running. Gaps while quit are excluded."* That was
  false for every gap under 15 minutes — the common case, not an edge case.

  **Resolved in favour of the code; the copy moved.** Folding forward from the
  stored cursor is not a leak in the dedupe, it *is* how observation works: it
  is the only reason a poll every 15 s can describe fifteen seconds of link
  quality rather than the one second we happened to ask on. Roadmap Phase 4
  widens the idle cadence to 5–15 s specifically to save battery, so clamping
  the fold to samples postdating `LastTs` would thin the statistics in exact
  proportion to how cheap we make polling — and would do it silently, since the
  footer would keep the same shape with a fifteenth of the evidence behind it.

  Every folded sample is a second the dish genuinely recorded and we genuinely
  retrieved, which is the whole of what "Observed" claims. The invariant in
  macos-ui.md was rewritten to say that (nothing interpolated, estimated, or
  projected) instead of the narrower "never backfill", and the tooltip now
  states the real envelope: a gap up to the ring is recovered in full, a gap
  wider than the ring contributes nothing at all. That far end stays
  deliberately under-claiming — we drop even the ~15 minutes still sitting in
  the buffer rather than count part of a longer gap. Both halves are pinned by
  `TestIntegrateStatsFoldsGapsInsideRing` and
  `TestIntegrateStatsGapWiderThanRingAddsNothing`.
- [x] **`deviceId` is mislabeled.** It's filled from
  `DeviceInfo.HardwareVersion` — the same source as `hardwareShort` — so the
  popover's "device ID" is really a hardware model string
  (`mini1_panda_prod1`). `internal/dish/status.go` doesn't decode a real device
  id at all. Decode `deviceInfo.id` or rename the field.
- [x] **No `.app` bundle, so nothing about the App Store had been exercised.**
  `app/Makefile` now assembles and signs one. Everything that was live-broken
  is fixed and verified from inside the bundle: launch-at-login threw on every
  toggle without a bundle identifier and the `catch` swallowed it, so the
  switch showed ON having done nothing — it now reverts itself and says why;
  the version string went from a permanent `dev` to `0.1.2 (44)`. The icon is
  generated from the app's own `DishArcGlyph` so it cannot drift from the menu
  bar, and carries no Starlink or SpaceX mark.

  Two findings worth keeping. **A sandboxed bundle cannot run the CLI at all**
  (`binaryNotFound`, even with an absolute `DISHWATCH_BIN`), which promotes the
  in-process engine from optimisation to prerequisite. And **a sandboxed bundle
  *can* reach the dish** — through `NWConnection` and a raw BSD socket alike,
  launched via LaunchServices so the app is its own TCC-responsible process.
  That was the gate the architecture decision was waiting on. See
  [roadmap.md](roadmap.md#gate-result-2026-08-05-reachability-passes-on-both-stacks).

  Also a self-inflicted lesson now fixed in the Makefile: `$(APP_DIR)` was a
  file target, so `make app SANDBOX=0` after `make app` printed `sandbox=0` and
  handed back the *sandboxed* bundle — no prerequisite had changed. That cost
  two wrong conclusions before it was caught. It always reassembles now.
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
