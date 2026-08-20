# Roadmap — native macOS app

> Status as of **2026-08-05**: the SwiftUI menu-bar app in [`app/`](../app) now
> builds a real signed, sandboxed `.app` (`make app`), and the architecture gate
> has been run against a live dish rather than argued about — a sandboxed bundle
> **can** reach `192.168.100.1`, through both candidate network stacks.
>
> The same spike killed the *external* subprocess bridge — sandboxed, the app
> cannot reach a Homebrew or checkout install — but an **embedded** helper inside
> the bundle works end to end. That settled the engine question: **Option C**, a
> long-lived embedded Go helper over pipes, chosen independently by both
> reviewers. `dishwatch helper` exists and measures 0.014 ms of IPC overhead per
> request, so the architecture costs nothing and the remaining latency is dish
> RPC time every option would pay.
>
> This doc supersedes the original "planned, not started" roadmap, whose phase
> order is now obsolete — the UI got built before the core split.
>
> **Update 2026-08-14.** A seven-reviewer round found that the engine decision
> was right and the engine's *implementation* is not yet a 24/7 Store process:
> no request deadline on either side of the pipe, no restart backoff despite the
> code claiming one, a `terminate()` the helper cannot receive, and a response
> contract that reads a successful reboot as helper death. Separately, `make
> app` builds `-c debug`, so every `#if DEBUG` guard written to keep dev
> scaffolding out of the shipped app is currently inert. The critical path is
> now [Phase 3.5](#phase-35--what-has-to-happen-before-anything-else), not
> Phase 4. Full findings in
> [optimizations.md](optimizations.md#round-3--2026-08-14).
>
> **Shipped 2026-08-14.** All of the above is fixed and **v0.1.3 is public** —
> a notarized, stapled, universal DMG plus a Homebrew cask, alongside the CLI
> formula for macOS and Linux. `make app` builds release, so the `#if DEBUG`
> guards are real. See [release.md](release.md) for the process and
> <https://dishwatch.github.io> for the landing page.
>
> This changes the distribution ordering below. "Mac App Store first, notarized
> direct build later" is now **direct build shipped, Store still blocked** — on
> certificates rather than code (Apple Distribution and 3rd Party Mac Developer
> Installer, neither of which this machine has).

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
| Live data | **done** — `HelperProvider` supervises an embedded `dishwatch helper`, verified sandboxed |
| `.app` bundle / Info.plist / entitlements / signing | **done** — `make app`, ad-hoc signed, sandboxed |
| Engine decision (A/B/C) | **settled — C**, long-lived embedded helper over pipes |
| `internal/model` + `internal/service` split | **not started** |
| Sandbox + reachability | **exercised** — sandboxed bundle reaches the dish; embedded helper runs |
| Local-network TCC first-run / prompt | **not exercised** — needs a clean account + Apple-issued identity |
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

## Settled: what backs the App Store build

Two review rounds split on this, so it was held open and settled by experiment
rather than argument. **The answer is Option C** — see the decision below the
three options.

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

**Option C — embed the CLI as a helper inside the bundle** *(discovered by the
spike; see below)*

- *For:* reuses the Go core whole with **no cgo, no c-archive, no dual math and
  no Go runtime resident in the menu-bar process**. Verified working end to end
  under the sandbox. Smallest amount of new code by a wide margin.
- *Against:* keeps the ~700 ms spawn-and-dial per poll, which is the cost
  Phase 3 exists to remove — so it needs either a long-lived helper speaking
  over a pipe (at which point it is an XPC-shaped design in disguise) or a much
  slower cadence. Ships a second executable through review.

**Decision (2026-08-05): Option C.** Both reviewers picked it independently on
a second pass, and Grok explicitly retracted its earlier recommendation of B.
The reachability gate below removed the veto that made B attractive
("maybe we can't run Go under the sandbox"), and the embedded-helper probe then
turned C from forbidden into demonstrated.

Why C over A, in the reviewers' words rather than mine: the deciding argument
is blast radius, not speed. A cgo fault takes the menu bar down with it; a
helper that dies is a helper the app restarts. And A's least-tested part —
embedding the Go runtime in Swift's address space, entered from arbitrary GCD
threads — is precisely what C never does.

Why C over B: B duplicates far more than "three small formulas". `integrateStats`
owns persisted cursors, reboot epochs, ring-gap rules and outage segmentation —
a persistence authority, not arithmetic. B would have to reproduce those rules
or invent a second authority. Golden vectors make B respectable but, per Grok,
"delay the crash; they do not remove the second codebase", and the thing that
rots first is the JSON/UI contract rather than the integrators.

**And a legal caveat that on its own disqualifies B for a first release.**
Vendoring the proto means redistributing descriptors extracted from the dish.
Starlink's software terms reserve their software IP and restrict deriving
source from binary software; whether reading an intentionally exposed
reflection API for interoperability falls inside that is a legal
interpretation, not an engineering fact. Extracting locally to test is fine.
Checking it into a public repo and shipping it in an App Store binary is not
something to do without advice. This repo is public.

### What C measured (2026-08-05, live dish)

| | |
|---|---|
| Warm poll through the helper | **median 154 ms**, min 54 ms, p95 202 ms (vs **696 ms** spawn-per-poll) |
| IPC round trip, no dish (`ping` op, n=200) | **0.014 ms** median, 0.024 ms p95 |
| Helper RSS over 787 polls / 15 min | 35.0 MB → **37.4 MB**, plateaued from t=685 s |
| Helper CPU between polls | **0.0%** |

The second row is the one that decides A vs C: **the architecture costs
14 microseconds**. The remaining 274 ms is dish RPC time, which every option
pays identically — so A's 61–91 ms figure was never about being in-process, it
was about connection reuse, which C has too. There is no performance argument
left for cgo.

The latency figures come from a 15-minute soak at 1 Hz — the app's current
worst-case cadence, and one Phase 4 intends to relax. RSS grew 2.4 MB over 787
polls and then sat flat at 37.4 MB for the final three-and-a-bit minutes, which
looks like a plateau rather than a leak; fifteen minutes is not long enough to
prove that, so it is worth re-checking over hours before submission.

Still outstanding, per both reviewers: combined **app + helper** Energy Impact
and wakeups from Instruments, not RSS and CPU sampled with `ps`. C **relocates**
the Go runtime, it does not remove it, and an earlier draft of this roadmap
oversold that.

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

**What this exercised is connectivity, not the permission narrative.** Both
reviewers flagged the distinction and it matters, because App Review cares
about the second one. No Local Network prompt appeared and no
`kTCCServiceLocalNetwork` row exists for the app — but that service lives in
the root-owned system TCC database, so whether a grant was recorded silently or
the prompt simply doesn't fire for unicast TCP to a private address on macOS
26.5.2 is not something this can distinguish. Treat "no prompt" as **unknown
policy path**, not as solved.

Three further limits on the evidence, all real:

- **Ad-hoc signing is a partial proxy.** It genuinely activates the sandbox and
  its entitlements, so the sandbox half is sound. It says nothing about Store
  distribution identity, receipts, or the review environment — and Apple
  recommends an Apple-issued identity for reliable local-network attribution,
  which makes ad-hoc especially weak evidence about TCC *persistence*.

  **Half-resolved 2026-08-14.** The identity objection no longer applies: a
  notarized, stapled, universal, sandboxed build signed with a real Developer ID
  was installed from a quarantined DMG into /Applications and launched cold. It
  connected — helper ESTABLISHED to 192.168.100.1:9200 — and **no Local Network
  prompt appeared**. So this is now the same "no prompt, works anyway" result as
  ad-hoc, under a real identity, through the actual distribution path.

  That removes one of the three limits and strengthens the reading that the
  prompt does not fire for unicast TCP from a Go BSD socket to a private address
  on this macOS build. It does **not** make it solved: this account has run the
  app many times under ad-hoc signing, so a silent pre-existing grant cannot be
  ruled out from here. The remaining limits — one machine, one OS version, and
  a never-before-seen user account — still stand, and a clean account is now the
  single experiment that would settle it.
- **One machine, one OS version.** Local Network behaviour has moved across
  releases. Re-run on a clean user account with an Apple-issued identity before
  trusting the first-run story, and record prompt, denial, retry and
  next-launch behaviour.
- **`isatty` is not proof of responsible-code identity.** The methodology is
  sound because the launch used `open`, not because that heuristic validates
  it; plenty of non-interactive shell launches also lack a TTY.

So the engine keeps the retry/backoff and visible permission state the App
Review checklist calls for, and "TCC exercised" is not a claim this makes.

**So reachability no longer vetoes anything — but that is all it establishes.**
Both reviewers pushed back on the stronger conclusion drafted here first, and
they were right: "the gate cleared A" is an opinion wearing an implication's
clothes. Removing a veto returns the decision to an ordinary trade, and a
raw socket is a proxy for Go's net stack rather than Go's net stack. What
narrows Option A's remaining risk is the embedded-helper result below, not this
table.

### What the spike killed, and what it didn't

Sandboxed, the app cannot reach a CLI installed **outside the bundle** —
`PROBE ERR binaryNotFound`, even with `DISHWATCH_BIN` pointing at an absolute
path. A/B'd with only `com.apple.security.app-sandbox` flipped, everything else
held constant.

The first draft of this section read that as "a sandboxed app cannot execute
the CLI." That was wrong, and Codex caught it: Apple explicitly supports
**embedded** command-line tools that inherit the containing app's sandbox. So
it was tested rather than argued —

```sh
cp bin/dishwatch .build/DishWatch.app/Contents/MacOS/dishwatch-helper
codesign --force --sign - --options runtime .../dishwatch-helper
DISHWATCH_BIN=.../dishwatch-helper DISHWATCH_PROBE=1 .../DishWatch
→ PROBE OK state=Connected signal=76 … hw=Mini fw=2026.07.24
```

The full chain works: the sandboxed app spawns the embedded helper, the helper
dials the dish over gRPC, decodes via server reflection, and writes state into
`~/Library/Containers/com.faeton.dishwatch/Data/.cache/sl/` — the container,
with the real `~/.cache/sl` untouched, exactly as `state.SetDir` intends.

Two consequences.

1. **This is a third architecture option**, call it **Option C — embed the CLI
   as a helper.** It reuses the Go core whole, with no cgo, no c-archive, no
   dual math, and no Go runtime resident in the menu-bar process. It keeps the
   ~700 ms spawn-and-dial cost per poll, which is exactly what Phase 3 was
   meant to remove, so it is not obviously good — but it is now *possible*,
   which it was not before this test, and it should be priced rather than
   assumed away.
2. **It substantially de-risks Option A.** The helper is Go's real net stack —
   runtime poller, resolver, gRPC, protoreflect — completing real RPCs inside
   the sandbox. Option A's open risk is therefore narrowed from "does Go
   network under the sandbox" (answered: yes) to "does it network correctly
   when linked in-process via `c-archive`, with cgo's thread model and Swift
   concurrency" — a real question, but a much smaller one. Confirming it still
   wants the archive actually linked and dialing.

What is *not* rescued is the current bridge, which hunts for Homebrew and
developer checkouts. That stays dead for any Store build.

Do not finish Swift features or polish UI before the engine decision. Do not
extract the Go core "for dishkit" before it either — extract it because the CLI
needs it (it does), which is true under all three options.

## Revised phases

| Phase | Work | Gate |
|-------|------|------|
| ~~**0**~~ | ~~Correctness: state transaction lock, energy bootstrap, characterization tests~~ | **done** |
| ~~**1**~~ | ~~Real `.app` bundle~~ | **done** — `make app` |
| ~~**2**~~ | ~~**Decision spike** — sandboxed local-network reachability~~ | **done — no veto; A vs B vs C still open** |
| ~~**3**~~ | ~~Engine behind `DishProvider`; kill the *external* subprocess~~ | **done** — supervised embedded helper |
| **3.5** | **Ship blockers + helper hardening** — see [below](#phase-35--what-has-to-happen-before-anything-else) | Nothing else starts until this closes |
| **4** | Adaptive polling, split RPCs, idle cost near zero | |
| **5** | Contract hardening: `schemaVersion`, strict decode, golden fixtures shared by Go and Swift | Precondition for the `Observed` row below |
| **5a** | Metric presentation per [macos-ui.md](macos-ui.md) — session footer, peaks over means | Needs 5, or a zero-default carve-out |
| **6** | Store prep: trademark/disclaimer copy, privacy label, screenshots, 1024 icon, privacy policy URL | |
| **7** | Submission + App Review | |
| **8** | *(optional)* notarized direct build via `cmd/dishwatchd`; Windows tray | |

~~Phase 4 is now the critical path.~~ **Superseded 2026-08-14.** Phase 4 is
correct product work and it is not what App Review, or a reviewer without a
dish, will fail us on. A 1 Hz menu-bar app can pass review; a bundle that ships
a debug build with an arbitrary-binary env hook, a footer reading "live" over an
offline dashboard, and a nested copy of the full CLI including `networkQuality`
will not. Phase 3.5 below is the critical path. The helper still removed the
per-poll dial, and adaptive polling remains where the battery cost lives — just
after the app stops being rejectable.

## Phase 3.5 — what has to happen before anything else

From the 2026-08-14 review round (seven reviewers; findings and evidence in
[optimizations.md](optimizations.md#round-3--2026-08-14)). Ordered so that each
step is independently shippable and the riskiest thing is never the last thing.

**1. Stop shipping a debug build.** `app/Makefile:19` → `CONFIG := release`,
keeping an explicit debug build for `make icon` (it needs `DISHWATCH_APPICON`).
Then `#if DEBUG` the three call sites in `DishWatchApp.swift:34-58` and the
whole of `Render.swift`, `NetProbe.swift`, `IconCandidates.swift` — or move them
to a target excluded from the app product. This one change removes the
`DISHWATCH_BIN` arbitrary-exec hook, the demo battery toggle, the raw-socket
prober and the env-var-controlled file write from the signed bundle at once.

**2. Build a real helper, not a copy of the CLI.** — **done 2026-08-20.** The
command table is now per-build: `dispatch_full.go` carries the CLI's nineteen
verbs, `dispatch_apphelper.go` carries `helper`, `--version` and `--help`. The
default command is per-build too, so a stray exec of the bundled engine prints
what it is instead of dialling the dish and rendering a terminal dashboard from
inside a sandboxed bundle.

Guarding the *dispatch* rather than each command's file is what made it cheap:
the render and interactive paths become unreachable and the linker drops them
along with the string literals only they referenced. The integrators in dash.go
stay reachable through `helper.poll`, which is correct — they are the engine.

One thing the linker could not do on its own. `renderBank` is a package-level
func var assigned from an `init()` in pb.go, and an `init()` always runs, so
`pbRenderBank` was reachable however dead its only caller became — it kept the
CLI's bank rendering alive inside the bundle by itself. Split into
`pb_render.go` under `!apphelper`; the anchor logic beside it stays, because
the app's `setAnchor` op calls straight into it.

Result: `usage: sl` and `dies in` gone from the submitted binary, `Obstruction`
4 → 1 and `Throughput` 6 → 4 — the remainder in both cases being wire field
names (`obstructionStats`, `downlinkThroughputBps`) the engine legitimately
needs. 100 KB smaller, and verified end to end against a live dish: banner
reports `restricted: true`, `ping` and `poll` answer, `dash` is refused.

The `networkQuality`/`ping` shell-outs and the Nominatim client were already
absent via `features_apphelper.go`; `make helper-check` now actually greps for
all three rather than printing a claim it never checked.

**3. Fix the `ok`-with-no-data contract.** Decode command acknowledgements
separately from poll responses so `reboot`/`setAnchor`/`ping` stop being read as
helper death. Never auto-retry a non-idempotent op — that means removing
`reboot` from `withClient`'s redial-and-retry (`helper.go:220-244`) as well as
fixing the Swift side. Let `reboot`/`setAnchor` throw so `AppState`'s `catch`
stops being dead code.

**4. Deadlines, then backoff, then a kill that works.** Per Grok's prescription,
which matches what the other reviewers found independently:

- `internal/dish/client.go:67` — wrap reflection in `context.WithTimeout` (~3 s).
  It currently takes the process ctx, so a dish that accepts TCP and stalls the
  reflection stream hangs the helper before its banner, forever.
- `helper.serve` — a per-request `WithTimeout` (~12 s) covering `withClient`'s
  redial, rather than passing the process ctx down.
- Swift is the watchdog: `BufferedLineReader.readLine` takes a deadline
  (`DispatchIO`, or a readability handler plus a timer). Banner 2 s, `ping` 1 s,
  `poll` 15 s, `reboot` 10 s. On expiry kill the child; do not wait on it.
- Backoff: `min(10s, 0.2s * 2^n)`, reset only after a banner **and** one `ok`
  reply. Do not loop on `protocolMismatch` or a missing binary. (Note: the claim
  that the current code eventually stops spawning is wrong — `send` still calls
  `ensureRunning()` on every poll, so it forks once per second indefinitely.)
- Killing: drop `signal.NotifyContext` for helper mode so default SIGTERM works;
  parent closes stdin, waits ~200 ms, then `SIGKILL`. Never abandon a live pid
  the way `shutdown()` does today after its 2 s wait.
- Add a per-request `defer recover()`. There is no `recover()` anywhere in the
  repo, so any panic under `buildDashboard` currently kills the process
  mid-reply.

Keep the framing exactly as it is — one stdin/stdout pair, JSON lines, `id`
echo, banner, stdout protocol-only. Half-duplex matches the serialized state
writes, and no reframing fixes a hang or a signal.

**5. Stop presenting offline and stale as live.** Split `dish.ErrUnreachable`
(→ offline dashboard) from every other error class (→ `resp.Error`), so firmware
drift is diagnosable instead of reading as "Offline" forever. Derive the footer
from transport success **and** `DishData.state`. Give the menu bar and the
pinned widget a staleness treatment — the widget currently has no provenance
signal at all and will happily animate `SampleProvider`'s 142.5 Mbps as live.
Add a permission-denied state and a first-run "no dish found" screen, since that
is the first thing App Review sees.

**6. `PrivacyInfo.xcprivacy`** declaring the app-local `UserDefaults` reason
(`CA92.1`), copied into `Contents/Resources` by `app/Makefile`. Add
`ITSAppUsesNonExemptEncryption=false` while there.

**7. The energy numbers that are wrong today.** These ship in the CLI right now
and are independent of everything above: give energy its own observed-sample
counter so `avgW` stops dividing observed joules by wall-clock time
(`dash.go:574`, which also poisons the power-bank estimate); change `+=` to `=`
at `dash.go:177`; handle a negative cursor delta symmetrically in both
accumulators. Then close the test gaps — `snapshotAndLog` is at **0%** coverage,
so Round 2's headline fix is untested.

**8. Then decide about `reboot` at all.** Both review rounds have now suggested
cutting it from v1. It is a destructive LAN action behind a confirmation dialog
that may not even receive clicks from a non-activating panel, and it is where
the retry bug did its damage. Shipping without it costs one feature and removes
a whole category of review anxiety.

Only after that: Phase 4.

The `internal/model` + `internal/service` extraction is no longer on the app's
critical path at all — under Option C the app never imports Go, it talks to it.
It stays worth doing for the CLI's own sake (the `fillBank`/`pbRenderBank`
duplication, the `renderBank` `init()` indirection), but it is cleanup now, not
a blocker.

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
