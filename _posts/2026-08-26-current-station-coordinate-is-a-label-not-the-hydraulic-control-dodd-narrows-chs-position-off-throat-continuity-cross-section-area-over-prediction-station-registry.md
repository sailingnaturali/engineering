---
layout: post
title: "A current station's coordinate is a label, not the hydraulic control"
description: "The CHS current station for Dodd Narrows publishes 49.134351 / -123.817132 — a nominal chart label 120 m from the pass's 80 m hydraulic control. Anchoring a Q/A continuity current model there implied 18.01 kn at the throat against a published 9.43 kn, a 91% over-prediction, and blew a 10% anchor-stability bar at 19.7–20.5%. Recovering the control coordinate from a topo-bathymetric DEM and putting it in a shared station registry is the fix; the model it was supposed to unblock still doesn't ship."
date: 2026-08-26
tags:
  - currents
  - tides
  - marine
  - opendata
  - canada
  - bathymetry
---

> **TL;DR** — A published tide or current station coordinate is an *identifier for the place*, not a measurement of where the physics happens. At Dodd Narrows the CHS current station sits 120 m from the pass's actual throat, on water twice the cross-sectional area. Any model that scales speed by continuity (`u ∝ 1/A`) divides by the wrong area there and over-predicts the throat by 91%. Fix it once, in shared reference data, with a `source:` field recording where the real coordinate came from. [Jump to the fix](#the-fix).

![Moving the anchor from the published CHS coordinate to the 80 metre hydraulic control drops the anchor cross-section area swing from 19.9 and 20.5 per cent to 8.6 and 9.6 per cent on the two section-placement variants, while the chart-datum variant gets worse, 19.7 to 22.7 per cent.](/assets/img/current-station-coordinate-is-a-label-not-the-hydraulic-control-dodd-narrows-chs-position-off-throat-continuity-cross-section-area-over-prediction-station-registry/anchor-stability-before-after.svg)

## Problem

We build offline tidal-current prediction for the Salish Sea. Harmonic prediction at a *station* is a solved problem — you fit constituents and evaluate them. Drawing a current *field*, a speed and direction at arbitrary points near a pass, is not.

The obvious source is a coarse ocean model. It is useless at rapids. Here is the coastal-ocean mesh against the fitted station truth at three BC/WA gates:

```text
gate               mesh cell    truth      mesh reads   ratio
Dodd Narrows       516 m        6.2 kn     1.46 kn      0.24
```

A 516 m mesh cell cannot see an 80 m rock gut. It smears a 6-knot rapid into a 1.5-knot drift, and animating that would make bad data more persuasive than no data.

So instead: grow a small patch of certified geometry around each gate. Take a 10 m bathymetric DEM, trace a thalweg through the pass, cut cross-sections every 50–200 m, and scale the station's own fitted speed along the reach by mass conservation:

```text
|u|(x) = |u|_anchor · A_anchor / A(x)
```

One anchor station, one reach, one law. It certified cleanly at Tacoma Narrows against held-out NOAA truth in both directions (speed median 0.32 kn and 0.20 kn against a 0.5 kn bar, no flood/ebb sign flips). It certified at Seymour Narrows. At Dodd Narrows it fell over, and the failure did not look like a data-quality problem:

```console
$ ./sensitivity.py dodd-narrows
anchor area swung 19.9% under variant 'shift+0.5' — anchor placement is sensitivity-unstable
```

That number is not prediction error. It is *anchor stability*: perturb the section grid by half a spacing, or recompute areas at chart datum instead of mean water level, and see how much the anchor section's own cross-sectional area moves. Every scale in the patch is `A_anchor / A(x)`, so a wobbly `A_anchor` multiplies straight into every cell. Over 10% and the pass ships nothing.

Dodd came in at **19.91 / 20.52 / 19.67%** across the three variants. All three. Not marginal — double the bar, on every axis.

## Diagnosis

The tell was in a field the pipeline prints and nobody reads:

```console
$ ./sections.py dodd-narrows
  kept_range [18, 18] of [0, 41] — throat 80.0 m (strip minimum (anchor is not the throat)),
  flare 1.3 → limit 104.0 m
```

`anchor is not the throat`. That string exists because the code has to decide what "the throat" is before it can decide where the patch ends:

```python
FLARE = 1.3        # first section wider than FLARE x throat ends the patch
THROAT_TOL = 1.1   # anchor may exceed the strip minimum by this and still be "the throat"

min_w = min(s["width_m"] for s in sections)
throat = sections[k]["width_m"]          # k = section nearest the anchor station
throat_ref = "anchor section"
if throat > min_w * THROAT_TOL:
    throat, throat_ref = min_w, "strip minimum (anchor is not the throat)"
```

