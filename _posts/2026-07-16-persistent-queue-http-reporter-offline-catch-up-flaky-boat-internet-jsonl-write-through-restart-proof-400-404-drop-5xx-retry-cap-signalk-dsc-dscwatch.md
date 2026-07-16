---
layout: post
title: "A persistent-queue HTTP reporter for distress traffic over flaky internet"
description: "A DSC distress call your VHF heard may be a copy that shore stations missed — and on a boat, the internet uplink is the least reliable link in the relay chain. How signalk-distress-core v0.5.x delivers reports to DSCWatch through a write-through JSONL queue: append-before-POST crash safety, in-order sequential delivery, a pinned response policy (400/404 = permanent drop, 5xx = capped retry, network error = queue and catch up offline), queue reload across restarts with torn-line skip and maxQueue trim, AbortSignal.timeout on every fetch, and the stale-flusher restart race that could clobber the queue file (fixed in v0.5.1)."
date: 2026-07-16
tags:
  - signalk
  - dsc
  - marine
  - nodejs
  - offline-first
  - message-queue
  - retry
  - reliability
  - self-hosted
---

> **TL;DR** — Don't `fetch()`-and-forget safety-relevant reports over marine internet. `signalk-distress-core` ships a generic persistent-queue HTTP reporter: every payload is appended to a JSONL file *before* the POST, delivered sequentially in order, retried forever on network errors, retried with a cap on 5xx, and dropped immediately on 400/404. The queue survives crashes and restarts. [Jump to the response policy](#the-response-policy-what-each-http-answer-means).

## Why this matters for safety at sea

When a vessel in trouble hits the red distress button on a DSC VHF radio — or an EPIRB, SART, or MOB beacon starts transmitting on AIS — every receiver in range gets a copy. Shore stations hear most of it. But VHF is line-of-sight: behind an island, deep in a fjord, or simply far enough offshore, a distress burst can be heard by a nearby boat *and missed by every shore station*. The copy your radio captured may be the only one with a position in it that made it anywhere.

That's the case for relaying received distress traffic to a shore-side aggregation service: a crowd of receivers extends coverage beyond what any single station — afloat or ashore — can hear. [DSCWatch](https://dscwatch.com) is one such network: it aggregates received DSC traffic from stations around the world into coverage maps and distress logs, and [`signalk-dsc`](https://github.com/sailingnaturali/signalk-dsc) can submit every call it hears.

But now look at the chain: radio → boat server → **boat internet** → aggregation service. On a boat, the uplink is the least reliable link in that chain. Cellular dies in exactly the remote places where your copy of a distress call matters most. Satellite drops in rain, in swell, behind terrain. The server power-cycles with the house bank. If the reporting code is a bare `fetch()`, every one of those blinks silently discards a heard distress call — and *"we dropped a MAYDAY on the floor because the internet blinked"* is not an acceptable failure mode.

So the delivery requirements write themselves:

- **Write-through persisted** — the report is on disk before the first delivery attempt, so a crash mid-flight loses nothing.
- **Restart-proof** — whatever was undelivered at shutdown is delivered after startup.
- **In-order** — DSC position *refinements* (`$--DSE`) must arrive after the alerts they refine.
- **Offline catch-up** — hours of outage queue up and drain when connectivity returns.

That's a generic problem, not a DSC problem. So it lives in [`signalk-distress-core`](https://github.com/sailingnaturali/signalk-distress-core) (v0.5.0) as a payload-agnostic module — `signalk-dsc` maps its events onto DSCWatch report bodies and calls `report()`; [`signalk-ais-distress`](https://github.com/sailingnaturali/signalk-ais-distress) can reuse it as-is. The rest of this post is the engineering.

## The naive versions, and why each one fails

**Fire-and-forget** is where everyone starts:

```js
// Looks fine on shore wifi. On a boat it's a data shredder.
fetch(url, { method: 'POST', body: JSON.stringify(report) }).catch(() => {});
```

