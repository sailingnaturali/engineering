---
layout: post
title: "Adding a type column to a shared registry breaks every consumer's filter"
description: "A shared npm data package grew an optional kind: tide field, and every consumer that enumerated it kept a hand-rolled 'which rows do I want' filter written before that field existed. Result: ten 'no live id for Victoria' throws per poll cycle on the boat server, and a 'registry gate found no live IWLS station (name drift?)' warning on every build for a station that is missing by definition. Why each consumer's own patch was half a fix, why a kind !== 'tide' denylist is the exact shape of the bug it fixes, and why the selection belongs in the package that owns the data — exported as currentGates(), typed by the three fields it reads so adopting it doesn't force a caller to widen its own record."
date: 2026-08-11
tags:
  - architecture
  - data-model
  - npm
  - typescript
  - signalk
  - currents
---

> A shared data package grew an optional `kind: "tide"` field, with absent meaning `"current"` for backwards compatibility. Every consumer that *enumerated* the registry had a hand-rolled "which rows are gates" filter written before that field existed, so the new rows swept straight in — ten `no live id for Victoria`-style throws per poll cycle on the boat server, and one false `name drift?` warning per build in another repo. The real fix isn't a better filter in each consumer. [Jump to the fix](#the-fix): export the selection from the package that owns the data.

![False log lines fall from ten per cycle to zero in both consumers, but the hand-rolled patch in chs-constituents left one false name-drift warning per build until the shared currentGates selector removed it.](/assets/img/shared-registry-kind-field-breaks-consumer-filters-allowlist-vs-denylist-no-live-id-name-drift-warning/false-log-lines-before-after.svg)

## The problem

Two symptoms, three weeks apart, in two repos that share one dependency.

The SignalK currents plugin, on the boat server, on **every poll cycle**:

```
no live id for Tofino
no live id for Victoria
no live id for Sooke
no live id for Fulford Harbour
no live id for Port Renfrew
no live id for Campbell River
no live id for Point Atkinson
no live id for Vancouver
no live id for Port Alberni
no live id for Owen Bay
```

And the harmonic-constituent bundler, on **every build**:

```
registry gate chs-malibu-rapids found no live IWLS station (name drift?)
```

Neither is fatal, which is exactly why both ran for weeks. The throw drops the
station, so `/currents` still served the right 20 gates; the bundler still emitted
a valid bundle. The cost is noise — a wasted fetch attempt per station per cycle,
real station errors buried under fake ones, and a drift warning that now fires on
a station that *cannot* drift, training you to ignore it when a real CHS rename
lands.

## Diagnosis

