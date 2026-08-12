---
layout: post
title: "A nearest-neighbour matcher turned a timing lag into a fake direction bug"
description: "A validation harness matched each golden extremum to the nearest computed event of ANY kind and then asserted the kind matched — a nearest-neighbour matching idiom that silently couples timing error and direction error, so a pure timing lag was reported as a label flip and falsely quarantined two good tidal-current stations. The fix separates the questions: same-kind matching for timing, and direction as the sign of modelled velocity at the golden time. Nearest-neighbor matching couples errors and your test oracle then lies about which dimension is broken."
tags:
  - testing
  - swift
  - tides
  - marine
  - open-source
  - data
date: 2026-08-11
---

> **TL;DR** — If your comparison against golden data matches each expected event
> to the *nearest computed event of any kind* and then asserts the kind, you have
> coupled two independent error dimensions. A timing lag will surface as a
> wrong-label failure and your oracle will confidently blame the wrong thing.
> Match same-kind-to-same-kind for timing, and test direction separately at the
> expected timestamp. [Jump to the fix](#the-fix).

We validate our offline tidal-current engine against the hydrographic
authority's own published current predictions: for each published maximum flood
or maximum ebb, does the model produce the same event, at about the same time,
at about the same speed, and pointing the same way? A validation run over the
Canadian stations came back with two stations flagged as having a **reversed
flood axis** — the model claiming flood where the authority says ebb. That is
the one failure you cannot ship. Both stations were quarantined.

Both stations were fine. The matcher was broken.

![Two comparison idioms give two verdicts on the same golden data: nearest-event-of-any-kind plus a kind assertion quarantines Tillicum Bridge and Calamity Point as reversed-axis stations, while same-kind matching plus a sign-of-velocity direction test measures 0 wrong signs out of 19 and 0 out of 24 and ships both.](/assets/img/nearest-neighbour-matching-couples-errors-validation-matcher-wrong-kind-test-oracle-false-positive-direction-error-golden-data-comparison/two-verdicts.svg)

This post is about the *matcher* — how you compare model output against golden
data. It is the sequel to
[porting a tide engine to Swift with the original as the test oracle]({% post_url 2026-08-11-porting-javascript-to-swift-test-oracle-neaps-tide-prediction-golden-vectors-harmonic-constituents-noaa-validation %}),
which is about where golden data comes from. Same test suite; the bug is in the
other half.

## The problem: a label-flip failure that wasn't

The failing assertion looked like this, and its output is what got two stations
quarantined:

```
✕ maxEbb at 2026-07-14T14:12:00Z: engine labeled slack (0.03 kn)
✕ maxEbb at 2026-07-15T02:41:00Z: engine labeled maxFlood (0.61 kn)
```

Read that at face value and there is only one conclusion available: the engine
is mislabelling direction. For a current station, direction comes from a single
piece of metadata — the **flood direction**, the compass bearing the channel
floods toward, which the model projects the fitted velocity onto. Get that
bearing wrong by 180° and every flood becomes an ebb. It is a real, documented
failure mode: the published `floodDirection` is occasionally wrong for the
actual channel axis. So "the engine labelled ebb as flood" reads as *"the flood
axis is reversed"*, which is a data-quality problem at the station, not a bug in
the model — and the response is to quarantine the station rather than ship a
current that runs backwards.

Here is the harness that produced it:

```swift
for e in fx.events where e.kind != "slack" {
    let t = parseISO(e.time)
    // Nearest computed event by TIME (avoids cross-cycle mis-match at weak,
    // mostly-single-direction stations), then require kind + tolerance.
    let m = try #require(
        computed.min { abs($0.time.timeIntervalSince1970 - t.timeIntervalSince1970)
                     < abs($1.time.timeIntervalSince1970 - t.timeIntervalSince1970) },
        "no computed event near \(e.time)")
    let kind: CurrentEventKind = e.kind == "maxFlood" ? .maxFlood : .maxEbb
    let timeErr = abs(m.time.timeIntervalSince1970 - t.timeIntervalSince1970) / 60
    let speedErr = abs(abs(m.speed) - abs(e.speed))
    #expect(m.kind == kind, "\(e.kind) at \(e.time): engine labeled \(m.kind) (\(m.speed) kn)")
    #expect(timeErr < 20, "\(e.kind) at \(e.time): time off \(timeErr) min (phase field wrong?)")
    #expect(speedErr < 0.3, "\(e.kind) at \(e.time): speed \(m.speed) vs \(e.speed)")
}
```

Four lines of idiom that every golden-data comparison in the world has written
at some point: **find the nearest computed thing, then assert everything about
it.**

## Diagnosis: the matcher couples two independent errors

Two properties of the model are being measured here, and they are independent:

1. **Timing** — is the model's max ebb at the same minute as the published max ebb?
2. **Direction** — does the model think the water is going the same way?

The nearest-neighbour match couples them, because the *search* is over time and
the *assertion* is over kind. The candidate list from `station.events()` contains
slacks as well as extrema. So the match picks the wrong event as soon as the
timing error exceeds roughly half the spacing to the neighbouring event of a
different kind — and then the kind assertion fires on an event that was never
supposed to be the counterpart.

![At a weak station whose prediction runs late, the nearest computed event of any kind to a published max ebb is a slack 17 minutes away, which the old assertion reported as a wrong-kind label flip, while the nearest same-kind event is the model's own max ebb 22 minutes away and the modelled velocity at the published time is minus 0.9 knots, correctly negative for an ebb.](/assets/img/nearest-neighbour-matching-couples-errors-validation-matcher-wrong-kind-test-oracle-false-positive-direction-error-golden-data-comparison/nearest-any-kind-vs-same-kind.svg)

At a strong, cleanly semidiurnal station you never hit that condition: slack to
max is about three hours, so a matcher would need to be ninety minutes wrong
before it grabbed the wrong event. But the stations that got quarantined are
weak and slow-reversing — narrow, shallow, tidally awkward places where the
velocity loafs around zero, the model's own timing error runs to tens of
minutes, and the extrema are broad and low. That is exactly where the gap
collapses and the nearest event of any kind stops being the counterpart.

So the failure output is a lie in a very specific way. The engine is not
labelling anything wrong. It is *late*, and the matcher converts lateness into a
label-flip report. Two error dimensions, one nearest-neighbour search, and the
oracle can no longer tell you which one is broken.

The sign test settles it in one line and is not fooled by timing at all: ask
what the modelled velocity actually *is* at the moment the authority reports a
maximum ebb. At both quarantined stations it is negative at every single one —
**0 wrong signs out of 19, and 0 out of 24**. Directionally perfect. The
quarantine was manufactured by the comparison idiom.

## What we tried (and why it failed)

**Attempt 1: believe the failure and quarantine the stations.** This is the
attempt that cost the most, because it *worked* in the sense that the test went
green and the bad data stopped shipping. Two stations dropped out of the offline
bundle with a note saying the flood axis was reversed, and downstream consumers
grew a stale line in their docs saying those stations "are known to flip."
Nothing about the quarantine looked wrong until someone asked why two stations
in completely different bodies of water, from different fits, would both have a
bad flood bearing.

**Attempt 2: match nearest-by-time *first*, then require the kind.** This is the
idiom above, and it deserves a proper Chesterton's-fence reading, because the
comment sitting on top of it is not decoration:

```swift
// Nearest computed event by TIME (avoids cross-cycle mis-match at weak,
// mostly-single-direction stations), then require kind + tolerance.
```

That comment is describing a *real* earlier bug. If you filter to the same kind
and then take the nearest, at a weak, mostly-single-direction station you can
match across a cycle boundary — grabbing yesterday's ebb, producing a wildly
wrong timing number. Matching by time first was a defence against that. It just
traded a loud, obviously-wrong timing number for a quiet, plausible direction
error, which is the worse trade: an absurd timing number gets investigated, a
credible-looking label flip gets believed.

**Attempt 3: drop slacks from the candidate list.** The obvious minimal patch —
if the nearest event is a slack, stop offering slacks:

```swift
let m = computed.filter { $0.kind != .slack }.min { /* nearest by time */ }
```

It removes the most common wrong match and none of the mechanism. The opposite
extremum is still in the list, and at a station running far enough late, the
nearest non-slack event to a published max ebb is the model's max *flood*. Same
coupled search, same false direction report, now with fewer symptoms — which
mostly means it takes longer to notice.

## The fix

Stop asking one question and reading two answers out of it. Match same-kind for
timing; test direction at the golden timestamp, where timing cannot interfere:

```swift
/// Nearest computed event of the SAME KIND as the golden event.
private func nearestSameKind(_ computed: [CurrentEvent],
                             _ kind: CurrentEventKind, to t: Date) -> CurrentEvent? {
    computed.filter { $0.kind == kind }
        .min { abs($0.time.timeIntervalSince1970 - t.timeIntervalSince1970)
             < abs($1.time.timeIntervalSince1970 - t.timeIntervalSince1970) }
}

/// Sign of the station's velocity at the golden extremum time — the sound
/// direction test (flood positive, ebb negative).
private func signedSpeed(_ station: CurrentStation, at t: Date) -> Double {
    station.speeds(from: t.addingTimeInterval(-30), to: t.addingTimeInterval(30), step: 60)
        .first?.speed ?? 0
}
```

and then the loop asserts the two things separately:

```swift
let kind: CurrentEventKind = e.kind == "maxFlood" ? .maxFlood : .maxEbb
let m = try #require(nearestSameKind(computed, kind, to: t), "no computed \(e.kind) near \(e.time)")
let timeErr = abs(m.time.timeIntervalSince1970 - t.timeIntervalSince1970) / 60
let speedErr = abs(abs(m.speed) - abs(e.speed))

let v = signedSpeed(station, at: t)
#expect(e.kind == "maxFlood" ? v > 0 : v < 0,
        "\(e.kind) at \(e.time): modelled velocity \(v) kn has the wrong sign")
#expect(timeErr < 20, "\(e.kind) at \(e.time): time off \(timeErr) min (phase field wrong?)")
#expect(speedErr < 0.3, "\(e.kind) at \(e.time): speed \(m.speed) vs \(e.speed)")
```

Three assertions, three questions, no shared search. A late station now reports
one number — `time off 22.4 min` — and a reversed station reports a wrong sign.
Neither can impersonate the other.

The same separation, in the TypeScript harness that builds the offline bundle:

```ts
for (const event of observed) {
  const at = Date.parse(event.time);
  let best = Infinity;
  for (const candidate of predicted) {
    if (candidate.kind !== event.kind) continue;   // TIMING: same kind only
    best = Math.min(best, Math.abs(candidate.time.getTime() - at) / 60_000);
  }
  if (best <= MATCH_WINDOW_MIN) deltas.push(best);
}

let wrongSign = 0;
for (const event of extrema) {                      // DIRECTION: sign at the golden time
  const modelled = velocityAt(new Date(event.time));
  if ((event.kind === "maxFlood" && modelled < 0) ||
      (event.kind === "maxEbb" && modelled > 0)) wrongSign++;
}
```

## Why it matters: same-kind matching is the *safer* test, not the laxer one

The instinct when you delete `#expect(m.kind == kind)` is that you have just
removed the check that catches a reversed axis. The opposite is true, and the
argument is worth internalising because it is what makes the fix safe to ship.

A genuinely reversed flood axis does not flip *some* labels. It flips every
event on the station, so the model's max ebbs land where the true max *floods*
are — **about half a tidal cycle away, roughly six hours**. Under same-kind
matching, the nearest computed max ebb to every published max ebb is therefore
six hours out, and blows through a ±20-minute timing gate at *every single
extremum* on the station.

![Same-kind matching still catches a genuinely reversed flood axis: a station that merely runs late puts its ebbs about 18 minutes from the published ebbs and passes the timing gate, while a reversed axis puts the nearest same-kind ebb about six hours away, half a tidal cycle, so the timing gate fails at every extremum instead of flipping a few labels.](/assets/img/nearest-neighbour-matching-couples-errors-validation-matcher-wrong-kind-test-oracle-false-positive-direction-error-golden-data-comparison/reversed-axis-half-cycle.svg)

So the reversed axis is caught *twice* — once loudly by the sign test, once
structurally by the timing gate — and a merely-late station is caught by
neither. Coupled, the two failures were indistinguishable. Separated, they can't
be confused: a real flip is systematic, a false one is occasional. The bundle
builder now encodes exactly that, quarantining only on systematic disagreement:

```
A reversed flood axis quarantines a station outright… The test is the sign of
the modelled velocity at CHS's own extremum times, and the bar is systematic
disagreement (≥ 60% of extrema): a genuinely reversed axis is wrong at nearly
every peak. Occasional wrong signs are timing error at a weak station, not a flip.
```

### The transferable version

None of this is about tides. The shape is:

- **A nearest-neighbour matcher couples every dimension you didn't search on.**
  You search on one axis (time, position, string distance, embedding distance)
  and then assert on others (kind, label, value). Every assertion downstream of
  the match inherits the search's error. The moment the search picks the wrong
  counterpart, the *other* assertions are the ones that fail — and they will
  fail with an entirely credible message about a problem you do not have.
- **The failure mode is a false positive that reads like a serious bug.** A
  coupled matcher does not produce noise, it produces a *specific, plausible,
  wrong* diagnosis. That is worse than a flaky test: you act on it. We deleted
  two good stations from a navigation dataset and wrote the wrong explanation
  into the documentation downstream of it.
- **Match on the dimension you are measuring; test the others where the match
  can't reach.** Same-kind matching for timing. Sign-at-the-expected-timestamp
  for direction. If a check can only be made *after* a match, ask whether a
  mismatch would make it lie.
- **Check that the strict version still catches the real bug** — explicitly,
  with an argument, in a comment. Ours: a reversed axis is half a cycle away, so
  it fails the timing gate everywhere. If you can't make that argument, you have
  loosened the suite rather than fixed it.
- **A test-oracle suite needs its comparison layer audited like production
  code.** Golden vectors get all the attention — where they come from, how
  they're generated, what tolerance they're gated at. The comparison idiom
  between the vectors and your output gets written once, in four lines, and
  never reviewed. It is just as capable of being wrong, and when it is wrong it
  discredits code that works.

The engine and the bundle builder are both MIT, and the tide/current work is
what keeps our own boat off the rocks in passes that only open for twenty
minutes: [slackwater-engine](https://github.com/sailingnaturali/slackwater-engine)
(Swift) and [chs-constituents](https://github.com/sailingnaturali/chs-constituents)
(TypeScript). If a station near you disagrees with them, the validation output
will now tell you which of the two things is actually wrong.

*Related:* [Porting a tide engine to Swift with the original as the test oracle]({% post_url 2026-08-11-porting-javascript-to-swift-test-oracle-neaps-tide-prediction-golden-vectors-harmonic-constituents-noaa-validation %}) · [Offline tidal current predictions when the boat has no signal]({% post_url 2026-07-31-offline-tidal-current-predictions-signalk-harmonic-constituents-noaa-harcon-neaps-fallback-slack-timing-rapids %}) · [Two tide libraries disagreed — compare internals, not outputs]({% post_url 2026-07-21-utide-neaps-tide-predictor-nodal-correction-f-u-schureman-foreman-2n2-slack-water-compare-internals-not-outputs %})
