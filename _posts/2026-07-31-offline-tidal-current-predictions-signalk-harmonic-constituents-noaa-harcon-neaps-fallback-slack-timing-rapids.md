---
layout: post
title: "Offline tidal currents from harmonic constituents — and when not to trust them"
description: "Adding an offline harmonic fallback to a SignalK tidal-currents plugin: bundling public-domain NOAA CO-OPS harcon constituents, synthesizing slack/flood/ebb events with @neaps/tide-predictor, and tagging every prediction with source/live/unreliableForTransit provenance. Why constituent-derived slack timing can be off by tens of minutes at constricted passes like Deception Pass and Seymour Narrows, why CHS constituents can't be bundled at all, and how a local harmonic-vs-live discrepancy log measures the fallback against ground truth while the network is still up."
date: 2026-07-31
tags:
  - signalk
  - marine
  - currents
  - tides
  - typescript
  - offline
  - selfhosted
---

> **TL;DR** — [`signalk-currents`](https://github.com/sailingnaturali/signalk-currents) v0.7.0 keeps publishing tidal-current predictions when the boat loses internet: it bundles public-domain NOAA harmonic constituents and synthesizes slack/flood/ebb events offline with [Neaps](https://github.com/neaps/neaps). But every fallback reading is labeled `source: "harmonic"`, `live: false`, and — at constricted passes — `unreliableForTransit: true`, because harmonic slack timing at a tidal rapids can be off by tens of minutes. While the network *is* up, the plugin logs harmonic-vs-live discrepancies locally so the error is measured, not guessed. [Jump to the build](#the-build).

{% raw %}

Marine software has one non-negotiable requirement that most connected software gets to ignore: it has to keep working when the internet doesn't. A tidal-currents plugin that answers "when is slack at the pass?" only while the LTE link is up is worse than a paper tide book — because you'll have built your habits around asking it.

This post is the deeper look promised in the [`signalk-currents` README](https://github.com/sailingnaturali/signalk-currents#offline-harmonic-fallback): how the offline harmonic fallback works, why it deliberately announces its own unreliability at constricted passes instead of silently degrading, and how it measures itself against live data while it still can.

## Problem

`signalk-currents` publishes `environment.current` and a `/currents` resource by fetching **live** predictions from the CHS (Canada) and NOAA (US) tides-and-currents APIs, one fetch per station per UTC day. Every poll needs connectivity. Kill the uplink and the failure looks like this in the server log:

```text
signalk-currents: station Seymour Narrows live fetch failed: fetch failed
signalk-currents: station Boundary Pass live fetch failed: fetch failed
```

The per-day cache papers over short outages — per-day predictions are immutable, so anything already fetched keeps serving — but it's an in-memory `Map` scoped to the process. Restart the server while offline, or sail past the configured `horizonDays`, and currents go dark. On a boat, "restart while offline" is not an edge case; it's Tuesday.

## What we tried (and why it failed)

**Attempt 1: just serve the cache harder.** Persist the day cache to disk, fetch a longer horizon. This helps (and is a good idea anyway), but it's not synthesis — it can never answer beyond the last fetched day, and it does nothing for a station you never fetched. A cache is a memory, not a model.

**Attempt 2: bundle harmonic constituents for every gate.** This is the obvious move: tide clocks have synthesized predictions from harmonic constituents for a century, entirely offline. It works — for exactly half the cruising ground:

```text
NOAA (US) current constituents:  public domain, freely redistributable ✓
CHS (Canada) current constituents: not redistributable ✗
```

CHS harmonic constants are licensed non-commercial, non-redistributable, and not-for-navigation — you cannot ship them in an MIT-licensed npm package. And the Salish Sea's strong narrows — Seymour, Dodd, Gillard, Dent, Arran, Active, Porlier — are all CHS waters. The licensing wall lands precisely on the stations that matter most.

**Attempt 3: WebTide.** DFO's WebTide model has Salish-wide current constituents, but it's Crown copyright (redistribution needs written permission) and carries only 8 constituents with no shallow-water overtides — and overtides are exactly what constricted channels need (more on that below).

So v1 bundles what's legal: nine public-domain NOAA current stations covering the US Salish passes — Deception Pass, Rosario Strait, Admiralty Inlet, San Juan Channel, Haro Strait (two bins), Guemes Channel (two bins), and Boundary Pass. The Canadian rapids stay API-only, and the plugin says so out loud rather than pretending otherwise.

## The build

### A tide-height engine, repurposed for currents

There was no currents-capable harmonic synthesis library on npm. But [Neaps](https://github.com/neaps/neaps) (`@neaps/tide-predictor`, MIT) does the hard part — the astronomical argument and node-factor machinery behind summing constituents — for tide *heights*. The trick: Neaps doesn't care what the scalar is. Feed it amplitudes in **knots** instead of meters and its "water level" is the **signed major-axis current velocity**. Positive level = flood, negative = ebb, zero crossing = slack:

```ts
// src/sources/harmonic.ts
export function synthesizeEvents(hs: HarmonicStation, start: Date, end: Date): CurrentEvent[] {
  const predictor = createTidePredictor(
    hs.constituents.map((c) => ({ name: c.name, amplitude: c.amplitudeKn, phase: c.phaseDeg })),
  );

  // Flood/ebb peaks come straight from the extremes predictor.
  const extremes = predictor.getExtremesPrediction({ start, end });
  // ponytail: assumes mean-zero constituents (no Z0/DC-offset term) — a level-curve max
  // is a positive (flood) peak; adding a Z0 constituent would shift the baseline and could flip labels.
  const events: CurrentEvent[] = extremes.map((x) =>
    eventFromParts(x.time.toISOString(), x.high ? 'flood' : 'ebb', Math.abs(x.level)),
  );

  // Slack = sign change on a 1-minute timeline; linear-interpolate the crossing.
  const line = predictor.getTimelinePrediction({ start, end, timeFidelity: 60 });
  for (let i = 1; i < line.length; i++) {
    const a = line[i - 1], b = line[i];
    if ((a.level <= 0 && b.level > 0) || (a.level >= 0 && b.level < 0)) {
      const frac = a.level === b.level ? 0 : a.level / (a.level - b.level);
      const t = a.time.getTime() + frac * (b.time.getTime() - a.time.getTime());
      events.push(eventFromParts(new Date(t).toISOString(), 'slack', 0));
    }
  }

  events.sort((x, y) => x.utc.localeCompare(y.utc));
  return events;
}
```

"High tide" becomes a flood peak, "low tide" an ebb peak, and the output is the same `CurrentEvent[]` (slack/flood/ebb) shape the live CHS/NOAA sources emit — a drop-in third source, no restructuring downstream.

Note the `ponytail:` comment: classifying an extremum as flood *because Neaps called it a high* only works if the constituent sum is mean-zero. There's no `Z0` (mean flow) term in the bundled data, so the baseline sits at zero and the labels hold. Add a mean-flow offset — say, a channel with persistent river outflow — and a weak "flood" maximum can sit entirely below zero: still ebbing, just less. The assumption is documented where it lives, because it's the first thing a future constituent refresh could silently break.

### Bundling the constituents

Constituents are fetched at build time from NOAA CO-OPS `mdapi` `harcon` metadata, converted, and committed — never fetched at runtime:

```ts
// scripts/refresh-constituents.ts (excerpt)
const CM_S_PER_KNOT = 51.4444;

const constituents = rows
  .filter((c) => NEAPS_KNOWN.has(c.constituentName) && Number(c.majorAmplitude) > 0)
  .map((c) => ({
    name: c.constituentName as string,
    amplitudeKn: Number(c.majorAmplitude) / CM_S_PER_KNOT, // cm/s -> knots
    phaseDeg: Number(c.majorPhaseGMT),                     // Greenwich phase, degrees
  }));
```

Three gotchas live in those six lines:

1. **Units.** NOAA `harcon` major-axis amplitudes are **cm/s**; Neaps just sums whatever you hand it. Divide by 51.4444 once at generation time and every downstream `level` is already knots.
2. **Phase reference.** Store `majorPhaseGMT` (Greenwich phase, degrees). Neaps evaluates in UTC, so local-phase constants would shift every event by the timezone offset.
3. **Silent drops.** A constituent name Neaps doesn't know is **silently ignored** — no error, just a subtly wrong prediction. The refresh script filters against an explicit `NEAPS_KNOWN` set so anything unexpected is excluded deliberately at generation time, not accidentally at runtime.

NOAA's own disclaimer applies and is carried in the data file's provenance header: the data is public domain, and predictions derived from it are **unofficial**.

### Aligning the horizon with the live path

The live path fetches per UTC day. The harmonic path must synthesize the *same* window, or the two series cover different spans and both fallback handoff and discrepancy comparison get skewed:

```ts
// Synthesize the whole horizon in one pass, aligned to UTC-day boundaries so the
// event window matches the live path (fetch.ts iterates UTC days from the same start).
export function synthesizeHorizon(hs: HarmonicStation, start: Date, horizonDays: number): HarmonicDayData {
  const base = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth(), start.getUTCDate()));
  const end = new Date(base.getTime() + horizonDays * 86400000);
  return { events: synthesizeEvents(hs, base, end), floodDir: hs.floodDir, ebbDir: hs.ebbDir };
}
```

### Selection: live wins, fallback declares itself

The refresh loop synthesizes harmonic data for every station with bundled constituents on *every* cycle — not just offline ones — then selects:

```ts
// src/select.ts
export function selectData(
  liveData: DirData | undefined,
  harmonicData: DirData | undefined,
  provider: 'chs' | 'noaa',
): Selected | undefined {
  if (liveData) return { data: liveData, source: provider, live: true };
  if (harmonicData) return { data: harmonicData, source: 'harmonic', live: false };
  return undefined;
}
```

Every reading that leaves the plugin carries provenance. In the `/currents` resource:

```json
{
  "stationId": "PUG1701",
  "label": "Deception Pass",
  "source": "harmonic",
  "live": false,
  "unreliableForTransit": true,
  "events": [
    { "utc": "2026-07-16T14:02:00.000Z", "kind": "slack", "speedKn": 0 },
    { "utc": "2026-07-16T17:10:00.000Z", "kind": "ebb", "speedKn": 5.8 }
  ]
}
```

And on the `environment.current` delta, as SignalK meta:

```ts
meta: [{
  path: 'environment.current' as Path,
  value: {
    source: entry.source,                  // 'chs' | 'noaa' | 'harmonic'
    live: entry.live,                      // false when synthesized offline
    unreliableForTransit: station.requiresLive === true && !entry.live,
  } as unknown as object,
}],
```

`requiresLive` is a per-station config flag, pre-set on the constricted passes in the default station list. The design rule: **the plugin states facts; it never suppresses a value and never editorializes.** A harmonic slack estimate at Deception Pass is still useful for rough planning — deciding whether to look, not when to go. Whatever consumes the data (a chart plotter, an agent, a human reading JSON) decides what to do with `unreliableForTransit: true`. Silently degrading — serving a synthesized number in the same shape as an authoritative one — is how someone times a rapids transit on a model that's 25 minutes wrong.

## Why harmonic predictions fall short at constricted passes

This is the part the README promises and defers, so here it is. Harmonic prediction is a **linear** model: the current is a sum of fixed sinusoids at astronomical frequencies,

```text
v(t) = Σᵢ Aᵢ · cos(ωᵢ·t − φᵢ)
```

with amplitudes and phases fitted to a historical current-meter record. That model is excellent where the tide behaves like a superposition of long waves — open coast, wide straits. A constricted pass breaks each of its assumptions:

**1. The flow is hydraulic, not wavelike.** At a narrows like Seymour (which routinely exceeds 15 knots) the current is driven by the water-level *difference* between the basins at each end. The velocity responds roughly as the square root of that head difference, through quadratic bottom/form friction. A square root of a sum of sinusoids is not a sum of sinusoids — the response is nonlinear by construction.

**2. Nonlinearity pumps energy into overtides the bundle truncates.** The nonlinear terms generate shallow-water constituents — M4, M6, MS4 and friends, at multiples and sums of the astronomical frequencies — which is what makes real rapids curves asymmetric: fast-rising floods, long-tailed ebbs, double-humped peaks. The bundled stations carry 23–29 constituents each (only the ones Neaps knows); the residual distortion the fit couldn't capture doesn't vanish, it lands in the error — concentrated where the curve shape matters.

**3. The error concentrates at slack — the only moment you care about.** At peak flow, a 10% amplitude error changes nothing about your decision; you weren't going through Dent Rapids at max ebb anyway. Near slack, the head difference across the pass is small, so *everything the constituents don't model* — wind setup, atmospheric pressure gradients, river discharge in freshet, the truncated overtides — shifts the zero crossing directly. The steeper, shorter slack window at a strong narrows means a modest phase error translates to arriving with real current already running. That's the mechanism behind "off by tens of minutes," and it's why the flag is named `unreliableForTransit` and not something politer.

**4. The fit itself is weaker.** Height constituents come from decades-long water-level records at permanent gauges. Current constituents come from comparatively short current-meter deployments in turbulent, stratified water, resolved per depth bin. The inputs are noisier before the model's structural limits even apply.

None of this makes the harmonic fallback useless — Boundary Pass under harmonic synthesis is a perfectly serviceable planning baseline. It makes the fallback *conditionally* trustworthy, and the condition is knowable per station in advance. That's exactly what a config flag is for.

## Measure the fallback while you still have ground truth

The claim above — "off by tens of minutes" — deserves numbers, per station. The trick is that the best time to measure an offline fallback is when you're online: every poll cycle where a station has *both* live and harmonic data, the plugin diffs them and appends a line to a local JSONL log:

```ts
// src/compare.ts — deltas are signed (harmonic − live):
// +slackDeltaMin = harmonic slack is later
export function computeDiscrepancy(
  stationId: string, label: string, live: CurrentEvent[], harmonic: CurrentEvent[], now: Date,
): Discrepancy {
  const ls = nextSlackAfter(live, now), hs = nextSlackAfter(harmonic, now);
  const lp = peakRate(live), hp = peakRate(harmonic);
  return {
    utc: now.toISOString(), stationId, label,
    slackDeltaMin: ls !== undefined && hs !== undefined ? (hs - ls) / 60000 : null,
    peakRateDeltaKn: lp !== undefined && hp !== undefined ? hp - lp : null,
  };
}
```

```text
<SignalK dataDir>/signalk-currents-discrepancies.jsonl
```

One row per station per poll: how far off the harmonic next-slack estimate is (signed minutes) and how far off the peak rate is (signed knots). Local file only — nothing is phoned home. The write is best-effort and swallowed on failure, because diagnostics must never take down the data path they're diagnosing.

The design intent: when someone eventually asks "how wrong is the fallback at *this* station?", the answer is a `jq` one-liner over months of accumulated rows, not a shrug. The follow-up post with a season of measured deltas is the plan; this post is the mechanism.

## Gotchas

- **NOAA `harcon` amplitudes are cm/s** — convert to knots (÷ 51.4444) at generation time, not runtime.
- **Neaps silently drops constituent names it doesn't know.** Filter against an explicit known set when generating the bundle, or you'll ship a prediction missing constituents with no error anywhere.
- **Flood/ebb labels assume mean-zero constituents.** A `Z0`/mean-flow term would shift the baseline and can flip extremum labels.
- **Align synthesis windows to UTC-day boundaries** to match a per-day live fetch path, or fallback handoffs jump.
- **You may not be able to redistribute your local constituents.** NOAA is public domain; CHS is not. Check before bundling anything Canadian — the licensing boundary decides your offline coverage map, not your code.
- **Provenance is part of the data model, not a log line.** `source` / `live` / `unreliableForTransit` ride on the resource payload *and* the SignalK meta, so every consumer sees them — not just whoever reads the server log.

## Close

This plugin is part of the open-source navigation stack for an all-electric charter catamaran that will spend its life transiting exactly these passes — which is why the fallback that keeps currents flowing offline also has to be honest about where it can't be trusted. Code, bundled constituents, and the refresh script: [github.com/sailingnaturali/signalk-currents](https://github.com/sailingnaturali/signalk-currents).

{% endraw %}

*Related: [why generic weather MCPs fail for marine navigation]({% post_url 2026-06-06-marine-weather-mcp-buoy-ground-truth-ndbc-spec-swell-wind-waves %}) — the same verify-against-reality instinct, with NDBC buoys as ground truth — and [LLM agents confabulating data provenance]({% post_url 2026-06-21-llm-agent-confabulation-inventing-infrastructure-and-data-provenance %}), the failure mode provenance fields exist to prevent.*
