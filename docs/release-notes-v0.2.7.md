# v0.2.7 — the throughput row gets its average

The history block showed a window statistic beside two of its three traces:

```
Ping ms   ~~~~~~~~~~~~~~~~   avg 49 ms
↓↑ Mbps   ~~~~~~~~~~~~~~~~
Power W   ~~~~~~~~~~~~~~~~   avg 46.4 W
```

The gap was deliberate and it was the wrong call. Mean throughput measures
utilization rather than link capability — an idle dish on a flawless link
averages a couple of Mbps, and a bare `avg 3` reads as a broken dish — so
`docs/macos-ui.md` ruled the figure out and left the slot empty. But emptiness
does not make that argument. With a statistic beside ping and power and a hole
beside throughput, the panel just asks *why is this row missing its number*.

It now reads:

```
↓↑ Mbps   ~~~~~~~~~~~~~~~~   avg ↓157 ↑11
```

One figure per direction, in the trace colours, over the window the three
buttons select. What makes the mean safe here is company, which is also the
narrowing of the old rule: the trace it summarizes is immediately to its left,
so the shape it flattens is on screen; the peak — the figure that does describe
what the link can do — is in the Observed footer two blocks down; and the
heading names the window. The rule still holds wherever a throughput mean would
appear without those three, which is every summary cell in the app.

## The details that make it honest

- **Computed from the traces the row drew**, not from `downAvg`/`upAvg` on the
  DTO. Same numbers, but reading the plotted series ties the figure to what is
  on screen: it follows 60s/5m/15m for free, and a direction whose ring the dish
  never sent contributes no number instead of a fabricated `↑0.0`.
- **Idle seconds count.** For ping and power a zero means *not measured* and the
  engine drops it; for throughput it is a real second in which nothing moved.
  Excluding those would answer "how fast while busy", which nobody asked and
  which flatters a bad link.
- **Non-finite samples do not.** One infinity in a sum takes the whole average
  with it — a sharper failure than the one `Spark.sample` already guards.
- **Scrubbing is unchanged**: press and drag still replaces the figure with the
  sample under the pointer. The `avg` word is what tells the two `↓n ↑n`
  readouts apart.
- The trailing column widened 60 → 82 pt for all three rows, so the charts keep
  a shared right edge and a row that loses its figure cannot shift the
  sparklines above it.

The landing page's panel replica carries the same row, since it is supposed to
show the panel the app actually ships.

## Also in this release

`make cask` renders `packaging/dishwatch-app.rb` into the Homebrew tap with the
version and the DMG's published SHA, instead of the cask being hand-copied.
v0.2.6 shipped with the tap's cask left at 0.2.5 and turned every nightly audit
red for days; that class of mistake is now a command rather than a memory.
