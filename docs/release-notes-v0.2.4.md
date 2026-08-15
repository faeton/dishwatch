# v0.2.4 — one energy figure, where you can read it

v0.2.3 explained the energy numbers with hover tooltips. Those tooltips never
appeared: `.help()` does not reliably fire inside a menu-bar panel, because the
panel is non-activating and AppKit's tooltip tracking mostly does not run there.

So the explanation is on screen instead:

```
OBSERVED 2H 14M
ping 29 · 92% clean · peak ↓186 ↑41 · 23.8 W
3.9 GB ↓ · 572.2 MB ↑ · ⚡ 53 Wh in 2h 14m
```

## The Power cell stops carrying an energy total

It had one for two releases and it did not belong there. Three things were
wrong with it at once:

- The cell is where you look for **watts now**, not watt-hours since.
- It is half a popover wide, so the honest three-case string overflowed and
  shipped visibly truncated: `115.1 Wh over 3h 44m · 30....`
- Once the Observed block grew its own energy figure, the two sat a few points
  apart showing near-identical numbers over subtly different windows.

No tooltip fixes that — the second number was the problem. The cell now shows
the session **peak draw**, which nothing else on screen was showing:

```
POWER
23.4 W
peak 48.1 W
```

Cold start is unchanged: before there is an Observed block, the cell still
carries the energy line so the figure is never simply absent.
