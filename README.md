# dishwatch

Tiny single-file bash CLI that turns your Starlink dish's local gRPC API into a
live terminal dashboard — connection, signal, aim, GPS, power draw, and 60-second
sparklines for ping, drop, throughput, and watts. Logs reboots and dropouts so
you can tell after the fact whether the dish rebooted or your Wi-Fi died.

Tested on **Starlink Mini** (`mini1_panda_prod1`, fw `2026.04.07.mr77639.1`).
Other generations probably work but some fields may differ.

## Install

```sh
brew tap faeton/tap
brew install dishwatch
```

Installs two binaries: `dishwatch` (canonical) and `sl` (shorthand symlink, all
docs/examples below use `sl`). Make sure your Mac is on the Starlink network
(`192.168.100.1` must be reachable).

## Usage

```
sl                    # one-shot status (plain text)
sl dash | sl d        # pretty one-shot dashboard
sl watch | sl w [s]   # live dashboard, press q to quit (default 5s refresh)
sl events [N]         # tail the event log (reboots, dropouts, state changes)
sl speed              # LAN RTT to dish + macOS networkQuality internet test
sl history            # 60s rolling means from the dish
sl location           # raw GPS (if enabled in the Starlink app)
sl map                # obstruction map summary
sl reboot             # reboot the dish
sl pb [pct [wh] | -]  # anchor power-bank % (and optional Wh); `-` clears; no args = show
sl raw '<json>'       # send an arbitrary gRPC request
```

### Watch mode

Alt-screen, flicker-free refresh. Every tick writes a snapshot to
`~/.cache/sl/state.json` and diffs it against the previous one, logging to
`~/.cache/sl/events.log`:

- `REBOOT` — bootcount went up, or uptime ran backwards
- `GAP Ns — dish rebooted during gap` vs `dish stayed up (local/Wi-Fi side)`
  — so when your Wi-Fi drops and you reconnect, you can tell who was at fault
- `STATE`, `SERVICE`, `READY`, `ALERTS` transitions
- `UNREACH` when the dish API doesn't answer (rate-limited)

If the API is unreachable, `sl dash` shows a frozen last-known snapshot plus the
last 10 events — useful for diagnosing what happened after your connection
comes back.

## What's shown on the dashboard

- **Connection**: state, ready flags, live ping + drop, active alerts, bandwidth limits
- **Signal**: 0–100 score synthesised from ping/drop/obstruction (Mini firmware
  doesn't expose numeric SNR; only a `isSnrAboveNoiseFloor` boolean), obstruction
  percentage, valid time, blocked time
- **Aim**: azimuth / elevation / tilt, attitude estimator state, and the angles the
  dish *wants* (for placement)
- **Location**: GPS lock, sat count, reverse-geocoded town/region via OpenStreetMap
  Nominatim (cached per ~1 km cell in `~/.cache/sl/`)
- **Link**: live power draw (W), ethernet speed, service state, firmware update state
- **Last 60s sparklines**: ping, drop, down/up throughput, power
- **Energy since boot**: Wh integrated from the dish's `powerIn` ring (1 Hz, 15 min
  deep). Bootstraps from the ring on first tick, then increments on each
  refresh. Resets when the dish reboots. Shows `since boot` once the observation
  window covers the full uptime; otherwise shows observed Wh plus a linear
  extrapolation to total.
- **Power-bank depletion** (opt-in, only shown when `SL_PB_WH` is set): with a
  Wh-per-full-charge calibration (see below), shows % remaining, Wh remaining,
  and estimated time to 0% at the current average draw.

## Power-bank tracking

The Bank row is hidden unless you either set an anchor with a Wh capacity or
export `SL_PB_WH` — if you're running off mains, leave both unset. The easiest
path is to anchor both pct and bank capacity in one command before starting
`sl watch`:

```sh
sl pb 100 67    # "bank is at 100% right now, full charge = 67 Wh"
sl pb 44        # update current %, keep existing Wh
sl pb           # show the active anchor
sl pb -         # clear the anchor (hides the Bank row unless SL_PB_WH is set)
```

The anchor (pct + wh) lives in `~/.cache/sl/pb.json` and survives across
sessions. As a fallback, env vars still work:

```sh
export SL_PB_WH=67          # dish-input Wh per full charge (enables Bank row)
export SL_PB_START_PCT=100  # bank % when the dish booted (default: 100)
```

The anchor auto-invalidates on dish reboot (bootcount mismatch), falling back
to the `SL_PB_START_PCT` assumption until you set a new one.

### Calibrating `SL_PB_WH`

1. Start `sl watch` with a freshly-charged bank. Note the bank %.
2. Let the dish run for 20+ minutes with mixed usage.
3. Note the new bank % and the `Energy X.XX Wh` from the dashboard.
4. `SL_PB_WH = Wh_consumed / (pct_drop / 100)` — e.g. 7.37 Wh over 11% drop → 67 Wh.

Wider `Δ%` shrinks fuel-gauge quantization error. Stay in the 30–80% mid-range
where gauges are most linear.

## Limitations

These are genuine dish/firmware limitations, not missing features:

- **Wi-Fi clients list** — `wifi_get_clients` and friends are `Unimplemented` on
  Mini firmware to unauthenticated callers. The iOS app sees them because it
  authenticates with your SpaceX account; the CLI can't do that without the
  app's signing key.
- **Dish-side speedtest** — same story; `start_speedtest` is `Unimplemented`.
  `sl speed` runs a Mac-side `networkQuality` instead, which measures the same
  thing from your end.
- **Numeric SNR in dB** — not exposed on Mini firmware. The dashboard synthesises
  a 0–100 Signal score from ping, drop, and obstruction.
- **Temperature / voltage / current** — not exposed on Mini. Only `powerIn` (W)
  in the history ring.
- **Stow / unstow** — the Mini has no actuators (`HAS_ACTUATORS_NO`), so there's
  nothing to stow.

## Files

- `~/.cache/sl/state.json` — last successful snapshot (includes energy accumulator)
- `~/.cache/sl/pb.json` — power-bank anchor (if set via `sl pb <pct>`)
- `~/.cache/sl/events.log` — append-only transition log (auto-trimmed to 2000 lines)
- `~/.cache/sl/geo_<lat>_<lon>.txt` — cached Nominatim lookups

## Releasing

Releases are cut locally with [GoReleaser](https://goreleaser.com) and published
to GitHub + the [`faeton/homebrew-tap`](https://github.com/faeton/homebrew-tap)
repo in one step.

```sh
# prereqs (one-time)
brew install goreleaser
gh auth login                       # needs repo write scope

# cut a release
git tag v0.1.2                      # bump per semver
git push --tags
make publish                        # builds, uploads, pushes formula

# local dry-run (no push, artifacts into dist/)
make publish-dry
```

`make publish` runs `goreleaser release --clean` with `GITHUB_TOKEN=$(gh auth token)`.
It builds darwin/linux × amd64/arm64 (~5 MB gzipped each), uploads tarballs to a
new GitHub Release on `faeton/dishwatch`, and commits an updated
`Formula/dishwatch.rb` to `faeton/homebrew-tap` so `brew install dishwatch` picks
up the new version after `brew update`.

Config lives in `.goreleaser.yaml`. To change what's shipped (add a build target,
tweak the description, etc.) edit that file and re-run `make publish-dry` to
preview the generated formula in `dist/homebrew/Formula/dishwatch.rb`.

## License

MIT
