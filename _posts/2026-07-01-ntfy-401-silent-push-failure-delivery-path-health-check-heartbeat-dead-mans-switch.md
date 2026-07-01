---
layout: post
title: "Monitor the delivery path, not just the alarm"
description: "An expired ntfy access token made every SignalK alarm the relay published return 401 and silently vanish — the whole alarm-to-phone path went dark, and nothing surfaced it because a quiet system produces no failed sends to notice. This is the 'who watches the watcher' blind spot in any self-hosted notification pipeline (ntfy, Gotify, Pushover, Home Assistant, PagerDuty webhooks). The fix: a delivery-path health check inside the relay — a proactive /v1/account heartbeat plus reactive consecutive-failure counting — that raises notifications.ntfyRelay.deliveryFailed on a channel independent of the down phone. With real code."
date: 2026-07-01
tags:
  - signalk
  - ntfy
  - notifications
  - push-notifications
  - monitoring
  - dead-mans-switch
  - self-hosted
  - marine
---

We built a [zero-dependency SignalK→ntfy relay](https://engineering.sailingnaturali.com/signalk-ntfy-push-notifications-to-phone-zero-dependency-relay/) so a man-overboard, low-battery, or depth alarm reaches a phone even when nobody's at the chartplotter. It worked. Then, a month later, it silently stopped working, and we found out **by accident** — while smoke-testing an entirely different plugin, this line scrolled past in the SignalK server log:

```console
ntfy responded 401
```

Every alarm the relay had tried to push was getting a `401 Unauthorized` from ntfy and evaporating. The alarm-to-phone path had been dark for who-knows-how-long, and nothing had told us. On a boat, "your emergency notifications quietly stopped delivering" is the exact failure you cannot afford to discover during the emergency.

This is the broke → tried → fixed of a blind spot that isn't marine at all: **you monitor the thing, but not the pipe that tells you about the thing.** Anyone running a self-hosted alert pipeline — ntfy, Gotify, Pushover, Home Assistant notifications, a PagerDuty webhook — has the same hole.

## The problem: a failure with nothing to fail

Here's the whole chain:

```
SignalK notification  →  signalk-ntfy-relay  →  ntfy  →  phone
```

The relay's send path is a fire-and-forget POST. By design it never throws — one bad push must not stall the next alarm — so a non-2xx response just gets logged:

```js
const req = lib.request(u, { method: 'POST', headers }, (res) => {
  res.resume(); // drain
  if (res.statusCode >= 300) app.error(`ntfy responded ${res.statusCode}`);
});
```

That log line *is* the entire failure signal. And nothing consumes it.

Now sit with the nastiest property of this failure mode: **the relay only sends when an alarm fires.** A boat at anchor on a calm night fires no alarms, so there are no sends, so there is nothing to fail, so the broken path stays perfectly invisible. An expired token isn't discovered until the next real MOB or EPIRB event tries to deliver — which is precisely the moment you needed it to already be working.

A per-send failure log is not monitoring. It's a receipt for a delivery that already didn't happen, filed in a drawer nobody opens.

## Diagnosis: isolate the leg that's failing

A 401 could be a lot of things — wrong topic, a publish-path bug, a reverse proxy eating the `Authorization` header (a [common ntfy 401 cause](https://github.com/binwiederhier/ntfy/issues/650)). We wanted to isolate it to one leg without firing a fake MOB every time. ntfy has a read-only account endpoint, so a token-only probe answers "is the token still good?" with zero side effects:

```console
$ curl -s -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer tk_..." https://ntfy.sh/v1/account
401
```

`401` on a bare `GET /v1/account` — no topic, no publish, no message body involved. That isolates it cleanly: not the topic, not the relay's publish code, **the token itself.** ntfy.sh account tokens can carry an expiry, and this one had lapsed. Our topic is reserved, so publishing to it *requires* a valid token — an expired token means every publish is a 401, forever, until someone notices.

Root cause found. But the root cause was never the interesting part. The interesting part is that a token expiring is a totally ordinary event, and our system's response to it was **silence**.

## What we tried first (and why it wasn't enough)

**Attempt 1 — just mint a non-expiring token.** ntfy lets you create a token that never expires:

```console
$ curl -s -X POST -H "Authorization: Bearer tk_old..." \
    -H "Content-Type: application/json" \
    -d '{"label":"signalk-relay","expires":0}' \
    https://ntfy.sh/v1/account/token
```

This removes the *most likely* cause, and it's worth doing — prefer eliminating a failure mode over monitoring it. But it's not a fix for the blind spot. A token can still be revoked, an ACL can change, ntfy.sh can have an outage, DNS can break. Every one of those reproduces the exact same silent-dark path. Removing the top cause narrows the hole; it doesn't close it.

**Attempt 2 — alarm on the first failed send.** Tempting, but wrong. Auth failures are permanent, but a lot of send failures are transient — a dropped connection, a 5-second timeout, a momentary ntfy hiccup. Alarming on the first blip would cry wolf constantly on a marine link that drops all the time. The signal we actually want is *sustained* failure, not one bad POST.

Neither attempt gives the system its own pulse. That's the real requirement: **the notification pipeline needs a health check separate from the events it carries.**

## The fix: a delivery-path health check inside the relay

Two mechanisms, one shared counter. Both live in the relay itself — no external watchdog service to also keep alive.

**Proactive heartbeat.** On an interval (default 24h), probe the path even when no alarms are firing. This is the piece that catches an expired token *between* alarms, on the quiet night before the emergency:

```js
// Read-only auth/reachability probe: GET {server}/v1/account.
// Catches an expired/revoked token (or an unreachable server) proactively,
// before a real alarm needs the path. Never throws.
function defaultCheckAccount({ server, token }, app, cb) {
  const u = new URL(`${(server || 'https://ntfy.sh').replace(/\/+$/, '')}/v1/account`);
  const lib = u.protocol === 'http:' ? http : https;
  const headers = token ? { Authorization: `Bearer ${token}` } : {};
  const req = lib.request(u, { method: 'GET', headers }, (res) => {
    res.resume();
    cb(res.statusCode >= 200 && res.statusCode < 300, res.statusCode);
  });
  req.on('error', (e) => { app.error(`ntfy account check failed: ${e.message}`); cb(false); });
  req.setTimeout(5000, () => req.destroy(new Error('ntfy account check timeout')));
  req.end();
}
```

**Reactive counting.** Every real send now reports its outcome, and consecutive failures accumulate. Both paths feed one function that alarms only past a threshold (default 3) — riding out the transient blips that killed attempt 2:

```js
// A run of `failureThreshold` consecutive failures raises the delivery-path
// alarm; any success resets and clears it.
function recordResult(ok, detail) {
  if (ok) {
    consecutiveFailures = 0;
    if (deliveryFailedRaised) { deliveryFailedRaised = false; setDeliveryFailed(false); }
    return;
  }
  consecutiveFailures += 1;
  if (consecutiveFailures >= failureThreshold && !deliveryFailedRaised) {
    deliveryFailedRaised = true;
    setDeliveryFailed(true, detail);
  }
}
```

**Where the alarm surfaces is the whole point.** It must not go out through the very path that's broken — pushing "the push path is down" to the down phone is a no-op. So the relay raises it as a *SignalK notification* under its own name:

```js
const DELIVERY_FAILED_PATH = 'notifications.ntfyRelay.deliveryFailed';

function setDeliveryFailed(active, detail) {
  app.handleMessage(plugin.id, {
    updates: [{ values: [{ path: DELIVERY_FAILED_PATH, value: active
      ? { state: 'alert', method: ['visual'],
          message: `ntfy delivery path failing${detail ? ` (${detail})` : ''} — alarms are not reaching the phone`,
          timestamp: new Date().toISOString() }
      : { state: 'normal', method: [], message: '' } }] }],
  });
}
```

That lands on the SignalK dashboard and our voice pipeline — **channels independent of the phone that's down.** And it carries one deliberate exclusion: the relay subscribes to `notifications.*`, so its *own* delivery-failed notification would otherwise get forwarded straight back to the failing ntfy path. Drop it:

```js
// Never forward our own delivery-path alarm — it must not loop through the
// failing ntfy path (it surfaces via the dashboard/voice instead).
if (path.startsWith('ntfyRelay.')) return;
```

Test-first, as always — four failing tests before any of this existed (threshold behaviour, clear-on-success + counter reset, loop-avoidance, reactive counting):

```console
✔ health check raises deliveryFailed only after failureThreshold consecutive failures
✔ a success clears deliveryFailed and resets the failure counter
✔ the deliveryFailed notification is never forwarded to ntfy (loop-avoidance)
✔ reactive send failures count toward the deliveryFailed threshold
```

Shipped in [`signalk-ntfy-relay` v0.2.0](https://github.com/sailingnaturali/signalk-ntfy-relay), two new config knobs, both with safe defaults:

```
healthCheckIntervalHours   24   Proactively probe /v1/account; 0 disables. Token-only.
failureThreshold            3   Consecutive failures before raising the delivery-path alarm.
```

We also added a small diagnostics CLI, `scripts/ntfy-doctor.js`, so the path can be verified on demand instead of waiting for a real alarm — `check` (the `/v1/account` probe), `test` (publish + poll to confirm end-to-end delivery), `poll`, `mint`, and `revoke`:

```console
$ node scripts/ntfy-doctor.js check --config .../signalk-ntfy-relay.json
/v1/account: 401
✗ token invalid/expired/revoked — mint a new one on ntfy.sh
```

## Why it matters / gotchas

- **A signal nobody consumes is not monitoring.** `app.error('ntfy responded 401')` felt like we'd "handled" the failure. We hadn't — we'd written it down. If no code path acts on a failure log, the failure is silent no matter how loudly it's logged. This is the [Watchdog / dead-man's-switch pattern](https://oneuptime.com/blog/post/2026-02-06-heartbeat-dead-man-switch-opentelemetry-pipeline/view) that Prometheus/Alertmanager users know well ("who watches the watcher?") — the twist is applying it to the *outbound* leg, and doing it *inside the relay* rather than bolting on a second service you'd also have to keep alive.

- **Absence of failure is not proof of health.** The trap specific to alert pipelines: they're exercised only when something's already wrong. A quiet week generates zero sends, so zero failures, so a false all-clear. That's why the proactive heartbeat matters more than the reactive counter — it manufactures traffic on purpose, so the path is exercised on the calm night, not for the first time during the MOB.

- **Alarm on a threshold, not the first failure.** Auth failures are permanent; network blips aren't. `N` consecutive failures rides out the transient and still catches the durable — a single knob (`failureThreshold`) that separates "the token expired" from "the wifi flickered."

- **Never route the health alarm through the failing path.** Push "the push path is down" to the down phone and it goes nowhere. The delivery-failed signal has to surface on an *independent* channel — for us the dashboard and voice, for you maybe a log-scraper, a second provider, or an LED. And exclude it from the pipe it describes, or it loops.

- **Prefer removing the failure mode over monitoring it — then monitor the rest.** The non-expiring token deletes the single likeliest cause outright. The health check then covers the long tail nothing can pre-empt: revocation, ACL change, provider outage. Belt *and* suspenders, in that order.

The general shape, provider-agnostic: any pipeline whose job is to tell you when something's wrong needs its own out-of-band pulse, because it is exercised only in the moment you most need it and least want to be discovering it's broken.

## Close

This came from running the alerting layer of an all-electric charter catamaran, where a silently-dead man-overboard notification is worse than none at all — at least a missing feature is a known gap. The relay, the health check, and the `ntfy-doctor` CLI are open source: [github.com/sailingnaturali/signalk-ntfy-relay](https://github.com/sailingnaturali/signalk-ntfy-relay).
