---
layout: post
title: "Tide predictions read higher than the tables? Suspect the datum"
description: "signalk-tides v2 (Neaps offline harmonics) read 0.35–0.48 m higher than the official CHS tide tables at Sidney BC. Not a broken algorithm: TICON serves heights above LAT, CHS tables use chart datum, and Canadian chart datum is not LAT — it sits up to ~0.43 m above it, per station. How to pull the MSL/LAT/chart-datum offsets from the CHS IWLS station metadata API, normalize both sides, and how the resulting benchmark caught a genuinely broken station (Cape d'Or, range overstated ~50%)."
tags:
  - signalk
  - marine
  - tides
  - navigation
  - chs
  - neaps
  - open-source
date: 2026-07-16
---

> **TL;DR** — If a harmonic tide prediction disagrees with the official tide
> tables by a *constant* offset at a station, the algorithm is fine; the two
> heights are measured from different zeros. Canadian chart datum is **not**
> LAT — at CHS stations it sits up to ~0.43 m above it, and the per-station
> offset is published in the CHS station `/metadata` API.
> [Jump to the fix](#the-fix).

![Worst-case height error against the official CHS tide tables, per station, before and after normalizing both sides to LAT. Sidney BC falls from 0.35 to 0.48 m down to 8 cm or less, Point Atkinson from 0.13 m to 5 cm, Halifax from 0.38 m to 13 cm.](/assets/img/harmonic-tide-predictions-higher-than-tide-tables-chart-datum-vs-lat-chs-datum-offset-signalk-tides-neaps/datum-normalized-error.svg)

Tide height numbers are meaningless without a stated vertical datum. Every
"3.2 m at 14:40" is really "3.2 m *above some agreed zero*", and there are
half a dozen zeros in circulation: mean sea level (MSL), mean lower low water
(MLLW), lowest astronomical tide (LAT), and each hydrographic office's own
chart datum. Compare two predictions that don't share a zero and you get a
bug report that looks exactly like broken code.

This is the story of one of those bug reports — against
[`signalk-tides`](https://github.com/openwatersio/signalk-tides), the SignalK
tide plugin — that turned out to be a datum mismatch, and of the
cross-checking that then turned up a genuinely broken station in the upstream
tide database.

## Problem

`signalk-tides` v2 ([2.0.0-beta.1](https://github.com/openwatersio/signalk-tides/releases),
after [#78](https://github.com/openwatersio/signalk-tides/pull/78) went
Neaps-only) predicts tides **offline** from harmonic constituents — no NOAA,
no WorldTides, no API keys. It runs on our boat's SignalK server and answers
for any position:

```bash
curl "http://<signalk-host>:3000/signalk/v2/api/tides/extremes?latitude=48.649&longitude=-123.393"
```

Cross-checking it against the official CHS predictions for Sidney, BC
(station 07260) before trusting it for anchoring math:

```text
validated against official CHS predictions, 2026-06-12

Sidney BC (07260):          every high and low +0.35 to +0.48 m HIGH
                            timing within ~16 min
Point Atkinson BC (07795):  heights within 0.03–0.13 m
                            timing within ~6 min
```

At Sidney, every single high and low read a consistent third-to-half metre
**higher** than the published tables — while Point Atkinson, checked the same
way on the same day, was nearly spot on. Timing was fine at both. The obvious
conclusion — the one any user would file
as an issue — is "the plugin over-reads by half a metre; the harmonic engine
is broken."

The same symptom was already sitting in the Neaps tracker as
[openwatersio/neaps#223](https://github.com/openwatersio/neaps/issues/223),
with a Halifax example:

```js
// Neaps (TICON constituents), Halifax NS, 2026-02-20, datum: "MLLW"
{ t: 'Fri, 20 Feb 2026 01:38:10 GMT', level:  1.507 }
{ t: 'Fri, 20 Feb 2026 07:51:58 GMT', level: -0.068 }
{ t: 'Fri, 20 Feb 2026 13:51:17 GMT', level:  1.474 }
{ t: 'Fri, 20 Feb 2026 20:08:29 GMT', level: -0.136 }
```

```js
// CHS official wlp-hilo predictions, same station, same day
{ "eventDate": "2026-02-20T01:36:00Z", "value": 1.817 }
{ "eventDate": "2026-02-20T07:57:00Z", "value": 0.310 }
{ "eventDate": "2026-02-20T13:46:00Z", "value": 1.774 }
{ "eventDate": "2026-02-20T20:09:00Z", "value": 0.181 }
```

Times agree to minutes. Levels are ~0.3 m apart — and *uniformly* apart.

## Diagnosis

That uniformity is the whole diagnosis. Harmonic synthesis produces an
oscillation about the station's **mean water level**; getting from there to
"height above chart datum" is a per-station constant from a datum table, added
at the end. So:

- A **constituent** error (bad amplitudes/phases) varies with the tide — big
  at springs, small at neaps, different at highs vs lows.
- A **datum** error is DC — the same offset on every prediction, at every
  tide.

A constant offset means the sine waves are right and the *zero* is wrong.

Here the zeros genuinely differ. Neaps serves heights in the station's
`chart_datum` from the [TICON-based tide database](https://github.com/openwatersio/tide-database),
which labels Canadian stations `"LAT"` (lowest astronomical tide). CHS tide
tables are referenced to **CHS chart datum**. And the common assumption that
Canadian chart datum ≈ LAT turns out to be false at station level: CHS chart
datum sits **above** LAT by a per-station amount — 0.43 m at Sidney.

![Vertical datum ladder at Sidney BC: CHS chart datum, the zero of the tide tables, sits 0.43 m above lowest astronomical tide, the zero of the harmonic record, so the same water surface is reported 0.43 m higher by the harmonic engine.](/assets/img/harmonic-tide-predictions-higher-than-tide-tables-chart-datum-vs-lat-chs-datum-offset-signalk-tides-neaps/sidney-datum-ladder.svg)

You don't have to take that on faith; CHS publishes every station's vertical
ladder in the IWLS `/metadata` endpoint:

```bash
# Sidney BC (station code 07260)
curl -s "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations/5cebf1df3d0f4a073c4bbd26/metadata"
# resolve the heightTypeIds via:
curl -s "https://api-iwls.dfo-mpo.gc.ca/api/v1/height-types"
```

```jsonc
// metadata "heights", values in metres relative to CHS chart datum
{ "code": "MWL",   "value":  2.09 }   // mean water level
{ "code": "LLWLT", "value": -0.22 }   // lower low water, large tide
{ "code": "LAT",   "value": -0.43 }   // lowest astronomical tide
{ "code": "HAT",   "value":  3.53 }
```

LAT is 0.43 m *below* chart datum at Sidney — exactly the amount by which the
plugin's LAT-referenced predictions "over-read" against the chart-datum
tables. (Note LLWLT ≠ 0 either: even the textbook definition of Canadian
chart datum doesn't sit at the datum's actual zero here.)

## What we tried (and why it failed)

**Suspecting the constituents.** The natural first read — offline harmonics
from a community database vs the hydrographic office, of course the
constituents are worse. But lining up TICON's own datum table against CHS's
published offsets shows the two agree almost exactly on where MSL sits above
LAT:

| Station | TICON MSL→LAT | CHS metadata (MWL above CD + CD above LAT) | agreement |
|---|---|---|---|
| Sidney BC | 2.522 m | 2.09 + 0.43 = 2.52 m | ~2 mm |
| Point Atkinson BC | 3.144 m | 3.09 + 0.08 = 3.17 m | ~3 cm |
| Halifax NS | 1.152 m | 1.03 + 0.09 = 1.12 m | ~3 cm |

The physics agreed to centimetres. It was bookkeeping.

**Comparing "MLLW to MLLW".** The Halifax example above asked Neaps for
`datum: "MLLW"` and still missed by 0.3 m — because CHS `wlp-hilo` values
aren't MLLW-referenced (they're chart datum), and TICON's MLLW is its own
computed statistic. Two datums with the same *name* from two sources are not
the same zero.

**Trusting the `chart_datum: "LAT"` label.** The station records say chart
datum is LAT, so diffing against the tables should be safe… except CHS chart
datum isn't LAT (see above). A label is a claim, not a measurement.

## The fix

Normalize both sides to one explicit datum before comparing — or before doing
any arithmetic at all with someone else's heights:

```ts
// CHS /metadata "heights": LAT is relative to chart datum (negative)
const lat = heights.find((h) => h.code === "LAT")!.value; // Sidney: -0.43

// shift CHS chart-datum predictions onto LAT…
const chsAboveLAT = chsPrediction.value - lat;

// …and ask the harmonic side for the same zero explicitly
const { extremes } = station.getExtremesPrediction({ start, end, datum: "LAT" });
```

Datum-aware, the "half a metre of error" collapses: Sidney residuals drop to
≤ ~8 cm, Point Atkinson ≤ ~5 cm, Halifax ~10–13 cm, timing within minutes
everywhere.

That normalization then became a standing benchmark, contributed upstream as
[openwatersio/neaps#272](https://github.com/openwatersio/neaps/pull/272): all
226 Canadian MEDS-sourced TICON stations diffed against live CHS predictions
(the TICON ids embed the CHS station code — `sidney_bc-7260-can-meds` —
so the join is free). Across the 180 stations that line up, full-year
height MAE is **p50 7.3 cm / p90 16.4 cm / p95 25.7 cm**, timing ~23 min
(p95 of median |Δt|), re-run monthly in CI against fresh CHS predictions.

## The bonus find: a station no datum can explain

The benchmark's per-station CSV kicked out one outlier that is *not* a datum
problem: `cape_dor-240-can-meds` (Cape d'Or, Bay of Fundy) carries a **+3.5 m
constant bias** — and unlike the others, its harmonic record itself is
implausible. Filed upstream as
[openwatersio/tide-database#93](https://github.com/openwatersio/tide-database/issues/93)
(still open as of this writing):

```text
TICON HAT−LAT:              18.58 m
CHS published HAT−LAT:      12.40 m   (same location)
one-year predicted range:   17.4 m    — would exceed the world-record
                                        range at Burntcoat Head
SA constituent:             2.08 m    — 4× the next-highest Canadian
                                        station; implausible for an
                                        open-marine site
```

Dropping the suspect SA term only brings the predicted range down to 16.0 m,
so the whole constituent set reads as over-amplified, not one bad row. The
point isn't this station — it's that **benchmarking against published ground
truth catches upstream data errors, not just your own bugs**. Nothing in the
code path was wrong; the input data was.

## Why it matters / gotchas

- **Never trust a height without asking "above what?"** Any pipeline that
  passes tide heights between systems should carry the datum with the number,
  and any comparison should normalize first.
- **The error signature tells you where to look.** Constant offset across all
  tides → datum/bookkeeping. Error that scales with the tide → constituents.
  This one rule would have saved the original "water levels differ from the
  public tide predictors" investigation a lot of head-scratching.
- **The optimistic direction is the unsafe one.** Charted depths are below
  chart datum. Add a LAT-referenced height to a charted depth where chart
  datum sits 0.4 m above LAT and you believe in 0.4 m of water that isn't
  there — exactly the wrong direction for under-keel clearance. Our agent
  tooling carries this as an explicit caveat and pads margins accordingly.
- **Per-station, not a constant.** The CHS chart-datum-to-LAT offset is 0.43 m
  at Sidney, 0.08 m at Point Atkinson, 0.09 m at Halifax. There is no single
  fudge factor; the station `/metadata` is the source of truth.

## Close

This came out of wiring `signalk-tides` v2 into the AI-ops stack we run on an
all-electric sailing catamaran — offline tide predictions the boat can answer
from with no internet, which is only useful if you've checked them against
the official tables first. The plugin, the
[Neaps](https://github.com/openwatersio/neaps) engine, and the
[tide database](https://github.com/openwatersio/tide-database) are all open
source and better for the benchmarking.

*Related:* verifying forecasts against what a buoy is actually measuring is
the same habit applied to weather — see
[why generic weather MCPs fail for marine navigation]({% post_url 2026-06-06-marine-weather-mcp-buoy-ground-truth-ndbc-spec-swell-wind-waves %}).
