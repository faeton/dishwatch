# v0.2.3 — the energy figures say over how long

Two watt-hour numbers now appear on the popover, a few points apart, covering
different windows. That is correct and it is confusing, so both explain
themselves on hover.

**The Observed block's energy** — hovering the `⚡ 103 Wh` gives:

> 103 Wh drawn over the 3h 22m this block covers — about 30.5 W on average.
> The figure under Power is the separate since-boot total.

**The Power cell's total** — hovering `251.9 Wh measured` gives:

> 251.9 Wh measured across 3h of samples — not the whole boot, because energy
> only accumulates while DishWatch is retrieving readings. The true since-boot
> figure is higher.

…and when the sample count and the total disagree, it says that instead of
offering an average it cannot support.

## Why there are two

They come from two accumulators over two windows. The Observed one is integrated
from exactly the samples that block describes; the Power one is a since-boot
total. Merging them would mean stating one figure for a span it does not cover —
the error v0.2.1 and v0.2.2 each fixed once. Explaining them is the honest way
out, so each says what it measures and over how long.
