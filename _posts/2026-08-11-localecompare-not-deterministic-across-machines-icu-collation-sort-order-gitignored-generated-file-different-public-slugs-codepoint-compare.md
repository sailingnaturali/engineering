---
layout: post
title: "A localeCompare in a build script minted different public URLs per machine"
description: "A build script sorted generated station data with String.prototype.localeCompare and no pinned locale. The output file is gitignored and rebuilt by npm run dev, npm run build and npm test, and a deterministic slug ladder hands each URL to whichever station the sort reaches first — so localeCompare's collation, which varies with the runtime's ICU build, was minting different permanent public URLs on different machines with no tracked diff to catch it. Why pinning the locale doesn't fix it, why Array.prototype.sort being stable since ES2019 is the wrong lever, and why the regression test has to pin real pipeline output instead of a constructed case."
date: 2026-08-11
tags:
  - javascript
  - nodejs
  - icu
  - i18n
  - build-tools
  - determinism
  - testing
---

> **TL;DR** — `String.prototype.localeCompare` with no locale argument uses
> whatever collation the runtime happens to have. If a sort ordered by it
> decides an identifier — a slug, a first-wins registry key, an index — that
> identifier is pinned to the machine, not to the repo. Sort by codepoint
> (`a < b ? -1 : a > b ? 1 : 0`) with an id tiebreak for anything a URL is
> built from, and keep `localeCompare` for what a human reads.
> [Jump to the fix](#the-fix).

[Slackwater](https://github.com/sailingnaturali/slackwater-web) is an
offline-first tide and current app for the Salish Sea. It bundles 133 NOAA
harmonic current stations, and each one gets a human-readable URL —
`/deception-pass`, `/the-narrows`, `/hale-passage`. Those URLs get shared. They
are the closest thing a static PWA has to a primary key.

NOAA gives a lot of those stations the same name. Of the 133 bundled stations,
**40 share a landmark name with at least one sibling** — 17 names in all —
distinguished only by a qualifier NOAA tacks on after a comma:

```console
$ node -e 'JSON.parse(require("fs").readFileSync("src/data/currents.json"))
    .filter(s => s.name.startsWith("Hale Passage"))
    .forEach(s => console.log(s.id, JSON.stringify(s.name)))'
noaa/PUG1529 "Hale Passage, East end"
noaa/PUG1530 "Hale Passage, West end"
noaa/PUG1710 "Hale Passage, east of Lummi Point"
```

Three stations, one slug: `hale-passage`. So there's a deterministic ladder that
hands out the collisions — plain slug, then `-current`, then the qualifier
folded back in, then the NOAA station id:

```ts
export function assignSlug(
  r: { slug: string; name: string; context: string },
  id: string,
  used: Set<string>,
): string {
  const candidates = [
    r.slug,
    `${r.slug}-current`,
    toSlug(`${r.name} ${r.context}`),
    `${r.slug}-${id.replace("noaa/", "").toLowerCase()}`,
  ];
  const slug = candidates.find((c) => !used.has(c)) ?? candidates[candidates.length - 1];
  used.add(slug);
  return slug;
}
```

Deterministic — given an order. `assignSlug` is called in a `.map()` over the
station array, so **the first station the array reaches claims rung 1**. Which
station that is depends entirely on how the array got sorted.

## Problem

The array gets sorted in a build script, one line, entirely unremarkable:

```js
// scripts/build-currents.mjs
const stations = bundle.stations
  .filter(/* harmonic only, primary bin, in-bounds, non-zero amplitude */)
  .map(/* reshape */)
  .sort((a, b) => a.name.localeCompare(b.name));

writeFileSync("src/data/currents.json", JSON.stringify(stations));
```

Two facts about that output file turn a sort into a URL problem.

**One: it's gitignored.**

```console
$ grep -n currents.json .gitignore
5:src/data/currents.json
```

**Two: every developer-facing command rebuilds it.**

```json
"scripts": {
  "build:data": "npm run build:stations && npm run build:currents",
  "dev":   "npm run build:data && vite",
  "build": "npm run build:data && tsc && vite build",
  "test":  "npm run build:data && vitest run"
}
```

So: whichever machine runs `dev`, `build` or `test` regenerates the 186 KB
station file, in that machine's sort order, and the ladder assigns public,
permanent, already-shared URLs off the back of it. There is no tracked artifact
anywhere in the repo recording which station got `hale-passage-current` last
time.

![Sorting the same 133-station NOAA currents bundle by codepoint compare versus localeCompare hands the clean hale-passage-current URL to two different stations, because the slug ladder gives each rung to whichever station the sort order reaches first.](/assets/img/localecompare-not-deterministic-across-machines-icu-collation-sort-order-gitignored-generated-file-different-public-slugs-codepoint-compare/slug-ladder-two-sort-orders.svg)

## Diagnosis

`localeCompare` called with no locale uses the runtime's default collation, and
collation is not codepoint order. The collision that bites this dataset is the
simplest one there is — case.

```console
$ node -e '
  const a = "Hale Passage, West end", b = "Hale Passage, east of Lummi Point";
  console.log("localeCompare:", a.localeCompare(b));  // 1  -> West sorts AFTER east
  console.log("codepoint:    ", a < b);               // true -> West sorts BEFORE east
'
localeCompare: 1
codepoint:     true
```

Codepoint order puts `W` (0x57) before `e` (0x65). Collation folds case at the
primary level and puts `east` before `West`. Both are correct sorts. Only one of
them can be the URL.

I re-ran the whole pipeline under both comparators and diffed the assigned
slugs:

```console
$ node scratch/probe.mjs
distinct base names: 110
names with >1 station: 17
stations in a collision group: 40
FLIP noaa/PUG1530 codepoint: hale-passage-current            localeCompare: hale-passage-west-end
FLIP noaa/PUG1710 codepoint: hale-passage-east-of-lummi-point localeCompare: hale-passage-current
FLIP noaa/PUG1546 codepoint: pickering-passage-current        localeCompare: pickering-passage-west-of-squaxin-island
FLIP noaa/PUG1547 codepoint: pickering-passage-off-graham-point localeCompare: pickering-passage-current
FLIP noaa/PUG1526 codepoint: the-narrows-current              localeCompare: the-narrows-north-end-west-side
FLIP noaa/PUG1524 codepoint: the-narrows-north-end-midstream  localeCompare: the-narrows-current
stations whose public slug differs: 6
```

Six stations, three name groups — Hale Passage, Pickering Passage, The Narrows.
Not a hypothetical: switching the comparator immediately reassigned six live
URLs.

The severity comes from the gitignore, not from the sort. A sort that varies is
a nuisance. A sort that varies, feeds a first-wins identifier, and writes to an
untracked file is a class of bug where **the wrong output can never appear in a
diff**. Nobody reviews it because there is nothing to review.

![The build script's localeCompare sort feeds a gitignored currents.json, so the collation of whichever machine ran dev, build or test decides the permanent public slug with no tracked diff to review.](/assets/img/localecompare-not-deterministic-across-machines-icu-collation-sort-order-gitignored-generated-file-different-public-slugs-codepoint-compare/gitignored-artifact-no-tracked-diff.svg)

## What I tried (and why it failed)

### Pin the locale

The obvious fix. `localeCompare` is non-deterministic because the locale is
implicit, so make it explicit:

```js
.sort((a, b) => a.name.localeCompare(b.name, "en-US"));
```

Identical output. So I widened it — every ladder outcome, under fifteen locales
and collation options:

```console
$ node scratch/locales.mjs
distinct slug outcomes across locales: 1
  group 1 en-US, en-GB, de-DE, fr-FR, sv-SE, tr-TR, cs-CZ, da-DK, ja-JP,
          zh-CN, pl-PL, es-ES, en-US-u-kf-upper, en-US-u-ka-shifted, en-US-u-kn-true
codepoint vs any-locale differing slugs: 6
```

Every locale I could name agrees with every other locale, and all fifteen
disagree with codepoint order. **Pinning the locale doesn't touch the axis that
actually flips this.** The `en-US-u-kf-upper` case-first keyword doesn't do it
either — case-first reorders `A` against `a` for the *same* letter, not `W`
against `e`.

That's worth sitting with, because it's the opposite of the reassuring result.
The variation isn't "someone in Germany gets different URLs." It's:

- **ICU presence.** Node's own docs mark `String.prototype.localeCompare` as
  *"partial (not locale-aware)"* under
  [`--with-intl=none`](https://nodejs.org/api/intl.html), meaning it "carries out
  its operation just like the non-`Locale` version of the function." A Node
  without full ICU produces the codepoint order in the figure above — literally
  the other column. Node ships full-icu by default now, but self-built,
  distro-packaged and size-trimmed container images all still exist.
- **ICU and CLDR version.** Collation tables ship with ICU, and ICU tracks CLDR.
  This machine is `node v24.1.0 / icu 77.1 / cldr 47.0`. A different Node major
  is a different table. Punctuation and symbol weights are exactly the part of
  the table that gets revised.

Both of those are properties of the machine. Neither is pinned by anything in
the repo. A comparator whose answer is a property of the machine cannot be
allowed to name a URL — and I couldn't demonstrate the flip by changing `LANG`,
which is precisely why it would have survived a casual look.

### "Just use a stable sort"

Wrong lever, and a common reflex. `Array.prototype.sort` has been
[required to be stable since ES2019](https://tc39.es/ecma262/#sec-array.prototype.sort);
V8 has been stable since Node 11. Stability guarantees that *equal* elements keep
their relative order. It says nothing about a comparator that decides
inequalities differently on a different machine. A perfectly stable sort with a
drifting comparator drifts.

Stability *is* worth a thought here, though, for the opposite reason: two
stations could genuinely have equal names, at which point stability preserves
whatever order the vendored extract happened to be in — which is also not
something the repo pins. Hence the id tiebreak in the fix.

### Commit the generated file

Tempting: check `currents.json` in, and a reordered build shows up as a diff.
Real, but it's the wrong shape. It makes a wrong build *reviewable*, not
*impossible* — someone still has to notice 186 KB of reordered JSON in a PR and
work out that line 4,012 moving means a URL changed. And the file re-churns on
every NOAA re-vendor, so the signal drowns immediately. Fix the comparator; use
a test for the noticing.

### The unit test that was already green

The ladder had tests. They were added in the same session, one commit earlier,
and they passed under **both** orderings:

```ts
it("pins the ladder order: exact slug, then -current, then the qualifier folded in", () => {
  const used = new Set<string>();
  const a = assignSlug({ slug: "alki-point", name: "Alki Point", context: "1 mile West of" }, "noaa/PUG1502", used);
  const b = assignSlug({ slug: "alki-point", name: "Alki Point", context: "West of" }, "noaa/PUG1516", used);
  const c = assignSlug({ slug: "alki-point", name: "Alki Point", context: "near the ferry dock" }, "noaa/PUG1599", used);
  expect(a).toBe("alki-point");
  expect(b).toBe("alki-point-current");
  expect(c).toBe(toSlug("Alki Point near the ferry dock"));
});
```

Read what it actually asserts. It constructs three station objects **in an array
literal, in the order it wants**, and hands them to `assignSlug` one at a time.
It proves the ladder walks its rungs correctly. It cannot fail because of a
re-sort, because it never touches the sort — the third argument is even a
freshly-constructed `Set`, so it doesn't touch the real `used` set either. A
green test here is a claim about the ladder, not about the URLs the app ships.

## The fix

Two parts. Sort by codepoint, with the station id as the tiebreak:

```js
// scripts/build-currents.mjs
// Codepoint compare, not localeCompare: this file is gitignored and rebuilt on
// whatever machine runs dev/build/test, and localeCompare with no locale pinned
// uses the runtime's default collation — which can mint different public slugs
// for the colliding station names on different machines. The id tiebreak keeps
// ties (equal names) deterministic too.
.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : 1));
```

And pin the real pipeline's output — not a constructed case — for one known
collision:

```ts
it("pins the real Alki Point ladder outcome (catches a re-sort silently reassigning public slugs)", () => {
  // Pinned to actual output from the build pipeline, not constructed — a
  // locale-dependent or otherwise reordered sort in build-currents.mjs would
  // flip which one gets the bare slug without any other test catching it
  // (currents.json is gitignored, so there's no tracked diff to notice either).
  const oneMileWest = resolvedNoaaCurrentStations.find((s) => s.id === "noaa/PUG1502")!;
  const west = resolvedNoaaCurrentStations.find((s) => s.id === "noaa/PUG1516")!;
  expect(oneMileWest.slug).toBe("alki-point");
  expect(west.slug).toBe("alki-point-current");
});
```

`resolvedNoaaCurrentStations` is the module the app itself imports, built from
the generated JSON. `npm test` runs `build:data` first, so this assertion runs
against a freshly generated bundle on every machine and in CI. That's the whole
point: it's the only artifact in the repo that says *which station owns which
URL*, and it's an assertion rather than a 186 KB blob.

## Why it matters / gotchas

**Split the two jobs of string comparison.** Collation answers "what order
should a human read these in." Codepoint comparison answers "which of these two
strings is canonically first." Sorting a station list for display should stay
`localeCompare` — an app used in Québec should file `Île` sensibly. Anything a
URL, cache key, content hash, or first-wins registry is built from must be
codepoint, because the answer has to be a property of the data and not of the
machine. `Intl.Collator` is not an escape hatch; it's the same ICU tables with a
nicer API.

**The generalization is bigger than sorting.** The dangerous pattern is
*ordering that becomes an identifier* in an *untracked* artifact. Slugs are one
instance. So are array-index ids in generated code, "first registration wins"
plugin keys, and anything downstream of `Object.keys()`, `fs.readdir()`, or a
glob. Ask of any generated file: if its order changed, would anything permanent
change with it — and would a diff show me?

**Ship the redirect, but don't count it as the fix.** Slackwater resolves a URL
segment in three passes: current slug, then a recorded former slug, then the
provider id, so an old shared link still lands on the right station. That's a
seatbelt. It only helps for a slug someone *noticed* had changed and wrote down.
The bug here is specifically the class where nobody notices.

**Grep your build scripts, not just your app code.** `localeCompare` in a
component that renders a list is fine. `localeCompare` in something that writes
a file is a question worth answering every time:

```console
$ rg 'localeCompare|Intl\.Collator' scripts/
```

I run this stack on a boat — an offline-first PWA for tides and currents in the
Salish Sea, part of the software for an all-electric charter catamaran. The
Slackwater web app is public at
[sailingnaturali/slackwater-web](https://github.com/sailingnaturali/slackwater-web).

*Related: [two false walls in NOAA's currents API]({% post_url 2026-07-18-noaa-co-ops-currents-api-harcon-empty-constituents-currbin-currents-predictions-not-available-user-agent-404 %}) covers where these station records come from, and [porting a tide engine to Swift with the original as the test oracle]({% post_url 2026-08-11-porting-javascript-to-swift-test-oracle-neaps-tide-prediction-golden-vectors-harmonic-constituents-noaa-validation %}) is the same test suite from the other end — pinning real output instead of eyeballing it.*
