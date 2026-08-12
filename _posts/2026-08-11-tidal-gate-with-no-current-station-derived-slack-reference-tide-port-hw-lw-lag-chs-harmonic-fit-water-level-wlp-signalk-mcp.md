---
layout: post
title: "A tidal gate with no current station: deriving slack from a tide port"
description: "Malibu Rapids has no CHS current station, so its slack is a reference tide port's high and low water plus a fixed lag. Supporting it needed a second harmonic fit path (a CHS IWLS wlp water-level series decimated to 15 minutes and fitted to the same constituent basis, producing a tide-harmonic record with no flood/ebb axis), a derived-slack record carrying no constituents at all, a validated `derived` block in the shared station registry, and a `derived: true` flag propagated to the SignalK resource and the MCP tool output so the agent never implies a current speed. Point Atkinson fits to RMS 0.075 m; out-of-sample HW/LW timing agrees to a median 5.5 min."
date: 2026-08-11
tags:
  - signalk
  - marine
  - currents
  - tides
  - typescript
  - mcp
  - data-modeling
---

> **TL;DR** — Some tidal gates have no current station at all: the published knowledge is "slack is the reference tide port's high water plus 25 minutes." That is strictly less information than a fitted gate carries — no constituents, no flood/ebb axis, no speed — and the honest move is to model it as its own record type and carry the shortfall all the way to the agent's answer rather than fabricating a zero. [Jump to the fix](#the-fix).

Our tidal-currents pipeline had one entity type: a station with harmonic constituents. Feed it a CHS or NOAA current station, fit the constituents, and it will tell you the signed velocity at any instant — slack times, flood and ebb peaks, the set in degrees true. That model held for every gate in the Salish Sea until it hit one that doesn't fit at all.

This is the follow-on to [the offline-harmonic-fallback post]({% post_url 2026-07-31-offline-tidal-current-predictions-signalk-harmonic-constituents-noaa-harcon-neaps-fallback-slack-timing-rapids %}), which built the fit path in the first place.

## Problem

Malibu Rapids is the reversing rapids at the entrance to Princess Louisa Inlet — a blind S-shaped dogleg about 30 m across at its tightest, running 8 to 9 knots at springs. It is one of the most-asked-about gates in British Columbia, and **CHS publishes no current station for it**. There is nothing to fetch and nothing to fit.

Adding it to the shared station registry as an ordinary `kind: current` gate broke the plugin's fetch cycle immediately, once per poll, forever:

```text
signalk-currents: station Malibu Rapids live fetch failed: no live id for Malibu Rapids
```

The registry-to-station filter read only the `provider` field, so Malibu was swept straight into the list of things to fetch:

```ts
// src/registry-stations.ts — before
return Object.entries(data)
  .filter(([, e]) => e.provider === 'chs')
  .map(([key, e]) => ({ stationId: key, label: e.name, /* … */ }));
```

Downstream, the resolver has no CHS current id to hand back, and `fetch.ts` throws on the missing id:

```ts
// src/fetch.ts
if (!s.liveId) throw new Error(`no live id for ${s.label}`);
```

What *is* published for Malibu is a sentence out of the cruising literature: slack occurs about **25 minutes after high water at Point Atkinson, and 35 minutes after low water**. A pointer and two numbers. No velocity series, no axis, no speed.

![Out-of-sample high-water and low-water timing error for the derived-slack fit at Point Atkinson, with a median of 5.5 minutes across nineteen extremes and the long tail concentrated on the flat low waters.](/assets/img/tidal-gate-with-no-current-station-derived-slack-reference-tide-port-hw-lw-lag-chs-harmonic-fit-water-level-wlp-signalk-mcp/derived-slack-timing-error.svg)
*The reference-port fit is good enough that the lag, not the harmonics, is the dominant error term. The four outliers are all low waters — a flat extremum's time is weakly determined at any accuracy.*

## Diagnosis

The whole chain — the registry, the fitting tool, the SignalK plugin, the MCP server, the agent's spoken answer — assumed one shape: `{ constituents, floodDirection, ebbDirection, offset }`. Everything downstream reads a signed velocity out of that. A derived gate breaks it in three separate places at once:

1. **No current series to fit.** There is no `wcsp1` velocity data for Malibu, so there are no constituents to produce.
2. **No flood/ebb axis.** A current station's metadata carries `floodDirection`/`ebbDirection` because someone measured the channel's major axis. Nobody measured Malibu's.
3. **No speed, ever.** Not "unknown until we fetch it" — CHS predicts no current there at all. The information does not exist.