Offline for six hours crossing a strait? Six hours of received calls are gone. Process restarts? Anything in flight is gone. And on a boat both of those are *routine*, not exceptional.

**Retry in memory** is the next instinct — keep an array, retry on failure:

```js
const queue = [];
function report(payload) { queue.push(payload); flushSoon(); }
```

Better, until the process exits — SignalK restarts whenever you save any plugin's configuration, and the whole server power-cycles with the boat's electrical system. Everything queued is gone.

**Batch to disk on a timer** is the classic telemetry answer: buffer, flush every N seconds. But the window between "received" and "persisted" is exactly the crash window, and for distress traffic the acceptable size of that window is zero.

## Write-through, not batching

The reporter appends the payload to a JSONL queue file *first*, then immediately kicks the flusher. A healthy network still sees the POST within milliseconds; the disk write just happens to come before it.

```js
return {
  /** Enqueue and kick the flusher. Fire-behind: never throws. */
  report(payload) {
    try {
      queue.push({ payload, attempts: 0 });
      if (queue.length > maxQueue) {
        queue = queue.slice(-maxQueue);
        persist();
      } else {
        fs.mkdirSync(path.dirname(queueFile), { recursive: true });
        fs.appendFileSync(queueFile, JSON.stringify(payload) + '\n');
      }
      flush();
    } catch (err) {
      log(`reporter: enqueue failed: ${err.message}`);
    }
  },
  start() { started = true; flush(); },
  stop()  { started = false; clearTimeout(timer); timer = null; },
};
```

Three deliberate choices in those few lines:

- **`appendFileSync`, one JSON object per line.** Append is the cheapest durable write there is, and JSONL means a partial write corrupts *one line*, not the file (more on that below).
- **Fire-behind, never throws.** The caller is a hot path handling a distress alert — raising alarms, writing the logbook. Reporting must never take that path down.
- **`attempts` is in-memory only.** The disk format is just payloads. Retry accounting resets on restart, which is fine — a restart is a fresh chance, not a continuation of a grudge.

Delivery is sequential and in order — one POST at a time, head of the queue first — so a `$--DSE` position refinement can never overtake the distress alert it refines.

## The response policy: what each HTTP answer means

The core design decision is that **"the POST failed" is three different situations**, and each one gets a different answer:

| Outcome | Meaning | Action |
|---|---|---|
| `2xx` | Delivered (200 merged / 201 created) | Dequeue, persist, reset backoff |
| `400` / `404` | Bad body or rejected receiver key — a retry cannot fix it | Drop it, move on (404 also signals the plugin once) |
| `5xx` | Server reachable but erroring | Retry with backoff, capped per entry |
| Network error / timeout | Offline — the marine normal | Keep **everything**, back off, catch up later |

Here's the flush loop that implements it:

```js
async function flush() {
  if (!started || flushing) return;
  flushing = true;
  try {
    while (started && queue.length) {
      const entry = queue[0];
      let res;
      try {
        res = await fetchImpl(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'User-Agent': userAgent },
          body: JSON.stringify(entry.payload),
          signal: AbortSignal.timeout(fetchTimeoutMs),
        });
      } catch (err) {
        // Network down (the offline-passage case): keep everything —
        // whatever is behind the head is failing for the same reason,
        // so in-order blocking costs nothing. Retry on a growing timer.
        if (!started) return;
        log(`reporter: network error (${err.message}) — ${queue.length} queued`);
        backoff();
        return;
      }
      if (!started) return;
      if (res.ok) {
        queue.shift();
        persist();
        backoffMs = backoffBaseMs;
        permanentSignaled = false;
        continue;
      }
      if (res.status === 400 || res.status === 404) {
        // A retry cannot fix a bad body or a rejected receiver key.
        queue.shift();
        persist();
        log(`reporter: dropped report (HTTP ${res.status})`);
        if (res.status === 404 && !permanentSignaled) {
          permanentSignaled = true;
          onPermanentError(res.status);
        }
        continue;
      }
      // Server reachable but erroring (5xx): retry with backoff, but cap
      // per entry — one poison payload must not block the queue behind it.
      entry.attempts += 1;
      if (entry.attempts >= maxAttempts) {
        queue.shift();
        persist();
        log(`reporter: dropped report after ${maxAttempts} attempts (HTTP ${res.status})`);
        continue;
      }
      backoff();
      return;
    }
  } finally {
    flushing = false;
  }
}
```

