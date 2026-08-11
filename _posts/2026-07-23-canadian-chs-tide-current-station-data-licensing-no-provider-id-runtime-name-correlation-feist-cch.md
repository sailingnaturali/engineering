---
layout: post
title: "Shipping Canadian CHS station data without redistributing the licensed file"
description: "NOAA tide/current station data is US public domain and redistributes freely; Canadian CHS data comes with a bespoke Crown licence (IWLS terms of use) that forbids it. Copyright never protected the facts — Feist v. Rural (499 U.S. 340), CCH Canadian v. LSUC (2004 SCC 13), and no sui-generis database right in either country — so the real constraint is contract, not copyright. Here's the design: ship an independently-obtained factual registry with zero provider-minted station ids, and resolve CHS's opaque station handle at runtime under the operator's own API licence, joining records by name."
date: 2026-07-23
tags:
  - opendata
  - licensing
  - marine
  - signalk
  - canada
  - copyright
---

{% raw %}

> **TL;DR** — US tide/current station data (NOAA) is public domain and you can bundle it into anything. Canadian data (CHS) is not: the IWLS API licence forbids redistributing derivative products. The facts inside — names, positions — aren't copyrightable anywhere (Feist, CCH Canadian), and there's no EU-style database right in the US or Canada. So the constraint isn't copyright, it's the *terms of use* — a contract. The safe design ships your own independently-obtained registry that carries **no provider-minted station id**, and resolves CHS's opaque handle at runtime under your own API licence, joining by station **name**. [Jump to the fix](#the-fix).

A quick disclaimer, said once: I'm an engineer reasoning about licences, not a lawyer, and none of this is legal advice. But the reasoning is the whole point of the post — if you're building a marine, mapping, or civic-data app on government open data and you hit "can I redistribute this?", the shape of the answer is worth having.

## Problem

We predict tidal currents offline for a boat in the Salish Sea, which straddles the Canada/US border. Both national hydrographic offices publish the harmonic data that makes offline prediction possible. One of them lets you ship it. The other does not.

**US — NOAA — public domain.** NOAA publishes tidal-current harmonic constituents as public-domain data. Anyone can bundle them into anything, commercial or not, and offline prediction just works. There is no problem to solve here.

