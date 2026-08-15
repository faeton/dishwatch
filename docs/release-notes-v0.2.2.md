# v0.2.2 — energy used, on the line where the other totals live

v0.2.1 made the energy figure honest. It was still in the wrong place: a small
grey sub-label under Power, which is where you look for *watts now*, not for
*watt-hours since*.

It now sits with the other session totals, in the Observed block:

```
OBSERVED 3H 22M
ping 53 · 99% clean · peak ↓247 ↑32 · 30.5 W
7.2 GB ↓ · 2.6 GB ↑ · ⚡ 103 Wh
```

`sl dash` gains the same figure on its Observed Power line:

```
Power  avg 31.4 W · peak 64.0 W · 267.6 Wh used
```

## It is that block's own energy, not the since-boot total

The number comes from the session accumulator's own watt-second sum, integrated
across exactly the samples the rest of the block describes — not from
`energyWhSinceBoot`, which is a separate accumulator over a separate window.

That distinction is the whole reason this took a new field rather than reusing
the one already on screen. Putting a since-boot total on a line headed
`OBSERVED 3H 22M` would state a figure for a span it does not cover, which is
the same error v0.2.1 fixed in the Power cell.

Being a sum of watt-seconds, it is an exact integration rather than an average
multiplied by a duration — the two differ whenever the dish reported no power
for part of the window.

## Also

The energy line under Power stays, still honest about its own coverage. Two
figures answering two questions, each on the surface that asks it.