The asymmetry is the point:

- **Network errors never consume retry attempts.** Being offline for a nine-hour passage is not the payload's fault, so nothing is dropped for it, ever (up to `maxQueue`). Head-of-line blocking is *free* here — everything behind the head would fail for the same reason.
- **5xx retries are capped per entry** (`maxAttempts`, default 10). Without the cap, one poison payload that reliably 500s would block every report behind it forever. With it, in-order delivery yields to liveness after a bounded effort.
- **400/404 are dropped on the first response.** A malformed body or an unknown receiver key will be exactly as malformed on attempt fifty. Retrying a permanent rejection just hammers someone else's server.
- **404 signals the plugin exactly once** (`onPermanentError` → `app.setPluginStatus` in `signalk-dsc`), and a later success resets the once-guard. Reports keep being attempted, so fixing the receiver key or the endpoint URL in config heals delivery without a restart — no "notification spam" and no "silently wedged until reboot".

That last point is the same lesson as our [ntfy 401 incident]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}): a delivery path that fails must *say so* somewhere a human looks, exactly once, and recover by itself when the config is fixed.

## Surviving restarts: reload, torn lines, and the trim

On construction the reporter reloads whatever the last process left behind:

```js
try {
  for (const line of fs.readFileSync(queueFile, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      queue.push({ payload: JSON.parse(line), attempts: 0 });
    } catch {
      // torn/corrupt line — skip it, keep the rest
    }
  }
} catch {
  // no queue yet
}
```

The **torn-line skip** is why the disk format is JSONL and not one big JSON array: if the power died mid-append, exactly one line is unparseable. `JSON.parse` per line means that line is skipped and every intact report before and after it still delivers. A JSON array with a torn tail would lose the whole file.

Rewrites (dequeue, trim) go through a **temp-file-and-rename** `persist()` so the queue file is never observed half-written:

```js
function persist() {
  const tmp = `${queueFile}.tmp`;
  fs.mkdirSync(path.dirname(queueFile), { recursive: true });
  fs.writeFileSync(tmp, queue.map((e) => JSON.stringify(e.payload)).join('\n') + '\n');
  fs.renameSync(tmp, queueFile);
}
```

And **`maxQueue` (default 5000) drops oldest first** when a long outage overflows it. Newest-wins is the right policy for distress relay: the most recent calls are the ones a shore-side service can still act on, and 5000 queued reports is weeks of traffic for most stations anyway.

## The bug that shipped in v0.5.0: the stale-flusher restart race

v0.5.0 shipped with the design above and a green test suite — and a race that could destroy the queue file. It was caught the same morning, reviewing the shutdown path, and fixed in v0.5.1.

The scenario: SignalK restarts a plugin whenever its configuration is saved. That calls `stop()` on the old reporter instance and constructs a new one — which loads the queue file and starts appending to it. But `stop()` can land **while the old instance's POST is still in flight**. The old flusher is parked on `await fetchImpl(...)`. When that stale fetch finally resolves:

```js
// v0.5.0 — the resolving await charges ahead:
if (res.ok) {
  queue.shift();
  persist();   // rewrites the queue file from the OLD instance's memory
  ...
```

