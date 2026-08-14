# v0.1.3 — the Mac app

The first release with a **macOS menu-bar app**, not just the CLI. Notarized by
Apple, universal (Apple Silicon and Intel), and it talks to your dish directly —
nothing leaves your network.

## DishWatch.app

Download `DishWatch-0.1.3.dmg`, drag it to Applications, launch it — or:

```
brew install --cask faeton/tap/dishwatch-app
```

It lives in the menu bar; there is no Dock icon and no window to manage.

- Signal, latency, throughput and power at a glance, updated every second
- Obstruction and outage history from the dish's own 15-minute rings
- Energy and power-bank tracking, with an anchor you set once
- Reboot the dish from the menu

It is sandboxed and notarized, so it installs without warnings. The engine that
speaks to the dish is a restricted build with no shell-outs, no arbitrary RPC
verb and no third-party geocoder.

**Requires macOS 14 or later.**

## The CLI

Unchanged in behaviour, but substantially more careful underneath.

```
brew install faeton/tap/dishwatch
```

## Fixes worth naming

**Wrong power figures after upgrading.** The energy accumulator paired
accumulated watt-hours with a wall-clock denominator. On the first poll after
upgrading a saved snapshot, that produced readings like 5802 W for a 20 W dish —
and presented them as a confident since-boot average. An epoch whose sample
count cannot be reconstructed now reports no average at all until the next
reboot, rather than a fabricated one.

**"Live" no longer means "the call returned".** The dashboard could show
**Offline** in the hero while the footer read **live**, over metrics restored
from a snapshot of arbitrary age. Transport success and link state are different
questions and the UI answers both now.

**A stalled dish no longer wedges the engine.** Reflection discovery had no
deadline, oversized replies could end the process, and SIGTERM was unhandled.

**Statistics no longer drift across a gap.** A cursor rewind, a reboot, or a
poll gap larger than the ring used to fold bad data into the accumulators;
outage runs spanning an unmeasured gap were reported as one long outage.

## Known limits

- Local Network permission behaviour on a **brand-new user account** is untested.
  It has never prompted here and works, but that is one machine.
- The Intel slice is built and verified present; it has not been executed.
- CLI binaries downloaded from this page (rather than via Homebrew) are unsigned
  and Gatekeeper will block them. Use Homebrew, or the app.

Not affiliated with SpaceX or Starlink.
