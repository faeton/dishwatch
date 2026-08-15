# v0.2.1 — the energy figure, said honestly and put where you can see it

A patch release for one number that was wrong in the CLI, understated in the
app, and effectively invisible in both.

## `avg 4724.1 W` is gone

The CLI's Energy line divided a since-boot watt-hour total by a sample count
that can restart, and published the result with complete confidence:

```
Energy 251.95 Wh   obs 3m 12s @ 4724.1 W · est 140735.3 Wh over 1d 5h 47m 27s
```

No dish draws 4.7 kW. Both figures came from two individually well-formed
numbers describing different spans — 251.95 Wh of measurements against a
192-second window.

The two counters are meant to advance together, and every branch that adds
joules also adds seconds. The guard exists anyway because `state.json` has more
than one writer: the bash `sl` shares the schema, and any older or stale build
on `$PATH` can write it too. A mean past what any dish can draw now means *the
pair is inconsistent*, and an inconsistent pair yields no average at all:

```
Energy 254.66 Wh   over 1d 5h 52m 31s
```

Refusing beats repairing — there is no way to know which of the two numbers is
the wrong one, so there is nothing to recompute.

## The app stops calling a partial total "since boot"

The Power cell read `90.3 Wh since boot` on a dish that had actually drawn
around 900 Wh. The accumulator only integrates samples it retrieved, so after
any gap it holds an under-count — and "since boot" is the one label that under-
count cannot carry.

It now says as much as the samples support, matching the three cases the CLI
picks between:

| Coverage | Reads |
|---|---|
| samples cover the boot | `894.2 Wh since boot` |
| partial, with a usable mean | `90.3 Wh over 3h · 30.1 W` |
| no honest denominator | `251.9 Wh measured` |

## Energy is a menu-bar field now

It had been in the app all along, as the smallest grey text on the panel. It is
a readout option, so you can put it where you will actually read it:

**Settings → Menu-bar readout → Energy used**

Off by default — adding it does not widen a bar you have already configured.

## Note for CLI + app users

The sandboxed app cannot reach `~/.cache/sl`, so it keeps its own accumulator in
its container. The CLI's energy total and the app's are therefore two separate
measurements of the same dish and will not agree. Everything else in
`~/.cache/sl` is still shared.