Point 3 is the one that matters. Points 1 and 2 you could paper over. Point 3 means any speed the pipeline emits is invented, and it would be invented at a pass where arriving off-slack pushes you into rock walls.

But the reference port *does* have a full water-level record. So the shape of the answer is: fit the reference tide offline, predict its high and low water, shift each by its lag, and publish the resulting times — and nothing else.

![Two fit paths side by side: a fitted gate goes from a CHS current station through a velocity series to a harmonic record with a flood and ebb axis, while a derived gate goes from a reference tide port through a water-level series to a tide-harmonic record with no axis, then to a derived-slack record holding only a reference and two lag values.](/assets/img/tidal-gate-with-no-current-station-derived-slack-reference-tide-port-hw-lw-lag-chs-harmonic-fit-water-level-wlp-signalk-mcp/two-fit-paths.svg)

## What we tried (and why it failed)

**Attempt 1: filter it out.** The first commit simply skipped any registry entry carrying a `derived` block, so the gate could exist in the shared registry without breaking anything that consumed it:

```ts
.filter(([, e]) => e.provider === 'chs' && e.derived === undefined)
```

This is correct as a guard and it shipped — but it is not a feature. The gate is in the registry and invisible to every consumer. Ask the agent about Malibu and you get "no station."

**Attempt 2: fake the missing fields.** The tempting shortcut: emit an ordinary harmonic record with the tide's constituents, `floodDirection: 0`, `ebbDirection: 0`, and let the existing machinery run. Everything downstream compiles, the resource publishes, the agent answers.

It also means `environment.current` starts publishing a speed and a set at a gate where nobody has ever predicted one, and a chart plotter draws a current arrow pointing due north because zero was the cheapest value to write. There is now a test whose entire job is to forbid this:

```ts
// test/fit-tide.test.ts
// A tide has no flood/ebb axis — those fields must be absent, not a fake 0.
expect(fitted).not.toHaveProperty('floodDirection');
expect(fitted).not.toHaveProperty('ebbDirection');
```

**Attempt 3: reuse `fitStation` on the water-level series.** The existing fit function looked reusable — same basis, same solver. It isn't:

- it fetches a *projected* velocity series, not `wlp`;
- it calls `client.metadata(id)` for `floodDirection` to project onto, and a tide port has no such field;
- `wlp` is sampled every minute against the current series' 15, so the sparse-series guard (`days * 96 * 0.6`) computes the wrong minimum by a factor of 15 and a genuinely broken series would pass;
- and the emitted record is typed `harmonic` with a flood/ebb axis it must not have.

That is four behavioural differences, which is a second function, not a flag.

**Attempt 4: push the new records through the existing bundle adapter.** The plugin's `adaptChsBundle` validates strictly — deliberately, since a malformed bundle entry is a silently wrong prediction. Feeding it the two new record types produced exactly what strictness is for:

```text
Error: CHS bundle station "chs-point-atkinson" is malformed
Error: CHS bundle station "chs-malibu-rapids" is malformed
```

Right call, wrong shape. The adapter had to learn there are now three kinds of record, not loosen its checks.

**Attempt 5: let the presentation layer infer the missing pieces.** The MCP server labels a slack window from the extrema on either side of it — "ebb→flood". A derived gate has no flood or ebb events at all, so both neighbours are absent and the helper falls through to its default:

```python
def _direction_label(prev_kind: str | None, next_kind: str | None) -> str:
    if prev_kind and next_kind:
        return f"{prev_kind}→{next_kind}"
    # …
    return "slack"
```

which the formatter then interpolated into its template, giving every Malibu window the tell-tale:

```text
Wed 05:55 PDT (slack, slack)
```

That string is the missing information surfacing as a cosmetic bug. It is the cheapest possible signal that a type carrying less than its siblings had reached the top of the stack without anyone modelling the difference.

**Attempt 6: ship the pairing in the data and the validator only.** The registry gained the `derived` block and a `tideReference` field for ordinary gates, both validated. But neither appeared in `index.d.ts`, and `resolve()` — the one function the spec says returns a complete resolved record — dropped them. A typed consumer building a paired tide-and-current view could not see a gate's reference port through the documented API, even though the data was right there in the JSON. Data plus validator is not a contract; the declarations are.

## The fix

Four coordinated changes: a validated registry block, a second fit path, a record type that carries no constituents, and a flag propagated to the tool output.

### 1. The registry describes the derivation, and validates it

```yaml
# data/registry.yaml
chs-malibu-rapids:
  name: Malibu Rapids
  context: Princess Louisa Inlet
  position: [50.1626, -123.8515]
  provider: chs
  kind: current
  aliases: [princess louisa, malibu islet]
  derived:
    reference: chs-point-atkinson
    hwLagMinutes: 25
    lwLagMinutes: 35
```

