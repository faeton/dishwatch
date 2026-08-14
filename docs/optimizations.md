# Optimizations & known issues

> Working backlog. Original findings from a code review on 2026-06-25; revised
> **2026-08-04** after the macOS app landed and two independent reviews (Codex,
> Grok). Revised again **2026-08-14** after a seven-reviewer sweep (five scoped
> passes plus Codex and Grok) — see [Round 3](#round-3--2026-08-14). Items are
> grouped by whether they block the app, the CLI, or both. Measurements are
> live-dish numbers on darwin/arm64, not estimates.

## Round 3 — 2026-08-14

> Seven reviewers over the whole tree: five scoped passes (Go state/accumulators,
> Go CLI + helper IPC, Swift model, Swift views, docs/build), plus Codex and Grok
> independently. Three of them found the `ok`-with-no-data defect without seeing
> each other's work, which is the strongest signal in this round.
>
> Build health is green and worth saying plainly: `go vet`, `go build`, `gofmt`,
> `go test ./...`, `swift build` and `swift test` (11 tests) all pass clean, and
> `git ls-files` is 70 files with no build artifacts committed. The 529 MB tree
> is entirely untracked local scratch. **Nothing below is a build failure — the
> failures are all in what the passing build does.**

### Ship blockers

- [x] **`make app` ships a debug build, which un-does every `#if DEBUG` guard in
  the repo.** `app/Makefile:19` sets `CONFIG := debug` and line 57 builds
  `swift build -c $(CONFIG)`. There are exactly three `#if DEBUG` blocks in
  `app/Sources`, and all three are things written specifically to be excluded
  from a shipped app. The worst is `HelperProvider.swift:246-254`, whose own
  comment reads *"Never compiled into a release build — a shipped app that went
  looking through $PATH could run an unknown binary."* It is compiled in:
  `DISHWATCH_BIN=<path>` makes the signed, sandboxed bundle exec an arbitrary
  binary as its helper, and `~/Sites/dishwatch/bin/dishwatch` is still probed.
  Also live: the "Simulate battery (demo)" toggle (`SettingsView.swift:35`) and
  `LiveProvider`'s `#if DEBUG` path. Set `CONFIG := release` — but note `make
  icon` depends on `DISHWATCH_APPICON`, so that target must keep an explicit
  debug build.
- [x] **The dev scaffolding in `DishWatchApp.swift:34-58` is not guarded at
  all**, so it ships regardless of configuration. `Render.runIfRequested()`
  (pulling in all of `IconCandidates.swift`), `NetProbe.runIfRequested()` —
  which opens raw BSD sockets and **writes to a file path taken from an
  environment variable** — and `DISHWATCH_PROBE`, which spawns a *second*
  `HelperProvider` alongside the app's own, giving two helpers contending the
  same flock. The roadmap already lists these as "cut before submission"; they
  need `#if DEBUG` or a separate target, not just a note.
- [x] **The embedded helper is the entire CLI.** `app/Makefile:65` copies
  `bin/dishwatch` to `Contents/MacOS/dishwatch-helper`. That binary still
  carries `speed` (which `exec`s `ping` and `networkQuality`, `misc.go:124,137`
  — shell-outs that cannot run sandboxed and that the review checklist says to
  drop), `raw` (arbitrary gRPC to any address), `dash`/`location` (the Nominatim
  geocoder), and a *"Starlink speed test"* banner string. The app uses exactly
  four ops. Build the shipped helper from a `cmd/dishwatch-helper` main, or
  behind a build tag that omits `geo`, `speed`, `raw`, `dash` and `watch`. Until
  then `Info.plist`'s "nothing is sent anywhere else" is a claim the binary
  contradicts.
- [x] **No `PrivacyInfo.xcprivacy`.** The app uses `UserDefaults`
  (`AppState.swift:16-37`), which is a required-reason API — Apple has wanted a
  declared reason (`CA92.1` for app-local defaults) since 2024. `app/Makefile:59-67`
  copies only `AppIcon.icns` and `Info.plist` into the bundle. This is the kind
  of thing that fails automated validation at upload, before a human sees it.
  Also add `ITSAppUsesNonExemptEncryption=false` to skip the per-build prompt.

### The helper contract — one bug, several faces

- [x] **`ok` with no `data` is treated as helper death, so a successful reboot
  reboots the dish twice and silently kills the helper.** Found independently by
  three reviewers and reproduced. `helper.go:161-185` answers `reboot`,
  `setAnchor` and `ping` with `{"ok":true}` and no `data`, which is correct.
  `HelperProvider.swift:169` requires data on every reply:
  `guard let data = resp.data else { throw .badResponse("ok with no data") }`.
  So every non-`poll` op throws. `requestLocked` (`:127-136`) reads that as a
  dead pipe: it increments `consecutiveFailures`, calls `shutdown()` — killing a
  healthy child — then retries, which spawns a **new** helper (fresh dial + full
  reflection download, the ~700 ms this architecture exists to avoid) and
  **sends `{"reboot":{}}` a second time**. The second throw reaches
  `_ = try? await request(...)` (`:96`) and is swallowed, so `AppState.reboot`'s
  `catch` (`AppState.swift:115`) is dead code and the user is told nothing after
  confirming a destructive action.

  `ping` is the sharpest version: its stated purpose is liveness, and calling it
  *kills the thing it is checking*. Fix by decoding command acknowledgements
  separately from poll responses — and never auto-retry a non-idempotent op.
- [x] **`withClient` retries non-idempotent operations.** `helper.go:220-244`
  wraps every op in redial-and-retry, including `{"reboot":{}}` (`:164-167`). A
  reboot the dish acks and then drops — the normal case, since it is going down —
  takes the retry path. Combined with the item above, one click can send four.
- [x] **Every `poll` failure is reported as success.** `helper.go:207-213`
  discards the error and returns `offlineDashboard(addr)` with `ok:true`.
  Defensible for an unreachable dish; the problem is that the branch also
  catches `decode status`, `decode envelope`, `reflect ... not found` and
  `service not found in reflected file`. Firmware that renames a field or drops
  the reflection service therefore reads as "Offline" forever, on a dish that
  is up and pingable, with the real error going to stderr — which the supervisor
  routes to `FileHandle.nullDevice` (`HelperProvider.swift:189`). There is no
  path by which anyone learns what broke. Distinguish `dish.ErrUnreachable`
  (→ offline dashboard) from every other error class (→ `resp.Error`).
- [x] **Offline is presented as live.** Because the poll "succeeds",
  `AppState.refresh` clears `lastError` (`:95`) and `ConnectedPopover.swift:173`
  prints `live`. So a reviewer with no dish sees a hero reading **Offline** next
  to a footer reading **live**, over metrics that `offlineDashboard`
  (`dashboard.go:113-123`) filled from a persisted snapshot of arbitrary age —
  hour-old `up 5.8 h · boots 139` and an hour-old ping, unmarked. That is the
  first screen App Review will see. Derive the footer from transport success
  **and** `DishData.state`, and add a real permission-denied state.
- [x] **No deadline anywhere on the app side, so a wedge is permanent.**
  `BufferedLineReader.readLine()` (`HelperProvider.swift:271-282`) blocks on
  `availableData` with no timeout, and `withCheckedThrowingContinuation` is not
  cancellable — so `pollTask?.cancel()` cannot free it and every later poll
  queues behind it on the serial queue, leaking a suspended Task each time. The
  Go side is only partly bounded: dial is 2 s and calls are 4 s
  (`internal/dish/client.go:36-37`), but **reflection discovery is not** —
  `client.go:67` passes the raw parent `ctx`, not `dialCtx`, to
  `grpcreflect.NewClientAuto` + `FileContainingSymbol`. And `state.Begin()` →
  `syscall.Flock(fd, LOCK_EX)` (`lock_unix.go:18`) has no `LOCK_NB`, no timeout
  and no ctx. A dish that accepts TCP and stalls the reflection stream hangs the
  helper at startup, before its banner — so the app sits on "Connecting…"
  forever. Even without a hang, one poll's worst case is ~14-16 s
  (2 dial + 4 fetch + 2 redial + 4 retry + 4 unused `GetLocation`), during which
  the poll loop is blocked and stale data reads as live.
- [x] **The claimed restart backoff does not exist.** `HelperProvider.swift:18-20`
  says the child is "restarted with bounded backoff if it dies". There is no
  backoff in the file. `consecutiveFailures` gates only the in-request second
  try; past the threshold `send()` still calls `ensureRunning()`, which spawns a
  fresh child. A helper that fails its banner check every time therefore forks
  once per poll — at the default 1 s interval, forever — each paying the 2 s
  `usleep` spin in `shutdown()` (`:226-229`). It also only resets on a
  *first-try* success (`:125`), never after a recovered retry.
- [x] **`Process.terminate()` cannot kill this helper.** Reproduced.
  `main.go:41` registers SIGTERM with `signal.NotifyContext` for every
  subcommand, which removes the default terminating disposition; `runHelper`
  only observes `ctx.Err()` at `helper.go:133`, *after* `sc.Scan()` returns a
  line. A helper parked in `Scan` or mid-request never sees the signal. The
  supervisor waits 2 s, sets `process = nil`, and the next poll starts a second
  helper — two processes on the same `state.json` until the first notices EOF.
  The flock keeps that from corrupting, but it is not the intended lifecycle.
- [x] **Smaller protocol defects, all reproduced.** A malformed request is
  answered without echoing the id (`helper.go:130`), so the Go side's
  deliberate fail-soft becomes a fail-hard on the client, which sees `id:0`,
  fails its `resp.id == id` guard (`HelperProvider.swift:163`) and tears the
  helper down. A line over 1 MB kills the scanner permanently (`helper.go:117-120`)
  — `bufio.Scanner` cannot resync, so the "cap allocation" guard is a kill
  switch — and `err != io.EOF` at `:138` is dead, since `Scanner.Err()` never
  returns `io.EOF`. There is **no `recover()` anywhere in the repo** (verified:
  zero occurrences), so any panic under `buildDashboard` takes the process down
  mid-reply; a per-request `defer recover()` turns that into one failed request.
- [x] **`deinit { queue.sync { shutdown() } }` (`HelperProvider.swift:87`) can
  self-deadlock.** The request closure at `:112` captures `self` strongly and is
  released on `queue`; if that is the last reference, `deinit` runs *on* the
  queue and `queue.sync` deadlocks. Needs a teardown that cannot re-enter.

### Wrong numbers shipped today

- [x] **`renderEnergy` divides observed-only energy by wall-clock time.**
  `dash.go:574`: `avgW := snap.EnergyWh * 3600 / obsDur` where
  `obsDur = now - snap.ObsStartTs`. But `EnergyWh` accumulates only *observed*
  samples, and the gap-wider-than-the-ring branch (`dash.go:154-157`) advances
  the cursor **without** advancing `ObsStartTs`. `Stats` avoids exactly this by
  using `Samples` as its denominator (`stats.go:149-152`); energy has no sample
  counter.

  Worked example: dish boots, CLI runs 10 min at 20 W (`energyWh ≈ 3.33`), user
  quits for 9 h, reopens. `obsDur ≈ 9h10m` → `avgW ≈ 0.36 W` for a 20 W dish.
  And because `obsDur` has grown to ≈ uptime, the `obsDur*100 >= UptimeS*95`
  gate at `:579` selects the **confident** "since boot" phrasing — the longer
  you are away, the more authoritative the wrong number looks. The same `avgW`
  is passed to `renderBank` (`:586`) and mirrored in `fillBank`
  (`dashboard.go:227-229`), so power-bank time-to-empty inflates by the same
  ~50× factor. This is the most damaging number in the product's headline use
  case. `estWh` (`:575`) is wrong for the same reason. Give energy its own
  observed-sample counter.
- [x] **The zero-cursor bootstrap adds where the reboot path assigns.**
  `dash.go:177` is `energyWh += joules / 3600`, inside the branch whose own
  comment (`:158-165`) says it bootstraps "exactly as the reboot path does" —
  and the reboot path *assigns* (`:138`). `energyWh` was seeded from
  `prev.EnergyWh`, so a legacy `state.json` carrying a total but no cursor gets
  the ring folded on top of it. Probed: `prev{EnergyWh: 14.45, LastCurrent: 0}`
  + a full 900-sample ring at 20 W → **19.45 Wh**, a 5 Wh phantom. The existing
  test (`energy_test.go:112`) uses `prev.EnergyWh == 0`, where `+=` and `=` are
  indistinguishable — which is why this survived the round that added the branch.
- [x] **A negative cursor delta freezes energy but re-counts stats.** Probed.
  `dash.go:145-157` has no `delta < 0` branch, so neither sub-branch fires,
  `lastCur` is never updated, and no energy accrues until the dish's cursor
  climbs back past the stale value. `sessionstats.go:72-74` does the opposite —
  clamps `n` to 0 but still assigns `st.LastCurrent = cur` (`:89`) — so the next
  poll re-folds samples it already counted. Actual: `prev{EnergyWh:30,
  LastCurrent:5000}` + `cur=100` → energy frozen at 30 with cursor stuck at
  5000, while stats jump their cursor to 100. The two files then describe
  different windows, printed on adjacent lines: precisely the skew the
  transaction lock was built to prevent, arriving through arithmetic instead of
  a race. Reachable if `current` resets without a bootcount bump (history
  service restart, firmware update).
- [x] **A corrupt `state.json` silently resets the energy total, and writes are
  not durable.** `dash.go:75` discards `Load`'s error, so a parse failure gives
  `prev == nil` → `reboot == true` (`:119`) → re-bootstrap from the ring. That is
  the same symptom this file celebrates fixing on the bash side ("seeded with a
  real 14.45 Wh total… rewrote it as 5.99 Wh"): the truncation window is closed
  but "unparseable" is still treated as "no prior state". Compounding it,
  `writeFileAtomic` (`store.go:94-113`) never `fsync`s the temp file or the
  parent directory around the rename — and this tool's whole audience runs dishes
  off batteries in vehicles, where an abrupt power cut is the normal shutdown.
- [x] **Epoch reset has no hysteresis.** `dash.go:119` and `sessionstats.go:38`
  treat uptime going backwards by one second as a reboot, wiping every
  accumulator irrecoverably. One rounded-down uptime report destroys hours of
  observed statistics.

### Corrections to Round 2

- [x] **"The read side needs the lock too" is marked `[x]` and is half done.**
  `buildDashboard` was fixed (`dashboard.go:169`, `BeginRead` spanning both
  loads). The terminal path was not: `renderObserved` calls `state.LoadStats()`
  bare at `dash.go:514` and `renderEnergy` calls `state.Load()` bare at
  `dash.go:565`, two unlocked reads whose output prints four lines apart. The
  irony is that `lock.go:32-33` cites `"obs 21m 8s @ 22.7 W"` as the motivating
  symptom, and that string is printed by the **unfixed** path. The same item
  also claims the fix "also fixes `renderEnergy` re-reading what was just
  written" — it does not, and the file separately lists that as still open.
- [x] **"All save errors are silently discarded" sits inside a `[x]` item and is
  still true.** `dash.go:90,91` and `sessionstats.go:91` all discard. A
  read-only or full cache dir freezes energy and stats with no user-visible
  signal, and once the stall exceeds the ring the missing energy is permanently
  unrecoverable. Worse, `state.Save` failing while `SaveStats` succeeds desyncs
  the two files in exactly the way the lock exists to prevent — a partial
  failure, which no lock can help.
- [x] **Teaching bash the lock does not close the cross-file skew.** Bash locks
  and advances only `state.json`; `stats.json` is Go-only by design. So Go
  writes both cursors at C, `sl watch` runs alone for 30 min advancing only
  energy, and the next Go poll sees a stats gap wider than the ring, adds
  nothing, and advances the stats cursor — permanently omitting those 30 minutes
  from `Observed` while energy counts them. Either give one implementation sole
  authority over both files, or have every writer update both.
- [x] ~~**No Swift tests.**~~ Done — 11 tests, passing, including the golden
  fixture. This file says so at two other points; the checkbox was stale.
- [x] ~~**Connection reuse / `PollOnce` would preserve the bug.**~~ Both resolved
  by the helper; superseded by the helper item above. The performance table
  below still describes the app as spawning `dishwatch json` every second, which
  it has not done since Phase 3.
- [x] **`state.SetDir` is never called outside tests**, so the sandboxed app and
  a terminal `sl` keep entirely separate accumulators inside and outside the
  container. That is probably the right behaviour under MAS, but it means a user
  who has been running the CLI sees the app start its history from zero — and it
  means the cross-process contention `lock.go:14-16` gives as the lock's
  motivation cannot occur in the shipped build. Decide and document which it is.

### The UI spec is written, tested, and not wired up

- [x] **`macos-ui.md` is unimplemented, while the two strings it was written to
  delete are still shipping.** `grep -rn "observed" app/Sources/DishWatch/Views/`
  returns nothing but `@ObservedObject`. `DishData.observed` is decoded
  strictly, constructed in `.sample`, covered by 11 tests — and read by no view.
  Meanwhile `ConnectedPopover.swift:90` still shows `max` over 60 s as a peak
  (the defect the doc opens with) and `CompactWidget.swift:58-59` still shows
  `avg` throughput as capability (the one it calls dangerous: an idle dish on a
  flawless link renders `avg 3`, which reads as broken). The cold-start rule —
  `—`, never `peak 0`, never a silent fall back to the 60 s mean — is
  unimplemented, and the current code is exactly the prohibited fallback. The
  load-bearing tooltip exists only in the `.md` file. **All the honesty
  machinery is built; none of it is on screen.**
- [x] **The battery workflow is a mock-up end to end.**
  `BatterySetupSheet.swift:69` is `DWButton(title: "Calibrate")` with no
  `action:`, so it takes the default `{}` (`Components.swift:179`) — and the Tip
  text at `:60` explicitly instructs the user to tap it. "Start tracking"
  (`:70-78`) is a comment plus `dismiss()`. `charge`/`capacity`/`onBattery` are
  `@State` read by nothing, never seeded from `d`, so reopening on an anchored
  78% bank shows 100%. The "Custom ›" chip is a bare `HStack`, not a button.
  `CompactWidget.swift:104` is a `Text` styled as a button.
  `HelperProvider.setAnchor` has **no callers**. And even fully wired,
  `BatteryPopover.swift:22` presents it via `.sheet`, which
  `PopoverView.swift:10-12` already documents as unusable from a non-activating
  `MenuBarExtra(.window)` panel. Wire it or hide the entry points; shipping a
  primary CTA that does nothing is worse than not having the feature.
- [x] **The always-on-top widget has no provenance or staleness signal at all.**
  `CompactWidget` / `PinnedPanel` never read `isLive`, `lastError` or
  `hasLoaded`. With no helper, `SampleProvider` jitters the mockup numbers every
  tick, so the pinned widget shows **142.5 Mbps with a moving sparkline** and
  looks entirely live. `ConnectedPopover.swift:162-174` gets this right; the
  widget never got the same treatment. It also has no `hasLoaded` gate, so it
  shows a false "Offline" card at every launch, and `CompactWidget.swift:85`
  hardcodes green for drop — 100% packet loss renders green.
- [x] **The menu bar itself has no staleness state.** `AppState.swift:97-101`
  keeps the last-good snapshot and overwrites only `state`, so
  `MenuBarIcon.swift:19,44` shows the last `signalScore`/`pingMs` indefinitely
  with a tooltip reading `Offline · 18 ms · 4↓ Mbps · sig 78`. It is the primary
  surface and the only one with no honesty gate.
- [x] **`MenuBarLabel` rasterizes a SwiftUI view on the main actor every poll.**
  `MenuBarIcon.swift:15-29` builds an `ImageRenderer` in `body` and takes
  `@ObservedObject var store: AppState` whole, so ~4 glyph-relevant fields
  invalidate on all ~40. At the default 1 s interval that is a full render plus
  `NSImage` allocation every second, forever — the app's dominant idle cost, and
  `DishData` is not `Equatable`, so there is no way to gate it. Note the
  backlog's "`.second()` clock re-renders every second" diagnosis is **wrong**:
  `Text(_:format:)` renders statically. The real defect there is that the clock
  is only as fresh as the poll interval while displaying seconds precision.

### Contract, CI, and hygiene

- [x] **`state` is decoded leniently, so version skew renders fresh metrics
  under a wrong header.** `DishData.swift`'s `s()` helper uses `try?`, which
  swallows type errors as well as absences — and it covers `state`, the
  discriminator. A Go side emitting `"CONNECTED"` or adding a `"Booting"` state
  decodes to `.offline` with everything else intact and the footer saying live.
  Good news: **there is no key drift today** — every `json` tag in
  `dashboard.go:17-84` has a matching Swift `CodingKey`, with `sessDropAvg`
  deliberately undecoded. Make `state` and a new `schemaVersion` strict, leave
  genuinely optional metrics lenient.
- [x] **The golden fixture cannot catch the drift it exists for.**
  `ObservedStatsTests.swift:147` decodes a checked-in file, so a Go-side rename
  leaves the fixture untouched and the test green. Add a Go test that reflects
  over `Dashboard`'s tags and diffs them against a checked-in list the Swift
  test also asserts against — that catches renames on the side that makes them.
  Note the helper's `protocol: 1` versions the envelope only; a Dashboard field
  rename needs no bump and raises nothing on either side.
- [x] **There is no CI.** No `.github/` at all. The release path is `make
  publish` from one laptop with a `gh` session, with no test gate — it will
  happily ship a red tree. A workflow running `go vet`, `go test`, `swift test`
  and `GOOS=windows go vet ./...` (which is the only thing that would ever
  exercise `lock_other.go`) is the cheapest durable win in this document.
- [x] **`.goreleaser.yaml:24` sets `-X main.commit={{.Commit}}` against a symbol
  that does not exist.** There is no `commit` variable in package `main`; `-X`
  against a missing symbol is silently ignored. This is the exact trap
  `main.go:18-22` documents having already been burned by for `version`.
- [~] **`lock_other.go:19-21` returns `nil` from `lockFile`**, so every caller on
  a non-unix build believes it holds a transaction. No warning, no error, no way
  to tell. `GOOS=windows go build ./...` succeeds today.
- [~] **`Txn` is not reentrant and self-deadlocks.** Probed on darwin: holding
  `Begin()` and then calling `BeginRead()` in the same process blocks forever —
  flock arbitrates per open file description, so a second `os.OpenFile` conflicts
  with the first. No current path nests, but `pb.go:88-90` reasons about the
  hazard in prose while `lock.go` offers callers no guard, no `Locked()`
  accessor and no panic-on-nest. One edit away from hanging the helper, which
  has no timeout to save it.
- [x] **The `grpcreflect` client is never `Reset()`** (`client.go:67`), so the
  reflection stream stays open for the helper's whole life and cleanup falls to
  a finalizer that can block all finalizers process-wide against an unresponsive
  dish. One line: `defer rc.Reset()` after the descriptors resolve.
- [ ] **`grpc.DialContext` + `WithBlock` are deprecated** (`client.go:59-62`).
  Worth flagging for whoever does it: `grpc.NewClient` is lazy, so the
  `defaultDialMS` timeout and the `ErrUnreachable` classification at `:64` both
  disappear and must move to the first RPC — and `helper.poll`'s offline branch
  and `dieUnreachable` depend on that classification.
- [x] **README inaccuracies.** `sl watch` default is **3** s, not 5
  (`main.go:106`, `sl:857`). "Feature parity is 1:1 today" is false — Go has
  `json` and `helper`, bash has neither. `json` is undocumented despite being
  what the whole app depends on. And `main.go:126` prints *"(more commands
  coming — bash `sl` still has the full set)"* on every `--help`, which is now
  backwards. `app/README.md:5` links a `DishWatch.dc.html` that does not exist.
  Root `make build` produces `bin/sl`, but `app/Makefile:35` needs
  `../bin/dishwatch` — the root Makefile never builds what the app build needs.

### CLI robustness (not app-blocking)

- [ ] **Quitting `sl watch` mid-fetch abandons a state transaction.**
  `watch.go:187-193` cancels and returns while the fetch goroutine may be inside
  `snapshotAndLog`, so the process can exit between `state.Save` (`dash.go:91`)
  and `integrateStats` (`:92`). The lock protects against concurrent writers,
  not against the holder exiting mid-sequence.
- [ ] **Terminal restore does not cover a panic in the render goroutine.**
  `watch.go:42-48`'s `defer restore()` handles `q`, SIGINT, SIGTERM and a main
  goroutine panic — not SIGHUP (closed terminal, dropped ssh) and not a panic in
  the fetch/render goroutine at `:126-137`. With no `recover()` in the tree, one
  nil deref leaves the user's tty in raw mode with the alt screen active.
- [x] **`geo.Reverse` — the doc's characterisation needs correcting.** It is at
  `dash.go:401` (not ~368), it is bounded at 3 s (not "can take 3 s and stall
  indefinitely"), the watch spinner does keep turning because it runs in the
  fetch goroutine, and **it is not on the app path at all** — `buildDashboard`
  never geocodes, so the privacy-label exposure the roadmap describes is
  currently zero. What is genuinely wrong: it is the only `context.Background()`
  in a request path in the repo, so Ctrl-C cannot interrupt it; negative results
  are cached as `"unknown"` **permanently** with no expiry, so one transient DNS
  failure or 429 poisons that cell forever; there is no pruning of `geo_*.txt`
  anywhere; and on a moving dish the `%.2f` ≈ 1.1 km grid means a new uncached
  3 s request every ~40 s at highway speed against a service with a 1 req/s
  policy. `internal/geo/geo.go:20`'s `userAgent = "sl-cli/1.0"` also violates
  that policy, which requires contact information.
- [ ] **Exit codes disagree about the same fault.** `runDash` and `runJSON`
  return `nil` on an unreachable dish (exit 0); `runStatus` returns the error
  (exit 1). `sl watch foo` and `sl events foo` silently discard the parse error
  and use the default. `sl speed` exits 0 even when both probes fail
  (`misc.go:140,144`).
- [x] **`runPb` anchors against stale state on failure.** `pb.go:191-193` prints
  a warning and proceeds. Since an anchor is only meaningful as a (pct, energyWh)
  pair, a stale `energyWh` permanently skews every later depletion estimate —
  the exact failure `setAnchor`'s own comment at `:80-87` warns about,
  reintroduced one level up.

### Round 3 — what shipped, and what did not

**Done, and verified rather than asserted.** Each of these was reproduced before
the fix and re-run after:

- SIGTERM now kills the helper (`kill -TERM` on a helper blocked in its read
  loop: *STILL ALIVE* → dies).
- A 1.5 MB request line is answered `request too long` and the next request on
  the same stream still succeeds; it used to end the process permanently.
- `ping`, `reboot` and `setAnchor` acknowledge without `data`, and the client no
  longer treats that as a dead pipe.
- The `apphelper` build contains zero occurrences of `networkQuality`,
  `nominatim.openstreetmap.org`, `Starlink speed test` or `os/exec.Command`, and
  is 2 MB smaller. `app/Makefile` refuses to assemble a bundle from a helper
  that fails that check.
- The release app binary contains zero occurrences of `DISHWATCH_BIN`,
  `DISHWATCH_NETPROBE`, `DISHWATCH_APPICON`, `DISHWATCH_PROBE` or
  `Sites/dishwatch`; the debug build still has all five, which is what makes the
  guards real rather than decorative.
- `scripts/check-contract.sh` was negative-controlled: renaming `downMbps` on
  the Go side alone fails it, which is exactly the drift the golden fixture
  cannot see.
- The two energy bugs are pinned by tests that were negative-controlled against
  the pre-fix code — reintroducing the fold publishes **19.45 Wh** where 14.45 is
  correct, and removing the rewind branch leaves the cursor frozen at 5000.

**Partly done, marked `[~]` above:**

- `Txn` reentrancy is now documented in detail but **not enforced**. A
  process-wide guard was written and removed: flock deadlocks a nested acquire
  on one goroutine, but two goroutines contending is legitimate and blocks
  correctly — `TestBeginIsExclusive` does exactly that, and the guard failed it.
  Go has no goroutine identity to distinguish them, and a guard that misfires is
  worse than a comment.
- `lock_other.go` no longer lies silently: `lockingSupported` is false there and
  `Txn.Degraded()` exposes it, and CI cross-compiles for windows so the file is
  at least built. No caller warns on it yet, because nothing ships on a non-unix
  platform today.

**Deliberately not attempted in this pass** — all still open below, none of them
ship blockers: adaptive polling and the `get_status`/`get_history` split (Phase
4, and the reason Phase 4 exists); skipping the `state.json` write when the
cursor has not moved; the `grpc.NewClient` migration (it moves the unreachable
classification that `dieUnreachable` and the helper's offline branch both depend
on, so it wants its own change); vendoring the proto; Swift 6 strict
concurrency; `os.UserCacheDir()`; the `watch.go` quit-mid-transaction and
SIGHUP/goroutine-panic terminal restore; the exit-code inconsistencies; and the
`fillBank`/`pbRenderBank` duplication.

One thing removing the wasted `get_location` call already bought: it was a third
of every poll's dish time, so Phase 4 starts from a lower baseline than the
measurements in this document assume. Those numbers want re-taking.

### Round 3b — the fixes reviewed, and seven regressions they introduced

Codex and Grok re-reviewed the diff adversarially. They agreed on the top three,
and every one below is a defect the fixes themselves created. Recorded because
the pattern is the point: four of the seven are a *new* guard firing in the one
situation it was written for.

- [x] **The banner deadline was shorter than the helper's own announce path.**
  Both reviewers' top finding. `runHelper` dialled before writing the banner —
  up to 2 s connect plus 3 s reflection — while the supervisor allowed the
  banner 2 s. So exactly when the dish is absent or stalling, which is the case
  every one of these timeouts exists for, the app killed a healthy helper for
  being slow to say hello and retried on a backoff forever. First launch with no
  dish is a core demo path and it would have failed there. The banner is now
  emitted first and the dial is a background goroutine: **measured 8 ms to
  banner against an unroutable address, against a 2 s deadline.**
- [x] **`ping` blocked on the warm-up dial.** Found while verifying the above,
  by measuring rather than reading: the background dial holds `h.mu`, so the
  first ping waited 2 s against its 1 s deadline — a liveness probe that would
  have killed the helper for being alive. `ping` now answers before taking the
  mutex, which is what its own comment always claimed it did.
- [x] **`EINTR` still led to a blocking read.** `waitReadable` returned
  `.readable` on a signal-interrupted `poll(2)`, and the caller went straight
  into `availableData` with nothing necessarily buffered. It now re-arms against
  the same deadline.
- [x] **The new backoff disabled the one-free-retry it sits next to.**
  `shutdown()` scheduled a backoff, and the retry immediately after it called
  `ensureRunning`, which refuses to launch before that deadline. So a helper
  dying mid-request always cost a poll instead of costing nothing. Backoff now
  lives only where a *launch* fails.
- [x] **`Quality` was worse than the bug it replaced.** It mapped every
  non-connected state to `.offline`, whose caption is "no dish at this address"
  — and `swiftState` maps every non-connected, non-disabled dish state to
  `Weak`, so a live dish on an imperfect link was captioned as an absent one.
  `.weak` is live, `.disabled` is its own case. Pinned by `QualityTests`, which
  was negative-controlled against the regression.
- [x] **A missing helper rendered as "sample data".** `MissingHelperProvider`
  sets `isLive = false`, which fell through to `.sample` — telling a user with a
  broken install that they were looking at a demo. Now `.brokenInstall`.
- [x] **The migration case produced a spectacular average.** The sharpest catch
  of the round. A legacy snapshot has a real `energyWh` and no `obsSeconds`, so
  the next poll paired hours of accumulated energy with a denominator counting
  only the seconds since the upgrade: **measured 5802 W for a 20 W dish**, and
  the coverage gate made it read as a confident "since boot" figure. `ObsSeconds`
  now has a third state, `ObsSecondsUnknown` (-1): an epoch whose count cannot
  be reconstructed offers no average at all until the next reboot resets it.
  Mirrored in the bash `sl`.

Also from the re-review, smaller: the bash side carried `obsSeconds` but still
divided by wall clock when *rendering* (fixed, both the Energy line and the
unanchored battery estimate); `fetchDash` discarded the persistence error so the
CLI never surfaced it (fixed, on stderr, and deliberately not in `watch` where it
would corrupt the alt screen); the app stored `warning` and no view drew it
(fixed); Settings still said "Live" via `isLive` and told Store users to install
a CLI (fixed); `BatteryPopover` never dimmed stale data (fixed); an exactly-5 s
uptime regression escaped the new slack (fixed by adding a halving rule in
`state.IsRestart`, mirrored in bash); and CI vetted the `apphelper` build without
testing it (fixed).

One re-review finding was **not** a defect: Codex reported `BufferedLineReader`
still `private` and the new tests therefore uncompilable. It had already been
made internal; the reviewer read a snapshot from before that edit. The suite
compiles and runs.

### Test gaps worth closing

`integrateEnergy` is at 90%, `integrateStats` 86.8%, `accumulate` 100% — and
**`snapshotAndLog` is at 0%**. The headline fix of Round 2, one lock spanning
both files, has no test at all. The highest-value additions:

- After `snapshotAndLog`, assert `state.json.lastCurrent == stats.json.lastCurrent`;
  then the same with a competing writer running during the call.
- Cursor rewind, both accumulators, asserting they stay consistent (D-4 above).
- Zero-cursor bootstrap with a **non-zero** prior total (the `+=` bug — the
  existing test uses zero, where `+=` and `=` agree).
- Reboot and zero-cursor clamps (`nb > ringLen`, `nb > cur`) for both integrators,
  asserted to agree, since "the shared bootstrap rule" is what the docs claim.
- `renderEnergy` after a gap wider than the ring — there is no render-layer test
  at all, which is why the `avgW` collapse survived.
- Save-failure paths, which currently assert nothing because nothing happens.

Three branches show as uncovered but are **dead, not untested** — `dash.go:141-143`,
`dash.go:184-186` (`obsStartUp < 0` cannot fire; `nb` starts at `uptime` and only
shrinks) and `sessionstats.go:81-83` (`n > ringLen` is already clamped by both
branches above it). Delete them rather than writing tests for them.

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
- [x] **Outage runs were welded across a dropped gap.** Found by Codex reviewing
  the fold-forward settlement, and neither of us caught it while making that
  change. `CurrentOutageS` is persisted, so when a gap wider than the ring set
  `n = 0` and skipped `accumulate`, an outage in progress stayed open — and the
  next dark sample continued it. Two separate outages either side of an
  unmeasured hole were reported as one, inflating `LongestOutage` by the gap
  and undercounting `Outages`, while the tooltip claimed gaps past the ring are
  excluded entirely. `closeOutage` now banks the run at the last second we
  actually saw, and is shared with the normal end-of-run path.
  `TestIntegrateStatsClosesOutageAcrossAGapWiderThanRing` fails without it
  (`OutageCount = 0, want 1`).
- [x] **The app paid a full process spawn + gRPC dial + reflection download per
  poll** (696 ms), and could not work sandboxed at all. Replaced by a
  supervised long-lived `dishwatch helper` speaking JSON lines over pipes:
  warm poll median 274 ms, and the pipe round trip itself is **0.014 ms**, so
  what remains is dish RPC time that no architecture avoids.

  Worth recording because it inverted an assumption: the 696 ms was never
  evidence for linking Go in-process. It was evidence for holding the
  connection open, which a child process does just as well as a `c-archive` —
  and without putting a Go runtime fault inside the menu bar's address space.
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
