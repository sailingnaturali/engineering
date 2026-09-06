---
layout: post
title: "Four ways a delivery-health alarm silently doesn't work"
description: "mqtt.js only invokes the publish callback on PUBACK, so while the broker is unreachable it fires neither success nor failure — a health counter fed on delivery outcomes goes dark during exactly the outage it exists to report. Three more from the same review: a self-notification skip placed before the MQTT publish so the alarm reached nobody, a SignalK plugin.start that cleared the in-memory raised set but not the notifications tree (an admin-UI config save calls stop then start, latching deliveryFailed at alert forever), and a method: ['visual'] health alarm that by design can never page. Real code, real fixes, in a SignalK notification router."
date: 2026-08-11
tags:
  - signalk
  - mqtt
  - notifications
  - monitoring
  - dead-mans-switch
  - alarms
  - self-hosted
  - marine
---

> Four independent bugs in one small delivery-health check. The headline: **mqtt.js only invokes the `publish` callback on PUBACK**, so during a broker outage it fires neither success nor failure and a consecutive-failure counter never moves — the monitor sleeps through the exact outage it was written to report. Fix: record a failure yourself when `client.connected === false`, then publish anyway. [Jump to the fix](#the-fix).

![Diagram of a delivery-health path — lane outcome, failure counter, raised guard, notifications tree, MQTT publish, dashboard and voice — with four marked points where the alarm silently stops: the callback that never fires, the loop guard placed before the publish, the restart that clears the in-memory set but not the tree, and a visual-only alarm that cannot page.](/assets/img/mqtt-js-publish-callback-not-called-broker-offline-puback-signalk-delivery-health-alarm-deliveryfailed-plugin-restart-latched-config-save-stop-start-visual-only/four-blind-spots.svg)

Five weeks ago I published [Monitor the delivery path, not just the alarm]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}). The argument: a notification pipeline is exercised only when something is already wrong, so it needs its own pulse — count consecutive delivery failures, raise a `deliveryFailed` notification past a threshold, and surface it on a channel that doesn't depend on the lane that's down.

I still believe every word of it. This post is what happened when I re-implemented that same pattern in the plugin that replaced the relay, shipped it, and then read the whole branch back with fresh eyes. **The health check was broken four independent ways.** None of them were in the alarm-routing paths — the sirens worked fine. All four were in the layer whose entire job is to tell me when the sirens don't.

## Problem: the watcher looked right and did nothing

