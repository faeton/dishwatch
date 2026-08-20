# dishwatch

Turns your Starlink dish's local gRPC API into a live terminal dashboard —
connection, signal, aim, GPS, power draw, and sparklines for ping, drop,
throughput, and watts over the dish's own history ring (60 s by default, up to
15 min). Logs reboots and dropouts so you can tell after the fact whether the
dish rebooted or your Wi-Fi died.

Tested on **Starlink Mini** (`mini1_panda_prod1`, fw `2026.04.07.mr77639.1`).
Other generations probably work but some fields may differ.

## Two implementations

The repo contains the tool twice:

- **Go** (`main.go`, `*.go`, `internal/…`) — a single statically-linked binary,
  zero runtime deps, ~12 MB (~5 MB gzipped), what ships via `brew install
  dishwatch`. This is what you should use.
- **Bash** (`sl`) — the original 881-line script that needs `grpcurl` + `jq` at
  runtime. Kept in the repo as a reference implementation and a fallback for
  anywhere Homebrew isn't available (a random Linux box, a recovery shell).
  Still works; not installed by the brew formula. It takes the state lock via
  `lockf(1)` on macOS and `flock(1)` on Linux, and parses timestamps with
  whichever of BSD or GNU `date` it finds — but the Go build is the one that is
  actually tested on both platforms, so treat the script as a fallback rather
  than an equivalent.

Both read and write the **same on-disk state** in `~/.cache/sl/`
(`state.json`, `pb.json`, `events.log`, `geo_*.txt`) with identical schemas, so
you can run either — even alternate between them — and the energy integrator,
event log, and power-bank anchor all stay consistent. The one exception is
`stats.json` (the `Observed` accumulator), which only the Go version maintains:
bash rebuilds `state.json` from scratch on every write, so a shared file would
lose the Go-only fields the moment `sl` ran.

Feature parity is 1:1 for everything the bash script implements. The Go build
is a strict superset: `json` (a machine-readable snapshot) and `helper` (the
long-lived engine the macOS app supervises) have no bash equivalent, and won't
get one — they exist to serve the app, not a terminal. If the two ever diverge
elsewhere, the Go version is canonical and the bash version will fall behind.

## Install

**The menu-bar app** — macOS 14+, universal, notarized:

```sh
brew install --cask faeton/tap/dishwatch-app
```

