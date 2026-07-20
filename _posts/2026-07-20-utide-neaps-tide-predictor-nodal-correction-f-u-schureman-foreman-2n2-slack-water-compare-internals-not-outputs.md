---
layout: post
title: "Two tidal libraries disagreed: diff their internals, not their outputs"
description: "Porting a tidal harmonic fit from Python utide to TypeScript @neaps/tide-predictor left slack-water timing 24.6 minutes apart at one station. Dropping constituents one at a time (M3, 2N2, MU2, MSF, MF, J1, T2) never found a culprit. Comparing the engines' own astronomical argument V and nodal correction factors f and u localized it in one step: neaps groups constituents by IHO Annex B nodal-correction code, utide uses Foreman satellite-derived per-constituent factors, and 2N2 splits 13%. Then the regime question cut the shipped impact by 4x."
date: 2026-07-20
tags:
  - tides
  - marine
  - typescript
  - python
  - debugging
  - open-source
  - signalk
---

> Two tide libraries gave different answers and bisecting by ablation found nothing, because the difference was spread thin across a dozen small terms. Both libraries expose their own per-constituent astronomical argument and nodal factors — comparing *those* instead of the predictions localized it in one probe. **[Jump to the fix](#the-fix).** Second lesson, nearly as valuable: ask which *regime* your discrepancy was measured in. Ours was measured without re-fitting, and the shipped pipeline re-fits, which made the headline number 4x too scary.

I have a small tool, [`chs-constituents`](https://github.com/sailingnaturali/chs-constituents), that fits tidal-**current** harmonic constituents from Canadian Hydrographic Service published predictions so a chartplotter or SignalK server can predict currents offline. It started in Python on [utide](https://github.com/wesleybowman/UTide). I ported it to TypeScript on [`@neaps/tide-predictor`](https://github.com/openwatersio/neaps), kept the Python running alongside as an oracle, and validated one against the other before deleting the Python.

Most of the port validated clean. One number would not.

## Problem

Nineteen Salish Sea current stations, a 180-day training window, validated out-of-sample against CHS's own published events for the following week. Both implementations got byte-identical input samples, so any difference is the fit, not the fetch.

Extremum timing — peak flood, peak ebb — came out at parity everywhere. Worst difference in either direction was 1.0 minute, which is the resolution of the measure.

**Slack** did not. Median absolute slack-timing error against ground truth, minutes:

```
station              TS (neaps)   Python (utide)
Juan de Fuca East          17.7              9.5
Race Passage                8.1              5.5
```

Slack water is where a current prediction earns its keep — it's the number you plan a transit around. Two stations, both weak and slow-reversing, both worse in the port.

Two hypotheses died fast:

```
mean/offset term  → agrees to 4 decimal places at every station. Not it.
basis degeneracy  → refit both at 240 days (clears more Rayleigh pairs).
                    Gap unchanged. Not it.
```

That leaves the synthesis engine itself. To prove it, feed the **Python's own fitted constituents** through neaps' synthesis and compare against the Python's own predicted events. Now nothing differs except the engine:

```
median slack difference, utide constituents → neaps synthesis
  Juan de Fuca East   24.6 min
  Tillicum Bridge      8.1 min
  Race Passage         5.0 min
  everywhere else     < 2.5 min
  extrema             ≤ 6 min throughout
```

24.6 minutes between two respectable open-source tide engines given the same constituents. Which one is wrong, and where?

## What I tried, and why it failed

The obvious move is to bisect: the disagreement lives in some constituent, so drop them one at a time and watch the number move.

```
Juan de Fuca East, median slack difference after dropping one constituent

  baseline (all)   24.6 min
  drop K2          19.4 min   ← largest single effect
  drop 2N2         ~22   min
  drop M3          ~22   min
  drop MU2, MSF, MF, J1, T2 each moved it by less than 5 min
```

Nothing is guilty. K2 is the biggest single contributor and removing it entirely accounts for a fifth of the gap. There is no culprit constituent because **there is no culprit constituent** — the disagreement is spread across 2N2, M2, MM, J1 and N2 with no dominant term.

This is the failure mode worth naming. **Ablation is a bisection, and bisection assumes the thing you're hunting is localized.** When a discrepancy is a sum of many small contributions, every removal moves the number a little and nothing ever looks responsible. You can run that loop for a long time and learn only that you've run it.

I also had two known convention differences on file and neither explained the magnitude alone:

- utide encodes M3's 180° offset as `semi=-0.5`; neaps encodes it as an extended-Doodson digit 7.
- 2N2 phase differed by a consistent ~5°.

Two suspicious details, one dead-end search, and a 24.6-minute number nobody could source.

## The fix

Stop comparing outputs. Compare **internals**.

A tide engine's prediction is a sum over constituents of

```
v(t) = Z0 + SUM_j  f_j(t) * A_j * cos( w_j*t + V0_j + u_j(t) - phi_j )
```

`A` and `phi` are fitted. Everything else — the speed `w`, the equilibrium/astronomical argument `V0`, and the nodal correction pair `f` (amplitude factor) and `u` (phase offset) — is *astronomy the library computes for you*. Both libraries expose all of it. So instead of diffing 24.6 minutes of predicted slack, diff the four intermediate values, per constituent, at one instant.

**neaps side** — `constituents[name].value(astro(t))` gives V in degrees, `.correction(astro(t))` gives `{f, u}`:

```ts
import { astro, constituents } from "@neaps/tide-predictor";

const NAMES = ["M2", "S2", "N2", "2N2", "MU2", "NU2", "K2", "T2",
               "K1", "O1", "P1", "Q1", "J1", "M3", "MM", "MSF", "MF"];

const t = new Date("2025-07-01T00:00:00Z");
const a = astro(t);

for (const name of NAMES) {
  const c = constituents[name];
  const { f, u } = c.correction(a);
  console.log([
    name,
    c.speed.toFixed(7),        // deg/hour
    c.value(a).toFixed(4),     // V, degrees
    f.toFixed(6),
    u.toFixed(4),              // degrees
  ].join("\t"));
}
```

**utide side** — `FUV` returns all three at once. Note the units: utide returns `U` and `V` in **cycles**, and `freq` in cycles/hour, so multiply by 360 to land in neaps' degrees:

```python
from datetime import datetime, timezone

import numpy as np
from matplotlib.dates import date2num
from utide.harmonics import FUV
from utide.constituents import ut_constants

NAMES = ["M2", "S2", "N2", "2N2", "MU2", "NU2", "K2", "T2",
         "K1", "O1", "P1", "Q1", "J1", "M3", "MM", "MSF", "MF"]

table = [n.strip() for n in ut_constants.const.name]
lind = np.array([table.index(n) for n in NAMES])

t = np.array([date2num(datetime(2025, 7, 1, tzinfo=timezone.utc))])
# ngflgs = [nodsatlint, nodsatnone, gwchlint, gwchnone] — all zero means
# exact nodal/satellite corrections and exact Greenwich phase, no shortcuts.
F, U, V = FUV(t, t[0], lind, 48.5, [0, 0, 0, 0])

for name, i in zip(NAMES, range(len(lind))):
    print("\t".join([
        name,
        f"{ut_constants.const.freq[lind[i]] * 360:.7f}",  # deg/hour
        f"{V[0, i] * 360:.4f}",                           # V, degrees
        f"{F[0, i]:.6f}",
        f"{U[0, i] * 360:.4f}",                           # u, degrees
    ]))
```

**Validate the mapping before you trust the diff.** The first run produced utide values that looked wrong, and the honest first question is not "which library is broken" but "is my comparison harness lining up the same waves?" A name-keyed lookup across two independent constituent tables is exactly the place an off-by-one index bug hides, and it will happily produce a beautiful, entirely fictional disagreement. So check identity by a quantity that doesn't depend on your mapping being right — **frequency**:

```
speed match, neaps vs utide, all 17 constituents:  < 1e-7 deg/hour
```

Same waves. Now the diff means something — and the frequency match doubles as a check on the unit conversion, since a wrong factor on utide's cycles would have thrown the speeds off by exactly that factor.

## Diagnosis

Three findings, in the order they landed.

**1. It is not the astronomical argument.** `V` agrees between the engines to **0.00°** on every constituent in the basis. The single exception is M3's known 180° offset, which lives in V, not u. Whatever the 24.6 minutes is, the two libraries agree exactly on where the sun and moon are.

**2. It is not the linear-phase shortcut either** — a hypothesis the original ablation never got around to testing. neaps evaluates `V` once at the start of the series and carries phase forward as `V0 + wt` rather than re-evaluating the astronomy at every sample. That's an approximation, and approximations are suspects. So check whether neaps' own tabulated `speed` actually equals the time derivative of its own `value()`:

```
d/dt value()  vs  tabulated speed:       agree to ~1e-8 deg/hour
accumulated phase drift over 187 days:   < 0.0002 deg, every constituent
```

Sound. Testing a hypothesis and *clearing* it is real progress even though it moves no numbers — it permanently removes a thing you'd otherwise keep circling back to.

**3. It is the nodal corrections, and it is a convention difference, not a bug in either library.** The nodal pair `f`/`u` corrects for the 18.6-year regression of the lunar nodes, and there are two schools:

- **neaps** applies **grouped** factors: it groups constituents by their [IHO Annex B](https://iho.int/) nodal-correction code, and constituents sharing a code share `f`/`u` *exactly* — M2, N2, 2N2, MU2 and NU2 agree to nine decimal places. O1 and Q1 share another code.
- **utide** applies **Foreman's satellite-derived per-constituent** factors, where each constituent gets its own, derived from the satellite lines around each main line.

The largest split:

```
constituent     f (neaps)     f (utide)     delta
2N2             0.965         1.110         13%      (+ ~3.6 deg in u)
```

neaps' 0.965 for 2N2 is just M2's value, because in the grouped scheme 2N2 *is* in M2's group. utide computes 2N2's own. Neither is wrong: grouping is the classical approximation — the tradition [Schureman](https://tidesandcurrents.noaa.gov/publications/SpecialPubNo98.pdf) codified and the one IHO's tables carry forward — and satellite-Foreman is the refined one. (Historical nicety for anyone in these waters: [Foreman's manual](https://waves-vagues.dfo-mpo.gc.ca/Library/54866.pdf) came out of the Institute of Ocean Sciences at Patricia Bay, which is about ten miles from the stations that surfaced this.)

And that is exactly why the ablation was doomed. The disagreement is a grouped-vs-per-constituent scheme difference, so it touches *every* constituent whose group has structure — a little bit each, no dominant term, nothing to bisect onto.

One asymmetry does look like a genuine gap rather than a convention: **utide returns `f = 1.0` and `u = 0.0` exactly for MM, MSF and MF** — no nodal correction at all on the long-period constituents, where neaps applies real factors. That is the one place I'd say neaps is more likely correct. It barely matters for currents, where those amplitudes are small.

## Check the default before you blame the library

Be careful with the label here, because I nearly got it wrong in a way that would have been quietly wrong forever.

neaps ships **two** fundamentals sets, `iho` and `schureman`, and they are selectable:

```ts
createTidePredictor(constituents, { nodeCorrections: "schureman" });
```

The default is `iho` — `correction(astro, fundamentals = ...)` resolves to the IHO set for any falsy argument — and `iho` is what the fit path and every number above actually used. I had originally written this up as "neaps applies Schureman factors," which is a reasonable guess from the fact that a `schureman` export exists, and it is wrong.

It matters, because the two sets are not interchangeable:

```
switching neaps from iho to schureman
  J1   moves 7.2%
  MF   moves 5.5%
```

Sit that next to the thing this whole post is about. **J1 differs by 7.2% between neaps' own two modes, against 1.5% between neaps and utide.** The intra-library spread is wider than the inter-library spread I spent a day characterizing. "Which nodal convention" turns out to be a bigger lever than "which library" — and if you attribute a discrepancy to a library without checking which convention it defaulted to, you can produce a confident, well-measured, completely misattributed finding.

The only reason I caught it is that the default was spelled out in the type signature. Read it.

## The regime question — and why 24.6 minutes was 4x too scary

Here's the part that changed the verdict.

The 24.6-minute figure was measured by feeding utide's constituents into neaps' synthesis. **Nothing is re-fitted in that setup**, so the entire f/u disagreement lands directly in the output.

The shipped pipeline does not work that way. It fits *and* synthesizes in neaps. A least-squares fit solves for amplitude and phase against the same `f`/`u` the synthesis will later apply — so any **constant** offset in `f`/`u` is absorbed into the fitted `A` and `phi` and cancels exactly. What survives is only the *drift* in `f`/`u` across the training-to-validation span.

Weighted by fitted amplitude at Dodd Narrows:

```
raw cross-engine  (the regime 24.6 min was measured in)   2.9%  of M2
post-fit residual (the regime that actually ships)        0.72% of M2
```

0.72% of M2 is roughly 0.85 minutes at an ordinary zero crossing. Multiply by the ~7x amplification a slow reversal gives — a weak, lazily-reversing station spends a long time near zero, so a small velocity error moves the crossing a long way in time — and you land on the 8.2-minute slack gap actually observed at Juan de Fuca East. **Mechanism and magnitude both check out, and the headline number overstated the shipped impact by about 4x.**

Same logic retires M3. Its scary-looking 180° convention difference drifts by 0.03° over the span — it is *constant*, so the fit absorbs it completely. Pure bookkeeping, zero effect on output.

**Verdict: not worth fixing.** The residual sits below the CHS validation floor and neither engine wins against ground truth — utide is closer at Juan de Fuca East and Race Passage, neaps is closer at Blackney, Tillicum, Sechelt and Hole in the Wall. Adopting Foreman factors in neaps would be real work with no evidence it improves anything. The whole stack is neaps-based, so agreeing with neaps is the more useful consistency. The characterization goes upstream as a documentation note, not a defect report.

## Why it matters

Five transferable pieces, none of them about tides.

**1. Ablation cannot find a distributed cause.** Dropping one input at a time is a bisection, and bisection needs the target to be localized. If the true cause is a scheme-level difference touching many terms, ablation returns a flat, uninformative gradient — every removal moves the number a little, nothing is guilty, and you conclude "no single X explains it" without ever learning what does. Recognize that flat gradient as a *signal*, not a stalemate: it's telling you to stop bisecting.

**2. When two implementations disagree, diff their intermediates.** Both of these libraries expose their internal astronomy. Comparing V, f and u took one probe and split the problem into "identical" and "the entire difference is here" in a single step, after the output-space search had run out of ideas. Almost any pair of libraries computing the same thing has this surface — parsers expose tokens, ML frameworks expose layer activations, numeric code exposes every stage. Diffing outputs tells you *that* you disagree; diffing intermediates tells you *where*.

**3. Validate the identity mapping before trusting a cross-library comparison.** A name-to-index lookup between two independent tables is a great place for a silent bug, and it produces a diff that looks like a real finding. Verify with something the mapping can't fake — here, matching frequencies to 1e-7 °/h.

**4. Check which convention your library defaulted to before blaming the library.** neaps' own two nodal sets differ by more on J1 (7.2%) than neaps and utide differ (1.5%). A library is not one implementation — it's a default plus a set of options, and "library A disagrees with library B" is only meaningful once you know which mode each one was in. The default is usually right there in the type signature.

**5. Ask which regime your number was measured in.** A difference measured in an artificial setup is not the difference your users see if the shipped path is different. Ours was measured with no re-fitting; the pipeline re-fits, and a fit absorbs any constant offset in a correction factor. That distinction was worth a 4x correction to the severity, and it's the difference between "chase this for a week" and "document it and move on."

One practical bonus: the event-comparison harness that produced the 24.6 minutes can never live in that repo, because it needs CHS-derived data and the [CHS licence](https://tides.gc.ca/en/licence-agreement) forbids redistributing it. The f/u probe above has that property inverted — **it uses no station data at all**, only the two libraries' own astronomy. Both snippets run standalone. That's a nice general property of internals-diffing: it's usually cheaper to reproduce and share than the output comparison it replaces.

I'm building an all-electric charter catamaran's software stack in the open, and offline current prediction for the Salish Sea's tidal gates is a piece of it — the pipeline is [`chs-constituents`](https://github.com/sailingnaturali/chs-constituents), and the SignalK plugin that consumes it is [`signalk-currents`](https://github.com/sailingnaturali/signalk-currents).

**References:** [Schureman, *Manual of Harmonic Analysis and Prediction of Tides*, Special Publication 98](https://tidesandcurrents.noaa.gov/publications/SpecialPubNo98.pdf) (1958) · [Foreman, *Manual for Tidal Heights Analysis and Prediction*, Pacific Marine Science Report 77-10](https://waves-vagues.dfo-mpo.gc.ca/Library/54866.pdf) · [UTide (Python)](https://github.com/wesleybowman/UTide) · [neaps](https://github.com/openwatersio/neaps)
