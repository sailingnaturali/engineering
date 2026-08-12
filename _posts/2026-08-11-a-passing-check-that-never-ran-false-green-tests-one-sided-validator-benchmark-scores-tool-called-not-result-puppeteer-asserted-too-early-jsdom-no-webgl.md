---
layout: post
title: "A passing check is a claim about what ran, not what's true"
description: "Six false-green checks from one month across unrelated codebases: a point-in-polygon predicate returning false for both 'open water' and 'no coastline data', a lock-file validator that iterated only the lock so unlocked entries were never examined, an agent benchmark scoring which tool was called instead of what it returned (hiding a months-old all-nulls bug), a CLI selftest grepping for a warning-box title the plain-text output never prints, a Puppeteer smoke test asserting the instant the canvas appeared — 2 s before the map finished failing — and a fix that no conventional check can guard because jsdom has no WebGL. Plus the checklist that catches all six."
tags:
  - testing
  - ci
  - javascript
  - python
  - puppeteer
  - vitest
  - validation
  - open-source
date: 2026-08-11
---

> **TL;DR** — A green check tells you a code path ran and produced the value it
> was compared against. It does not tell you the subject was examined. Six
> independent bugs in one month, across four unrelated codebases, were all the
> same shape: something reported success for a region it never looked at.
> [Jump to the checklist](#the-checklist).

I hit this six times in a month. Different languages, different repos, no shared
code: a JavaScript data package, a Python MCP server, a shell wrapper, a
TypeScript PWA. Every one of them produced a clean result for something that was
never actually examined — not a wrong answer, an *absent* answer, dressed as a
pass.

That's a nastier failure than a wrong answer. A wrong answer is a signal. An
absent answer that reports itself as a pass is silence you've been trained to
read as safety.

![Six green checks from one month, each with the region of its subject it never examined: outside the coastline clip, entries absent from the lock file, what the tool returned, the plain-list warning format, the two seconds after the canvas appeared, and anything needing WebGL.](/assets/img/a-passing-check-that-never-ran-false-green-tests-one-sided-validator-benchmark-scores-tool-called-not-result-puppeteer-asserted-too-early-jsdom-no-webgl/blind-spots.svg)

Here they are, shortest first, each with the rule I'd generalize out of it.

## 1. A boolean that returns false for "no" and for "I can't tell"

[`station-corrections`](https://github.com/sailingnaturali/station-corrections)
exists to audit the published positions of tide and current stations. Its
headline check: is this station's coordinate sitting on land? That's a
point-in-polygon test against a bundled coastline:

```js
// src/coastline.js — before
export function isOnLand(lat, lon) {
  const at = point([lon, lat]);
  return coastline.features.some((feature) => booleanPointInPolygon(at, feature));
}
```

The coastline ships clipped to a bounding box — the full planet coastline is far
too large to bundle. Outside that box there are no polygons, so `some()` finds
nothing and the function returns `false`. Which is byte-identical to the answer
it returns for a station verified to be in open water.

Three CHS current gates — Blackney Passage, central Johnstone Strait, Weynton
Passage — sat north of the clip. The audit reported them valid. It had never
looked at them. And the registry was growing north, so the silent region was
growing too.

The fix is a coverage predicate derived from the data rather than hardcoded, so
rebuilding the coastline with a different clip updates it for free:

```js
// src/coastline.js — after
export function isWithinCoverage(lat, lon) {
  const b = coverageBounds();   // walked off the bundled polygons, memoized
  return lat >= b.minLat && lat <= b.maxLat && lon >= b.minLon && lon <= b.maxLon;
}
```

Then the second-order fix, which matters more: a registry station outside
coverage became a validation **failure**, not a note — and the coastline build
script now derives its clip box from the registry's own extent plus a margin,
floored at the proven box so it only ever grows outward. The clip can no longer
fall behind the data it's meant to check
([`7d52f67`](https://github.com/sailingnaturali/station-corrections/commit/7d52f67),
[`1c06273`](https://github.com/sailingnaturali/station-corrections/commit/1c06273)).

> **Rule:** a predicate over partial data needs three states, not two. If
> "no" and "I have no data here" collapse to the same value, every caller that
> reads `false` as a verdict is reporting a result it never computed.

## 2. A validator that iterates one side of a pair

Same package, next day. Station slugs are public URL segments, so a rename is a
breaking change. A lock file pins the slug each station last shipped with, and
`check-slugs` runs in CI ahead of the data checks:

```js
// src/slugs-lock.js — before
for (const [id, lockedSlug] of Object.entries(lock.slugs)) {
  const nowSlug = current.get(id);
  if (nowSlug === undefined || nowSlug === lockedSlug) continue;
  // ...fail if the slug moved without the old value in formerSlugs
}
```

Read the loop bound. It iterates **the lock**. A station present in the data but
absent from the lock is never visited — so a brand-new station's slug entered
the public API with nothing pinned to compare against, and that slug plus every
future change to it passed green forever. The one thing the lock exists to
prevent was invisible for exactly the stations most likely to get renamed: the
new ones.

The guard is now symmetric — the lock must reflect the current knowable slugs
exactly, in both directions:

```js
// src/slugs-lock.js — after
for (const [id, lockedSlug] of Object.entries(lock.slugs)) {
  const nowSlug = current.get(id);
  if (nowSlug === undefined) {
    problems.push(`${id}: in the slug lock but no longer in the data — its slug "${lockedSlug}" is dead`);
    continue;
  }
  // ...moved-slug check unchanged
}

for (const [id, slug] of current) {
  if (!(id in lock.slugs)) {
    problems.push(`${id}: slug "${slug}" is not in the lock — run \`station-corrections slugs\``);
  }
}
```

The commit message named the pattern out loud, because it landed a day after the
coastline one: *"Same failure class as the coverage bug: a clean result for
something never checked"*
([`99afa20`](https://github.com/sailingnaturali/station-corrections/commit/99afa20)).

> **Rule:** a validator comparing two collections must iterate their **union**.
> Iterating one side can only ever find disagreements about things both sides
> already know about — which is the easy half of the problem.

## 3. A benchmark that scored the call, not the result

I run a benchmark over the boat agent's MCP tool routing: a set of golden asks,
each with the tools a correct answer requires. Scoring:

```python
# poseidon/bench/scoring.py
def score_ask(ask, observed_tools, observed_args=None):
    if not set(ask.expected_tools).issubset(set(observed_tools)):
        return False
    # ...optional argument matching
    return True
```

Set containment on tool names. It measures routing — did the model reach for
`battery_state` when asked about the batteries — and routing is genuinely what
the benchmark was built to compare across models. But nothing in that function
ever opens the payload.

Meanwhile, in [`signalk-mcp`](https://github.com/sailingnaturali/signalk-mcp):

```python
async def battery_state(client: SignalKClient, bank: str = "0") -> dict:
    raw = await client.get_value(f"electrical.batteries.{bank}")
```

`"0"` is the SignalK instance convention, and it's a perfectly reasonable
default — except the vessel publishes `electrical.batteries.house`. So the bare
tool returned this, on a boat that had been publishing battery data the entire
time:

```json
{"bank": "0", "soc_fraction": null, "voltage": null, "current": null, "display": null}
```

Right tool, right arguments, no data. Score: match. The agent only got a real
reading if the person asking happened to say the word "house". This survived
months of green benchmark runs and was found by hand, mid-benchmark, reading a
transcript for an unrelated reason
([`e837d92`](https://github.com/sailingnaturali/signalk-mcp/commit/e837d92)).

The tool fix is small — try `"0"`, then discover the vessel's own banks off the
`electrical.batteries` subtree, and never second-guess an explicitly named bank
because answering about a different battery is worse than answering "no data".
The interesting fix is the scoring one: at least one assertion per ask has to
reach into the returned payload.

> **Rule:** a score computed from the call examines your harness's routing. A
> score computed from the result examines the system. If nothing in your
> scorer opens the response body, a tool that returns nulls forever is a
> perfect performer.

## 4. A selftest that greps for a string the command never prints

A CLI wrapper on the boat gateway sources its secrets and execs the real
binary. Scripts parse its output, so a missing environment variable has to fail
loudly and early — hence a `--selftest` that proves the secrets resolved on a
real invocation.

The trap: the CLI reports the same condition in two different formats depending
on the subcommand.

```console
$ mytool audit
┌ Config warnings ──────────────────────────────┐
│ ! api.token: Missing env var API_TOKEN        │
└───────────────────────────────────────────────┘

$ mytool config validate
1 warning(s): ! api.token: Missing env var API_TOKEN
```

The selftest called `config validate` and grepped for the box title:

```bash
# before — passed while the token was genuinely missing
out="$(mytool config validate 2>/dev/null || true)"
if grep -qi "Config warnings" <<<"$out"; then
  echo "SELFTEST FAIL"; exit 1
fi
echo "SELFTEST PASS"
```

`config validate` never prints `Config warnings`. The grep could not match. The
selftest passed, cleanly and instantly, with a required token genuinely absent
— a check whose entire job was catching that exact state.

```bash
# after — match the thing both formats actually contain
if grep -qi "missing env var" <<<"$out"; then
```

What caught it wasn't review and wasn't a test. It was running the negative
control: deliberately unsetting the variable and watching whether the selftest
went red. It didn't.

> **Rule:** you have not tested a check until you have watched it fail. Break
> the thing on purpose, confirm red, put it back, confirm green. A selftest
> that passes when broken is worse than no selftest — it converts an unknown
> into a false known.

## 5. An assertion that fired before the system finished failing

[`slackwater-web`](https://github.com/sailingnaturali/slackwater-web) is an
offline-first tide PWA, so its Puppeteer smoke suite loads the map with the
network cut and asserts no unexpected console errors. It looked like this:

```js
await mapPage.waitForSelector(".map-canvas .maplibregl-canvas", { timeout: 10_000 });
assert.deepEqual(mapErrors, []);   // green
```

MapLibre puts a canvas in the DOM as soon as it initialises the GL context —
well before it has finished trying, and failing, to fetch its tiles and glyphs
over a network that isn't there. The assertion fired into an empty array
roughly two seconds early. Green, for the wrong reason.

![Timeline showing the canvas element appearing about two seconds before the map finishes failing its external tile fetches, so the old assertion fired into an empty error list and passed, while the fixed version settles first and then judges.](/assets/img/a-passing-check-that-never-ran-false-green-tests-one-sided-validator-benchmark-scores-tool-called-not-result-puppeteer-asserted-too-early-jsdom-no-webgl/settle-then-judge.svg)

The fix separates collection from judgement — a watcher that starts before the
navigation and a `settle()` that drains every pending handle before anything is
asserted:

```js
const settleMapErrors = watchErrors(mapPage);
await mapPage.goto(`${URL}/map`);
await mapPage.waitForSelector(".map-canvas .maplibregl-canvas", { timeout: 10_000 });
// The canvas appears well before the map has finished failing its external
// fetches, so asserting the instant it exists passed for the wrong reason.
const mapErrors = await settleMapErrors();
assert.deepEqual(mapErrors, []);
```

(The same commit fixed why those errors were unreadable in the first place:
Puppeteer's `msg.text()` renders an object argument as its class name, so
MapLibre's minified `AJAXError` arrived as `[object Ae]` with the host it named
invisible to the noise classifier. Resolving each argument through its
`JSHandle` makes collection async, which is what forces the settle-then-judge
shape anyway —
[`32bfe09`](https://github.com/sailingnaturali/slackwater-web/commit/32bfe09).)

> **Rule:** an assertion is a claim about an instant. If the system is still
> working when you sample, you measured a different system. Collect over a
> window, settle, then judge — and be suspicious of any wait keyed on the
> *first* sign of life rather than the last.

## 6. When deleting the fix leaves every check green

Same app, same evening. `resolvePinStates` called with no dependency object let
every unsynced station fall through to a live upstream fetch — a request storm
on every map open, throttled behind a ~24 req/min limiter, with a single
`setData` gated on the slowest of them. In review the pins effectively never
coloured. The fix is one argument: a rejecting `fetchFn` that makes state reads
cache-only, so an unsynced station stays neutral, which is the honest unknown
([`afa3df1`](https://github.com/sailingnaturali/slackwater-web/commit/afa3df1)).

Now: which check catches its removal?

- `tsc` — green. The argument is optional.
- The Vitest suite — green. jsdom has no WebGL, so the map component never
  mounts and no test observes the call.
- The production build — green.
- The Puppeteer smoke test — green. A request storm against a third-party API
  is not a console error.

Delete the fix and all four stay green while the storm comes back. The bug is
invisible to every conventional layer, which means writing a conventional test
would be theatre. So the guard reads the source file as text:

```ts
it("resolves pin states cache-only — never fetching", () => {
  // Guarded by source text because nothing else can catch it: jsdom has no
  // WebGL so the map never mounts, and dropping the fetchFn leaves tsc, the
  // suite, the build and the smoke test all green while every map open fires
  // one live request per unsynced station at a third-party API.
  const src = readFileSync(join(__dirname, "MapScreen.tsx"), "utf8");
  const call = src.match(/resolvePinStates\([\s\S]*?\)\s*\n\s*\.then/);
  expect(call, "resolvePinStates call site not found").toBeTruthy();
  expect(call![0]).toContain("fetchFn");
});
```

That test is ugly. It's coupled to formatting, it can't see a rename, and it
proves nothing about behaviour. It is also the only thing in the repo that goes
red when the fix is removed
([`88ec107`](https://github.com/sailingnaturali/slackwater-web/commit/88ec107)).

> **Rule:** if you delete the fix and nothing goes red, the missing thing is the
> check, not the bug. A real guard with a known ceiling beats an elegant guard
> that doesn't exist — as long as the test says, in the test, why it's shaped
> that way.

## What they have in common

None of these were flaky. None were wrong answers. Every one of them was a
**scope** bug in the check itself: the set of things examined was smaller than
the set of things claimed, and nothing in the output distinguished the two.

That's the whole thesis. A green check is a claim about what ran. Reading it as
a claim about what's true requires an extra assumption — that the check's
subject and the check's coverage are the same set — and that assumption is
exactly what nobody verifies, because verifying it feels like testing the tests.

Two structural tells show up in five of the six:

1. **The check consumed a partial data source and had no way to say so.** The
   clipped coastline, the lock file, the jsdom environment, the two-second
   window. Partial coverage plus a boolean result is a machine for manufacturing
   false confidence.
2. **Nobody had ever watched it fail.** The negative control caught #4 within a
   minute. It would have caught #1, #2 and #3 just as fast.

## The checklist

Six questions. They take a minute, and each one is a bug I actually shipped:

- **Does this validator iterate both sides of the pair?** Or does it loop over
  one collection and silently exempt everything the other one knows about?
- **Can this predicate return "no" and "I don't know" as the same value?** If
  yes, every caller reading it as a verdict is reporting a result nobody
  computed.
- **Does the score examine the result, or just the call?** Set containment on
  tool names, exit codes, "did it get called" — all of these pass on an empty
  payload.
- **Did you run the negative control?** Break the thing, watch the check go
  red, put it back. If you've never seen it fail, you don't know it can.
- **Does the assertion fire after the system has finished, or at the first sign
  of life?** Waiting on the first artifact to appear is not the same as waiting
  for the work to finish.
- **If you deleted the fix, which check would go red?** If the honest answer is
  "none", write that check first — even if the only shape available is an ugly
  one.

None of this is exotic. It's the difference between a test suite that tells you
the code works and one that tells you the suite ran.

---

I'm building the software stack for an all-electric charter catamaran — data
packages, SignalK plugins, MCP servers, an offline tide app — mostly in public.
Code for the bugs above lives in
[station-corrections](https://github.com/sailingnaturali/station-corrections),
[signalk-mcp](https://github.com/sailingnaturali/signalk-mcp) and
[slackwater-web](https://github.com/sailingnaturali/slackwater-web).

*Related:* [Porting a tide engine to Swift with the original as the test oracle]({% post_url 2026-08-11-porting-javascript-to-swift-test-oracle-neaps-tide-prediction-golden-vectors-harmonic-constituents-noaa-validation %}) — what a check looks like when it *does* examine the result · [Monitor the delivery path, not just the alarm]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}) — the same silence, one layer out · [Bench your own workload before you switch LLM vendors]({% post_url 2026-08-06-benchmark-your-own-llm-workload-before-migrating-gpt-5.6-vs-claude-sonnet-mcp-tool-routing-reasoning-effort-none %}) — the benchmark from vignette 3, before its scoring blind spot showed up
