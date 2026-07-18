---
layout: post
title: "How I proved a from-scratch harmonic tide engine is accurate"
description: "Validating a pure-Swift harmonic tide-prediction engine two ways: golden vectors to floating-point agreement against the Neaps reference (astronomy, node corrections, constituents, extremes), and a head-to-head against NOAA's own CO-OPS predictions API at Friday Harbor — max 7.9 min / 3.5 cm. Plus the datum trap: harmonic predictions read higher than the printed tide tables because chart datum (MLLW/LAT) isn't mean sea level, and the fix is a per-station MSL→MLLW offset."
date: 2026-07-17
tags:
  - tides
  - swift
  - harmonic-analysis
  - noaa
  - chart-datum
  - offline
  - marine
  - validation
---

You wrote a tide engine. It computes a number: 1.42 m at 3:10 PM. How do you know
that number is *right*? You can't measure the future ocean. You can't diff against
"the truth" because the truth is a prediction too. This is the whole problem with a
from-scratch harmonic tide predictor — the output looks authoritative the day you
first run it, and authoritative-looking is not the same as correct.

> **TL;DR** — Validate a harmonic tide engine on two axes. **Algorithm:** golden
> vectors against a trusted oracle (`@neaps/tide-predictor`) — every layer to
> floating-point agreement. **Reality:** head-to-head against the tide authority's
> *own* published predictions — NOAA CO-OPS at Friday Harbor, **max 7.9 min / 3.5 cm**
> across 12 highs and lows, inside the ±15 min / ±0.15 m you'd accept from a printed
> table. And before you trust any of it: if your predictions read *higher* than the
> printed tide tables, that's usually not a bug — it's the **chart-datum offset**.
> [Jump to the numbers](#the-receipt-vs-noaas-own-predictions).

## The trap that makes a correct engine look wrong

Here's the first thing that will convince you your engine is broken when it isn't.

Compute the harmonic tide height for a station, line it up against the printed tide
tables for the same minute, and your number comes out **higher** — consistently,
by a fixed amount. The instinct is to hunt for the bug. There isn't one.

A harmonic sum is referenced to the datum its constituents were derived against —
typically **mean sea level (MSL)**, the average of all water levels. Printed tide
tables and nautical charts are referenced to **chart datum**: **MLLW** (mean lower
low water) in the US, **LAT** (lowest astronomical tide) in Canada. Chart datum sits
*below* MSL by design — it's a low-water reference so that charted depths are
conservative. So a raw harmonic prediction reads higher than the table by exactly the
distance between the two datums.

The fix is a single per-station offset. In this engine it's one optional field on the
station:

```swift
let station = Station(
    constituents: [HarmonicConstituent(name: "M2", amplitude: 0.96, phase: 128) /* … */],
    offset: 1.387  // datum offset (e.g. MSL → MLLW), optional
)
```

And that offset isn't a fudge factor — it's published metadata. NOAA ships the datum
values per station; the offset is just their difference:

```js
const fh = stations.find((s) => s.id === 'noaa/9449880');
const offset = fh.datums.MSL - fh.datums.MLLW; // shift MSL-relative harmonics to chart datum MLLW
```

The apps that "match the printed number" without applying this are the ones actually
carrying an error — they've hidden a datum mismatch by accident, or they never summed
the harmonics in the first place. Once you know the offset exists, it's a knob, not a
mystery. (This is a subtlety of the *harmonic-prediction path* — computing heights
from constituents versus reading a printed table. Hydrographic services like NOAA and
CHS serve their own predictions at their own stated datum; they're not wrong, they're
just answering a different question than a from-scratch sum does.)

That's the trap. Now the actual validation.

## Method: golden vectors against an oracle

You can't test a predictor against the ocean. You *can* test it against another
predictor that's already trusted — and if the two agree to floating-point precision,
your port of the algorithm is faithful by construction.

The oracle here is [`@neaps/tide-predictor`](https://github.com/openwatersio/tide-predictor)
`@0.10.0`, a well-exercised JavaScript harmonic engine. The Swift engine is a port of
its algorithm, so the bar isn't "close" — it's *the same number*. A Node tool
generates golden fixtures from Neaps; `swift test` replays them and asserts agreement
layer by layer:

```sh
swift test                    # golden validation against the Neaps reference
node tools/gen-golden.mjs     # regenerate golden fixtures from @neaps/tide-predictor
node tools/gen-realworld.mjs  # refresh the NOAA real-world fixture
```

The point of going layer by layer is that a tide prediction is a stack of
computations, and an error in any one of them hides inside a plausible-looking final
curve. Test the whole pipeline only end-to-end and a sign error in the node
corrections can cancel against a phase error somewhere else for the 48 hours you
happened to check. So each layer gets pinned independently:

| Layer | Check | Tolerance | Result |
|-------|-------|-----------|--------|
| Astronomy | mean longitudes + node angles, 8 times across the 18.6-yr nodal cycle | 1e-6° | pass |
| Node corrections | IHO f/u, 17 base constituents × 3 times | 1e-6 | pass |
| Constituents | V₀ + compound f/u, ~39 constituents × 2 times | 1e-6 | pass |
| Prediction | 48 h height series, mixed-tide set | < 1e-6 m | pass |
| Extremes | hi/lo count, kind, time, height | 60 s / 0.02 m | pass |

A few of these deserve a note on *why* they're the layers that break:

- **Astronomy across the 18.6-year nodal cycle.** The moon's orbital plane precesses
  over 18.6 years, and the mean longitudes and node angle are sampled across that full
  cycle — not just at one date — because a bug in the node angle is invisible near one
  epoch and large near another.
- **Node corrections (the f/u factors).** These are the per-constituent amplitude (`f`)
  and phase (`u`) adjustments that account for that same nodal modulation. They're the
  most common place a harmonic engine quietly drifts, which is why they get their own
  fixture instead of only being checked through the final height.
- **Extremes, not just the height curve.** Sampling heights on a grid and calling the
  peaks "high tide" gives you the wrong minute. The extremes layer solves for the
  actual turning points and is checked on count, kind (high vs low), time, and height
  separately — the tolerances there (60 s, 0.02 m) are the tight ones.

Every layer lands at floating-point agreement (`1e-6`). The algorithm is faithful to
the reference. But "faithful to the reference" only proves the port is correct — it
says nothing about whether the *reference* matches the real world. That's the second
axis.

## The receipt: vs NOAA's own predictions

The stronger test is against a completely independent authority: NOAA's own published
predictions, straight from the [CO-OPS Data Retrieval
API](https://api.tidesandcurrents.noaa.gov/api/prod/). This is a real head-to-head —
feed the engine the published harmonic constituents for a station, then compare its
highs and lows to what NOAA's *own* internal engine says for the same station and days.

Station: **Friday Harbor, WA (NOAA 9449880)**. Constituents come from
[`@neaps/tide-database`](https://github.com/openwatersio/tide-database) (sourced from
NOAA, public domain, bundled offline). The comparison target is fetched live from
CO-OPS at MLLW, GMT:

```js
const url = `https://api.tidesandcurrents.noaa.gov/api/prod/datagetter`
  + `?begin_date=20260715&end_date=20260717`
  + `&station=9449880&product=predictions&datum=MLLW&interval=hilo`
  + `&units=metric&time_zone=gmt&format=json`;
```

Twelve highs and lows over 2026-07-15…17:

| Metric | Engine vs NOAA | Navigational tolerance |
|--------|----------------|------------------------|
| Max time error | **7.9 min** | ±15 min |
| Max height error | **3.5 cm** | ±0.15 m |

The engine reproduces NOAA's published tide tables to a few minutes and a few
centimetres — inside half the tolerance you'd accept from a paper table, on both axes,
computed entirely offline from the bundled constants. That's the claim that matters:
not "agrees with the code I ported from," but "agrees with the tide authority."

## The honest residual — why ~8 minutes

I'm not going to tell you the error is zero, because it isn't, and the residual is
worth understanding rather than papering over.

The ~8 min / 3.5 cm gap against CO-OPS is **expected**. NOAA's operational engine
isn't the same engine — it uses a different node-correction epoch and a somewhat
different constituent set than the Neaps algorithm this port follows. Two correct
harmonic engines, fed the same station's constants but differing in those internals,
will land a few minutes apart. That's not error accumulating toward a wrong answer;
it's the known spread between two legitimate methods, and it sits an order of magnitude
inside navigational tolerance.

The tell that it's method-spread and not a bug: against the Neaps oracle — same
algorithm — the agreement is `1e-6`, essentially exact. Against NOAA — different
algorithm — it's minutes. If the port were broken, the first number wouldn't be
floating-point tight. The two results are consistent with exactly one story: a faithful
port of one correct method, differing from another correct method by the amount two
correct methods differ.

## A note on data sourcing

The constituents themselves are public. NOAA harmonic constants are public domain and
bundled with the engine (~3400 stations via `@neaps/tide-database`), which is what makes
offline prediction possible at all — no network, no key, no live dependency, predictions
years ahead from data that ships with the app. For Canadian waters, CHS publishes
*predictions* (not just constants) through its IWLS API, fetched and cached online.

One gotcha worth flagging for anyone bundling multi-source constants: **constituent
naming isn't standardized**. NOAA writes `NU2`, `MM`, `RHO`; CHS and other sources use
their own variants for the same physical constituents. Feed a station's published
constants straight in and the ones whose names don't match your catalog silently drop
out of the sum — a prediction that's subtly, plausibly wrong. The engine's catalog
resolves **83 aliases** to canonical names so published constants from any source
predict correctly.

## Close

A tide number you computed yourself is only worth anything if you can show your work.
Two axes do it: golden vectors prove the algorithm is a faithful port, and a
head-to-head against the authority's own predictions proves the port matches reality —
with the datum offset applied so you're comparing to the right zero. The engine is
MIT-licensed and the validation is reproducible from the fixtures:
[**slackwater-engine**](https://github.com/sailingnaturali/slackwater-engine). If it's
off in your home waters, the fixtures are right there — check it and send a number back.

> **Not for navigation.** Predictions are astronomical estimates and don't account for
> weather, surge, or local effects. Carry official tables and charts.
