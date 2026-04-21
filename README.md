# dishwatch

Tiny single-file bash CLI that turns your Starlink dish's local gRPC API into a
live terminal dashboard — connection, signal, aim, GPS, power draw, and 60-second
sparklines for ping, drop, throughput, and watts. Logs reboots and dropouts so
you can tell after the fact whether the dish rebooted or your Wi-Fi died.

Tested on **Starlink Mini** (`mini1_panda_prod1`, fw `2026.04.07.mr77639.1`).
Other generations probably work but some fields may differ.

## Install

```sh
brew install grpcurl jq
git clone https://github.com/<you>/dishwatch.git
ln -s "$PWD/dishwatch/sl" ~/.local/bin/sl   # or copy it
```

Make sure your Mac is on the Starlink network (`192.168.100.1` must be reachable).

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

- `sl` — the whole tool. ~500 lines of bash, depends only on `grpcurl` and `jq`.
- `~/.cache/sl/state.json` — last successful snapshot
- `~/.cache/sl/events.log` — append-only transition log (auto-trimmed to 2000 lines)
- `~/.cache/sl/geo_<lat>_<lon>.txt` — cached Nominatim lookups

## License

MIT
