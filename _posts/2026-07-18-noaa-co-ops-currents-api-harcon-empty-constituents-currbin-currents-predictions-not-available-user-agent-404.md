---
layout: post
title: "Two false walls in NOAA's currents API: empty constituents and \"not available\""
description: "How I got US tidal-current harmonic constituents and predictions out of NOAA CO-OPS after two dead-ends that both looked terminal. harcon.json returns an EMPTY constituent list until you query the station's currbin instead of bin=0 — empty is not absent. currents_predictions returns \"Currents predictions are not available from the requested station\" for the default fetch/curl User-Agent, under probing-rate-limit 404s, and at the wrong depth bin — the service was never down, my request was wrong. Outcome: XTide dropped entirely, 855 harmonic + ~1,700 subordinate stations sourced straight from NOAA, validated to 9.7 min / 0.055 kn against NOAA's own predictions."
date: 2026-07-18
tags:
  - currents
  - noaa
  - co-ops
  - harmonic-analysis
  - api
  - debugging
  - offline
  - marine
---

This one started with a snap judgment, and the snap judgment was wrong in the most
useful way. I was looking at [XTide](https://flaterco.com/xtide/), the reference-grade
open-source tide and current predictor, and my first reaction was: *this website looks
like it was built in 1998, I wouldn't trust something this poorly put together.* That
reaction is unfair — XTide's data is impeccable, and the crustiness of a maintainer's
homepage tells you nothing about the quality of the harmonic constants underneath it.
But being wrong about XTide's *site* pushed me to the right question about XTide's
*role*: do I even need to harvest XTide's data, or can I go straight to the source it
ultimately derives from — NOAA? Chasing that question cost me two full days walking into
walls that both looked like the end of the road. Neither was.

> **TL;DR** — I wanted US tidal-current harmonic constituents for an offline engine.
> **Wall 1:** NOAA's `harcon.json` returned an **empty** constituent list for current
> stations, so I concluded NOAA doesn't publish current constituents. Wrong — it's empty
> only at `bin=0`; query the station's **`currbin`** and you get 26 real constituents
> (Deception Pass M2 = **5.418 kn @ 241.2° GMT**). **Empty ≠ absent.** **Wall 2:**
> `currents_predictions` returned *"not available from the requested station"* for every
> station — including NOAA's own documented example — so it looked like a dead product.
> Wrong again: **browser User-Agent + a real prediction station + its currbin** and it
> returns data. The service was never down; my request was. Outcome: **XTide dropped
> entirely**, 855 harmonic + ~1,700 subordinate stations straight from NOAA, validated to
> **9.7 min / 0.055 kn** against NOAA's own predictions.
> [Jump to the validation](#the-receipt-vs-noaas-own-predictions).

## Plan A, and why it wasn't Plan A for long

The engine already predicted tides from NOAA harmonic constants, offline and validated
to a few minutes against CO-OPS. Currents are the *same math* — a sum of cosines that
happens to produce signed velocity instead of height — so the only new input was
current constituents. The obvious source was XTide's Harmbase2 (via libtcd): US current
stations, public-domain-derived, exactly the constants I needed.

But routing through XTide means adopting XTide's snapshot of the constants, its naming,
its extraction toolchain, and its update cadence. If NOAA publishes the same constituents
directly, I'd rather consume them at the source and skip the middleman entirely. So before
committing to Harmbase2, I spent an hour poking at NOAA's metadata API to see whether the
current constituents were there.

They appeared not to be. That's Wall 1.

## Wall 1: "NOAA doesn't publish current constituents"

NOAA's CO-OPS metadata API (`mdapi`) serves harmonic constituents for a station at:

```
https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/<id>/harcon.json?units=english
```

For a tide station this returns the full constituent set. For a *current* station —
Deception Pass, Rosario Strait, the passes I actually cared about — it returned a valid
JSON envelope with an **empty constituent array**. Not a 404, not an error. Just: here is
your station, and it has zero harmonic constituents.

The natural read is that current stations simply don't carry published constituents —
that NOAA serves current *predictions* as a finished product but keeps the underlying
harmonics private, the way some hydrographic services do. I wrote that down as a finding
and started building the XTide extractor for real.

That conclusion was wrong, and the tell was sitting in the station metadata the whole
time. Current stations are three-dimensional in a way tide stations aren't: a current is
measured at a **depth bin**, and each station has a *reference* bin — the depth the
published predictions are computed for. That field is `currbin`, and it's right there in
the station-list record:

```
https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions&units=english
```

Each record carries `id`, `name`, `lat`/`lng`, `type` (H = harmonic, S = subordinate,
W = weak/rotary), and crucially **`currbin`**. The `harcon.json` endpoint takes a `bin`
parameter, and it defaults to `bin=0`. Bin 0 is above the reference depth for these
stations — there's no harmonic solution published there, so the array is legitimately
empty. Ask for the *right* bin and the data pours out:

```
harcon.json?units=english&bin=<currbin>
```

Deception Pass Narrows (`PUG1701`, `currbin=18`) returns **26 constituents**, and they're
exactly what a current predictor needs — richer than the tide equivalent:

```
constituentName   "M2"
majorAmplitude    5.418      // knots, major-axis semi-amplitude
majorPhaseGMT     241.2      // Greenwich-referenced phase, degrees
majorMeanSpeed   -0.619      // mean flow along the axis (Z0), knots
azi               92.9       // major-axis azimuth, degrees true
minorAmplitude / minorPhase  // the rotary (cross-axis) component
binNbr / binDepth / constNum
```

That's the whole model: `majorAmplitude` and `majorPhaseGMT` drive the sum, `azi` gives
the flood axis (ebb is `azi`+180), and `majorMeanSpeed` is the Z₀ offset for a station
whose flow doesn't average to zero. The empty array wasn't NOAA telling me the data
didn't exist. It was NOAA answering a question I hadn't meant to ask — *what are the
constituents at the surface?* — and me reading the answer as *there are no constituents.*

**Empty is not absent.** An empty result to a query with a defaulted parameter is a
statement about your query, not about the data. That cost me the better part of a day and
an entire wrong architecture.

## Wall 2: "the predictions API is down"

With constituents in hand I needed an oracle — NOAA's *own* predicted slack/max events —
to validate the engine against. That lives on the older Data Retrieval API:

```
https://api.tidesandcurrents.noaa.gov/api/prod/datagetter
  ?product=currents_predictions&interval=max_slack&bin=<currbin>
  &station=<id>&begin_date=...&end_date=...&units=english&time_zone=gmt&format=json
```

Every station I tried came back with:

```json
{ "error": { "message": "Currents predictions are not available from the requested station" } }
```

Every one. Including the station NOAA uses in its *own API documentation* as the worked
example. When even the documented example fails, the honest inference is that the product
is down — CO-OPS was mid cloud-migration that week, so a dead endpoint was entirely
plausible. I nearly wrote it off and shipped with structural validation only.

It wasn't down. There were **three** separate things wrong, stacked, each one enough on
its own to produce a failure that *looked* like an outage:

**(a) NOAA 404s the default User-Agent.** Plain `curl` and Node's `fetch` send a
default UA (`curl/8.x`, `node`), and NOAA's edge returns a bare 404 for it. The exact
same request from a browser — same machine, same residential IP — returns data. Send a
browser `User-Agent` header and this failure vanishes:

```
User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ...
```

**(b) Transient rate-limiting that looks like an IP block.** My probing volume (I was
hammering the endpoint trying to figure out why it failed) tripped NOAA's throttle, which
also returns bare 404s. I spent an embarrassing stretch convinced NOAA was blocking
*datacenter IPs* — I'd seen mdapi 404 from cloud egresses before — until the same box that
was 404ing from a script served the request fine *in a browser*. That's not an IP block;
an IP block would fail in the browser too. The variable that changed between the two was
the User-Agent (and the request pacing), not the IP. Slow down and send a real UA and the
404s stop.

**(c) Wrong stations at the wrong bin.** Some of the stations I was hammering are
*observation / survey* stations, not published-prediction stations — `currents_predictions`
genuinely isn't served for those, correctly. My actual target passes (`PUG1701` Deception
Pass, `PUG1717` Turn Point) are survey stations NOAA doesn't publish predictions for. But
hundreds of *other* harmonic stations are served — `PUG1741` (Bellingham Channel),
`PUG1612` (Clinton Ferry), `SFB1222` — and only when queried at their `currbin`.

Fix all three — browser UA, polite pacing, a served station at its reference bin — and
`currents_predictions` returns clean data. It was never down. Every failure I saw was my
own request.

## The turn: verify against a known-good client

What actually broke the logjam wasn't a NOAA status page. It was reading someone else's
working code.

I found the [Perigee-Tides MCP](https://github.com/RyanCardin15/Perigee-Tides), a
third-party client that talks to the same CO-OPS endpoints, and diffed its request
construction (`src/services/data-api.ts`, `metadata-api.ts`) against mine. Byte for byte,
the URL shape, the parameters, the field names — identical. My request *format* was
correct. It had been correct the whole time.

That's the pivot the whole debugging session turned on, and it generalizes:

> When your request matches a known-good client and it still fails, the variable is the
> **target**, not the syntax. Stop editing the request and start changing what you point
> it at — the station, the bin, the headers, the rate.

Once the format was ruled out, the remaining differences could only be the station, the
bin, the UA, and the request rate — which is exactly where the three real problems were.
I'd spent hours suspecting my URL. The URL was fine.

## Outcome: XTide dropped entirely

Both walls fell, and on the far side of them the original question answered itself: I
don't need XTide at all. Everything comes straight from NOAA CO-OPS, public domain:

- **Constituents** — `harcon.json` at the station's `currbin`.
- **Flood/ebb axis** — `azi` (flood) and `azi`+180 (ebb).
- **Mean flow** — `majorMeanSpeed` as the Z₀ offset.
- **Subordinate stations** — `currentpredictionoffsets.json`, giving time and speed
  offsets against a reference harmonic station.

The build-time extractor sweeps NOAA's station list and pulls each station's harcon (at
its currbin) and offsets, producing a bundled `currents.json` computed offline at runtime
— **855 harmonic + ~1,700 subordinate stations**, all of US waters, including the US Salish
Sea passes I set out for: Deception Pass, Rosario, San Juan Channel, Turn Point. No XTide
data, no `tide` binary, no libtcd, at build time or run time.

## The receipt: vs NOAA's own predictions

Once `currents_predictions` was serving, it became the oracle it was always meant to be —
the independent authority check. Feed the engine a station's published constituents,
predict its slack/max events, and compare to NOAA's *own* published events for the same
station and days.

**Harmonic station — `PUG1741` (Bellingham Channel), a clean ~2.8 kn reversing station:**
max flood/ebb events match NOAA to **9.7 min / 0.055 kn** across 11 events — on par with
the tide engine's Phase-0 (7.9 min / 3.5 cm). The fixture is captured offline so the check
runs in CI without the network.

**Subordinate reduction — `PCT0236` (reference `SFB1201`):** **6.1 min / 0.05 kn** over 11
events. Subordinate stations were subtler than tides because NOAA publishes **two** slack
offsets — slack-before-flood (`sbfTimeAdjMin`) and slack-before-ebb (`sbeTimeAdjMin`) —
not one. A slack takes the offset for the phase it *precedes*. Model it with a single slack
offset and half your slacks land at the wrong minute.

One labeling insight fell out of matching NOAA at weak stations: **classify max flood vs
max ebb by the sign of the velocity, not by slope high/low.** At a strong reversing pass,
a velocity peak (slope zero) that's positive is a flood and negative is an ebb, and
high/low slope gives the same answer. But at a weak, non-reversing station a relaxation
peak never crosses zero — a −0.3 kn local maximum during a long ebb is *slope-high* but
it's still an ebb. Label it by sign and you match NOAA's `max_slack` exactly.

## The bugs only a batch caught

Validating one station passed clean. Then I validated a *diverse batch* — different regions,
offset signs, speed ratios, harmonic and subordinate — and it broke in two different ways the
single-station test had walked right past. Both are the same shape: a category I'd treated as
monolithic turned out to have a second variety, and only the second variety triggered the bug.

**A reference is (station, bin), not just a station.** A subordinate references a specific
**bin** of its reference station (`refStationBin`) — because, same lesson as Wall 1, a current
reference is depth-keyed. My extractor stored *one* bin's constituents per reference. That's
fine until a reference publishes multiple bins with *different* constituents. `SFB1201`
publishes bins `[26, 20, 10]`, each with its own harmonic set. Storing one silently resolved
half the subordinates against the *wrong* constituents — ~50 min and ~0.6 kn off. The
single-station test had happened to hit the bin I'd stored, so it passed and told me nothing.
Fix: resolve each reference at its exact `refStationBin`.

**"Subordinate" doesn't always mean subordinate.** Some NOAA `type: S` stations carry their
*own* harmonic constituents, and NOAA predicts *those* harmonically — the offset reduction is
only for stations that have none. `PUG1716` (which references San Juan Channel) is type S but
has its own 25-constituent harcon; reducing it from San Juan Channel over-shot it by **89 min
/ 0.7 kn**. Predicted from its own constituents: **6.8 min / 0.06 kn**. Fix: for a type-S
station, fetch its own harcon first; fall back to the reduction only when it's empty. With
both fixes, nine genuinely-subordinate stations match NOAA to **0.9–7.7 min**.

The lesson keeps recurring in this engine: **n=1 validation hides class bugs.** One passing
station proves one station. Validate across the *diversity* of the data — regions, bins, ratios,
harmonic and subordinate — and the class of bug that only shows up at the second variety finally
has somewhere to show up.

## The passes I set out for turned out served

There's a fitting last twist. This whole project started to get currents for *my* home passes —
Deception Pass, Rosario Strait, San Juan Channel, Turn Point. Early on those returned
`"not available"`, so I filed them as survey stations NOAA doesn't predict and validated them
only *transitively* — engine-correct-on-other-stations plus faithful constituents. That was Wall
2 in miniature, and I'd quietly surrendered to it.

Re-checked with the right bin and a browser User-Agent: **every one is served.** They validate
*directly* against NOAA's own predictions now — Deception Pass to 14 min, Admiralty Inlet to 3.5,
Race Rocks to 6.0, on the significant currents. (The weak sub-¾-knot relaxation extrema at the
mixed-tide stations disagree by tens of minutes — but those are ill-conditioned in NOAA's
computation too, and a boat doesn't care when a third of a knot peaks.) The premise that my home
water was unreachable was, like every wall in this story, my request being wrong — not the data
being absent.

## Five things I'm keeping

1. **Empty ≠ absent.** An empty result to a query with a defaulted parameter (`bin=0`) is a
   fact about your query, not about the data. Check what you defaulted before you conclude
   the data doesn't exist.
2. **"The service is down" is usually your request.** Three stacked causes — User-Agent,
   rate, target — each looked like an outage. The endpoint was serving the whole time.
3. **An ugly UI is not evidence about data quality.** XTide's 1998 homepage says nothing
   about its constants. The reaction was wrong, but interrogating it led to the better
   architecture — go to the source.
4. **Verify against a known-good client before you touch your request.** When your request
   matches a working client and still fails, the variable is the target, not the syntax.
5. **Validate at scale, not n=1.** One passing station hid *two* bugs here, each triggered
   only by a second *kind* of station. Test across the diversity of the data — and the passes
   you gave up on may turn out served all along.

The engine is MIT-licensed and the currents fixtures are reproducible from NOAA's own
predictions: [**slackwater-engine**](https://github.com/sailingnaturali/slackwater-engine).
If it's off at your home pass, the golden generator points at any served NOAA station — run
it and send a number back.

> **Not for navigation.** Current predictions are astronomical estimates and don't account
> for wind, freshet, or local effects. Carry official current tables and charts.