Normally the anchor *is* the throat: you anchor at the rapid, the rapid is the narrowest water, `scale` is 1.0 there by construction. Seymour Narrows behaves exactly that way — anchor section, 770 m, done.

Dodd does not. The section nearest the published coordinate is **160 m** wide. The narrowest section in the strip is **80 m**, two sections away.

![Plan view of Dodd Narrows: the published CHS current-station coordinate falls on a 160 metre wide transect of area 2322 square metres, 120 metres from the 80 metre hydraulic control whose area is 1216 square metres, so continuity scales the published 9.43 knots up to 18.01 knots at the gut.](/assets/img/current-station-coordinate-is-a-label-not-the-hydraulic-control-dodd-narrows-chs-position-off-throat-continuity-cross-section-area-over-prediction-station-registry/dodd-anchor-vs-control.svg)

Two things follow, and they are different bugs.

**1. The published rate is a throat number, so anchoring off the throat over-predicts.** The reach-mean cross-sectional areas are 2322 m² at the published coordinate and 1216 m² at the gut. CHS publishes ~9.43 kn as Dodd's spring maximum — that is the *fastest water in the pass*, which is the water at the control. Feed it in at a section with 1.9× the area and continuity dutifully scales it up:

```text
9.43 kn × 2322 / 1216 = 18.01 kn at the gut
```

Eighteen knots. Dodd is a nine-knot rapid. The model is not wrong; the anchor is in the wrong place, so the model is answering a question nobody asked.

**2. The published coordinate sits on the flare, where geometry is unstable.** Section 18 is on the shoulder where the channel opens out. Nudge the section grid 25 m and the area at that station moves a lot; do the same at the gut and it barely moves. That is where the 19.9% comes from.

Now the part that took the longest to accept: **this is not a data error.** Query the station metadata directly and it is internally consistent:

```console
$ curl -s "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations?code=..." | jq '.[0] | {officialName, latitude, longitude}'
{
  "officialName": "Dodd Narrows",
  "latitude": 49.134351,
  "longitude": -123.817132
}
```

Six decimals. That coordinate is not sloppy — it is precise about the wrong thing. It exists so a mariner can find "Dodd Narrows" in a list and a chart plotter can drop a pin near the pass. It was never a claim about which cross-section the predictions describe. The same is true across the region, and the giveaways are visible:

```text
Seymour Narrows   50.133333 / -125.35      ← lands on its control section (by luck)
Dodd Narrows      49.134351 / -123.817132  ← 120 m SSE of an 80 m gut
Porlier Pass      49.015    / -123.585     ← three decimals, exactly round
```

Porlier's coordinate is `49.015 / -123.585`. Three decimals, both values landing on a round thousandth. Nobody surveyed that. It is a label.

## What we tried (and why it failed)

### Blamed the section spacing

Dodd's gut is only ~200 m long, so we cut sections at 50 m — finer than the pipeline's usual 100–200 m band. Reasonable suspicion: 50 m is under-sampled noise. So we re-ran at 100 m.

```text
spacing   anchor area swing (shift+½ / shift−½ / datum=CD)
50 m      19.91 / 20.52 / 19.67 %
100 m     27.62 / 33.64 / 20.33 %   ← worse
```

Worse on every axis, and the strip's narrowest section reads 100 m instead of 80 m — the coarser grid stops resolving the gut at all. Spacing was not the cause. Recorded in the pass inputs so it never gets re-suspected.

### Moved the anchor to the DEM throat, expecting that to be the fix

It is the obvious next move, so we ran it as a diagnostic before touching any canonical data:

```text
anchor placed at section 20 (the 80 m gut)
  shift +½ spacing    8.60 %   ✓ inside the 10 % bar
  shift −½ spacing    9.58 %   ✓
  datum = chart datum 22.67 %  ✕ worse than before the move
```

