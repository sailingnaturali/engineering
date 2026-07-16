---
layout: post
title: "Porting a tide engine to Swift with the original as the test oracle"
description: "How we ported the Neaps harmonic tide-prediction algorithm (@neaps/tide-predictor, JavaScript) to pure Swift without eyeballing a single curve: wire the reference implementation up as a test oracle that generates golden vectors, port layer by layer (astronomy, IHO node corrections, constituent V₀, timeline prediction, extremes), gate every layer at 1e-6 agreement, emit the 394-constituent catalog as generated data instead of hand-porting 5,000 lines, then validate against NOAA CO-OPS published predictions — max 7.9 min / 3.5 cm at Friday Harbor."
tags:
  - swift
  - testing
  - tides
  - marine
  - open-source
  - javascript
date: 2026-07-16
---

> **TL;DR** — Porting numeric code by hand and eyeballing the output is how you
> ship plausible-looking wrong answers. Instead, treat the original
> implementation as a *test oracle*: scripts that run the reference and dump
> golden fixtures, one per algorithm layer, each ported layer gated on matching
> the oracle to 1e-6 before the next begins. And when the port passes, you're
> still not done — the last gate is matching *reality*, not the reference.
> Repo: [slackwater-engine](https://github.com/sailingnaturali/slackwater-engine).

We needed a pure-Swift harmonic tide/current prediction engine — tide math is
deterministic astronomy, so given a station's harmonic constituents you can
compute heights and high/low turns for any minute, years ahead, with zero
network. The best open reference implementation is
[Neaps](https://github.com/openwatersio/neaps)
(`@neaps/tide-predictor`, JavaScript, MIT). This post is about *how* we ported
it — the oracle-driven method — because the method transfers to any port of
numeric code between languages.

## The problem: numeric ports fail silently

The Neaps algorithm is ~600 lines of real math: astronomical mean-longitude
polynomials, Doodson coefficients, Schureman/IHO node-correction formulas
full of terms like this one:

```swift
private func _nupp(_ N: Double, _ i: Double, _ omega: Double) -> Double {
    let I = d2r * _I(N, i, omega), nu = d2r * _nu(N, i, omega)
    let tan2 = pow(sin(I), 2) * sin(2 * nu) / (pow(sin(I), 2) * cos(2 * nu) + 0.0727)
    return r2d * 0.5 * atan(tan2)
}
```

Flip a sign in one of those, or mix degrees and radians once, and the engine
still produces beautiful sinusoidal tide curves — highs and lows in roughly
the right places, just quietly off by centimetres or minutes in ways that
drift with the 18.6-year lunar nodal cycle. Eyeballing plots against a tide
table catches none of it. A port validated by "looks right" is a liability
you discover at a shallow anchorage.

## Wire the original up as an oracle

The fix is to make the reference implementation *generate the tests*. A small
Node script imports Neaps, evaluates each layer of the algorithm at fixed
instants, and writes the results as JSON fixtures the Swift tests load:

```js
// tools/gen-golden.mjs — Neaps is the oracle. TideEngine (Swift) must match.
import { astro, constituents, createTidePredictor } from '@neaps/tide-predictor';

// Spread of UTC timestamps across the 18.6-year nodal cycle to exercise corrections.
const TIMES = [
  '2000-01-01T00:00:00Z', '2010-06-15T12:00:00Z', '2020-03-21T06:30:00Z',
  '2026-07-12T00:00:00Z', '2026-07-12T18:45:00Z', '2031-11-02T09:15:00Z',
  '2035-09-23T00:00:00Z', '2040-12-31T23:00:00Z',
];

write('astronomy.json', {
  note: 'Neaps astro(date) unwrapped to plain degrees; TideEngine must match within 1e-6.',
  times: TIMES,
  values: TIMES.map((t) => ({ time: iso(t), astro: unwrap(astro(new Date(t))) })),
});
```

Two properties make this an oracle rather than just "some tests":

1. **Fixtures are generated, never hand-written.** `node tools/gen-golden.mjs`
   regenerates every fixture from `@neaps/tide-predictor@0.10.0`. There is no
   opportunity to transcribe an expected value wrong, and bumping the oracle
   version re-derives the whole suite.
2. **There's a fixture per layer, not just end-to-end.** An end-to-end height
   comparison tells you *that* you diverged; a per-layer fixture tells you
   *where*. Every divergence is caught at the layer that caused it.

## Port layer by layer, gate each layer

The algorithm decomposes into five layers, each consuming the one below.
Each got the same treatment: generate the fixture → write the failing Swift
test → port the math → gate on green before starting the next layer.

| Layer | Golden check | Tolerance |
|-------|--------------|-----------|
| Astronomy | 15 quantities (mean longitudes + node angles) × 8 instants across the nodal cycle — 120 values | 1e-6° |
| Node corrections | IHO f/u for 17 base constituents × 3 instants | 1e-6 |
| Constituents | V₀ + compound f/u for ~39 constituents (incl. M4, MS4, 2MK3) | 1e-6 |
| Timeline prediction | 48 h height series, mixed-tide station, 10-min step | 1e-6 m |
| Extremes | high/low count, kind, time, height | 60 s / 0.02 m |

Because both sides implement the same algorithm, the interesting tolerance is
*floating-point agreement*, not "close enough for tides." The prediction test
asserts both — the domain tolerance per point, and a divergence tripwire on
the max error:

```swift
var maxErr = 0.0
for (got, expected) in zip(points, fixture.points) {
    let err = abs(got.height - expected.height)
    maxErr = max(maxErr, err)
    #expect(err < 0.02, "height at \(expected.time): got \(got.height), want \(expected.height)")
}
// The engines share the algorithm, so agreement should be far tighter than 2cm.
#expect(maxErr < 1e-6, "max height error \(maxErr) exceeds 1e-6 — engines diverging")
```

If a future change drifts the port to, say, 5 mm of error — still a perfectly
plausible tide — the tripwire fires long before the domain tolerance would.

The per-layer gates earn their keep on the fiddly semantic mismatches between
the languages, because each one surfaces in the *one* layer it belongs to:

- **Timeline construction.** Neaps floors the start and ceils the end to the
  step interval. Get that wrong and every sample is shifted — the astronomy
  and constituent layers stay green, and the prediction fixture pinpoints it.
- **Array identity vs value semantics.** Neaps recomputes node corrections
  every 24 h and callers detect the refresh with a JS `!==` identity check.
  Swift arrays are value types — there is no identity. The port adds an
  explicit `generation` counter that callers compare instead. The extremes
  fixture is what proves the refresh logic actually matches.
- **What *not* to port.** Neaps ships both Schureman and IHO node-correction
  schemes; the predictor only ever uses IHO. The oracle made that safe to
  verify — no fixture ever exercised Schureman, so it stayed unported.

## Don't port the catalog — generate it

The single biggest porting risk wasn't the math — it was the data. Neaps
bundles ~5,000 lines of constituent definitions: 394 constituents with
speeds, Doodson coefficients, and compound-member decompositions, plus an
IHO Annex-B name parser that resolves compound names at runtime. Hand-porting
5,000 lines of numeric literals is transcription, and transcription is where
silent errors live.

So the catalog isn't code in the Swift port at all. A second codegen script
walks Neaps' constituent map and emits it as a bundled JSON resource — with
the name parsing *already resolved*:

```js
// tools/gen-catalog.mjs — the IHO Annex-B name decomposition + sign resolution
// runs HERE, in Neaps, at build time; Swift consumes the resolved members
// and never needs the parser.
for (const key of Object.keys(constituents)) {
  const c = constituents[key];
  if (key !== c.name) aliases[key] = c.name;   // NOAA "NU2" → canonical "nu2"
  seen.set(c.name, {
    name: c.name,
    speed: c.speed,
    coefficients: c.coefficients ?? null,      // Doodson, when fundamental
    members: c.members?.map((x) => ({ name: x.constituent.name, factor: x.factor })),
  });
}
```

A compound constituent in the emitted `catalog.json` (52 KB, 394 constituents,
83 name aliases) looks like this:

```json
{"name": "2MK3", "speed": 42.9271398,
 "coefficients": [3, -1, 0, 0, 0, 0, 1],
 "members": [{"name": "M2", "factor": 2}, {"name": "K1", "factor": -1}]}
```

And the entire Swift side of "compound constituent support" collapses to two
recursions over pre-resolved members:

```swift
/// Node correction (f, u°). IHO fundamental if the constituent has one, else
/// combined from members: f = Π f_memberᵃᵇˢ⁽ᶠᵃᶜᵗᵒʳ⁾, u = Σ factor·u_member.
func correction(_ name: String, _ a: Astro) -> (f: Double, u: Double) {
    let key = canonical(name)
    if let fundamental = ihoCorrection(key, a) { return fundamental }
    guard let e = byName[key] else { return (1, 0) }
    var f = 1.0, u = 0.0
    for m in e.members ?? [] {
        let c = correction(m.name, a)
        u += m.factor * c.u
        f *= pow(c.f, abs(m.factor))
    }
    return (f, u)
}
```

The aliases matter more than they look: real station data is inconsistent
about constituent names (NOAA publishes `NU2`, `MM`, `RHO`; the catalog's
canonical names are `nu2`, `Mm`, `rho1`), and the engine silently ignores
constituents it can't resolve. Without alias resolution, published harmonic
constants would predict — just with pieces of the tide missing.

Net result: the whole engine is **577 lines of Swift** against Neaps'
~6,300-line bundle, because the 5,000 data lines crossed over as data.

## Golden checks → `swift test` → CI

The first iterations ran as a throwaway command-line checker. Once the layers
were green, the checks converted to [swift-testing](https://github.com/swiftlang/swift-testing)
suites — fixtures under `Tests/TideEngineTests/Fixtures/` — so the whole
oracle runs as plain `swift test`, and CI is 18 lines:

```yaml
jobs:
  test:
    name: swift test
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: swift test
```

That conversion is worth calling out as its own step: an oracle that lives in
a side script rots; an oracle that *is* the test suite re-verifies the entire
port on every push, forever.

## Matching the reference isn't the finish line

At this point the Swift engine reproduces Neaps to floating-point agreement.
That proves the *port* is faithful. It proves nothing about whether the
*algorithm* predicts actual water — if the reference had a bug, we ported the
bug at 1e-6 fidelity.

So the final gate compares against the tide authority itself. A third codegen
script takes published harmonic constants for Friday Harbor, WA
(NOAA 9449880, via `@neaps/tide-database`) and fetches NOAA's own official
high/low predictions from the CO-OPS API for the same window:

```js
const fh = stations.find((s) => s.id === 'noaa/9449880');
const offset = fh.datums.MSL - fh.datums.MLLW; // shift MSL-relative harmonics to chart datum

const url = `https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?...`
  + `&station=9449880&product=predictions&datum=MLLW&interval=hilo&units=metric&time_zone=gmt`;
```

The test predicts extremes from the constants and matches each official
high/low to the nearest computed one of the same kind — with deliberately
*looser* tolerances than the oracle tests, because now the differences are
real (datum rounding, node-correction epoch, constituent-set differences
between NOAA's internal engine and ours):

```swift
#expect(timeErr < 15, "\(off.kind) at \(off.time): time off by \(timeErr) min")
#expect(heightErr < 0.15, "\(off.kind) at \(off.time): height off \(heightErr) m")
```

Result across 12 highs/lows over three days: **max time error 7.9 minutes,
max height error 3.5 cm** — well inside tide-table tolerance. The ~8-minute
residual is expected and instructive: NOAA's engine uses a different
node-correction epoch and constituent set, so *exact* agreement with the
authority was never on the table. Two tolerance regimes, two different
claims: 1e-6 says "the port is faithful"; ±15 min/±0.15 m says "the
predictions are real."

The same validation pass confirmed the data path for Canadian waters:
CHS doesn't publish bundled harmonics the way NOAA does, but its IWLS API
serves tide *predictions* directly — and current predictions for 35+ BC
stations — so Canadian coverage rides the authority's own numbers online
rather than redistributed constituents.

## Trim the API before anyone depends on it

Porting layer-by-layer leaves scaffolding: everything was `public` so the
interim checker could poke at it, and some ported code turned out dead (an
astronomical-speeds derivation the engine never uses — constituent speeds
ship pre-computed in the catalog). The last commit of the phase is a
deliberate audit: delete the dead code, demote the internals, and ship the
smallest surface that does the job —

```swift
public struct Station {
    public init(constituents: [HarmonicConstituent], offset: Double = 0)
    public func heights(from: Date, to: Date, step: TimeInterval = 600) -> [TidePoint]
    public func extremes(from: Date, to: Date) -> [TideExtreme]
}
```

Four public types, two methods. `Astro`, the catalog, the node-correction
table — all internal. Every symbol you expose during the port is a symbol
you can't rename after someone imports it; the oracle makes the trim safe,
because `swift test` proves the demotions broke nothing.

## Three transferable lessons

1. **An oracle turns a risky port into a mechanical one.** Generate golden
   vectors from the reference per layer, and every divergence is caught at
   the layer that caused it — sign flips, degree/radian mixups, and
   value-vs-reference semantic mismatches all surfaced as a single red layer,
   never as "the tides look slightly wrong."
2. **Generate data catalogs from the source; only port algorithms.** The
   5,000-line constituent catalog crossed languages as a JSON resource with
   the hard parts (name parsing, compound decomposition) pre-resolved at
   codegen time. Data you generate can't be mistranscribed, and regenerating
   beats re-porting when upstream moves.
3. **Matching the reference isn't the finish line — matching reality is.**
   A faithful port of a wrong reference is still wrong. Close the loop
   against the authority's published numbers, with honest (looser) tolerances
   and an explanation for the residual.

The engine is MIT, extracted as the open-source core for offline tide work on
our own boats: [slackwater-engine](https://github.com/sailingnaturali/slackwater-engine).
If your home waters disagree with it, the fixtures show you exactly which
layer to blame — send a fix.

*Related:* [Why Claude won't transcribe your PDF — and what to do instead]({% post_url 2026-06-10-output-blocked-by-content-filtering-policy-verbatim-transcription-deterministic-extraction %}) · [Why generic weather MCPs fail for marine navigation (use NDBC buoys)]({% post_url 2026-06-06-marine-weather-mcp-buoy-ground-truth-ndbc-spec-swell-wind-waves %})