**Canada — CHS — a bespoke Crown licence.** The [CHS licence agreement](https://tides.gc.ca/en/licence-agreement) you accept by using the IWLS API is *not* the [Open Government Licence](https://open.canada.ca/en/open-government-licence-canada). Three clauses bite:

```text
Clause 3  — CHS copyrights "shall not be sold, licensed, leased, assigned
            or given to a third party."
Clause 4  — prohibits derivative products "for commercial purposes, for
            sale or profit under any form whatsoever."
Clause 10 — permits non-profit derivative products, provided you carry a
            prominent notice (your name, that it contains CHS IP, Crown
            copyright retained, not for navigation, CHS does not endorse it).
```

Clause 10 lets *you* derive data for your own non-commercial use. Clause 3 stops anyone from handing you — or you handing anyone — a finished bundle. So you cannot ship a Canadian tide/current dataset the way you ship a NOAA one.

That leaves a design question with a non-obvious answer: **how do you ship a Canadian tide/current app — a station picker, a slack-window planner, a registry of gates — without redistributing CHS's file?** The naive read is "you can't." The precise read is "you can ship everything except the one thing that is actually theirs."

## Diagnosis: copyright vs. contract

The instinct is to reach for copyright — "are these facts protected?" — and that instinct sends you down the wrong road, because the answer is *no*, and it doesn't help.

**Facts are not copyrightable. Two courts, two jurisdictions, say so directly.**

- **US** — [*Feist Publications v. Rural Telephone Service*, 499 U.S. 340 (1991)](https://supreme.justia.com/cases/federal/us/499/340/). A phone book's white pages got **zero** copyright protection. Compiling facts, however laborious, is not authorship; "sweat of the brow" was explicitly rejected. Only an *original selection, coordination, or arrangement* is thinly protected, and the underlying facts stay free for anyone to re-extract.
- **Canada** — [*CCH Canadian v. Law Society of Upper Canada*, 2004 SCC 13](https://www.canlii.org/en/ca/scc/doc/2004/2004scc13/2004scc13.html). Originality requires "skill and judgment," not mere labour. A factual list with an obvious arrangement is not protected.

And neither the US nor Canada has an EU-style *sui generis* database right, so the labour of assembling a station list creates no separate right, either. A station's name, latitude, and longitude are facts. You may re-state them from a chart, a gazetteer, or your own survey, and nobody owns your copy.

So copyright isn't the risk. **The risk is contract.** The IWLS licence is terms-of-use you *agreed to* in exchange for API access, and that agreement is separable from — and survives — the fact that the data inside is free. You can lawfully re-state every fact CHS knows; you cannot redistribute the *file you pulled from them under their licence*. The line isn't "which facts appear," it's **"did you hand someone a copy of the provider's licensed product."**

Which turns the whole problem into a question of *method*, and puts a spotlight on one specific field.

### The tell: the opaque station id

Every CHS station has an internal handle — an opaque id like `63aef18…` — that you fetch its data with. It looks like just another fact, and copyright-wise it *is* one. But it's a fact with a special property: **it has no independent existence.** You cannot derive a CHS station id from a chart or a gazetteer. The only place it comes from is CHS's licensed API. So a file that carries the id is, by construction, a slice of CHS's export — it is the one field that can *only* have been redistributed, and the one field that points straight back into their system.

That is the field to not ship.

![A station-corrections registry record ships four independently obtainable facts — name, context, position and provider — and deliberately carries no provider-minted station id, because the CHS id has no source other than the licensed IWLS API and is resolved at runtime instead.](/assets/img/canadian-chs-tide-current-station-data-licensing-no-provider-id-runtime-name-correlation-feist-cch/registry-record-fields.svg)

## What we tried (and why it crossed the line)

The honest version of this section is that our own earlier releases did the wrong thing, and we caught it.

**Attempt 1 — ship the id as "just the join key."** Version 1.5.0 of our station registry carried `providerId` on every record, treating it as harmless reference data — the handle a consumer needs to look up live current data:

```yaml
# station-corrections registry.yaml — v1.5.0 (the version we walked back)
chs-dodd-narrows:
  name: Dodd Narrows
  context: Nanaimo
  position: [49.1344, -123.8171]
  provider: chs
  providerId: 63aef1866a2b9417c035030f   # ← CHS's opaque handle, redistributed
```

And the downstream fitting pipeline read exactly that field to fetch with:

```ts
// chs-constituents — the coupling we later removed
registry providerId -> StationRef.id    // what IwlsClient actually fetches
```

The problem: `providerId` is the one field on the record that isn't independently obtainable. `name`, `context`, and `position` we wrote ourselves from charts and our own fitting pipeline — those are our facts that happen to agree with CHS. But the id could only have come from CHS's API. Bundling it into a published npm package is handing a third party a piece of CHS's licensed export — precisely what clause 3 forbids ("given to a third party"). "It's just a reference" doesn't save it; the reference *is* the redistribution.

**Attempt 2 — rationalize it as a bare fact.** "But the id is a fact, and Feist says facts are free." True, and irrelevant: copyright was never the live risk. Terms-of-use is contract, and the contract restricts redistributing the file regardless of whether its contents are copyrightable. Winning the copyright argument doesn't win the licence argument. And there's a compilation-copyright trap hiding in the same instinct — see the gotchas.

**Attempt 3 — the "just ship the whole CHS station table" temptation.** Completeness *feels* safe ("it's a mirror of a public API"). It's the opposite: a complete list is the weakest possible compilation-copyright position (no original *selection* left to protect), and it maximizes the terms-of-use exposure by shipping the most of their file. Both readings point the same way — don't mirror their table.

The fix isn't to cite a case. It's to change the method so the provider's handle never enters the repository at all.

## The fix: a pipeline, not a download

Here's the part worth internalizing before the code. On the US side, "add offline tide/current prediction" is essentially **one API call** against a public-domain endpoint — fetch, bundle, done. On the Canadian side the same feature takes a **chain of pieces**, each of which exists specifically to keep the licensed handle out of anything you publish:

![Offline tide and current data is one public-domain call on the NOAA side, while the licensed Canadian CHS side takes three stages: chs-constituents resolves the CHS station id at runtime under the operator's own IWLS licence, the published station-corrections registry carries no provider id at all, and consumers correlate to live data by station name.](/assets/img/canadian-chs-tide-current-station-data-licensing-no-provider-id-runtime-name-correlation-feist-cch/us-vs-canada-pipeline.svg)

The registry in the middle is the linchpin: it's the only stage that gets *published*, so it's the stage that must carry zero of CHS's file. The two ends touch CHS's licensed API — but only at runtime, on the operator's own machine, under the operator's own licence. A builder's real takeaway is that the Canadian version needs the whole chain; there's no single package that is both useful and shippable, because "useful" means resolving the licensed handle and "shippable" means not carrying it.

Two moves make each stage clean: **remove the id from the published data, and resolve it at runtime under the operator's own licence.**

### 1. The registry ships facts and zero provider ids

Version 2.0.0 dropped `providerId` (and a NOAA depth-cell `providerBin`) from the schema, the data, and the tests — a deliberate breaking change:

```yaml
# station-corrections registry.yaml — v2.0.0
chs-dodd-narrows:
  name: Dodd Narrows
  context: Nanaimo
  position: [49.1344, -123.8171]
  provider: chs                 # the string "chs"/"noaa" — a fact, identifies the authority
  # no providerId. The stable key `chs-dodd-narrows` is the public id, safe in a URL.
```

```console
$ git log --oneline
50c740a docs: registry ships no provider id; bump to 2.0.0
46410cf feat!: remove providerId/providerBin from registry data and fixtures
8dfea91 feat!: drop providerId/providerBin from the registry schema and validation
```

Everything left is a fact we obtained independently and reviewed by hand: the name (re-cased and cleaned from a shouting survey label), the position (from our own fitting pipeline and charts, audited against a coastline), the context. The `provider` string stays — "this is a CHS authority station" is itself a fact. The **public join key is the station name** (and its stable `slug`), which anyone is free to publish.

That "deliberately absent" id is the load-bearing move, so it's worth stating how the package itself frames it. Its [`PROVENANCE.md`](https://github.com/sailingnaturali/station-corrections/blob/main/PROVENANCE.md) records provenance field by field — name is a hand-written label, context is written here, position is independently derived and human-verified — and then, for the provider id, one row that just reads:

> **provider id — Deliberately absent.** The registry carries no provider-minted identifier at all — not even as a reference. A consumer joins a record here to a provider's live data by name; the provider's own opaque handle is resolved at runtime by whoever holds a licence to that provider's API, and it never enters this repository.

The registry isn't only used as an id-less lookup table, either — it's a four-tier resolver, so a consumer with *any* station reference lands on the same curated identity:

```text
1. Registry        — stations this package owns outright (CHS gates with no
                     upstream record to correct). Resolves from a key alone.
2. Curated override — a hand-written correction wins over the provider's own name.
3. Derived fallback — nearest place from a bundled gazetteer, so context is never empty.
4. Source data      — the provider's own name, cleaned (upper-case → title-case).
```

None of the four tiers stores or emits a provider id. The dance is exactly this: tiers 1–4 traffic only in facts (names, positions, contexts) that agree with CHS *because facts agree with facts* — never because a byte was copied from CHS's file — and the one field that would point back *into* CHS's system is the one field the whole design refuses to hold.

### 2. Resolve the opaque handle at runtime, under your own licence

The id still has to exist *somewhere* — you need it to actually fetch current data. The move is to fetch it live, on the operator's machine, under the operator's own CHS API licence, and never write it to disk. The fitting pipeline lists CHS's stations live from the IWLS index and matches them to the registry **by name**:

```ts
// chs-constituents — the CHS id is fetched live and used only as a fetch handle
export function currentStations(raw: RawStation[]): IwlsStation[] {
  return raw
    .filter((s) => (s.timeSeries ?? []).some((t) => t.code === "wcsp1")) // current stations
    .map(({ id, officialName, latitude, longitude, operating }) => ({
      id, officialName, latitude, longitude, operating,
    }));
}

// The registry is a name overlay, NOT the id source. It reads no id at all:
export function stationsFromApi(stations: IwlsStation[], overlay: Map<string, OverlayEntry>) {
  return stations.map((s) => {
    const hit = overlay.get(normalizeName(s.officialName));
    // id: live from CHS, used only to fetch, never emitted.
    // key + curated label: from our registry, when the name matches.
    return hit ? { id: s.id, label: hit.label, key: hit.key } : { id: s.id, label: s.officialName };
  });
}
```

The join is a normalized-name match, applied symmetrically so a case/whitespace difference doesn't silently drop a station:

```python
# currents-mcp — correlate a live plugin reading to a gate by name, not by id
def _norm(name: str) -> str:
    """Fold case and trim so a label/name differing only in casing still matches."""
    return name.strip().casefold()

# cache[_norm(station_label)] = events   ← keyed by name
# events_for_station(gate.name)          ← looked up by name
```

The CHS id lives for exactly as long as one fetch, on the operator's box, covered by the operator's own IWLS licence. It is never committed, never published, never handed to a third party. The registry, the vault, the npm package — none of them contain it.

That's the entire trick: **the facts ship; the licensed handle resolves at runtime.** Same functionality as the NOAA path — a consumer still gets a named station picker and offline predictions — reached by a more involved route because the licence demands it.

## Why it matters / gotchas

- **Completeness is the *weakest* compilation-copyright position, not the strongest.** Compilation copyright rewards original *selection* — deciding what to leave out. A complete list is unselective by definition, so there's no protectable selection left. If you're mirroring a whole provider table "to be safe," you're both maximizing the terms-of-use exposure and standing on the flimsiest copyright ground. Curate a bounded, rule-governed subset instead.

- **The rule is about method, not about which facts appear.** A record that agrees with CHS on a coordinate is facts agreeing with facts. A byte-for-byte copy of CHS's export is redistributing their file. Same coordinate, different method, different answer. Write the facts yourself; don't paste their rows.

- **The identifier that can only come from the provider is the one to never ship.** A name or a position you can re-derive from a chart. An opaque internal id you cannot — its only source is the licensed API, so shipping it *is* the redistribution. If a field has no independent origin, treat it as the provider's, and resolve it at runtime.

- **Contributor guidance falls straight out of the rule.** For anyone adding a station: obtain the name, context, and position independently (chart, gazetteer, your own fitting pipeline, direct observation) and write them yourself; **do not paste a row out of a provider's export, and do not add a provider-id field.** If your workflow needs the provider's handle to join live data, resolve it there, under your own licence.

- **This isn't hypothetical — ask XTide.** XTide once shipped Canadian harmonic constants with non-commercial notices attached; Debian packaged them separately as `xtide-data-nonfree` precisely because commercial distribution wasn't permitted. The author was then contacted by what he understood to be the Department of Justice Canada asking him to strengthen the warnings, stopped maintaining the non-US data in 2012, and [XTide has shipped US-only ever since](https://flaterco.com/xtide/faq.html). A published notice is not a substitute for a licence you were never granted. That precedent is why we ship a pipeline and a factual registry, not a dataset.

## Close

This came out of building offline current prediction for an all-electric charter catamaran working both sides of the Canada/US border, where "just bundle the tide data" is a one-liner on the US side and a licence analysis on the Canadian one. The whole pipeline is open source: the licence-clean identity layer in [`station-corrections`](https://github.com/sailingnaturali/station-corrections) (facts only, no provider ids, [`PROVENANCE.md`](https://github.com/sailingnaturali/station-corrections/blob/main/PROVENANCE.md) documenting every field), the runtime-resolution end in [`chs-constituents`](https://github.com/sailingnaturali/chs-constituents) (whose README walks the CHS licence clause by clause), and the by-name correlation in [`currents-mcp`](https://github.com/sailingnaturali/currents-mcp). Three stages, because the licence needs three; on the US side it would have been one.

{% endraw %}
