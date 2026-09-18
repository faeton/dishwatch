# Brief — iOS app

> Status **2026-09-18**: nothing built. This is a brief, not a plan with dates.
> It exists to say what an iPhone app can honestly be, what iOS takes off the
> table, and which decisions get settled by an experiment rather than by
> argument — the discipline that settled the Mac engine question in
> [roadmap.md](roadmap.md#settled-what-backs-the-app-store-build).
>
> One thing is decided by the platform rather than by us: **Option C is dead on
> iOS.** The Mac app's whole answer — supervise an embedded `dishwatch helper`
> as a child process — rests on `fork`/`exec`, which iOS does not give an app.
> So the A-versus-B argument that the 2026-08-05 spike made moot comes back,
> and it has to be settled again on different ground.
>
> Two outside reviews were run on this brief (2026-09-18) and **they split, the
> same way they split on the Mac**: Codex for A, Grok for B. Where they agree
> is recorded below as settled; where they split is a spike, not a thread.

## What the phone is for

The Mac app answers one question: *is it the dish or is it my Wi-Fi, right now,
while I am working.* The phone is in a different place at a different moment,
and rebuilding the Mac app on a smaller screen answers a question nobody is
asking on the device they are holding.

Three questions the phone is genuinely the right screen for:

1. **Aiming and setup.** Standing next to the dish with a laptop is not a thing
   people do. Obstruction state, aim and signal while you physically move the
   thing is phone work, and on a Mini it is *the* phone work.
2. **Power.** Off-grid on a battery, the laptop is shut. Watts, the bank's
   remaining charge, and time left are worth a glance from a pocket.
3. **Is it up, and for how long.** A Lock Screen glance, not a dashboard.

And one question the phone **cannot** honestly answer, which shapes everything
below: *anything at all, while not on the dish's network.* There is no cloud in
this product. On cellular, or on home Wi-Fi behind a router that is not the
dish, every surface has nothing new to say and must say exactly that. This is
not the error case. On a phone it is the **normal** case, and a design that
treats it as an error will spend its life showing a red dot to people whose
dish is fine.

## What iOS takes away

| Mac design | iOS consequence | Kind |
|---|---|---|
| Embedded `dishwatch helper` over pipes (Option C) | No subprocess execution. The engine decision reopens. | **Hard** |
| 1 Hz poll from an always-on menu-bar process | Frozen seconds after backgrounding. No goroutine, timer or socket survives. | **Hard** |
| A persistence authority accumulating across hours | There is nothing to author between visits. See [Persistence](#persistence-the-dish-is-the-integrator-the-phone-is-a-visitor). | **Hard** |
| `~/.cache/sl/` shared with the CLI and bash | Gone — and good riddance: the [cross-process energy double-count](optimizations.md) cannot exist here. State is an App Group snapshot. | Fine |
| Menu-bar glyph with a tooltip | No equivalent. Home/Lock Screen widget, a Control Center control, maybe a Live Activity. | Awkward |
| Local Network TCC, exercised and passing in a sandboxed `.app` | Re-run from scratch. Different prompt, and on iOS a denial is silent failure, not an error. | **Hard** |
| Universal arm64 + x86_64 | arm64 device + arm64 simulator. And the **simulator does not implement Local Network Privacy** — device or it did not happen. | Awkward |

## Persistence: the dish is the integrator, the phone is a visitor

This is the section that decides the engine, so it comes first.

The instinct is that an app sampling every fifteen minutes cannot maintain an
energy integrator, so the integrator must be ported carefully. Both reviews
landed somewhere better: **do not port it, because the phone should not have
one.**

The dish sends a **900-slot, 1 Hz history ring** with a monotonic write cursor
(`internal/dish/history.go`). One successful `get_history` *is* energy, drop,
throughput and watts over the last ≤15 minutes — complete, self-contained, no
phone-side cursor, no `state.json`, no epoch bookkeeping. That is also the
only window the phone can honestly claim, unless it sat in the foreground on
that LAN for the whole boot.

| Piece | iOS |
|---|---|
| Energy **since boot** | **Cut as a claim.** True only if you observed essentially all of `uptimeS`, which iOS will not. Showing a since-boot total from a fifteen-minute visit is the same class of lie as dividing joules by wall clock across a gap — the bug `ObservedAvgW` exists to refuse. |
| Ring energy, mean W, sparklines | **Keep**, labelled as the dish's last 15 min (or `min(uptime, ring)`). One RPC. |
| Foreground-session Wh | **Optional, clearly named.** While the app is open on the LAN you may fold the ring forward across polls — the non-reboot path of `integrateEnergy`. Discard on process death. Never write it as though it continued in a pocket. |
| `stats.json` Observed accumulators | **Cut.** Peaks and means over "everything seen this boot" assume coverage. Replace with ring peaks and means. |
| `events.log` as a multi-day log | **Cut as source of truth.** A gap wider than the ring is invisible, and a phone on LTE would invent a day of outage that belongs to the phone. Keep at most "what this phone witnessed", said in those words. |
| Outage inside the ring | **Keep.** Segment drop across the samples you just fetched. "Was the last quarter-hour clean" is exactly a phone glance. |
| Reboot detection | **Keep**, but as a label on this snapshot ("dish up 12 min") via bootcount and `IsRestart`, not as a trigger to wipe accumulators you do not have. |
| Power-bank gauge | **Redefine.** Persist *calibration* only — capacity, last anchored percentage, timestamp. Do not deplete it from a background integrator. On the next on-LAN poll, apply ring joules if the gap fits inside the ring; otherwise say "last seen 44% at 14:32" and ask for a re-anchor. Invalidate on bootcount change, as the Mac does. |
| Last snapshot + `capturedAt` + bootcount + uptime | **Keep.** This is the widget's entire data model. |

One concrete Go-side consequence, spotted by Codex: `internal/state/store.go`
logs a gap as `"%s unseen — dish stayed up (local/Wi-Fi side)"` (`store.go:392`).
On a phone that sentence is usually false — the gap means *the app was
suspended*, not that anything happened on the network. If the event log ever
runs on iOS the label has to become an observation gap, and arguably it should
say that on the Mac too, where a closed lid produces the same gap for the same
non-reason.

## The engine decision, reopened

Both options were written up for the Mac in
[roadmap.md](roadmap.md#settled-what-backs-the-app-store-build). The arguments
carry over; the **weights do not**.

**Option A — the Go core as an XCFramework**, confined to the containing app
(Codex's pick)

- *For:* one implementation of transport, decoding, and whatever state
  semantics survive. 29 MB of archive is nowhere near any App Store limit, and
  the Mac's measured 61–91 ms c-archive call says the shape works.
- *Against:* the Go runtime lands in a process that is suspended and resumed
  all day. Go's networking does not see `NWPathMonitor` path changes, so a
  channel held across a Wi-Fi→cellular switch is the classic silently-dead
  connection. Grok adds that a Go panic inside a `c-archive` is a `SIGABRT` of
  the whole app with no Go stack in the crash report — *unverified, and worth
  verifying, because it inverts the blast-radius argument that won Option C.*
- *And:* `gomobile bind` is the worse of the two A variants — it cannot export
  maps or most slices, so you would end up wrapping `Poll() -> JSON` and
  reimplementing the helper protocol *inside* the process Option C existed to
  keep it out of. If A, then `-buildmode=c-archive` for `ios/arm64` +
  `iossimulator/arm64` behind a tiny C ABI. Not gomobile.

**Option B — pure Swift, grpc-swift v2 over Network.framework** (Grok's pick)

- *For:* no Go runtime in a suspended process. NIOTS rides `NWPathMonitor`, so
  the tear-down-and-redial-on-path-change behaviour the phone needs constantly
  is the default rather than a research project. Ordinary Xcode CI. Small
  enough to *consider* in an extension later, which A never can be.
- *Against:* two decoders for `get_status` and `get_history`, held together by
  golden fixtures — the drift the architecture has twice refused. A vendored
  proto also freezes a contract that reflection adapts to.
- *Caveat that may be a veto:* grpc-swift's TransportServices transport is
  documented **iOS 18+**. NIOPosix works earlier and is the wrong stack on
  Darwin. If the product needs iOS 17, that is a real tax, not a footnote.

### Decision (2026-09-18): Option B, vetoable by G2

**B** — but not for the reason this brief originally gave.

The first draft leaned B because a widget cannot hold a Go runtime. Codex
dissolved that: the widget never has to fetch. The app polls — foreground, and
opportunistically from a `BGAppRefreshTask` that runs in the *app's* process —
writes a snapshot to the App Group, and calls `reloadTimelines`. The extension
decodes JSON and draws. Under that split, A is perfectly viable and the widget
ceiling is irrelevant. (The ceiling is not theoretical: the desktop helper
measures **37.4 MB RSS**, over the ~30 MB extension budget before a single view
is allocated.)

What actually moves it to B is the section above. A's core argument is that the
Go state machine is a persistence authority too subtle to reimplement — cursors,
boot epochs, gap rules, outage run-length, all made correct by being found wrong
twice. **That argument only pays if the phone runs that machine, and the phone
should not run it.** Cut the cross-visit accumulators and what is left is
"decode two messages, fold one ring, paint a dashboard" — which Swift already
does on the Mac, from JSON, today. The expensive thing is the thing we are not
porting.

Grok's counter to the hybrid is half right and worth stating: Go in the app plus
Swift in the widget means two stacks, so you have paid B's cost and kept A's
runtime. Half, because the widget decoding an App Group snapshot is not a second
dish client — both designs need that, and it is a `Codable` struct. But the
direction is right: if the widget is Swift either way, A's single-implementation
claim is already partial.

This is recorded as a decision rather than a preference so that Phase 1 can
start without the argument reopening every time someone reads the file. It has
exactly one veto, named below, and it is an experiment rather than an opinion.

**What flips it back to A:** G2 failing. If grpc-swift NIOTS cannot speak
plaintext h2c to this dish on a real phone, B has no happy path, and a
main-app-only `c-archive` is the fallback. Not gomobile, and not in the widget.

**Not in question:** the Mac stays on Option C. Unifying the two platforms on a
c-archive would trade a working isolation story for a platform that cannot use
it.

## Gates — run these before writing screens

Each is a time-boxed spike on a physical device against a live dish, in a signed
build. The simulator is not evidence for any of them.

| # | Question | Settles |
|---|---|---|
| **G1** | Can a signed iOS app reach `192.168.100.1:9200` from a phone on the dish's Wi-Fi — and what does the Local Network prompt say, when does it fire, and does the first connect fail *while the alert is up*? | Everything. Run it first. |
| **G2** | grpc-swift v2 + NIOTS, plaintext, `get_status` against the real dish. Then leave the Wi-Fi and confirm the client dies cleanly instead of hanging. | A vs B. A failure here is B's only veto. |
| **G3** | Widget extension with an App Group snapshot and no gRPC: measure RSS. Separately, whether an extension can complete a LAN connection at all after the app has been allowed. | Whether v2's widget may ever fetch. Not on v1's path. |
| **G4** | Over a week on a real phone: how often do `BGAppRefreshTask` and widget reloads actually fire *while on the dish's LAN*? | Whether the widget is nearly-fresh or a bookmark with a timestamp. |

G1 has the same shape as the macOS reachability gate that killed the external
subprocess bridge: a question everyone assumed the answer to, where the
assumption was load-bearing. It has one iOS-specific twist — per Apple's TN3179,
extensions **inherit** the container app's local-network privilege and a
background-class extension **cannot present the prompt**, so if the grant is
undetermined the connect is denied and not even recorded. The first Allow must
happen in the foreground app. G1 therefore has to test the widget too, not just
the app.

The published WidgetKit figures — 15–60 minutes, 40–70 reloads a day — are
typical, not guaranteed. G4 exists because designing against documented numbers
instead of observed ones is how you ship a widget that is wrong at 3pm.

## Surfaces

| Surface | May honestly show | Must not |
|---|---|---|
| App, foreground, on the LAN | Everything the Mac popover shows, at 1 Hz | — |
| App, foreground, off the LAN | Last-known, timestamped, and *why* it is stale | A sparkline that looks live |
| Home Screen widget | State, uptime, watts, bank %, and the age of the reading | Any number without its age |
| Lock Screen / inline | One fact — up/down, or watts | A dashboard |
| Control Center control | Up/down, tap to open | Anything that needs a fresh poll to be true |
| Live Activity | **Cut for v1.** Same LAN problem plus a "this looks live" honesty problem | — |
| StandBy | Whichever view survives G4 | — |

**Aiming deserves its own screen**, and it is the one place the phone beats the
Mac outright: obstruction, azimuth and elevation, live while the person turns
the dish, screen kept awake. Starlink's own app does this; ours does not have to
be better, it has to be in the same app as everything else.

**Cut `reboot` from iOS v1.** Both Mac reviews already suggested it there. A
phone that can power-cycle hardware over the LAN is a conversation with App
Review that buys nothing.

## Staleness is the primary UI, not a footer

The Mac already paid for this lesson once — the pinned panel drew a moving
sparkline at 142.5 Mbps while disconnected, because the widget never got the
provenance treatment the popover did (see [optimizations.md](optimizations.md)).
On iOS that state is not an edge case, it is most of the day.

Two timestamps, never one: **last observation** and **last attempt**. A failed
refresh keeps the old observation time and adds "couldn't refresh". It does not
flip to Offline and it does not zero anything.

Buckets driven by `capturedAt`, never by `DishData.state` alone:

| Age | Caption | Presentation |
|---|---|---|
| < 2 min, last fetch succeeded | `Live` | Full colour, current numbers |
| 2–15 min | `Updated 6 min ago` | Full numbers — they can still come from a ring the dish itself holds |
| 15 min – 6 h | `Last seen 14:32` | Desaturated. State and signal if you like; **not** ping or throughput as if current. The sparkline is historical and says so |
| > 6 h | `Last seen yesterday 21:04` | One line of last-known state, or the empty glyph |
| Never captured | `Open DishWatch on dish Wi-Fi` | A designed empty state, not a spinner that never resolves |
| Permission denied | Distinct copy + a Settings deep link | **Not** "Offline" |
| Off the LAN | `Not on dish Wi-Fi` | The typical home-screen state. Must not look like an outage |

Rules: one timeline entry, policy `.after(~30 min)`; never invent future entries,
this is not weather. Foreground `reloadTimelines` does not consume the daily
budget, so write on every foreground poll. And never decode a missing field into
a design-mockup number — the `DishData` defaulting trap is worse on a surface
people read without opening the app.

A snapshot carrying `state: Connected` and a `capturedAt` six hours old is not
connected.

## Code shape

`app/` becomes a multi-platform SwiftPM package rather than a macOS executable:

- `DishWatchCore` — `DishData` and its enums, `Render`, formatting, the
  `DishProvider` seam, `ObservedStats`. Platform-free already in practice; the
  tests move here.
- `DishWatchMac` — menu bar, popover, pinned panel, `HelperProvider`.
- `DishWatchiOS` — the app.
- `DishWatchWidget` — the extension. Reads the App Group snapshot. Links no
  transport in v1.
- The provider seam is why this is cheap: `DishProvider` is one `async throws`
  method (`Model/DishProvider.swift`), and an iOS engine is another conformance.
  It was built for exactly this and has already survived one architecture
  reversal.

`Package.swift` declares `platforms: [.macOS(.v14)]` and one executable target;
that is the first edit and it is mechanical.

**Deployment target: iOS 18.** grpc-swift's TransportServices transport is
documented iOS 18+, and NIOPosix is the wrong stack on Darwin — so on B the
target is set by the transport, not by taste. Three major versions of back
support in late 2026 is generous for a first release of a LAN utility whose
users own a 2022-or-newer dish. If a real reason for iOS 17 turns up, it is a
G2 variant — measure NIOPosix against the dish before paying for it.

If B: the drift risk gets managed the way the Swift decoder contract already is
— golden fixtures generated from the Go implementation and run in Swift CI, the
`make contract` precedent. Fixtures delay drift rather than remove it; that
objection stands and is accepted.

## App Review

Both reviewers converged here, so treat it as settled.

- **`NSLocalNetworkUsageDescription` on the app**, not the extension, and phrased
  for a human: it reads status from your Starlink dish at `192.168.100.1`. Do
  not say gRPC.
- **No multicast entitlement.** This is plain unicast TCP. Do not port the Mac's
  entitlement assumptions, and do not add a dummy `NSBonjourServices` browse to
  force the prompt — the dish advertises none, and it is review-gray besides.
- **ATS: the two reviews disagree.** Codex says ATS does not govern raw
  Network.framework connections, so nothing is needed; Grok says add
  `NSAllowsLocalNetworking` because the dish is plaintext h2c. Both are right in
  different transports, which means G2 answers it for the transport we pick.
  Either way, never `NSAllowsArbitraryLoads`.
- **No background modes.** Not `fetch`-as-keepalive, not audio, not VoIP,
  not location. Guideline 2.5.4, and it would not work anyway. `BGAppRefresh`
  for opportunistic snapshots is legitimate; a keepalive dressed as one is not.
- **The real risk is guideline 4.2, not the hardware dependency.** A reviewer
  with no dish launches the app, sees nothing, and calls it thin. Accessory
  companions are a normal category (3.1.4), so the mitigation is a *designed*
  "no dish on this network" screen, a **labelled** Preview mode using
  `SampleProvider`, and review notes naming the IP, the Allow prompt and the
  Preview button. Preview must be user-facing and clearly marked — not hidden
  reviewer-only fake data, and never the default in Release. The Mac's
  `MissingHelperProvider` exists because animated 142.5 Mbps looks like a
  working product.
- **Trademark (5.2)** is higher-stakes here than for a notarized cask, because
  there is an official Starlink iOS app. Keep "Starlink" out of the App Store
  *name*; put it in the subtitle and description. No SpaceX marks in the icon.
- **Privacy:** local-only, no tracking, and no third-party geocoding from iOS —
  coordinates stay on device or are omitted. `PrivacyInfo.xcprivacy` and
  `ITSAppUsesNonExemptEncryption=false`, as on the Mac.
- Same developer account, and the same certificate problem noted for the Mac
  Store build.

## Explicitly out of scope

**A browser app / PWA.** Three stacked blockers, any one fatal. JavaScript
cannot speak gRPC — no access to HTTP/2 trailers — and the dish serves plaintext
gRPC, with grpc-web support unverified and probably absent. A page served over
HTTPS cannot fetch `http://192.168.100.1` (mixed content, no override on iOS).
A page served over plain HTTP on the LAN is not a secure context, so no service
worker, no offline cache, no install — a bookmark, not an app. Revisit only if a
probe shows the firmware answers grpc-web:

```sh
curl -sv -X POST http://192.168.100.1/SpaceX.API.Device.Device/Handle \
  -H 'content-type: application/grpc-web+proto' --data-binary @/dev/null
# try :80 and :9201 too
```

**Remote access** — Tailscale, a tunnel, or a box on the LAN serving JSON. It is
the only design that answers "is the dish up" while away from it, and it is a
different product with an infrastructure requirement. Its own brief, not a
section in this one.

## Phases

Phases 0 and 1 are the next stage and they run in parallel — 1 is a no-regret
refactor that is correct under either engine, so it does not wait on 0.

0. **Gates.** G1, then G2. G3 alongside. A week, mostly spent waiting on G4.
1. **Package split.** `DishWatchCore` out, Mac app still builds and ships, tests
   move. No behaviour change. Correct under A or B, so start it now.
2. **Engine**, whichever the gates pick, behind `DishProvider`.
3. **App, foreground only.** One screen, real data, the staleness doctrine
   applied from the first commit rather than retrofitted.
4. **The aiming screen.** The thing the phone is actually for.
5. **Widget + Control Center control**, shaped by G4's answer rather than hope.
6. **TestFlight**, then submission.

## Open questions

- **Reflection or a vendored proto, if B?** Runtime reflection ships no
  descriptors; a hand-written `.proto` reconstructed from fields we already
  decode is a different act from checking in extracted descriptors, but neither
  reviewer is a lawyer and the roadmap already flags redistribution as open.
  Worth a real opinion before the first upload. How hard reflection is in
  grpc-swift v2 — which is codegen-first — is uncosted.
- Is there any way to refresh *on joining the dish's Wi-Fi* without a background
  mode we cannot justify? Assume no until shown otherwise.
- Does the phone want its own state at all, or should it defer to a Mac that has
  been watching continuously when both are on the same network? That is the
  remote-access product in disguise — and also the only honest answer to "what
  was the dish doing while my phone was asleep".
- iPad: free, or a second layout problem? Probably free; verify before promising.
