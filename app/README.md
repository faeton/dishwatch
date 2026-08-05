# DishWatch.app

Native macOS menu-bar app for the Starlink dish monitor — the GUI companion to
the `sl` CLI. Implements the design in
[`DishWatch.dc.html`](../docs/) (Claude Design project "Dishwatch status bar UI").

> Status: **live data through an embedded helper.** The app supervises one
> long-lived `dishwatch helper` child that holds the gRPC connection and answers
> JSON-line requests, so the app reflects exactly what `sl`/`dishwatch` sees —
> including power-bank state: with no anchor set the app stays in connection
> mode and shows no battery UI. With no helper found it falls back to
> `SampleProvider` and says so in the footer.
>
> This is the settled App Store architecture, chosen over an in-process cgo
> `c-archive` and over a pure-Swift client — see
> [`../docs/roadmap.md`](../docs/roadmap.md) for the reasoning and the numbers.

## Build & run

```sh
# 1. Build the CLI with the `json` subcommand the app calls for live data:
(cd .. && CGO_ENABLED=0 go build -o bin/dishwatch .)

# 2a. Bare executable — fastest loop, no bundle:
cd app
swift build
./.build/debug/DishWatch        # appears in the menu bar (accessory app, no Dock icon)

# 2b. Or the real thing — signed, sandboxed .app:
make run
```

**Use `make run` for anything involving the sandbox, signing, launch-at-login
or the version string** — none of those exist in the bare executable, and only
the bundle carries the embedded helper.

| Target | What it does |
|---|---|
| `make app` | build, assemble the bundle, ad-hoc sign, sandboxed |
| `make app SANDBOX=0` | same without the sandbox — the A/B control |
| `make app CODESIGN_ID=...` | sign with a real identity |
| `make run` | build and launch via LaunchServices |
| `make icon` | regenerate `Resources/AppIcon.icns` from the app's own glyph |
| `make test` | the Swift tests |

### How live data works

`HelperProvider` starts one `dishwatch helper` child and keeps it, sending
newline-delimited JSON over pipes. `make app` copies `../bin/dishwatch` into
`Contents/MacOS/dishwatch-helper` and signs it with
`Resources/helper.entitlements` — `app-sandbox` plus **`inherit`**, which is
Apple's supported pattern for an embedded command-line tool: the child inherits
the containing app's sandbox rather than carrying its own profile. That is why
the *app* needs `network.client` even though the app process never opens the
dish socket itself.

One consequence that will confuse you once: **the bundled helper cannot be run
from a terminal.** A binary carrying `inherit` must be spawned by a sandboxed
parent, so running `Contents/MacOS/dishwatch-helper` directly dies with
SIGTRAP. That is correct. Use `../bin/dishwatch helper` to poke at the protocol
by hand.

The old `LiveProvider` (spawn `dishwatch json` per poll) is still there but only
as a fallback for an unbundled `swift run`. It cannot work sandboxed — the
sandbox denies access to a CLI installed outside the bundle — and pays ~700 ms
per poll against the helper's ~274 ms.

### Check the bundle end to end

```sh
make app
open -W .build/DishWatch.app \
  --env DISHWATCH_NETPROBE=~/Library/Containers/com.faeton.dishwatch/Data/netprobe.txt
cat ~/Library/Containers/com.faeton.dishwatch/Data/netprobe.txt
```

Reports bundle id, version, `SMAppService` status, whether the sandbox is
actually on, and whether the dish is reachable via both `NWConnection` and a
raw BSD socket. Launch it with `open`, not by running the Mach-O directly:
from a shell, Terminal is the responsible process for TCC and the app inherits
its permissions, so the result tells you nothing. The probe says which case it
was in.

Requires macOS 14+, Swift 6 / Xcode 26. A bundled app uses
`Contents/MacOS/dishwatch-helper` and nothing else. An unbundled debug build
falls back to `$DISHWATCH_BIN` then `~/Sites/dishwatch/bin/dishwatch`; both
lookups are `#if DEBUG`, so a shipped app can never run a binary it found lying
around.

### Verify wiring without clicking

```sh
DISHWATCH_PROBE=1 ./.build/debug/DishWatch   # polls live once, prints decoded fields, exits
```

### Snapshot the screens (no clicking)

```sh
DISHWATCH_RENDER=/tmp/dwshots ./.build/debug/DishWatch
```

Rasterizes each screen to a PNG via `ImageRenderer` and exits. (Native controls
— `Slider`/`Toggle`/`Picker` — don't rasterize faithfully headless; run the app
to see them properly.)

## Structure

| File | Screen / role |
|------|---------------|
| `DishWatchApp.swift` | `@main`, `MenuBarExtra` (window style), accessory `AppDelegate` |
| `Theme.swift` | design tokens — cyan/amber/green/red, panel gradient, score→color |
| `Model/DishData.swift` | snapshot DTO (mirrors the Go `model.Dashboard`) + `IconMode` |
| `Model/DishProvider.swift` | `DishProvider` protocol + `SampleProvider` (mockup numbers) |
| `Model/HelperProvider.swift` | supervises the embedded helper; JSON-line protocol + framing |
| `Model/LiveProvider.swift` | legacy spawn-per-poll bridge, unbundled dev only |
| `Model/AppState.swift` | `@MainActor ObservableObject`: poll timer + persisted settings |
| `Views/Components.swift` | `Spark`, `SignalGauge`, `SignalBars`, `BatteryGlyph`, `DishArcGlyph`, buttons |
| `Views/MenuBarIcon.swift` | the status-item glyph (resolves `IconMode`, `.auto`) |
| `Views/PopoverView.swift` | routes mains vs battery |
| `Views/ConnectedPopover.swift` | **A** — connected, on mains |
| `Views/BatteryPopover.swift` | **B** — power-bank hero |
| `Views/CompactWidget.swift` | **C** — always-on-top pinned widget |
| `Views/BatterySetupSheet.swift` | battery setup → maps to `sl pb <pct> <wh>` |
| `Views/SettingsView.swift` | icon picker + behaviour toggles |
| `Render.swift` | headless PNG snapshot mode + the 1024 app-icon source |
| `NetProbe.swift` | Phase 2 spike — bundle health + dish reachability via two stacks |
| `Resources/` | `Info.plist`, entitlements (sandboxed + the unsandboxed control), `AppIcon.icns` |
| `Makefile` | assembles and signs the `.app` around the SwiftPM binary |
| `Tests/` | decode contract + a golden fixture from the live CLI |

## Next

Live data is wired. What remains before this is shippable, in order:

1. **Adaptive polling.** The app still polls at a fixed interval. Target is
   5–15 s idle, 1–2 s while the popover or pinned panel is visible, backing off
   on Low Power Mode and screen lock. The helper makes this cheap — there is no
   longer a per-poll dial to amortise.
2. **Split the RPCs.** The icon needs `get_status` only; `get_history` is the
   expensive one and is only needed when sparklines, energy or bank are on
   screen.
3. **The `Observed` footer** (`../docs/macos-ui.md`). The decode contract is
   done and tested; the view is not built.
4. **Store prep** — a real signing identity, MAS entitlements, and cutting the
   dev scaffolding listed in the roadmap.
