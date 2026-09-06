---
layout: post
title: "Read Puppeteer console errors off the argument handles, not msg.text()"
description: "Puppeteer's ConsoleMessage.text() renders an object console argument as its class name — under a minified bundle that's `[object Ae]` or `[object Object]`, and the URL inside the error is gone, so a console-noise classifier can't see it. The fix resolves each msg.args() JSHandle with arg.evaluate(), which makes collection async and forces a settle-then-judge shape. Plus the offline-emulation ordering: navigator.onLine is not evidence under CDP Network.emulateNetworkConditions, prove the cut with a real fetch, and attach console listeners after that proof fetch."
tags:
  - puppeteer
  - testing
  - ci
  - javascript
  - maplibre
  - pwa
  - offline
date: 2026-08-11
---

> **TL;DR** — Puppeteer's `msg.text()` is a *rendering* of a console argument,
> not the argument. Log an object and you get `[object Object]` — or, from a
> minified bundle, `[object Ae]` — with every URL and field inside it gone. If
> anything downstream classifies console errors by substring, read the arguments
> instead: `msg.args()` → `arg.evaluate(…)`. That's async, so collection has to
> be separated from judgement. [Jump to the fix](#the-fix).

![Two lanes showing the same maplibre console error: read through msg.text it renders as a minified class name with the tile host lost, so the noise filter cannot classify it and CI goes red; read through msg.args and arg.evaluate it arrives as real error text naming the tile host, gets classified as expected offline noise, and CI goes green.](/assets/img/puppeteer-console-message-text-object-object-class-name-msg-args-jshandle-evaluate-maplibre-ajaxerror-navigator-online-emulatenetworkconditions-offline/console-arg-resolution.svg)

[`slackwater-web`](https://github.com/sailingnaturali/slackwater-web) is an
offline-first tide and current PWA, so a big share of its Puppeteer smoke suite
runs with the network deliberately cut and asserts that nothing broke. "Nothing
broke" means: no `pageerror`, and no `console.error` that isn't *expected*
offline noise. Expected noise is a real category here — with the network down,
Chrome itself logs a resource-load failure for every external fetch the app
makes and honestly handles, and none of those are app errors.

So there's a classifier. It matches on the hosts we know are external:

```js
function isChsFetchNoise(text) {
  return (
    text.includes(IWLS_HOST) ||        // tide prediction API
    text.includes(SEASCAPE_HOST) ||    // bathymetry tiles
    /blocked by CORS policy/.test(text) ||
    /Failed to load resource: net::ERR_(FAILED|INTERNET_DISCONNECTED|NAME_NOT_RESOLVED|CONNECTION_REFUSED|TIMED_OUT|ADDRESS_UNREACHABLE)/.test(text)
  );
}
```

Every clause reads a **string**. That's the whole bug.

## The problem

The map check went red in CI and only in CI:

```console
SMOKE FAILED: /map offline reload reported errors:
console.error: [object Ae]
console.error: [object Ae]
console.error: [object Ae]
console.error: [object Ae]
```

Four lines, no information in any of them. `Ae` is a two-letter token out of a
minified bundle. There's no host to look up, no stack, no status code — nothing
to decide whether this is the map politely failing to reach a tile server with
the network cut (fine, expected, that's the whole point of the check) or the
app actually breaking (not fine).

The listener that produced them was the obvious one, copied six times across
the suite:

```js
page.on("console", (msg) => {
  if (msg.type() === "error" && !isChsFetchNoise(msg.text())) {
    errors.push(`console.error: ${msg.text()}`);
  }
});
```

## Diagnosis: `text()` is a description, not the value

A console argument lives in the browser. Puppeteer holds a `JSHandle` — a
*reference* into the page — and `ConsoleMessage.text()` gives you the browser's
own short description of each argument joined together. For a string that
description is the string. For an object it's whatever Chrome would print as a
one-line label.

Fifteen lines of Puppeteer will show you the difference. Log four things and
read each one both ways:

```js
p.on("console", async (msg) => {
  if (msg.type() !== "error") return;
  const viaEval = await Promise.all(
    msg.args().map((a) =>
      a.evaluate((o) => (o instanceof Error ? `${o.name}: ${o.message}` : String(o))),
    ),
  );
  console.log(JSON.stringify({ text: msg.text(), viaEval }));
});

await p.evaluate(() => {
  class Ae { constructor(url) { this.url = url; this.status = 404; } }
  class Be extends Error { constructor(u) { super("Not Found: " + u); this.url = u; } }
  console.error(new Ae("https://tiles.example.org/a.pbf"));
  console.error(new Be("https://tiles.example.org/b.pbf"));
  console.error(new Error("Failed to fetch"));
  console.error({ plain: "object", url: "https://tiles.example.org/x" });
});
```

Output, on Chrome 151 with `puppeteer-core` 25.3.0:

```json
{"text":"[object Ae]","viaEval":["[object Object]"]}
{"text":"Be: Not Found: https://tiles.example.org/b.pbf","viaEval":["Error: Not Found: https://tiles.example.org/b.pbf"]}
{"text":"Error: Failed to fetch","viaEval":["Error: Failed to fetch"]}
{"text":"[object Object]","viaEval":["[object Object]"]}
```

Line one is the CI failure, reproduced in a file with no app in it. A class
instance Chrome doesn't describe as an `Error` renders as
`[object <ClassName>]`, and after minification the class name is `Ae`. The
`url` property that was sitting right there on the object never appears in the
rendered text at all — so `isChsFetchNoise` had literally nothing to match on,
and a fetch failure we *expect* under a cut network got counted as an app error.

Note line two as well: even for an `Error` subclass the prefix is the minified
**constructor** name, not `err.name`. `text()` is a debugging convenience. It
was never a data source, and nothing in its shape tells you when it has dropped
the field you're keying on.

### Why it was green locally

The tempting explanation is a browser difference. It wasn't one. CI resolved
Chrome-for-Testing **151.0.7922.71**; the laptop that ran the same suite green
was on **151.0.7922.109**. Same major, same minor, three days apart.

The real reason is duller and much more common: the assertion ran before the
errors existed.

```js
await mapPage.reload({ waitUntil: "domcontentloaded" });
await mapPage.waitForSelector(".map-canvas .maplibregl-canvas", { timeout: 10_000 });
if (mapErrors.length) throw new Error(/* … */);   // green
```

MapLibre puts its canvas in the DOM as soon as it has a GL context — well
before it has finished trying, and failing, to fetch tiles and glyphs over a
network that isn't there. On a fast local machine the check sampled an empty
array roughly two seconds early and passed. On a slower CI runner the failures
landed inside the window, got collected, and were unreadable. One bug hid the
other: the suite had to get *slower* before it could show me it was also
blind.

## What I tried first

**Add the missing host to the allowlist.** Can't — that's the point. The host
is inside an object the classifier never sees. There is no string to add.

**Widen the filter to swallow the unreadable shape.**

```js
// no
/^\[object \w+\]$/.test(text) ||
```

This is the version that ships. It's green, it's one line, and it converts
every future object-shaped console error in the app — including real ones —
into permitted noise. A filter whose match is "I couldn't read this" isn't a
filter.

**Reach for `jsonValue()`**, which is the answer most search results give:

```js
const args = await Promise.all(msg.args().map((a) => a.jsonValue()));
```

It's better than `text()` and still wrong for this. `jsonValue()` serialises,
so an `Error` comes back as its enumerable own properties only:

```json
{"name":"AJAXError","url":"https://tiles.openwaters.io/12/34/56.pbf"}
```

The `message` — which is where MapLibre puts the status and the failing URL —
isn't an enumerable own property, so it's gone. On a plain `new Error("boom")`
you get `{}`. It happens to carry the URL here because that error also stores it
as a field; rely on that and the next library breaks you.

**Only assert `pageerror` and stop filtering console errors at all.** Genuinely
tempting, and it would have stayed green forever. It also deletes the assertion
that catches an app that logs its way through a broken offline path without
throwing — which is exactly the failure mode an offline-first PWA has.

## The fix

Resolve each argument *in the page*, where it's still a real object:

```js
function watchErrors(page) {
  const pending = [];
  page.on("pageerror", (err) =>
    pending.push(Promise.resolve({ kind: "pageerror", raw: err.message })));
  page.on("console", (msg) => {
    if (msg.type() !== "error") return;
    pending.push(
      Promise.all(
        msg.args().map((arg) =>
          arg
            .evaluate((o) => (o instanceof Error ? `${o.name}: ${o.message}` : String(o)))
            .catch(() => null),
        ),
      )
        // Falls back to the rendered text when the page closed before the
        // handles could be read, or when there are no arguments at all
        // (browser-level "Failed to load resource" lines).
        .then((parts) => parts.filter(Boolean).join(" ") || msg.text())
        .catch(() => msg.text())
        .then((raw) => ({ kind: "console.error", raw, filterable: true })),
    );
  });
  return async () => {
    const seen = await Promise.all(pending);
    return seen
      .filter((e) => !e.filterable || !isChsFetchNoise(e.raw))
      .map((e) => `${e.kind}: ${e.raw}`);
  };
}
```

Read that same failing line now and it says:

```text
Error: AJAXError: Not Found (404): https://tiles.openwaters.io/…
```

— which `isChsFetchNoise` classifies correctly, because the host is finally in
the string.

Three things in there are load-bearing beyond the `evaluate`:

- **`pageerror` is never filterable.** An uncaught exception is always a
  failure, whatever it says. Only console errors get classified.
- **Both `.catch()`es fall back to `msg.text()`.** A handle can't be read after
  its page closes, and browser-level lines like `Failed to load resource:
  net::ERR_FAILED` arrive with no arguments at all — `msg.text()` is the
  correct source for those, and it's the reason that regex clause still earns
  its place.
- **The return value is a `settle()`, not an array.** Resolving a handle is a
  round trip to the browser, so the listener can't append synchronously any
  more. Collection and judgement are now two separate moments, and every call
  site has to await the second one:

```js
const settleMapErrors = watchErrors(mapPage);
await mapPage.reload({ waitUntil: "domcontentloaded" });
await mapPage.waitForSelector(".map-canvas .maplibregl-canvas", { timeout: 10_000 });
// The canvas appears well before the map has finished failing its external
// fetches, so asserting the instant it exists passed for the wrong reason —
// the errors simply hadn't been logged yet. Settle first, then judge.
await new Promise((resolve) => setTimeout(resolve, 2_000));
const mapErrors = await settleMapErrors();
if (mapErrors.length) throw new Error(`/map offline reload reported errors:\n${mapErrors.join("\n")}`);
```

The async fix forced the shape that fixes the race. That's a nice accident, not
a design — but it's the reason to prefer a collector object over an array you
push into: an array tempts you to read it at the wrong instant, and a `settle()`
can't be read at all until you've awaited it.

## The ordering the offline blocks need

Same suite, adjacent trap. Cutting the network with CDP and then asserting
requires the steps in one specific order, and two of the six exist purely
because getting them wrong produces a **green** run.

![Six ordered steps for an offline emulation check: load online until the service worker controls the page, cut the network over CDP, prove the cut with a real fetch because a connectivity flag is not evidence, attach the console listeners only after that proof fetch, reload and wait for the canvas, then settle every pending handle before judging.](/assets/img/puppeteer-console-message-text-object-object-class-name-msg-args-jshandle-evaluate-maplibre-ajaxerror-navigator-online-emulatenetworkconditions-offline/offline-block-ordering.svg)

```js
// 2. cut it
const cdp = await page.createCDPSession();
await cdp.send("Network.enable");
await cdp.send("Network.emulateNetworkConditions", {
  offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1,
});

// 3. prove it — a real request to an origin that must not resolve
const networkState = await page.evaluate(() =>
  fetch("https://example.com/" + Math.random()).then(() => "UP").catch(() => "down"),
);
if (networkState !== "down") {
  throw new Error(`network emulation did not take effect: fetch reported "${networkState}"`);
}

// 4. only NOW attach the listeners
const settleErrors = watchErrors(page);
```

**Don't accept `navigator.onLine` as the proof.** It answers "does this device
have a network interface", never "can I reach anything" — a captive portal
returns `true` all day. Under CDP emulation it's worse than merely unhelpful:
whether the flag follows the emulated state is a browser-and-transport detail
that has changed across versions and setups, and has read `true` on a cut
network in this project before. On the combination I re-measured today
(Chrome 151, `puppeteer-core` 25.3.0) it reported `false` correctly, both via
CDP and via `page.setOfflineMode(true)` — which is exactly why it's a bad
oracle. A signal that's right on your machine, this week, and silently wrong on
the runner is the same failure class as everything else in this post. A fetch
that must reject is evidence. A flag is a claim.

**Attach the listeners *after* the proof fetch, not before.** The proof fetch is
supposed to fail — that's its job — and Chrome logs its own resource-load error
for it regardless of the `.catch()` on the JS side. Attach a console listener
first and your very first collected "app error" is the test's own probe. It'll
be the top line of a failure report about something else entirely.

## The bonus finding: a third origin nobody had written down

Once the errors were legible, they immediately said something new. The
allowlist had two external hosts on it — the tide API and the bathymetry tile
host. The real map was hitting **three**.

![The map style sheet fetched from the bathymetry tile host points its glyphs field at a third-party font server, so the label layer fetches glyph files from an origin on no allowlist, while the tile host and the tide API host were both already allowed.](/assets/img/puppeteer-console-message-text-object-object-class-name-msg-args-jshandle-evaluate-maplibre-ajaxerror-navigator-online-emulatenetworkconditions-offline/three-origins.svg)

A MapLibre style sheet has a `glyphs` field, and the vendor style we load points
it at MapLibre's public demo font server — a different origin from the one
serving the style. Add a label layer and you're fetching glyph files from a host
nobody in the project ever chose:

```js
const GLYPH_HOST = "demotiles.maplibre.org";   // NOT the tile host
```

That's a real finding, not just test bookkeeping: an offline-first app was
quietly depending on a third party's demo infrastructure to draw place names.
It had been true for weeks. Nobody knew, because for weeks the only evidence
was a line reading `[object Ae]`.

One more, in the same batch: when the network is cut hard enough that no
response comes back at all, MapLibre re-wraps the rejection as a bare
`Error: Failed to fetch` carrying no URL — its `AJAXError`, the one that *does*
name the host, only exists once a response actually arrived. There is nothing
left to attribute it to, so that one gets an anchored exact match rather than a
substring:

```js
/^Error: Failed to fetch$/.test(text) ||
```

Anchored, so `Error: Failed to fetch https://…` from anywhere else still fails
the smoke.

## Why it matters

The general rule is narrower than "console errors are unreliable":

**Never classify on a rendering.** `msg.text()`, a log line, a formatted table,
a CLI's pretty output — every one of them is a lossy projection chosen for a
human reader, and every one of them can change between versions without
breaking a single type. If a decision depends on a field, get the field. Here
the field was one `arg.evaluate()` away the whole time.

Two traps sit next to it:

- **A filter that can't parse its input must fail, not pass.** The one-line
  regex that swallows `[object Ae]` is available at every step of this story and
  it's the wrong move every time. If your classifier gets something it can't
  read, that's a red test, not a matched rule.
- **Waiting for the first sign of life is not waiting.** `waitForSelector` on
  the artifact that appears *earliest* is the most common way to build a check
  that samples before the system has finished. Wait for the last thing, or
  settle over a window and judge afterwards.

And the meta-lesson: this suite was green for two months. It went red only when
a slower machine let the errors land inside the assertion window — the fastest
way to find out a check is blind is to make it slower.

---

I'm building the software for an all-electric charter catamaran mostly in
public — SignalK plugins, MCP servers, and this offline tide app that has to
work with no signal in the Salish Sea. The smoke suite above lives in
[`scripts/smoke.mjs`](https://github.com/sailingnaturali/slackwater-web/blob/main/scripts/smoke.mjs)
([`32bfe09`](https://github.com/sailingnaturali/slackwater-web/commit/32bfe09)).

*Related:* [Porting a tide engine to Swift with the original as the test oracle]({% post_url 2026-08-11-porting-javascript-to-swift-test-oracle-neaps-tide-prediction-golden-vectors-harmonic-constituents-noaa-validation %}) — what it looks like when a check does examine the result · [Monitor the delivery path, not just the alarm]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}) — the same silence, one layer out
