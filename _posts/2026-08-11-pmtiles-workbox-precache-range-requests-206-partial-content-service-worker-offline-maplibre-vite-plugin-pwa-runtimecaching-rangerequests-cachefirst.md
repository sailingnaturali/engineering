---
layout: post
title: "Your service worker's precache can't do Range requests — PMTiles needs 206"
description: "A Workbox-precached .pmtiles archive is served as a plain 200 with the whole body and no Content-Range, but pmtiles reads with HTTP Range requests and requires 206 Partial Content — so the MapLibre map drew on the cold first visit and threw 'Server returned no content-length header or content-length exceeding request. Check that your storage backend supports HTTP Byte Serving.' on every return visit. Fix: take .pmtiles out of the vite-plugin-pwa globPatterns and serve it from a CacheFirst runtimeCaching route with rangeRequests: true, plus a non-ranged warm fetch — because a ranged request can never populate that cache under cacheableResponse statuses [200]. Sub-gotchas: registerType 'prompt' means no clientsClaim so serviceWorker.ready resolves before controller is set, and the 2 MB maximumFileSizeToCacheInBytes default silently drops large precache entries."
tags:
  - pwa
  - service-worker
  - workbox
  - pmtiles
  - maplibre
  - offline
  - vite
date: 2026-08-11
---