It stays `kind: current` — it is still a gate — but a consumer reads its slack from the reference, not from a fitted series. The validator refuses the ways this can be wrong:

```js
if (record.kind === "tide") {
  problems.push(`${id}: a tide port cannot be derived`);
}
if (!isNonEmptyString(d.reference)) {
  problems.push(`${id}: derived.reference is required`);
} else if (!registry.has(d.reference)) {
  problems.push(`${id}: derived.reference "${d.reference}" is not a station in this registry`);
} else if (registry.get(d.reference).kind !== "tide") {
  problems.push(`${id}: derived.reference "${d.reference}" must be a tide port (kind: tide)`);
}
for (const field of ["hwLagMinutes", "lwLagMinutes"]) {
  if (typeof d[field] !== "number" || !Number.isFinite(d[field])) {
    problems.push(`${id}: derived.${field} must be a number`);
  }
}
```

A dangling reference or a reference that is itself a current station would derive slack from the wrong water, silently. It fails the build instead.

### 2. A second fit path for water level

`fitTideStation` fetches `wlp`, thins the 1-minute series to 15 minutes, fits the same constituent basis, and emits a record that is explicitly *not* a current:

```ts
/** wlp is 1-minute sampled; a harmonic fit wants nothing finer than this. */
const WLP_STEP_MINUTES = 15;

export async function fitTideStation(client, station, { start, days, stepMinutes = WLP_STEP_MINUTES }) {
  const series = await client.series(station.id, "wlp", start, days);
  const samples = decimate(series, stepMinutes);

  const minimum = Math.floor(days * (1440 / stepMinutes) * 0.6);
  if (samples.length < minimum) return null;          // a holey series is worse than none

  const result = fit(samples, { constituents: BASIS });
  return {
    id: station.key ?? slug(station.label),
    name: station.label,
    type: "tide-harmonic",     // not "harmonic"
    source: "chs-derived",
    offset: result.offset,     // the datum, recovered as Z0
    constituents: result.constituents.filter((c) => c.amplitude > MIN_AMPLITUDE),
    rms: result.rms,
    trainingDays: days,
  };
}
```

No `floodDirection`, no `ebbDirection` — absent, not zero. Over a 210-day window Point Atkinson fits to **RMS 0.075 m** on 19 constituents above the amplitude floor.

### 3. The record type that admits it knows less

```ts
/**
 * The bundle record for a derived gate: no constituents and no speed — a
 * consumer predicts the referenced tide port and derives slack from its HW/LW.
 * `tide-derived` (not `chs-derived`) marks that this record itself holds no CHS
 * data, only a pointer and the lags.
 */
export interface DerivedSlackRecord {
  id: string;
  name: string;
  type: "derived-slack";
  source: "tide-derived";
  reference: string;
  hwLagMinutes: number;
  lwLagMinutes: number;
}
```

Seven fields, none of them a measurement. That is the entire honest content of a derived gate.

### 4. Slack timing, and only slack timing, all the way out

In the plugin, derived gates get their own refresh pass, publish to the `/currents` resource with `derived: true`, and are structurally excluded from the `environment.current` path:

```ts
export function synthesizeDerivedEvents(gate: DerivedGate, tide: TideStation, start: Date, end: Date): CurrentEvent[] {
  const predictor = createTidePredictor(
    tide.constituents.map((c) => ({ name: c.name, amplitude: c.amplitudeKn, phase: c.phaseDeg })),
    { offset: tide.z0M },
  );
  return predictor
    .getExtremesPrediction({ start, end })
    .map((x) => {
      const lagMs = (x.high ? gate.hwLagMinutes : gate.lwLagMinutes) * 60_000;
      return eventFromParts(new Date(x.time.getTime() + lagMs).toISOString(), 'slack', 0);
    })
    .sort((a, b) => a.utc.localeCompare(b.utc));
}
```

Every event is a `slack` with a speed of exactly `0`, and there are no flood or ebb events to be a peak of. The MCP server picks up the flag and states the limitation in words the agent can read out:

```python
if await currents.derived_for_station(gate.name):
    out["derived"] = True
    out["derived_display"] = (
        "Slack timing only — this pass has no current station, so its slack is "
        "derived from a reference tide port's high/low water. No current speed "
        "or set is predicted."
    )
```

So the answer a skipper gets is slack windows plus an explicit statement of what is missing, instead of a confident bearing:

```text
Malibu Rapids — slack timing only (derived from Point Atkinson HW/LW)
  Wed 05:55 PDT (slack)
  Wed 11:25 PDT (slack)
  flood_dir_true: null    ebb_dir_true: null
```