Two axes fixed. The third got *worse*. The `datum=CD` variant recomputes every area at chart datum instead of mean water level — at Dodd that removes 3.08 m of water from the section. The gut carries about 12 m over an 80 m width, so 3.08 m is a quarter of its depth: Dodd's cross-sectional area is a strong function of tide stage in a way Seymour's 90–150 m depths simply are not (`datum=CD` moves Seymour's anchor area by 4.56%).

This is the finding that reframed the whole thing. **The position error and the datum sensitivity are two separate problems that happened to sum to the same failing number.** Moving the anchor was necessary and not sufficient, and if we had only ever looked at the aggregate "19.9% vs 10%" we would have concluded the fix didn't work and reverted it.

### Made the area tide-stage dependent

If area is a function of stage, stop treating stage as noise and model it: compute each section's area at seven chart-datum heights (0…6 m), evaluate the paired tide station's fitted model at runtime, interpolate the scale. The interpolation itself is fine — held-out half-metre heights come back within **0.9164%**, and with the datum axis modelled rather than swept, the corrected anchor clears placement sensitivity.

And Dodd still ships nothing. With a stable anchor, the surviving certified range collapses to `[20, 20]` — a single transect, no neighbour to triangulate an interval from, **zero cells** packed.

### Tried the other bathymetry source

The fallback grid, a CHS NONNA-10 tile, resolves the gut at 50 m. Same ending:

```text
1.3× flare rule          → one transect
1.6× diagnostic widening → adjacent 80 m sections fail the unchanged 10 % bar by 12.6–32.9 %
```

No bar was relaxed and no singleton transect was inflated into an area. The ruling instead is a station-local indicator centred on Dodd's corrected coordinate, drawing no fill, outline or boundary — nothing that suggests a certified spatial extent.

## The fix

The whole shipped change is one coordinate and one provenance string, in the registry that owns station identity for every consumer in the workspace:

```diff
 chs-dodd-narrows:
   name: Dodd Narrows
   context: Nanaimo
-  position: [49.1344, -123.8171]
+  position: [49.13546639419797, -123.81735084108287]
   provider: chs
   cities: [Nanaimo]
+  source: GSC West Coast Topo-Bathymetric DEM v2 hydraulic control section
```

Plus the test that pins it, because a coordinate with no test is a coordinate somebody rounds:

```js
const resolved = resolve({ id: "chs-dodd-narrows" });
assert.equal(resolved.latitude, 49.13546639419797);
assert.equal(resolved.longitude, -123.81735084108287);

const dodd = loadRegistry(yaml).get("chs-dodd-narrows");
assert.equal(dodd.source, "GSC West Coast Topo-Bathymetric DEM v2 hydraulic control section");
```

Three details that are the actual work:

**The coordinate was recovered, not inferred.** The pipeline had already *recorded* "~130 m off the control", and it would have been easy to project 130 m along the thalweg bearing and call it done. Instead: regenerate the sections from the DEM and read the generated centre of the minimum-width section straight out.

```console
$ ./sections.py dodd-narrows
$ jq '.sections | to_entries | min_by(.value.width_m) | {index: .key, center: .value.center, width_m: .value.width_m}' \
    passes/dodd-narrows.json
```

The offset between the two shipped positions comes out at **120.0 m on a 351° bearing** — close to the recorded ~130 m, but not equal to it, because the recorded figure was section-centre to section-centre and the label is not on the centreline. Derive the number you are shipping from the artifact that produced it.

**Full precision, no rounding.** `49.13546639419797` is not false precision — it is the generated section centre, and rounding it re-introduces exactly the ambiguity the fix removes. The old value, `49.1344`, was the published coordinate rounded to four decimals. Rounded labels are how a coordinate stops being traceable.

**`source:` is the load-bearing field.** The registry's default provenance is documented once, repo-wide: names are hand-written, positions come from the fitting pipeline. Dodd's no longer does — it comes from a specific DEM version and a specific derivation. Without that string, in six months this is an unexplained coordinate that disagrees with the government's, and the safest-looking action is to "fix" it back.

- **Dataset:** [Canada west coast topo-bathymetric digital elevation model](https://open.canada.ca/data/en/dataset/e6e11b99-f0cc-44f7-f5eb-3b995fb1637e), Geological Survey of Canada Open File 8963, 10 m grid, [OGL – Canada](https://open.canada.ca/en/open-government-licence-canada).
- **Station predictions:** [CHS tidal current predictions](https://tides.gc.ca/en/current-predictions-station) via the IWLS API.

## Why it matters, and the traps next door

**Published reference coordinates are identifiers.** Every published station, gauge, buoy and sensor coordinate you consume was chosen to *name and find* a thing. Your model may need to know where a physical process happens. Those are different requirements, and the data does not tell you which one it is satisfying. The 120 m that is a rounding error on a chart is a factor-of-two error in a cross-sectional area.

**A rule that works at one station and not the next is not a rule you have.** Seymour's coordinate lands on its control section, so Seymour certified and nobody learned anything. Dodd and Porlier both do not. If your first integration succeeds, you have one sample.

**Detect it, don't eyeball it.** The single most useful line in that pipeline is the `THROAT_TOL` branch — "the section nearest the anchor is not the narrowest in this strip." That is a cheap, mechanical assertion any geometry-anchored model can carry, and it turns a subtle physical misplacement into a printed string.

**Watch the walk that keeps the anchor by construction.** Dodd's flare limit is `1.3 × 80 m = 104 m`, and the surviving `kept_range` is `[18, 18]` — the 160 m anchor section, which *itself violates the limit*. The bounds walk starts at the anchor and only tests neighbours, so a single-element range is never checked against its own rule. If you write an outward walk from a seed, decide deliberately whether the seed is exempt.

**Fix it in the shared registry, not the consumer.** The tempting patch is a local override in the pipeline that needed it. Then the app has a different Dodd from the agent tool surface, which has a different Dodd from the harmonic fitter, and the *reason* lives in a commit message in one repo.

![One edit to the shared station registry serves three readers: the harmonic fitter and the offline app pick it up on an npm bump, while the Python MCP server vendors a copy and needs a re-vendor that its drift test enforces.](/assets/img/current-station-coordinate-is-a-label-not-the-hydraulic-control-dodd-narrows-chs-position-off-throat-continuity-cross-section-area-over-prediction-station-registry/registry-one-edit-three-readers.svg)

Be honest about what "shared" buys, though. It is not instant propagation — one reader takes it on a version bump, one needs its build-time generator re-run, and one is Python with no npm at all and vendors a copy of the JSON. That last one keeps a drift test whose entire job is to fail when the copy goes stale:

```python
@pytest.mark.skipif(not REAL.is_file(), reason="sibling station-corrections not present")
def test_bundle_matches_published_registry():
    assert json.loads(BUNDLE.read_text()) == json.loads(REAL.read_text()), (
        "vendored _registry.json drifted from station-corrections/data/registry.json"
    )
```

What the registry actually buys is that the *derivation and the review happen once*. Nobody re-derives the coordinate, nobody re-argues whether it is right, and nobody ships a second, quieter answer.

**Don't let a consumer's need bend the registry's membership rule.** The plan for this change also wanted to pair Dodd with Nanaimo Harbour as its tide reference, because the stage-aware model needed a water-level source. Nanaimo Harbour is not a CHS-designated reference port, and that designation is the registry's entire admission rule for tide stations — an external rule, chosen precisely so a hand-curated list can't quietly grow into a mirror of the whole provider station table. So the pairing did not land. Nanaimo stayed a runtime input to the pipeline that needed it, and the registry kept its rule. A position correction is the registry's job; a private modelling dependency is not.

**The last one is the uncomfortable one.** The model this coordinate was recovered for does not ship. Dodd draws no current field today, from either bathymetry source. The coordinate correction shipped anyway, and it was worth doing on its own: the pass's identity is right for every reader, anything drawn at Dodd is now drawn on the real constriction, and the next attempt at a field model starts from a good anchor and a written-down reason. **Reference-data corrections outlive the pipelines that discover them.** That is a good argument for landing them separately, in their own repo, with their own tests — not as a commit inside the feature that found the bug.

## Close

This came out of building offline current prediction for a boat that will spend a lot of time waiting on tidal gates in the Salish Sea. The station registry is public and MIT: [`@sailingnaturali/station-corrections`](https://github.com/sailingnaturali/station-corrections) — names, contexts and positions for tide and current stations in both countries, shipping [no provider-minted station id](https://github.com/sailingnaturali/station-corrections/blob/main/PROVENANCE.md) so it stays redistributable. The Dodd change is [PR #15](https://github.com/sailingnaturali/station-corrections/pull/15), released in v2.9.2.

*Related:* [Shipping Canadian CHS station data without redistributing the licensed file]({% post_url 2026-07-23-canadian-chs-tide-current-station-data-licensing-no-provider-id-runtime-name-correlation-feist-cch %}) · [A tidal gate with no current station: deriving slack from a tide port]({% post_url 2026-08-11-tidal-gate-with-no-current-station-derived-slack-reference-tide-port-hw-lw-lag-chs-harmonic-fit-water-level-wlp-signalk-mcp %}) · [Harmonic tide predictions read higher than the tide tables]({% post_url 2026-07-16-harmonic-tide-predictions-higher-than-tide-tables-chart-datum-vs-lat-chs-datum-offset-signalk-tides-neaps %})