> **TL;DR** — Workbox's precache stores and replays a full `200 OK`. `pmtiles`
> reads the archive with HTTP Range requests and requires `206 Partial
> Content`, so a precached `.pmtiles` renders fine on a cold first visit — when
> no service worker is in the path yet — and throws on every visit after that.
> Take `.pmtiles` out of `globPatterns` and serve it from a `CacheFirst`
> `runtimeCaching` route with `rangeRequests: true`, plus **one non-ranged warm
> fetch**, because a ranged request can never populate that cache on its own.
> [Jump to the fix](#the-fix). Repo:
> [slackwater-web](https://github.com/sailingnaturali/slackwater-web).

[Slackwater](https://github.com/sailingnaturali/slackwater-web) is an offline
tide and current app for the Salish Sea — a PWA that computes predictions on
device so it still works with no signal, which is the only condition that
matters when you're actually in Dodd Narrows. Its map screen draws a coastline
from a committed 4.78 MB PMTiles archive (`public/land.pmtiles`, OSM land
polygons clipped to the Salish Sea, z0–14) rendered by MapLibre. No tile
server, no network.

Getting that archive to survive offline took two tries, and the failure mode of
the first one is the entire post: **it worked on the first visit and broke on
every visit after.**

## The problem: the map draws once, then never again

The obvious way to make a file available offline in a `vite-plugin-pwa` app is
to precache it. That's one glob entry:

```ts
// vite.config.ts — the first attempt
workbox: {
  globPatterns: ["**/*.{js,css,html,svg,png,json,woff2,pmtiles}"],
  // land.pmtiles is 4.78 MB; the default 2 MB cap would silently skip it
  // and the map would have no land offline.
  maximumFileSizeToCacheInBytes: 6 * 1024 * 1024,
},
```

Load the app in a fresh tab: coastline draws. Reload it: blank map, and this in
the console —

```
Error: Server returned no content-length header or content-length exceeding
request. Check that your storage backend supports HTTP Byte Serving.
```

That string is thrown by `pmtiles`' own `FetchSource.getBytes`, and it is
*correct*. Something in the path really did return the whole file instead of
the slice it asked for. It just wasn't the storage backend.

![The same pmtiles byte-range read gets 206 Partial Content from the static host on a first visit and a plain 200 with the full body from the Workbox precache on every return visit, which is what makes pmtiles throw.](/assets/img/pmtiles-workbox-precache-range-requests-206-partial-content-service-worker-offline-maplibre-vite-plugin-pwa-runtimecaching-rangerequests-cachefirst/first-visit-vs-return-visit.svg)

## Diagnosis: precache is 200-shaped, and it only joins the path on visit two

Two facts collide.

**1. A precache response is always a full 200.** Workbox precaches by
`cache.put()`-ing complete responses, and the Cache API flatly refuses to store
a partial one — try it and you get
`TypeError: Failed to execute 'put' on 'Cache': Partial response (status code 206) is unsupported`.
So the precache route can only ever answer with the entire body and status 200.
It doesn't read the `Range` header; it has nothing to slice.

**2. pmtiles treats a 200 as a hard error, deliberately.** Here's the check, from
[the pmtiles source](https://github.com/protomaps/PMTiles/blob/main/js/src/index.ts):

```ts
// some well-behaved backends, e.g. DigitalOcean CDN, respond with 200 instead of 206
// but we also need to detect no support for Byte Serving which is returning the whole file
const contentLength = resp.headers.get("Content-Length");
if (resp.status === 200 && (!contentLength || +contentLength > length)) {
  if (controller) controller.abort();
  throw new Error(
    "Server returned no content-length header or content-length exceeding request. Check that your storage backend supports HTTP Byte Serving."
  );
}
```

A 200 whose `Content-Length` exceeds what was requested means byte serving isn't
working — pmtiles aborts rather than silently downloading a multi-gigabyte
archive to read a 16 KB directory. Against a Workbox precache entry that's
exactly what it sees, every time.

**And the timing is what hid it.** A service worker only controls navigations
that *start after* it activates. On a first-ever visit the SW registers,
installs and activates, but the page that installed it was never controlled —
so `/land.pmtiles` went straight to the static host, which handles Range
properly and answered `206`. Everything worked. On the next load the SW is in
the path, the precache answers, and it throws.

The bug is invisible in exactly the state you test in (fresh incognito tab,
hard reload after a deploy) and present in the only state a user is ever in.

## What we tried, and why it failed

### Attempt 1 — precache it and raise the size cap

The config above. Worth keeping the sub-lesson even though the approach was
wrong: `maximumFileSizeToCacheInBytes` defaults to **2 MB**, and a file over
that is dropped from the precache manifest with a build-log line and *no*
runtime error. The app just quietly has no offline copy. If you precache
anything big — a tile archive, a model, a wasm blob — check the manifest, don't
assume the glob matched.

### Attempt 2 — a smoke test that agreed with us

The offline smoke check was green throughout. It was green because it had been
written to be:

```js
// M5: /map opens the discovery map directly. This has to run as the very
// first navigation, before anything else on this origin installs the PWA
// service worker: once the SW is controlling, its default Workbox precache
// route serves the precached land.pmtiles as a plain 200 with no
// Range/Content-Length support, and pmtiles' own byte-serving check throws
// on that — a real bug (land.pmtiles needs workbox-range-requests wired to
// its precache route to survive a returning/offline visit), but out of scope
// for this smoke-only task.
```

The comment names the bug, in full, and then orders the test to avoid it. A
passing check is a claim about what ran, not about what's true — and here the
claim was "the cold path works", which was never in doubt.

### Attempt 3 — runtimeCaching with rangeRequests, and an empty cache

The documented answer is a `runtimeCaching` route with `rangeRequests: true`,
which wires up
[`workbox-range-requests`](https://developer.chrome.com/docs/workbox/modules/workbox-range-requests):

```ts
runtimeCaching: [
  {
    urlPattern: ({ url }) => url.pathname.endsWith(".pmtiles"),
    handler: "CacheFirst",
    options: {
      cacheName: "land-pmtiles",
      rangeRequests: true,
      cacheableResponse: { statuses: [200] },
    },
  },
],
```

Ship that alone and the map still doesn't work offline — and now
`caches.open("land-pmtiles")` is *empty*. Nothing was ever stored.

The reason is in the plugin's one and only callback:

```ts
// workbox-range-requests/src/RangeRequestsPlugin.ts
cachedResponseWillBeUsed: WorkboxPlugin['cachedResponseWillBeUsed'] = async ({
  request,
  cachedResponse,
}) => {
  // Only return a sliced response if there's something valid in the cache,
  // and there's a Range: header in the request.
  if (cachedResponse && request.headers.has('range')) {
    return await createPartialResponse(request, cachedResponse);
  }

  // If there was no Range: header, or if cachedResponse wasn't valid, just
  // pass it through as-is.
  return cachedResponse;
};
```

`cachedResponseWillBeUsed` — that's it. The plugin never touches the outbound
request. It slices a response *you already have*; it has no opinion on how you
got one.

So the first request to reach the route is pmtiles' own, carrying `Range:
bytes=0-16383`. `CacheFirst` misses, goes to the network, and the origin
correctly answers `206`. Then `cacheableResponse: { statuses: [200] }` refuses
to store it — and you can't widen that to `[200, 206]`, because the Cache API
rejects a 206 on `put()` anyway. The cache stays empty, the next read misses
again, and the loop never closes.

![A ranged request can never populate a CacheFirst route because the origin answers 206 and cacheableResponse only stores 200, so the cache stays empty forever; one non-ranged warm fetch stores the full 200 that RangeRequestsPlugin then slices into 206 partials.](/assets/img/pmtiles-workbox-precache-range-requests-206-partial-content-service-worker-offline-maplibre-vite-plugin-pwa-runtimecaching-rangerequests-cachefirst/cachefirst-range-deadlock.svg)

## The fix

Two pieces: the route, and one plain fetch that primes it.

```ts
// vite.config.ts
workbox: {
  // pmtiles is deliberately NOT globbed here: a precache entry is a plain 200
  // with the full body and no Range support, but pmtiles reads the archive
  // with Range requests and needs 206.
  globPatterns: ["**/*.{js,css,html,svg,png,json}"],
  runtimeCaching: [
    {
      urlPattern: ({ url }) => url.pathname.endsWith(".pmtiles"),
      handler: "CacheFirst",
      options: {
        cacheName: "land-pmtiles",
        rangeRequests: true, // serve 206 partials from the cached full body
        cacheableResponse: { statuses: [200] },
        expiration: { maxEntries: 4, maxAgeSeconds: 60 * 60 * 24 * 365 },
      },
    },
  ],
},
```

```tsx
// src/main.tsx — the warm fetch, without which the cache above is never filled
if ("serviceWorker" in navigator) {
  const warm = () => {
    fetch("/land.pmtiles").catch(() => {});
  };
  navigator.serviceWorker.ready.then(() => {
    if (navigator.serviceWorker.controller) warm();
    else navigator.serviceWorker.addEventListener("controllerchange", warm, { once: true });
  });
}
```

That `fetch` carries no `Range` header, so it gets a full `200`, which
`cacheableResponse` accepts and stores. From then on every ranged read that
pmtiles issues hits the cache and `RangeRequestsPlugin` slices the stored body
into the `206` it wanted — offline, forever.

The one-line version: **`rangeRequests: true` is a read path, not a write path.
You still have to get a whole 200 into the cache yourself.**

## Gotchas

### `serviceWorker.ready` does not mean the service worker controls your page

`ready` resolves once there's an *active* registration for the scope. It says
nothing about `navigator.serviceWorker.controller`, and with
`registerType: 'prompt'` those two diverge on the first load: `'prompt'` does
not set `clientsClaim`, so the page that installed the worker is never
controlled. Fire the warm fetch on `ready` alone and on a first-ever visit it
goes straight to the network, bypasses the route entirely, and caches nothing.

![With registerType prompt there is no clientsClaim, so serviceWorker.ready resolves on the first load while controller is still null and the warm fetch is skipped; only the next controlled load has a controller and populates the cache.](/assets/img/pmtiles-workbox-precache-range-requests-206-partial-content-service-worker-offline-maplibre-vite-plugin-pwa-runtimecaching-rangerequests-cachefirst/service-worker-control-timeline.svg)

Hence the two-branch guard: run it now if `controller` is already set,
otherwise wait for `controllerchange` — which is what fires when a worker
*does* claim, whether that's `registerType: 'autoUpdate'` (vite-plugin-pwa
forces `clientsClaim` and `skipWaiting` for that mode) or an update takeover
later in the session.

### Test the controlled path, because that's the one users are on

The rewritten smoke check stops dodging the service worker and goes looking for
it: load online, wait for the SW, **reload to gain control**, wait for the
cache entry to actually exist, then cut the network and reload again.

```js
await mapPage.goto(`${URL}map`, { waitUntil: "domcontentloaded" });
await mapPage.waitForSelector(".map-canvas .maplibregl-canvas", { timeout: 10_000 });
await mapPage.evaluate(() => navigator.serviceWorker.ready);

// NOW the active SW controls the page, so the warm fetch and the map's own
// pmtiles reads go through the runtime Range route.
await mapPage.reload({ waitUntil: "domcontentloaded" });
await mapPage.waitForFunction(() => navigator.serviceWorker.controller != null, {
  timeout: 15_000,
});
await mapPage.waitForFunction(
  async () => (await (await caches.open("land-pmtiles")).match("/land.pmtiles")) != null,
  { timeout: 15_000 },
);

const mapCdp = await mapPage.createCDPSession();
await mapCdp.send("Network.enable");
await mapCdp.send("Network.emulateNetworkConditions", {
  offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1,
});

await mapPage.reload({ waitUntil: "domcontentloaded" });
// This is the assertion the fix exists for.
await mapPage.waitForSelector(".map-canvas .maplibregl-canvas", { timeout: 10_000 });
```

Waiting on `.maplibregl-canvas` rather than the container `div` matters —
the container mounts whether or not MapLibre ever got a WebGL context up. And
don't trust `navigator.onLine` to tell you the emulation took: under CDP
offline it lies. Prove the network is down with a real `fetch()` to an
unreachable origin first, and attach your error listeners *after* that probe,
or Chrome's own resource-load error for the probe lands in your assertions.

### The nice side effect

Once `.pmtiles` left the precache, the largest precached chunk was the map
screen's ~1 MB of JS — comfortably under the 2 MB default — so the
`maximumFileSizeToCacheInBytes` bump could go away. Fewer knobs is the correct
outcome of a fix.

---

Slackwater is the offline tide app I want in my pocket on an all-electric
charter catamaran with no cell signal, so "works on a return visit" isn't a
nice-to-have. Code: [slackwater-web](https://github.com/sailingnaturali/slackwater-web).

*Related: [Porting a tide engine to Swift with the original as the test oracle]({% post_url 2026-08-11-porting-javascript-to-swift-test-oracle-neaps-tide-prediction-golden-vectors-harmonic-constituents-noaa-validation %}) — the prediction engine behind this same app; and [A persistent-queue HTTP reporter for distress traffic over flaky internet]({% post_url 2026-08-01-persistent-queue-http-reporter-offline-catch-up-flaky-boat-internet-jsonl-write-through-restart-proof-400-404-drop-5xx-retry-cap-signalk-dsc-dscwatch %}) — offline-first on the other side of the wire.*