![A schematic reference-port tide curve with high and low water marked, and arrows offset by twenty-five and thirty-five minutes to the derived gate's slack windows on a lower timeline that carries times only and no speed axis.](/assets/img/tidal-gate-with-no-current-station-derived-slack-reference-tide-port-hw-lw-lag-chs-harmonic-fit-water-level-wlp-signalk-mcp/reference-tide-lags.svg)
*Schematic — the curve shape is illustrative, not plotted CHS prediction data.*

## Why it matters, and the traps nearby

**Represent "less information" as a type, not as a sentinel.** Every shortcut here — a zero flood direction, a zero speed on an ordinary record, an empty constituent array — types cleanly and reads as data downstream. A separate record type is the only version where the compiler, the validator, and the tool output all agree about what is unknown. The `(slack, slack)` string was the system telling us, in the cheapest possible way, that a type mismatch had reached the presentation layer.

**Measure the fit even when the accuracy story is about something else.** The harmonic fit at the reference port is not the weak link here — I re-checked it against CHS predictions over the five days immediately *before* the 210-day training window, entirely out of sample:

```text
n 19   median 5.5 min   mean 8.2 min   max 23.8 min
```

The four worst cases are all low waters. A flat extremum's time is poorly determined by anything, including CHS's own published tables. The dominant uncertainty is the **lag**, which comes from the cruising literature and community consensus — not from a CHS product — so the pass entry in our vault carries a `source confidence: medium` and says where the numbers came from. Fitting to six minutes and then shifting by a number good to maybe fifteen tells you where to spend the next hour, and it isn't on more constituents.

**`getExtremesPrediction`'s prominence filter is window-relative.** Extremes near the edge of the requested window can be dropped or kept depending on the window itself, so a high water just outside the horizon whose shifted slack lands *inside* it goes missing. The horizon function pads by the largest lag plus an hour, then clips:

```ts
const pad = Math.max(gate.hwLagMinutes, gate.lwLagMinutes) * 60_000 + 3600_000;
const events = synthesizeDerivedEvents(gate, tide, new Date(base.getTime() - pad), new Date(end.getTime() + pad))
  .filter((e) => {
    const t = new Date(e.utc).getTime();
    return t >= base.getTime() && t <= end.getTime();
  });
```

The same bites the test: a test that recomputes the expected extremes over a *different* window disagrees with the implementation at the edges, for reasons that have nothing to do with the code under test. Match the padded window exactly.

**Watch for a field name that already means something else.** Surfacing the pairing through `resolve()` ran straight into a collision — `derived` on the resolved record was already a gazetteer-context boolean. The slack block is therefore surfaced as an *effective* `tideReference`, resolving to a gate's explicit pairing or a derived gate's `derived.reference`, and the raw block is not re-exposed under the colliding name:

```ts
/**
 * The effective reference tide port for a paired tide+current view — the
 * registry key of a current gate's `tideReference`, or, for a gate whose
 * slack is derived, its `derived.reference`. Present only when the gate names
 * one; a tide port and a genuinely unpaired gate carry none.
 */
tideReference?: string;
```

**Curated pairings only.** The same change annotated nine ordinary gates with the tide port they're displayed beside — Seymour Narrows to Campbell River, Sechelt Rapids to Point Atkinson, and so on — each the nearest `kind: tide` reference port in the gate's own regime, verified against the positions in the file. Nearest-by-haversine would have been one line of code and wrong at least twice; a guessed pairing pointing at the wrong side of an island is worse than no pairing at all.

## Close

This is one gate on the boat's currents stack — the one that finally forced the pipeline to admit that its entities are not all the same shape. The registry is [`station-corrections`](https://github.com/sailingnaturali/station-corrections), the fitting tool is [`chs-constituents`](https://github.com/sailingnaturali/chs-constituents), and the two consumers are [`signalk-currents`](https://github.com/sailingnaturali/signalk-currents) and [`currents-mcp`](https://github.com/sailingnaturali/currents-mcp) — all MIT, all built for an all-electric charter catamaran that will eventually have to transit that dogleg on the right minute.

*Related: [Offline tidal currents from harmonic constituents — and when not to trust them]({% post_url 2026-07-31-offline-tidal-current-predictions-signalk-harmonic-constituents-noaa-harcon-neaps-fallback-slack-timing-rapids %}) · [Two tidal libraries disagreed: diff their internals, not their outputs]({% post_url 2026-07-21-utide-neaps-tide-predictor-nodal-correction-f-u-schureman-foreman-2n2-slack-water-compare-internals-not-outputs %}).*
