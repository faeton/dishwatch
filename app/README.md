# DishWatch.app

Native macOS menu-bar app for the Starlink dish monitor — the GUI companion to
the `sl` CLI. Implements the design in
[`DishWatch.dc.html`](../docs/) (Claude Design project "Dishwatch status bar UI").

> Status: **live data wired.** The app shells out to `dishwatch json` (a CLI
> subcommand that emits a `Dashboard` JSON reusing the gRPC client, energy
> integrator, and power-bank state) and decodes it into `DishData`. It reflects
> exactly what `sl`/`dishwatch` sees — including power-bank state: with `sl pb`
> disabled (no anchor) the app stays in connection mode and shows no battery UI.
> If the `dishwatch` binary isn't found it falls back to `SampleProvider`.
>
> The App Store build will swap the subprocess for an in-process `dishkit`
> c-archive behind the same `DishProvider` protocol — see
> [`../docs/roadmap.md`](../docs/roadmap.md).

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
or the version string; none of those exist in the bare executable.** But note
the live-data bridge below does *not* work in a sandboxed bundle — see below.

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

Requires macOS 14+, Swift 6 / Xcode 26. The app finds the CLI via, in order:
`$DISHWATCH_BIN`, `~/Sites/dishwatch/bin/dishwatch`, `/opt/homebrew/bin`,
`/usr/local/bin`, then `dishwatch` on PATH. **Note:** a Homebrew-installed
`dishwatch` predating the `json` command won't work — rebuild/reinstall the CLI.

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

## Wiring live data (next)

Implement a `LiveProvider: DishProvider` that calls the Go `dishkit` c-archive
(`DishkitPoll(storageDir, addr) -> Dashboard JSON`) and decodes into `DishData`.
Swap it in at `AppState(provider:)`. Everything above the protocol stays as-is.