`persist()` rewrites the whole file from the *old* instance's in-memory queue — silently deleting every report the *new* instance had appended since. A config tweak at the wrong millisecond erases a heard distress call from the queue. Exactly the failure mode this module exists to prevent, reintroduced by its own cleanup path.

The fix is two guards — re-check `started` after every `await` boundary before touching shared state:

```diff
      } catch (err) {
        // Network down ...
+       if (!started) return;
        log(`reporter: network error (${err.message}) — ${queue.length} queued`);
        backoff();
        return;
      }
+     if (!started) return;
      if (res.ok) {
        queue.shift();
        persist();
```

The catch-branch guard matters too: without it, a network error resolving on a stopped reporter schedules a fresh backoff timer — a zombie instance that wakes up later and races the live one.

Two consequences worth naming:

- **The in-flight entry stays queued for the new instance**, so it may be POSTed twice. That's deliberate: the DSCWatch backend deduplicates repeated submissions of the same call (DSC alerts auto-repeat on air anyway, and every repeat is reported), so at-least-once is the correct choice over at-most-once. For distress traffic, a duplicate is noise; a loss is the failure.
- **This is the generic `async` shutdown lesson**, nothing marine about it: any `await` in a loop is a suspension point where the world can change — including "you were stopped and replaced". Every resumption that mutates shared state (a file, a socket, a DB row) has to re-validate that it still owns that state.

And the race got a test — a gated fetch that holds the POST in flight across a `stop()`:

```js
test('stop() during an in-flight POST: the stale flusher never touches the queue file', async () => {
  const queueFile = tmpQueue();
  let resolveFetch;
  const gate = new Promise((r) => (resolveFetch = r));
  const impl = async (url, opts) => {
    calls.push(JSON.parse(opts.body));
    await gate; // hold the POST in flight
    return { ok: true, status: 201 };
  };
  const reporter = createReporter({ url: 'u', userAgent: 'ua', queueFile, fetchImpl: impl });
  reporter.start();
  reporter.report({ seq: 0 });
  await eventually(() => assert.equal(calls.length, 1)); // fetch is in flight
  reporter.stop(); // plugin restart: a new instance may now own the file
  fs.appendFileSync(queueFile, JSON.stringify({ seq: 99 }) + '\n'); // new instance's append
  resolveFetch(); // stale POST finally resolves
  await new Promise((r) => setTimeout(r, 50));
  const onDisk = fs.readFileSync(queueFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l).seq);
  assert.deepEqual(onDisk, [0, 99]); // stale flusher must NOT have shifted/persisted
});
```

## Fetch timeouts: a black-holed link must not wedge the flusher

v0.5.1 also added the one thing a default Node `fetch` won't give you — a deadline:

```js
res = await fetchImpl(url, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'User-Agent': userAgent },
  body: JSON.stringify(entry.payload),
  signal: AbortSignal.timeout(fetchTimeoutMs),   // default 30 s
});
```

Marine links don't just go down — they *black-hole*: a satellite terminal that accepts the TCP connection and then says nothing more, sometimes for minutes. Without a timeout, the single sequential flusher sits parked on that `await` indefinitely, and the whole queue stalls behind a connection that will never answer. `AbortSignal.timeout()` (stdlib since Node 17.3, no `AbortController` boilerplate needed) turns that into an abort error, which takes the existing network-error path: keep the entry, back off, retry.

## Tests pin the policy, not the implementation

The response policy *is* the contract, so the tests assert it directly against a scriptable `fetch` stand-in — no HTTP server, no mocking framework, just `node:test`:

```js
test('400 is dropped without retry; the next report still delivers', async () => {
  const { impl, calls } = mockFetch((call) =>
    call.body.bad ? { ok: false, status: 400 } : { ok: true, status: 201 }
  );
  const reporter = createReporter({ url: 'u', userAgent: 'ua', queueFile: tmpQueue(), fetchImpl: impl });
  reporter.start();
  reporter.report({ bad: true });
  reporter.report({ good: true });
  await eventually(() => {
    assert.equal(calls.length, 2); // bad tried exactly once
    assert.equal(calls[1].body.good, true);
  });
  reporter.stop();
});

test('5xx retries are capped per entry, then the entry drops and the queue moves on', async () => {
  const { impl, calls } = mockFetch((call) =>
    call.body.poison ? { ok: false, status: 500 } : { ok: true, status: 201 }
  );
  const reporter = createReporter({
    url: 'u', userAgent: 'ua', queueFile: tmpQueue(), fetchImpl: impl,
    maxAttempts: 3, backoffBaseMs: 5, backoffMaxMs: 10,
  });
  reporter.start();
  reporter.report({ poison: true });
  reporter.report({ after: true });
  await eventually(() => {
    const poisonTries = calls.filter((c) => c.body.poison).length;
    assert.equal(poisonTries, 3); // exactly maxAttempts, then dropped
    assert.equal(calls[calls.length - 1].body.after, true);
  });
  reporter.stop();
});
```

The full suite pins every row of the policy table: 200-and-201 both accepted, in-order delivery, offline catch-up resuming in order with nothing dropped, restart recovery from the JSONL file, torn-line skip, `maxQueue` oldest-first trim, the 404 signal-once-reset-on-success behaviour, and the stale-flusher race above. `fetchImpl` is injectable for exactly this reason — the only seam the module needs.

Two small design notes riding along in the same release:

- **The receiver key is minted once and persisted** (`loadOrCreateReceiverKey`): DSCWatch has no registration call — the first report for a new key creates the receiver record — so the only rule is *reuse the same value forever*. A UUID written to a file in the plugin data directory does that; a station that wants attribution can configure its own key instead.
- **What leaves the boat is a pick-list, not a filter.** The report builder in `signalk-dsc` copies an explicit allow-list of parsed call fields; local-only data (own-ship weather snapshots, spoken alert text, internal IDs) is never sent because it is never picked. Privacy boundaries built as "copy what's allowed" don't rot the way "strip what's forbidden" does. Reporting is on by default with a single toggle to keep all data on the boat — see the [plugin README](https://github.com/sailingnaturali/signalk-dsc#dscwatch-reporting) for the exact field list.

## Gotchas if you build one of these

- **Append-before-POST, always.** If the durable write isn't strictly first, there is a crash window, and on a boat the crash window gets hit.
- **Classify responses; don't treat "not ok" as one case.** Permanent rejections (400/404) retried forever are abuse; transient errors (5xx, timeouts) dropped immediately are data loss. The policy needs both, explicitly, with tests.
- **Cap retries per entry, not globally.** The cap exists to defeat poison-payload head-of-line blocking; a global cap would let one bad payload spend the whole budget.
- **Re-check ownership after every `await`.** `stop()` + in-flight I/O + shared file = the stale-flusher race. Guard every resumption that touches shared state.
- **`timer.unref()` the backoff timer** so a pending retry never keeps the host process alive past shutdown.
- **JSONL over a JSON array** for any on-disk queue: torn writes cost one record, not the file.

## Close

This runs on the same all-electric-catamaran SignalK stack as the rest of this blog, relaying what the radio hears toward people who can use it. The reporter is payload-agnostic and MIT-licensed: [`@sailingnaturali/signalk-distress-core`](https://github.com/sailingnaturali/signalk-distress-core) (`lib/reporter.js`, ~180 lines, tests included), consumed by [`signalk-dsc`](https://github.com/sailingnaturali/signalk-dsc) for DSCWatch reporting.

*Related:* how the DSC calls get captured in the first place — [Logging VHF DSC distress calls in SignalK (PGN 129808)]({% post_url 2026-06-11-signalk-dsc-distress-call-logging-nmea0183-dse-pgn-129808 %}) — and the delivery-path-monitoring lesson this reporter inherits — [Monitor the delivery path, not just the alarm]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}).