or download the DMG from [the latest release](https://github.com/faeton/dishwatch/releases/latest).

**The CLI** — macOS and Linux, arm64 and x86_64:

```sh
brew install faeton/tap/dishwatch
```

Installs two binaries: `dishwatch` (canonical) and `sl` (shorthand symlink, all
docs/examples below use `sl`). Make sure the machine is on the Starlink network
(`192.168.100.1` must be reachable).

Two tokens, not one, and the distinction matters: a tap may hold a formula and
a cask under the same name, but Homebrew resolves that by preferring the
formula and only warning — so a shared token would install the CLI and never
mention the app. The CLI stays a formula rather than becoming a cask because
casks quarantine everything they extract, and these binaries are unsigned.

<https://dishwatch.github.io>

## Usage

```
sl                    # one-shot status (plain text)
sl dash | sl d        # pretty one-shot dashboard
sl watch | sl w [s]   # live dashboard, press q to quit (default 3s refresh)
sl events [N]         # tail the event log (reboots, dropouts, state changes)
sl speed              # LAN RTT to dish + macOS networkQuality internet test
sl history            # 60s rolling means from the dish
sl location           # raw GPS (if enabled in the Starlink app)
sl map                # obstruction map summary
sl reboot             # reboot the dish
sl pb [pct [wh] | -]  # anchor power-bank % (and optional Wh); `-` clears; no args = show
sl raw '<json>'       # send an arbitrary gRPC request
sl json               # one snapshot as JSON (what the macOS app consumes)
sl json --window 900   # …with 15 min of sparkline history instead of 60 s (max = the dish's ring)
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

## Knowing which dish you have

`sl status` and `sl dash` gloss the raw model string, and the macOS app puts the
same thing in its header beside a drawn dish:

```
Hardware:     rev3_proto2  (Standard Gen2, self-aiming)   class=CONSUMER …
```

The gloss answers the question the raw string does not: **is this thing
motorized, or do I aim it myself?** The dish will not say directly —
`dish_get_context`, which carries the actuator flag, is `PermissionDenied` to an
unauthenticated caller and `get_status` has no such field — so it is inferred
from the model, which is sound because the motors are a property of the model
and nothing else:

| Model string | Dish | Aim |
|---|---|---|
| `rev1_*` | Round Gen1 | self-aiming |
| `rev2_*`, `rev3_*` | Standard Gen2 (rectangular) | self-aiming |
| `rev4_*` | Standard Gen3 | by hand |
| `mini1_*` | Mini | by hand |
| `hp*` | flat High Performance | by hand |

Anything else keeps its raw string and gets no gloss at all — a guess here sends
someone up a mast for nothing. The table is `classifyHardware` in `dashboard.go`.

If you want to confirm it against the hardware rather than the table,
`sl raw '{"dish_stow":{"unstow":true}}'` returns OK on a motorized dish (a
no-op when it is already unstowed) and `HAS_ACTUATORS_NO` on one without motors.
It does command the actuators, so don't run it on a dish that is stowed unless
you mean to unfold it.

## Files

- `~/.cache/sl/state.json` — last successful snapshot (includes the energy
  accumulator and `obsSeconds`, the count of power samples actually integrated —
  the denominator for the average, so that a gap the dish buffered past cannot
  dilute it)
- `~/.cache/sl/stats.json` — observed-sample accumulator behind the `Observed`
  section (Go only — bash rewrites `state.json` wholesale, so this lives apart)
- `~/.cache/sl/pb.json` — power-bank anchor (if set via `sl pb <pct>`)
- `~/.cache/sl/events.log` — append-only transition log (auto-trimmed to 2000 lines)
- `~/.cache/sl/geo_<lat>_<lon>.txt` — cached Nominatim lookups

## Releasing

Releases are cut locally with [GoReleaser](https://goreleaser.com) and published
to GitHub + the [`faeton/homebrew-tap`](https://github.com/faeton/homebrew-tap)
repo. The CLI goes in one step; the menu-bar app's cask needs a second, because
goreleaser can only maintain taps for artifacts it built and the notarized DMG
is not one of them — see [docs/release.md](docs/release.md).

```sh
# prereqs (one-time)
brew install goreleaser
gh auth login                       # needs repo write scope

# cut a release
git tag v0.1.2                      # bump per semver
git push --tags

# 1. the notarized universal DMG, which the release embeds. Not optional:
#    goreleaser attaches it via extra_files and fails if it is missing.
cd app && make notarize CODESIGN_ID="Developer ID Application: ... (TEAMID)" UNIVERSAL=1 && cd ..

# 2. everything else — tarballs, the GitHub Release, the DMG, AND both tap
#    files (Formula/dishwatch.rb via goreleaser, Casks/dishwatch-app.rb via
#    the `cask` target it now calls for you).
make publish

# local dry-runs (no push, artifacts into dist/)
make publish-dry
make cask-dry
```

`make publish` runs `goreleaser release --clean` with `GITHUB_TOKEN=$(gh auth token)`,
then `make cask`. goreleaser builds darwin/linux × amd64/arm64 (~5 MB gzipped
each), uploads tarballs and the DMG to a new GitHub Release on
`faeton/dishwatch`, and commits an updated `Formula/dishwatch.rb` to
`faeton/homebrew-tap` so `brew install dishwatch` picks up the new version after
`brew update`.

The `cask` half is not cosmetic. goreleaser maintains the formula but knows
nothing about `Casks/dishwatch-app.rb`, which is how the app is delivered — and
the tap's nightly `brew audit --cask --online --strict` compares that cask
against livecheck, so a release that updates only the formula turns a different
repository red every night until someone notices. That was missed at v0.2.6 and
again at v0.2.8, which is why the two are one command now. Run `make cask` alone
only for a cask-only change that is not tied to a release.

Config lives in `.goreleaser.yaml`. To change what's shipped (add a build target,
tweak the description, etc.) edit that file and re-run `make publish-dry` to
preview the generated formula in `dist/homebrew/Formula/dishwatch.rb`.

## Roadmap

A native macOS menu-bar app (App Store first) is planned — see
[`docs/roadmap.md`](docs/roadmap.md) for the architecture and phased plan, and
[`docs/optimizations.md`](docs/optimizations.md) for the review findings and
cleanup backlog that Phase 0 works through.

## License

MIT