The successor is [`signalk-notification-router`](https://github.com/sailingnaturali/signalk-notification-router) — one subscription to `notifications.*`, three outputs: MQTT (which the dashboard and the voice agent read), a Telegram siren for `alarm`/`emergency`, and an agent webhook for `alert`/`warn`. Delivery health is tracked **per lane**, so MQTT dying doesn't claim Telegram is failing:

```js
const failures = new Map();   // lane -> consecutive failure count
const raised = new Set();     // lanes currently carrying a deliveryFailed alarm

function recordResult(lane, ok) {
  if (ok) {
    failures.set(lane, 0);
    if (raised.has(lane)) { raised.delete(lane); setDeliveryFailed(lane, false); }
    return;
  }
  const n = (failures.get(lane) || 0) + 1;
  failures.set(lane, n);
  if (n >= failureThreshold && !raised.has(lane)) {
    raised.add(lane);
    setDeliveryFailed(lane, true);
  }
}
```

That is the July post's design, faithfully. It shipped in 1.0.0 with 53 passing tests. Every test I had thought to write was green — and the reason they were green is that **each of the four bugs lives in a seam between two components I had tested separately**: the counter and the MQTT client, the notification tree and the publish path, the plugin lifecycle and the in-memory mirror of the tree, the alarm and the human.

A whole-branch review after shipping is what found them. Not a bug report — nothing reported it, which is the point.

## Diagnosis: four places one alarm can stop

Walk the path an alarm has to travel and the failures line up in order:

```text
lane send outcome → recordResult() → raised guard → notifications tree
                                   → MQTT publish → dashboard + voice → human
```

1. The outcome never arrives, so the counter never moves. (mqtt.js)
2. The counter moves and the tree is written, but the row never leaves the tree. (the loop guard)
3. The tree is written, and can then never be un-written. (the restart latch)
4. The row reaches the dashboard, which is the *only* place it can ever reach. (visual-only)

Each one alone makes the health check useless. I had all four.

## Blind spot 1: mqtt.js only calls back on PUBACK

The MQTT lane's outcome came from the publish callback:

```js
function publishMqtt(topic, envelope) {
  if (!mqttClient) return;
  mqttClient.publish(topic, JSON.stringify(envelope), { qos: 1, retain: true }, (err) =>
    recordResult('mqtt', !err)
  );
}
```

This reads like every callback in Node: fires with an error, or fires without one. It isn't. From the [mqtt.js README](https://github.com/mqttjs/MQTT.js/blob/main/README.md#publish), on `client.publish(topic, message, [options], [callback])`:

> `callback` - `function (err, packet)`, fired when the QoS handling completes, or at the next tick if QoS 0. An error occurs if client is disconnecting.

"When the QoS handling completes" means **on PUBACK** at QoS 1 (PUBCOMP at QoS 2). The client is `mqtt@5`; in `lib/client.js`, an offline publish never reaches the wire at all:

```js
// _sendPacket()
if (!this.connected) {
  this._storePacket(packet, cb, cbStorePut);   // queue it, and return
  return;
}
```

and `_storePacket` puts the QoS-1 packet in the outgoing store, where the callback waits for an ack that cannot arrive until the broker comes back. The callback isn't errored. It isn't dropped. It's **deferred, indefinitely**.

So during a broker outage the MQTT lane records neither a success nor a failure. `failures.get('mqtt')` stays at `0`, the threshold is never crossed, and `deliveryFailed.mqtt` cannot raise. A health counter that only counts *completed* deliveries measures nothing during an outage, because an outage produces no completions.

This is the July post's own lesson biting from the other end. There I wrote that a quiet boat produces no sends, so no failures, so a false all-clear. Here the boat is noisy — alarms are firing, publishes are being called — and it *still* produces no failures, because failure was defined as "the callback said so" and the callback is on the far side of the broken thing.

### What I tried

**Await the publish instead.** mqtt v5 has `publishAsync`, and a promise reads better than a callback:

```js
try { await mqttClient.publishAsync(topic, body, { qos: 1, retain: true }); recordResult('mqtt', true); }
catch (e) { recordResult('mqtt', false); }
```

Identical semantics. The promise settles on the same PUBACK, so it simply hangs instead of not calling back. Prettier, equally blind.

**Race the callback against a timer.** There is no per-publish timeout option, so this means hand-rolling one per message — and then holding the bag when the deferred callback *does* fire on reconnect, twenty minutes later, against a message you already recorded as failed. Double-counting a recovering lane into a fresh alarm is worse than the bug.

**Drop to QoS 0 with `queueQoSZero: false`.** This genuinely does produce an immediate error callback while offline — `_storePacket`'s last branch fires `cb(new Error('No connection to broker'))`. It also throws away the thing QoS 1 buys: real alarms queue and flush on reconnect. Trading alarm delivery for alarm *observability* is exactly backwards.

The fix is not to make the callback trustworthy. It's to stop asking the callback a question it can't answer, and ask the client directly.

![Two timelines of an mqtt.js QoS-1 publish. With the broker up, publish is followed by PUBACK and the callback fires, so the health counter records a result. With the broker down the packet is queued in the outgoing store, no PUBACK arrives, the callback never fires, and the failure counter stays frozen at zero so deliveryFailed can never raise.](/assets/img/mqtt-js-publish-callback-not-called-broker-offline-puback-signalk-delivery-health-alarm-deliveryfailed-plugin-restart-latched-config-save-stop-start-visual-only/puback-timeline.svg)

## Blind spot 2: the loop guard sat one line too early

The July post's hardest-won rule was: never route the health alarm through the failing path. The router obeyed it with an early `continue` at the top of the delta handler:

```js
const path = v.path.slice('notifications.'.length);
// Never route our own delivery-path alarms back out — they must not
// loop through the very lane that is failing.
if (path.startsWith(SELF_PREFIX)) continue;
```

Correct intent, wrong line. Everything downstream of that `continue` includes the MQTT publish:

```js
publishMqtt(`${prefix}/${path}`, buildEnvelope(row, position()));   // ← never reached for self rows
newlyActive.push(row);                                             // ← the push lanes (correctly skipped)
```

MQTT is not a push lane here. It is the **only** path from the SignalK notifications tree out to the dashboard and the voice agent — the two "independent channels" the whole design leans on. Skipping it meant `deliveryFailed.mqtt` (and `.telegram`, and `.hook`) reached exactly one audience: somebody already logged into the SignalK admin UI, looking at the notifications tree, which is not a thing anyone does on a boat at 02:00.

The alarm was real, correct, well-tested, and invisible.

The test that covered this was green, and its name is the giveaway:

```console
✔ the plugin never routes its own deliveryFailed alarm
```

It asserted the alarm didn't reach Telegram or the webhook. It never asserted the alarm reached *anything*. A negative test with no positive counterpart will happily pass on a dead system.

## Blind spot 3: an admin-UI config save latched the alarm forever

`raised` is an in-memory mirror of what's currently `alert` in the notifications tree. `plugin.start` reset it along with everything else, which looks like ordinary hygiene:

```js
failures.clear();
raised.clear();      // ← this one
```

The SignalK notifications tree is server state; it survives a plugin restart. The in-memory `Set` does not. And **saving config in the SignalK admin UI calls `stop()` then `start()`** — no server restart, no page reload, just a save button. Sequence:

```text
1. the mqtt lane fails 3× → raised = {mqtt}, tree shows deliveryFailed.mqtt = alert
2. operator saves any config change → SignalK calls stop(), then start()
3. start() clears raised     → raised = {},  tree still shows alert
4. the broker comes back, a publish succeeds → recordResult('mqtt', true)
5. `if (raised.has(lane))` is false → setDeliveryFailed(lane, false) never runs
6. tree shows alert forever — until the whole SignalK server restarts
```

A latched-on alarm on a recovered lane is arguably worse than no alarm: it trains you to ignore the one indicator whose entire value is that it's normally quiet.

**What I tried:** rebuilding `raised` on start by reading the tree back with `app.getSelfPath('notifications.notificationRouter.deliveryFailed…')`. It works, and it's more "correct" in that it re-derives state from the source of truth. It's also more code, one more API dependency, and one more thing to get wrong at startup — to fix a bug whose cause was clearing a set that had no business being cleared. `failures` *should* reset (a stale failure streak shouldn't count toward a fresh threshold). `raised` shouldn't. Deleting one line beats adding ten.

![Timeline of the latched alarm, showing the notifications tree stuck at alert while the in-memory raised set is emptied by a config save, so the lane's recovery never clears the tree.](/assets/img/mqtt-js-publish-callback-not-called-broker-offline-puback-signalk-delivery-health-alarm-deliveryfailed-plugin-restart-latched-config-save-stop-start-visual-only/restart-latch.svg)

## Blind spot 4: visual-only, on purpose

The fourth isn't a bug. It's the design constraint that makes the other three matter, and it doesn't go away when they're fixed:

```js
value: active
  ? {
      state: 'alert',
      method: ['visual'],      // never ['sound'], never a push
      message: `${lane} delivery path failing — notifications are not reaching it`,
      timestamp: new Date().toISOString(),
    }
  : { state: 'normal', method: [], message: '' },
```

Routing keys on the notification's own `method` array, so `['visual']` is what stops the health alarm from being classified into a push lane and looping straight back through the lane that's failing. It's deliberate and it's right.

It also means the health alarm **can never page anybody.** It is a light on a panel. If the Telegram lane is down and nobody opens the dashboard, the fact that Telegram is down is displayed, correctly, to an empty room. The July post said to surface the alarm on an independent channel; what it didn't say clearly enough is that *independent* and *reachable* are two different properties, and a self-hosted stack usually only has enough independent paths to guarantee one of them.

I don't have a fix for this one. I have a boundary: the health alarm reports lane failures to whatever is watching, and something outside this plugin — a phone, a person, a second provider — has to be the thing that watches. Naming the residual risk beats pretending the fourth channel exists.

## The fix

**1 — ask the client, not the callback.** One line before the publish, and still publish, so QoS-1 alarms queue and flush on reconnect:

```js
function publishMqtt(topic, envelope) {
  if (!mqttClient) return;
  // mqtt.js only calls the publish callback on PUBACK, so an unreachable
  // broker would otherwise record neither success nor failure — the health
  // counter would sit silent through the exact outage it exists to report.
  // Still publish: qos-1 messages queue and flush on reconnect.
  if (mqttClient.connected === false) recordResult('mqtt', false);
  mqttClient.publish(topic, JSON.stringify(envelope), { qos: 1, retain: true }, (err) => {
    try {
      recordResult('mqtt', !err);
    } catch (e) {
      try { app.error(`mqtt publish callback error: ${e.message}`); } catch {}
    }
  });
}
```

(`=== false`, not `!mqttClient.connected` — a test double or a client mid-handshake without the property shouldn't be read as offline. And the callback is invoked directly by mqtt.js, not through a promise chain, so a throw inside it takes down the process rather than losing one outcome.)

**2 — move the guard past the publish.** Self rows publish to MQTT like any other row; only push routing is skipped:

```js
const isSelf = path.startsWith(SELF_PREFIX);
// …
publishMqtt(`${prefix}/${path}`, buildEnvelope(row, position()));
// Our own delivery-path alarms still publish to MQTT (the only path from the
// notifications tree to voice/dashboard) but are never routed back out through
// classify/route — that would loop through the very lane that is failing.
if (isSelf) continue;
newlyActive.push(row);
```

Safe by two independent mechanisms, not one: `method: ['visual']` means `classify()` can't assign it a lane anyway, and an MQTT failure can't re-raise past the `raised` guard.

**3 — don't clear the mirror of state you didn't clear.**

```js
failures.clear();
// Do NOT clear `raised`: the notifications tree survives a plugin restart, so
// forgetting a raised lane here means the next success never clears the tree.
```

**4 — no code.** Documented as a boundary, in the README and above.

Every fix TDD'd, red before green, 53 → 63 tests:

```console
✔ an unreachable MQTT broker still records failures and raises deliveryFailed.mqtt (Finding 3)
✔ a connected test double without a `connected` property is treated as connected
✔ the delivery-health alarm itself reaches MQTT (Finding 1)
✔ the plugin never routes its own deliveryFailed alarm, but still publishes it to MQTT
✔ a raised alarm survives a restart and still clears on recovery (Finding 2)
✔ a throwing app.error does not produce an unhandled rejection, and later deliveries still work (Finding 5)
```

Note the second test name in that renamed pair. `the plugin never routes its own deliveryFailed alarm` became `…, but still publishes it to MQTT`. The bug was in the clause that wasn't there.

Shipped as [`@sailingnaturali/signalk-notification-router` 1.2.0](https://www.npmjs.com/package/@sailingnaturali/signalk-notification-router). Anyone who ran 1.0.0–1.1.0 is affected by the first two.

## Why it matters / gotchas

- **Your monitor's failure modes are correlated with the thing it monitors.** This is the whole post in one line. Three of the four bugs are the same mistake wearing different clothes: the health check was built out of the same components as the delivery path, so the outage took both down together. The publish callback is unavailable precisely when the broker is; the health alarm's only exit is the transport whose failure it reports. Independence has to be *designed in* and then *checked*, or you've built a smoke detector wired to the same circuit as the stove.

- **"Fires on success or error" is an assumption, not a contract.** Check what your client actually promises. mqtt.js says "when the QoS handling completes", and completion requires the broker. Two caveats if you copy this fix: with `queueQoSZero: false` an offline QoS-0 publish *does* error back immediately (a different branch entirely), and [MQTT.js#1561](https://github.com/mqttjs/MQTT.js/issues/1561) documents a race where a QoS-0 callback can be dropped rather than deferred — closed as not planned. Don't state the deferral as a universal guarantee; state it for QoS 1 at default settings, which is what it is.

- **The plugin lifecycle is a failure mode.** Saving config in the SignalK admin UI is a `stop()` + `start()`. Any in-memory structure that mirrors server-side state — the notifications tree, a resource provider's cache, a subscription list — has to survive that, or reset *both* sides. Half a reset is a latch. (`plugin.start` is now also self-guarding: it calls `plugin.stop()` first, so a `start()` without a preceding `stop()` can't leave two live subscriptions and a double siren.)

- **A negative test passes on a dead system.** `never routes its own alarm` was true of the correct implementation, of the broken one, and of a plugin that does nothing at all. Every "X must not reach Y" assertion needs its "X must reach Z" partner in the same test, or the day Z breaks, nothing turns red.

- **Ship, then read the whole branch back.** No user reported any of this; the failure mode of a broken monitor is silence. The four were found by re-reading a shipped branch end to end, with the specific question "how does each of these paths *not* work?" — which is a different exercise from code review, and the only one that catches a bug whose symptom is nothing happening.

## Close

This is the alerting layer of an all-electric charter catamaran, where the difference between a silent alarm and a working one is the entire value of the system. The router — the health check, the four fixes, and the tests — is MIT and open: [github.com/sailingnaturali/signalk-notification-router](https://github.com/sailingnaturali/signalk-notification-router).

*Related: [Monitor the delivery path, not just the alarm]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}) — the health check this post re-implements and breaks; [a zero-dependency SignalK relay]({% post_url 2026-06-05-signalk-ntfy-push-notifications-to-phone-zero-dependency-relay %}) — the plugin this router replaced; [the NMEA 2000 alarm-fatigue problem]({% post_url 2026-07-11-nmea-2000-paradox-alarm-fatigue-signalk-open-source-severity-notifications-plain-language-voice-alerts-vendor-lock-in %}) — why the notification's own `method` array decides routing.*
