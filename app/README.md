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

# 2. Build & run the app:
cd app
swift build
./.build/debug/DishWatch        # appears in the menu bar (accessory app, no Dock icon)
```

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
| `Render.swift` | headless PNG snapshot mode |

## Wiring live data (next)

Implement a `LiveProvider: DishProvider` that calls the Go `dishkit` c-archive
(`DishkitPoll(storageDir, addr) -> Dashboard JSON`) and decodes into `DishData`.
Swap it in at `AppState(provider:)`. Everything above the protocol stays as-is.
