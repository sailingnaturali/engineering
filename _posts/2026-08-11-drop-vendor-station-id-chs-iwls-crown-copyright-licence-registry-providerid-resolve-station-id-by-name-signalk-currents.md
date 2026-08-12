---
layout: post
title: "Drop the vendor station ID: licensing as a data-model constraint"
description: "Why @sailingnaturali/station-corrections 2.0.0 deleted providerId and providerBin — the only fields pointing into a provider's database — and how the CHS IWLS licence agreement (clause 3, Crown copyright, no third-party redistribution) turned into a schema change across four repos. signalk-currents now resolves the live CHS station id from api-iwls.dfo-mpo.gc.ca by normalized name and never writes it to disk, chs-constituents recast the registry as a name overlay, and currents-mcp re-keyed its cache on the station label instead of the station id."
date: 2026-08-11
tags:
  - signalk
  - marine
  - currents
  - licensing
  - open-source
  - npm
  - typescript
---

> **TL;DR** — [`@sailingnaturali/station-corrections`](https://github.com/sailingnaturali/station-corrections) 2.0.0 deleted `providerId`, the one field in a public MIT registry that pointed *into* a provider's database. Consumers now join records by station **name** and resolve the provider's opaque handle at runtime, under their own licence to that API. It cost a major version and reshaped four repos — and it's a stronger control than a compliance note in a README, because the id can't leak from a field that doesn't exist. [Jump to the fix](#the-fix).

![The same nineteen CHS station handles were committed three times across three published packages, fifty-seven copies in all, and station-corrections 2.0.0 took every one of them to zero.](/assets/img/drop-vendor-station-id-chs-iwls-crown-copyright-licence-registry-providerid-resolve-station-id-by-name-signalk-currents/committed-ids-before-after.svg)

"Don't redistribute the vendor's identifiers" is normally a compliance checkbox — a line in a NOTICE file, a paragraph in a licence audit, nothing that touches code. This one turned into an architecture. Here's what it actually cost, and what it bought.

## Problem

`station-corrections` is a small public npm package that publishes *station identity* for tide and current stations in the Salish Sea: the friendly name, the corrected position, search aliases, and a stable key that URLs and caches key on. Every record looked like this:

```yaml
chs-dodd-narrows:
  name: Dodd Narrows
  context: Nanaimo
  position: [49.1344, -123.8171]
  provider: chs
  providerId: 63aef1866a2b9417c035030f
```

The package ships a `PROVENANCE.md` that walks the schema field by field and says where each value came from, because the whole claim of the package is *these are our own facts, not a copy of anyone's station export*. Names are hand-written. Contexts and aliases don't exist in provider data at all. Positions come out of a harmonic-fitting pipeline and get audited against a bundled coastline by a person.

And then there was one row that read differently:

```markdown
| `providerId`, `providerBin` | **The provider's own opaque handle**, necessarily obtained from the
  provider because it keys the provider's API (`63aef09f…` for CHS, `PUG1717` for NOAA). It is a
  reference/pointer — the minimum needed to be interoperable — and a fact. This is the one field
  that points *into* a provider's system, by construction. |
```

The contributor guide made the exception explicit:

```markdown
- The `providerId` is the exception — it is the provider's handle and there is nowhere else
  to get it. That is expected and fine.
```

The Canadian data behind those hex strings comes from the Canadian Hydrographic Service's IWLS API, whose [licence agreement](https://tides.gc.ca/en/licence-agreement) is a bespoke Crown licence, not the Open Government Licence. Clause 3 is one sentence long:

```text
The copyrights of CHS in the Data remain the property of CHS and shall not be
sold, licensed, leased, assigned or given to a third party.
```

An MIT npm package is, structurally, giving something to third parties. Nineteen CHS station handles were sitting in it, then re-published in a SignalK plugin's `defaults.ts`, then re-published again in a Python MCP server's vendored copy of the registry — fifty-seven committed copies of the same nineteen handles, across three packages anyone can `npm install` or `pip install`.

## Diagnosis

Two things were true at once, and only noticing both makes the fix obvious.

**One: an id is the weakest thing you can defend as "just a fact."** The provenance doc leans on *Feist* (US) and *CCH* (Canada) — facts aren't copyrightable, and neither jurisdiction has an EU-style database right. That argument is strong for a position (independently derivable: chart, gazetteer, direct observation) and strong for a name (hand-written editorial work). It's weakest exactly where the contributor guide admitted the weakness: **there is nowhere else to get it.** A field whose only possible provenance is the vendor's database is the field where "we obtained this independently" stops being available as a defence. The sentence written to justify the exception is a precise statement of why the exception is the problem.

**Two: the field was doing two jobs.** It was the *identity* of a station — what caches, resource keys and cross-package joins keyed on — and it was the *fetch handle* the provider's API wants in a URL path. Those are different lifetimes. Identity should be stable forever and safe in a URL. A fetch handle is whatever the vendor's index says today. Conflating them is what made the id feel load-bearing and undeletable.

![Before, the provider-minted station id was copied into the registry and republished under MIT to every consumer; after, the registry publishes only name, position and a stable key, and each consumer resolves the live id from the provider API at runtime under its own licence.](/assets/img/drop-vendor-station-id-chs-iwls-crown-copyright-licence-registry-providerid-resolve-station-id-by-name-signalk-currents/id-path-before-after.svg)

Separate the two jobs and the licence problem dissolves: the identity half is our own fact and publishable, the fetch-handle half never needs to be written down.

## What we tried (and why it failed)

**Attempt 1: document the exception harder.** The first response was the provenance table above — a careful, honest, field-by-field account ending in "carried because interoperability requires them." It's good documentation and it moves zero bytes. The published tarball is identical before and after you write it. A README does not change what a package distributes, and clause 3 is about what you distribute.

**Attempt 2: just delete the field.** This is where it stops being a paperwork exercise. The plugin's entire online path is keyed on that id:

```ts
const defaultFetcher: DayFetcher = async (s, a, b) =>
  s.provider === 'chs'
    ? { events: await fetchChsEvents(s.stationId, a, b) }
    : fetchNoaaEvents(s.stationId, s.noaaBin ?? 0, a, b);
```

Delete `providerId` and there is no `stationId` to fetch with — you don't get a compile error in the registry package, you get a plugin that can no longer answer "when is slack at Dodd Narrows?" at all, online or off. The design spec had to spell out the three separate things a gate needs at runtime before anything could be removed:

```text
Need                      | Old source (deleted)   | New source
--------------------------|------------------------|----------------------------------------
name / position / label   | defaults.ts            | station-corrections (by name/key)
live CHS id (online fetch)| defaults.ts stationId  | resolved live from IWLS /stations by name
offline constituents      | did not exist          | operator-triggered local build
```

The sibling fitting library had the same coupling, expressed as a guard that *required* the id to be present:

```ts
if (!key?.trim() || !entry.name?.trim() || !entry.providerId?.trim()) {
  throw new Error(`registry entry ${JSON.stringify(key)} has an empty key, name, or providerId`);
}
return { id: entry.providerId, label: entry.name, key };
```

**Attempt 3: keep the id, but only where it's public domain.** NOAA data *is* US-government public domain — `PUG1717` is genuinely free to redistribute. So carve out CHS and keep the field for NOAA rows. This was rejected, and the reason is worth stating: a schema field whose legality depends on which row you're looking at is a field every future contributor has to reason about correctly, forever, in a package that takes drive-by PRs from anyone who spots a wrong station name. `PUG1717` and its depth-cell bin came out too. The rule in the shared package is uniform — *no provider-minted identifier, ever* — and the one consumer that genuinely may ship a NOAA id keeps it in its own package, where the provider is fixed and the reasoning is local.

**Attempt 4: assume the two provider endpoints share an id namespace.** The plugin lists stations from `api-iwls.dfo-mpo.gc.ca` but fetches events from `api-sine.dfo-mpo.gc.ca`. If those two mint different ids, "resolve from IWLS, fetch from SINE" returns an empty array for every gate — no error, no 404, just currents quietly gone. That is not a thing to find out after wiring four repos together, so it got a throwaway probe first:

```js
const stations = await (await fetch(`${IWLS}/stations`)).json();
const dodd = stations.find((s) => s.officialName === "Dodd Narrows");
const resp = await fetch(`${SINE}/stations/${dodd.id}/data?${params}`);
console.log(rows.length > 0 ? "PASS: shared id namespace" : "FAIL: ids differ — move event fetch to IWLS");
```

Twenty-three lines, one request, PASS. Had it failed, the live event fetch would have moved to IWLS as well — a different plan entirely, and much cheaper to discover before the refactor than during it.

## The fix

**1. The registry ships identity and nothing else.** Two `feat!` commits and a major version:

```yaml
chs-dodd-narrows:
  name: Dodd Narrows
  context: Nanaimo
  position: [49.1344, -123.8171]
  provider: chs
```

`provider` stays — "this is a CHS gate" is a fact about the world and tells a consumer which API to go ask. The validator drops `providerId` from its required-fields list and deletes the `providerBin` range check entirely. `PROVENANCE.md`'s exception row became a prohibition:

```markdown
| provider id | **Deliberately absent.** The registry carries no provider-minted identifier at
  all — not even as a reference. A consumer joins a record here to a provider's live data by
  name; the provider's own opaque handle is resolved at runtime by whoever holds a licence to
  that provider's API, and it never enters this repository. |
```

**2. Consumers split identity from the fetch handle.** In the SignalK plugin, `stationId` becomes the stable registry key and a new `liveId` carries the ephemeral one:

```ts
// Ephemeral IWLS station id for a CHS gate, resolved live at runtime (see
// resolveLiveIds). NEVER committed. `stationId` above is the stable identity
// (registry key for CHS); `liveId` is only the fetch handle.
liveId?: string;
```

```ts
const chsLiveId = (s: StationConfig): string => {
  if (!s.liveId) throw new Error(`no live id for ${s.label}`);
  return s.liveId;
};
```

That throw is the enforcement. There is no path where a CHS fetch silently falls back to something committed, because there is nothing committed to fall back to.

![One station now carries two identifiers: a stable committed key that every cache, URL and resource is keyed on, and an ephemeral provider handle resolved at startup and used only to make the fetch.](/assets/img/drop-vendor-station-id-chs-iwls-crown-copyright-licence-registry-providerid-resolve-station-id-by-name-signalk-currents/identity-split.svg)

**3. Resolve the handle at runtime, from the provider, by name.** The whole resolver is twenty-odd lines:

```ts
export function currentStations(raw: RawStation[]): IwlsStation[] {
  return raw
    .filter((s) => (s.timeSeries ?? []).some((t) => t.code === 'wcsp1'))
    .map(({ id, officialName, latitude, longitude }) => ({ id, officialName, latitude, longitude }));
}

export async function resolveLiveIds(fetchFn: typeof fetch = fetch): Promise<Map<string, string>> {
  const resp = await fetchFn(`${IWLS_BASE}/stations`);
  if (!resp.ok) throw new Error(`IWLS ${resp.status}`);
  const stations = currentStations((await resp.json()) as RawStation[]);
  return new Map(stations.map((s) => [normalizeName(s.officialName), s.id]));
}
```

It runs at `start()`, holds the map in memory for the life of the process, and tolerates failure by falling through to the offline path. The id never reaches a file.

**4. One normalizer, applied symmetrically, in every language that joins.** TypeScript:

```ts
// Same folding rule chs-constituents uses, so "JUAN DE FUCA - EAST" matches the
// registry's "Juan de Fuca - East".
export function normalizeName(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}
```

Python, in the MCP server that reads the plugin's `/currents` resource and joins each reading back to a registry gate:

```python
def _norm(name: str) -> str:
    """Join key for correlating a gate to a plugin reading: fold case and trim
    so a label/name that differs only in casing or spacing still matches."""
    return name.strip().casefold()
```

Applied on **both** sides — once when the cache is built, once on lookup — so a whitespace difference between the plugin's label and the registry's name can't silently drop a station.

**5. Tests that keep it true rather than a rule that asks nicely.** The fitting library's overlay test asserts the absence directly:

```ts
it("keys entries by normalized name and reads no id at all", () => {
  // No providerId field anywhere — proves the overlay is forward-compatible
  // with the registry dropping providerId in Phase 2.
  const overlay = registryOverlay(
    { "chs-dodd-narrows": { name: "Dodd Narrows", provider: "chs" } },
    "chs",
  );
  expect(overlay.get("dodd narrows")).toEqual({ key: "chs-dodd-narrows", label: "Dodd Narrows" });
});
```

and the MCP server's vendored copy of the registry is guarded by a drift test that fails the moment it stops byte-matching the published one.

## Why it matters, and the gotchas

**A licence term makes a better schema constraint than a policy.** Compare "reviewers should check that nobody adds a provider id" against "the schema has no such field and the validator rejects unknown ones." The second one survives a contributor who never read `PROVENANCE.md`, which is most of them.

**Name joins are fragile exactly where ids are robust — so put the renames somewhere.** An opaque id survives a rename; a name join doesn't. The mitigation is that the registry is the thing that *owns* renaming: change a station's display name there and every downstream package follows, because they all read it. What the join can't survive is the **provider** renaming its station, and that is a real, unhandled failure mode — the gate goes offline-only until someone updates the registry name. The fitting library degrades gracefully (an unmatched live station keeps its official name and gets no key); the plugin logs and falls back. Neither pretends it matched.

**Shipping the change broke the boat, twice, and both were migration bugs — not the design.**

*Nineteen duplicated gates.* An operator config written before 2.0.0 still names a gate by its provider-minted UUID. That never collides with the registry's slug, so both entries survived the merge, and the stale one resolved no live id either:

```ts
// Re-key such an entry onto the registry slug so it lands as the OVERRIDE it was
// always meant to be: the slug is what resolveLiveIds works from, and every other
// field the operator set (set directions, estimate flags, bins) rides along.
// Deliberately keyed on label, not position: renaming a station is the registry's
// job and downstream is supposed to follow it.
```

It was invisible for weeks because downstream consumers key on the label and silently keep whichever copy they saw last. When you re-key a shared identifier, write the migration for configs you don't control — someone is running the old shape.

*Ten stations throwing every poll cycle.* The registry later grew tide reference ports alongside current gates. Tide ports publish no `wcsp1` series, so `resolveLiveIds` finds nothing for them and the fetch guard fired ten times a cycle:

```text
no live id for Point Atkinson
no live id for Campbell River
…
```

The fix wasn't a filter in the plugin — that filter existed and was already wrong. Selection moved into the package that owns the data, as an exported `currentGates()`. If a package can grow a new row type, only that package can be trusted to say which rows are which.

**Scrub the whole repo, not just `src/`.** After the code was clean, a CHS id was still sitting in a fenced code sample inside an old implementation-plan doc, where no grep of the source would find it:

```diff
-  { provider: 'chs', stationId: '63aef1866a2b9417c035030f', label: 'Dodd Narrows', … },
+  { provider: 'chs', stationId: '<24-hex-id>', label: 'Dodd Narrows', … },
```

Docs, specs, plans, test fixtures, issue templates, commit messages. Grep for the shape of the thing, not the name of the field.

**Make the invariant structural where you can.** The offline harmonic bundle a user builds locally is written to the server's data directory — outside the repo and outside the npm package — so it *cannot* be committed or published by accident. That's not discipline, it's geography, and geography doesn't get tired.

**The reward is the part nobody asks for.** Because nothing downstream stores a provider handle any more, renaming a station is now a one-line PR in one repo, and the version of the package that made this legally safe is the same version that made renames free. That was not the goal; it fell out of deleting the field that pointed sideways into someone else's database.

---

Built while putting a boat-agent stack together for an all-electric charter catamaran, where "the Canadian rapids stop working offline" is a licensing problem before it is a software one. The registry is [`station-corrections`](https://github.com/sailingnaturali/station-corrections); the plugin is [`signalk-currents`](https://github.com/sailingnaturali/signalk-currents); the fitting pipeline that has to be run rather than downloaded is [`chs-constituents`](https://github.com/sailingnaturali/chs-constituents).

*Related:* [Offline tidal currents from harmonic constituents]({% post_url 2026-07-31-offline-tidal-current-predictions-signalk-harmonic-constituents-noaa-harcon-neaps-fallback-slack-timing-rapids %}) — the same licence wall, one layer down, where it decides which predictions you can bundle at all. And [the NOAA CO-OPS currents API gotchas]({% post_url 2026-07-18-noaa-co-ops-currents-api-harcon-empty-constituents-currbin-currents-predictions-not-available-user-agent-404 %}) for the other half of this cruising ground, where none of this applies.
