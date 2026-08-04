# Optimizations & known issues

> Status: **review findings, not yet applied.** From a code review on 2026-06-25,
> corroborated by an independent Grok consult that timed the live dish
> (~630ms cold one-shot, ~110ms warm; `sl dash` ~210ms). Verify each still
> applies before acting. These feed Phase 0 of the [roadmap](roadmap.md).

## Correctness bugs (fix regardless of the app)

- [ ] **watch.go reconnect data race** (~line 119). A background goroutine writes
  `c`/`dialErr` while the main `select` loop reads them. `go build -race`
  confirms. Fix with a channel-fed reconnect or a mutex.
- [ ] **No file lock on `state.json`.** Two `sl` processes (e.g. `sl pb` during
  `sl watch`) can consume the same `lastCurrent` cursor and **double-count
  energy**. Add `flock`/lockfile; the in-process app or a daemon fixes it
  structurally.
- [ ] **First-observation energy undercount** in `dash.go integrateEnergy`. A
  non-reboot first poll sets the cursor but integrates zero history; bootstrap
  with `min(uptime, ringLen, cur)` like the reboot path does.
- [ ] **No tests anywhere.** `integrateEnergy` and `History.LastN/Latest` are pure
  and the most error-prone code — add table tests (reboot mid-ring, gap > ring,
  cursor jump, all-zero `powerIn`) before refactoring.

## Performance

- [ ] **Reflection + 2s blocking dial on every one-shot.** `grpc.DialContext` +
  `WithBlock` are deprecated → `grpc.NewClient` with a 200–500ms LAN timeout. The
  in-process app / daemon removes per-command dial entirely.
- [ ] **`grpcreflect` client never closed** (minor leak in watch mode).
- [ ] **`geo.Reverse` blocks the render path** (`dash.go` ~368). Nominatim can take
  3s and stalls the watch spinner; geocode async, show coords until the label
  arrives.
- [ ] **`renderEnergy` re-reads `state.json`** that `snapshotAndLog` just wrote —
  pass the snapshot through instead of re-reading.
- [ ] **(Optional) Vendor the `SpaceX.API.Device` proto.** Drops reflection
  entirely and removes the `protojson` → `json` double-hop in `client.go Call()`.
  Secondary latency win, real maintainability/correctness win. Keep the
  "decode only rendered fields / ignore unknowns" discipline — firmware updates
  add and rename fields.

## Cross-platform landmines

- [ ] **Cache dir** — `~/.cache/sl` is hardcoded. `os.UserCacheDir()` is correct
  everywhere (`~/Library/Caches` on macOS, `%LocalAppData%` on Windows, respects
  `XDG_CACHE_HOME` on Linux). Trade-off: breaks on-disk state-sharing with the
  bash `sl` on macOS — acceptable for the app, which sandboxes anyway.
- [ ] **Speed test** — `networkQuality` is macOS-only and `ping -W` differs across
  BSD/GNU/Windows. Abstract behind an `internal/speed` interface; do LAN RTT in
  Go for portability (and the sandbox can't shell out at all).

## Structure cleanup

- [ ] **Energy integrator lives in the CLI layer.** `integrateEnergy` /
  `snapshotAndLog` / `signalScore` are domain logic stranded in `dash.go`; move to
  `internal/model` + `internal/service` (see [roadmap](roadmap.md)).
- [ ] **`renderBank` `init()` indirection** (pb.go ↔ dash.go) is a link-time dodge
  around an import cycle. Once logic leaves `dash.go` the cycle dissolves — call
  `pb` directly and delete the indirection.