The dependency is [`@sailingnaturali/station-corrections`](https://github.com/sailingnaturali/station-corrections)
— station identity (name, position, provider) for the Salish Sea tide and current
stations, published as a plain JSON artifact so non-JS consumers can read it
without npm. It was **currents-only by accident**: current gates were simply the
first data whose identity we owned, not a decision anyone made.

Then it grew a second class. CHS tide reference ports arrived so a gate could name
its companion port:

```yaml
chs-owen-bay:
  name: Owen Bay
  context: Sonora Island
  position: [50.310, -125.223]
  provider: chs
  kind: tide
```

The schema change was written to be maximally compatible:

```js
// kind is optional, not required: the 19 existing gates predate the
// distinction and an absent kind reads as "current", so the resolver
// applies that default (one line) rather than backfilling every entry.
```

Optional-with-a-default is the right call for the *data*. For consumers it is a
trap, because their filters are written in terms of what the registry happened to
hold on the day they were written. Both of them said the same thing:

```ts
// signalk-currents
return Object.entries(data)
  .filter(([, e]) => e.provider === 'chs')
  .map(/* → a station we will fetch a live current series for */);
```

```ts
// chs-constituents
for (const [key, entry] of Object.entries(data)) {
  if (entry.provider !== provider) continue;
  // → a name overlay we will match against the live IWLS station list
}
```

Both answer "which rows are current gates?" with "the ones from this provider."
True when written. Silently false the moment the registry grows a class.

![The shared registry holds four row classes; each consumer hand-rolled a filter that excluded one new class and let the other leak in, so signalk-currents swept in ten tide ports and chs-constituents swept in the derived gate.](/assets/img/shared-registry-kind-field-breaks-consumer-filters-allowlist-vs-denylist-no-live-id-name-drift-warning/registry-classes-and-filters.svg)

The registry today is 31 rows in four shapes: 19 plain current gates (`kind`
absent), 10 tide ports (`kind: tide`), 1 NOAA gate, and one oddity that matters —
a **derived** gate. Malibu Rapids is a genuine current gate that CHS publishes no
current station for at all; its slack comes from Point Atkinson's high/low water
plus a lag:

```yaml
chs-malibu-rapids:
  name: Malibu Rapids
  position: [50.1626, -123.8515]
  provider: chs
  kind: current          # still a gate…
  derived:               # …but there is no series of its own to fetch
    reference: chs-point-atkinson
    hwLagMinutes: 25
    lwLagMinutes: 35
```

So there are two ways to be in the registry and not be something you can fetch a
live current series for — a wrong `kind`, and a right `kind` with a `derived`
block. Each consumer discovered exactly one of them.

## What we tried (and why it failed)

### 1. Exclude the new kind, in the consumer

`chs-constituents`, the day the tide ports landed. Ten false drift warnings per
build, so:

```ts
// Tide reference ports (2.2.0+) have no current series; carrying them
// into the overlay makes the no-live-station drift warning fire 10x/build.
if (entry.kind && entry.kind !== "current") continue;
```

Warnings per build: 10 → 1. The survivor is Malibu. This filter has no opinion
about `derived`, because on the day it was written Malibu did not exist yet — it
was added to the registry the *next day*. A gate that is derived *precisely
because* CHS publishes no station for it can never match a live IWLS station, and
the code warns on exactly that condition. One false warning, every build, for
three weeks.

### 2. Exclude derived gates, in the *other* consumer

`signalk-currents`, the next day, against the other new class — Malibu would have
been swept into the fetch list and thrown every cycle:

```ts
.filter(([, e]) => e.provider === 'chs' && e.derived === undefined)
```

The exact complement of fix #1. Two consumers of one registry, 24 hours apart,
each excluding the class that had just arrived in front of it, neither noticing
they were the same bug. `signalk-currents` still swept in all ten tide ports —
nearly three more weeks of ten throws per poll cycle on the boat server before
anyone read that log.

### 3. Denylist the tide ports

The obvious patch, shipped as 0.11.1:

```ts
.filter(([, e]) => e.provider === 'chs' && e.derived === undefined
  && e.kind !== 'tide')
```

Correct today, and the wrong shape. **The bug was the registry growing a kind this
repo had never seen — and `!== 'tide'` re-acquires that bug the next time it
grows one.** The regression test writes down the shape:

```ts
it('skips a kind it has never seen, rather than assuming it is a gate', () => {
  const future = { 'chs-somewhere': { name: 'Somewhere', position: [49, -123], provider: 'chs', kind: 'wave' } };
  expect(registryChsStations(future as never)).toEqual([]);
});
```

The denylist fails it. An allowlist passes:

```ts
.filter(([, e]) => e.provider === 'chs' && e.derived === undefined
  && (e.kind === undefined || e.kind === 'current'))
```

### 4. Two correct filters, in two repos

Now both consumers agreed. The policy still lived in two places, expressed in two
different styles, in two languages' worth of idiom — and the next reader of that
registry would write a third copy from whatever it happened to hold that month.
Four fixes in, nothing had changed about *why* it kept breaking.

## The fix

Move the selection into the package that owns the data:

```js
export function currentGates({
  registry = new Map(Object.entries(bundledRegistry)),
  provider,
  includeDerived = false,
} = {}) {
  const gates = new Map();
  for (const [id, record] of registry) {
    if (provider !== undefined && record.provider !== provider) continue;
    if ((record.kind ?? "current") !== "current") continue;   // allowlist
    if (!includeDerived && record.derived !== undefined) continue;
    gates.set(id, record);
  }
  return gates;
}
```

Both consumers delete their filters and ask:

```ts
// signalk-currents
return [...currentGates({ registry: new Map(Object.entries(data)), provider: 'chs' })]
  .map(/* … */);
```

```ts
// chs-constituents
const gates = currentGates({ registry: new Map(Object.entries(data)), provider });
for (const [key, entry] of gates) { /* … */ }
```

`kind` is the registry's own editorial classification. Only the package that adds
a class knows what the existing consumers meant by "gate" — so it should be the
one that decides, once, instead of every reader rediscovering the split from a
production symptom.

## Why it matters, and the traps nearby

**An optional column with a default is a breaking change for enumerators.** Semver
calls it a minor: nothing was removed, no field changed meaning, every old row
still parses. But every consumer that iterates rows carries an implicit
`WHERE` clause it never wrote down, and a new row type silently violates it. If
you ship a shared data artifact, "we added a type column" belongs in the release
notes next to the breaking changes, whatever the version number says.

**A denylist re-acquires the bug it just fixed.** `kind !== 'tide'` encodes "the
classes I know about today." The failure mode being patched *was* not knowing
about a class. Prefer `kind is current`, and prove it with a test that passes a
kind you invented.

**Type the shared selector by what it reads, not by your record.** The first
release declared `registry?: Registry` — the package's own full station type.
`chs-constituents` builds its overlay on a deliberately narrow `{name, provider,
kind}` record whose fixtures omit `position` to prove the overlay reads no
position. Adopting the selector meant widening a type to satisfy a signature
rather than a caller, so the follow-up release made it generic over the caller's
shape:

```ts
/** The three fields currentGates reads. */
export interface GateSelectable { provider?: string; kind?: string; derived?: unknown; }

export function currentGates<T extends GateSelectable = RegistryStation>(options?: {
  registry?: Map<string, T>;
  provider?: string;
  includeDerived?: boolean;
}): Map<string, T>;
```

A shared selector that forces its callers to widen their own types is not
adoptable, and un-adopted selectors leave the hand-rolled filters in place. Note
that `tsc` is the only thing that catches this class of regression, so it's worth
a compile-only surface test that instantiates the narrow shape.

**Only the enumerators are at risk.** A third consumer reads the same registry and
never broke: `currents-mcp` looks stations up by key, because each vault pass
names its own `station:` id. A new row class is invisible to code that asks for a
row by name.

![A new row class in a shared registry only breaks the consumers that enumerate every row; a consumer that looks a row up by key never sees the new class at all.](/assets/img/shared-registry-kind-field-breaks-consumer-filters-allowlist-vs-denylist-no-live-id-name-drift-warning/enumerate-vs-lookup.svg)

**A warning that fires on a station missing by definition is worse than no
warning.** The `name drift?` check exists to catch a real CHS rename detaching a
curated gate from its live station — a failure that would otherwise be silent. One
guaranteed false positive per build is enough to teach you to scroll past it. The
value of that last fix isn't the log line it removes; it's the signal it restores.

## Close

All of this runs on a boat: a SignalK server serving tidal-current predictions to
an agent that answers questions about when a pass goes slack. The registry, the
plugin, and the constituent bundler are public —
[station-corrections](https://github.com/sailingnaturali/station-corrections),
[signalk-currents](https://github.com/sailingnaturali/signalk-currents),
[chs-constituents](https://github.com/sailingnaturali/chs-constituents) — and
`currentGates()` is now the only place any of them decides what a gate is.

*Related:* [Offline tidal currents from harmonic constituents]({% post_url 2026-07-31-offline-tidal-current-predictions-signalk-harmonic-constituents-noaa-harcon-neaps-fallback-slack-timing-rapids %}) — what the gates in this registry are actually for — and [two false walls in NOAA's currents API]({% post_url 2026-07-18-noaa-co-ops-currents-api-harcon-empty-constituents-currbin-currents-predictions-not-available-user-agent-404 %}), the other half of where station identity comes from.
