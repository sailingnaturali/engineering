---
layout: post
title: "Two alert lanes: the siren shouldn't depend on an LLM"
description: "Routing every SignalK notification through an agent gateway puts a model turn, a hook token and a billing relationship in the path of a dragging anchor. The fix is two lanes with independent failure modes: alarm/emergency go straight to the Telegram Bot API from an in-process SignalK plugin, alert/warn wake an agent turn. Routing keys on the notification's own method array (no sound, no push) instead of a path allowlist, the soft lane's coalesce timer is armed from the oldest pending row so a trickle can't reset it, and the hard lane never batches. Plus the operational sting: a correct config file is not evidence a lane is live."
date: 2026-08-21
tags:
  - signalk
  - notifications
  - alarms
  - ai
  - agents
  - telegram
  - marine
  - self-hosted
---

> Don't put a model in the path of the alarm that matters most. Split the notification router in two: `alarm`/`emergency` go **straight to the Telegram Bot API** from the SignalK plugin — no gateway, no model, no billing relationship — while `alert`/`warn` wake an agent turn that reads the vessel and writes one considered message. The lane that matters most then depends on the fewest components. [Jump to the fix](#the-fix).

![A failure-mode grid showing the hard lane still fires when the agent gateway is wedged, the model API is down, the gateway token is broken or the billing has lapsed, while the soft lane is silent in every one of those cases.](/assets/img/signalk-notification-router-two-alert-lanes-hard-soft-telegram-bot-api-no-llm-in-the-alarm-path-method-array-sound-coalesce-window/failure-modes.svg)

In June I wrote up the first generation of this: [a zero-dependency SignalK relay]({% post_url 2026-06-05-signalk-ntfy-push-notifications-to-phone-zero-dependency-relay %}) that turned a notification into a phone push in about a second. This is the second generation, and it exists because that relay came out of the stack and I briefly replaced a one-second push with a twelve-hour one.

## Problem: the alarm path became a cron job

The relay's push service went away, and what filled the gap was an agent gateway running a scheduled boat check:

```cron
0 7,19 * * *    boat-watch    # wake the agent, ask it to look at the vessel
```

Twice a day. A condition arising at 02:00 waits until 07:00. **Worst-case alarm latency went from about a second to about twelve hours.** That is survivable only because my boat is ashore and the vessel data is mocked; it is not survivable with real sensors.

The naive fix is obvious and wrong:

```cron
* * * * *    boat-watch    # every minute — problem solved?
```

Latency fixed, shape still wrong. Every notification now goes through a model turn, so a dragging anchor waits on an LLM round trip — and inherits every way that round trip can fail. The alarm that matters most ends up gated behind the slowest, most expensive, least reliable component in the stack, and the failure is silent: an agent that never wakes looks exactly like a quiet boat.

## Diagnosis: count the things that have to work

My first instinct was "fine, send hard alarms through the gateway, just faster." That turns out not to be possible, and the reason it isn't is what produced the design.

The gateway's inbound hook surface exposes exactly two actions — `wake` and `agent` — and **both of them run a model turn**. There is no no-model message-send endpoint over HTTP. There is a CLI that can send a plain message, but it's a client over the gateway's WebSocket RPC, not something a plugin can call.

So "route the siren through the gateway for tidiness" means the siren depends on:

```text
SignalK  →  router  →  internet  →  gateway process  →  hook token
                                 →  model API  →  provider account in good standing
```

Six things, two of which are somebody else's business relationship with me. Whereas going straight to the messaging platform's Bot API depends on:

```text
SignalK  →  router  →  internet
```

Three things, all of which have to be up anyway for a notification to exist and leave the boat. Once you write both chains down, the split writes itself.

![The router subscribes to the SignalK notifications tree and splits it three ways: every forwardable row to MQTT, alarm and emergency straight to the Telegram Bot API with no model in the path, and alert and warn through an agent gateway and a model API.](/assets/img/signalk-notification-router-two-alert-lanes-hard-soft-telegram-bot-api-no-llm-in-the-alarm-path-method-array-sound-coalesce-window/two-lanes.svg)

A hard alarm takes **both** lanes: the siren immediately, and a follow-up agent turn that adds context when — if — it's ready. The siren has to stand alone, because on a bad day it's the only message that arrives.

## What I tried, and why each one failed

### 1. A path allowlist to decide what pages

The first routing rule I wrote was a list of paths worth waking someone for:

```js
// don't do this
const PUSH_PATHS = [
  /^navigation\.anchor$/,
  /^electrical\.batteries\..*\.voltage$/,
  /^mob$/,
];
const shouldPush = (path, state) =>
  rank(state) >= rank('warn') && PUSH_PATHS.some((re) => re.test(path));
```

It fails on contact with real data. The whale-protection zone plugin I run raises zone presence as a `warn`, and those zones blanket most of the waterways here — so "inside a restricted area" is the *normal* condition, not an exception. Every SignalK restart re-fires them. Under a severity-only rule that's a page on every restart; under an allowlist it's fine right up until a new plugin ships an alarm you forgot to add, and then it's silent. An allowlist for alarms is a denylist you maintain by getting paged.

The data already had the answer in it:

```json
{
  "path": "notifications.navigation.restrictedArea.<zone-id>",
  "value": {
    "state": "warn",
    "method": ["visual"],
    "message": "Inside 400m Approach Distance Prohibition"
  }
}
```

`method: ["visual"]` is the publisher saying *display this, do not sound it*. Meanwhile every distress plugin I run sets `method: ["visual", "sound"]`. The publishers had been declaring their intent the whole time and my router was ignoring it in favour of a regex list I'd have to keep current forever.

So: **`method` decides whether a notification pushes at all; `state` only picks the lane.** No allowlist anywhere. If something routes wrong, it gets fixed at the publisher, which is where the knowledge actually lives.

### 2. A coalesce window re-armed on every arriving row

The soft lane batches — one SignalK restart can transition six paths at once, and six concurrent agent turns is both a spam burst and a bill. My first window was the obvious one:

```js
// don't do this either
function onSoftRow(row) {
  pending.push(row);
  clearTimeout(flushTimer);              // "reset the window"
  flushTimer = setTimeout(flush, 10_000);
}
```

That's a *sliding* window, and a sliding window is a promise that a steady trickle never gets delivered. Rows arriving every 4 seconds reset a 10-second timer forever; the batch grows and never flushes. Which is a strange thing to build into the path of "something is wrong on the boat."

![A timeline comparison: re-arming the window on every arriving row means a steady trickle resets it forever and the batch never flushes, while arming the timer once from the oldest pending row flushes on schedule at ten seconds as one agent turn.](/assets/img/signalk-notification-router-two-alert-lanes-hard-soft-telegram-bot-api-no-llm-in-the-alarm-path-method-array-sound-coalesce-window/coalesce-timer.svg)

The predecessor to this plugin had a `coalesce(transitions, window_s)` function with five tests asserting that the window runs from the oldest pending row. None of them got ported, because the timer *is* the rule once you arm it in the right place:

```js
// The window runs from the OLDEST pending row: arm once when the buffer goes
// non-empty, never re-arm while one is in flight.
function armFlush() {
  if (flushTimer) return;
  const ms = (currentOptions.coalesceSeconds ?? 10) * 1000;
  flushTimer = setTimeout(flushSoft, ms);
  if (flushTimer.unref) flushTimer.unref();
}
```

`if (flushTimer) return;` is the entire fix, and it makes the property structural rather than asserted.

### 3. Posting `{"message": "..."}` to the agent hook

The soft lane looked healthy for weeks. The hook returned `200`, the gateway logged an agent turn, the turn ran and read the vessel. Nobody ever got a message.

```console
$ curl -sS -X POST "$HOOK_URL" -H "Authorization: Bearer $HOOK_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"message":"tank level rising"}'
{"ok":true,"runId":"..."}

# ...and in the gateway's run log:
Delivering to Telegram requires target <chatId>
```

The gateway takes the delivery target as a **body field**, not something implied by the hook URL. Both the old Python sidecar and the plugin's first cut posted only `message`, so every soft alarm since the sidecar era had completed an agent turn and then dropped the answer on the floor. A `200` from a hook endpoint means *admitted*, not *delivered*, and I had been reading it as the latter.

The fix stays gateway-agnostic — the plugin merges an opaque JSON blob the operator supplies, and never learns anyone's field names:

```json
{
  "hookBodyExtra": "{\"deliver\":true,\"channel\":\"telegram\",\"to\":\"123456789\"}"
}
```

```js
body: JSON.stringify({ ...parseHookExtra(opts.hookBodyExtra), message }),
```

`message` is spread last, so operator JSON can never clobber it.

## The fix

Two lanes, one classifier, and the classifier is nine lines:

```js
const HARD = new Set(['alarm', 'emergency']);   // siren + agent follow-up
const SOFT = new Set(['alert', 'warn']);        // agent turn only

// Which push lane this notification takes, or null for no push.
function classify(state, method) {
  if (state == null || INACTIVE.has(state) || !(state in SEVERITY)) return null;
  if (!Array.isArray(method) || !method.includes('sound')) return null;
  if (HARD.has(state)) return 'hard';
  if (SOFT.has(state)) return 'soft';
  return null;
}
```

Routing is then a shape, not a policy engine:

```js
function route(rows) {
  const hardEnvs = [];
  for (const row of rows) {
    const lane = classify(row.state, row.method);
    if (lane === 'hard') hardEnvs.push(buildEnvelope(row, position()));
    else if (lane === 'soft') pendingSoft.push(row);
  }

  // Hard lane fires per-row immediately and never coalesces — deduplication is
  // a comfort feature, a missed alarm is not.
  for (const env of hardEnvs) deliver('telegram', () => sendTelegram(renderSiren(env), opts));
  for (const env of hardEnvs) deliver('hook', () => postHook(renderFollowupPrompt(env), opts));

  if (pendingSoft.length) armFlush();
}
```

The hard sender is a bare `fetch` to the platform's Bot API. No SDK, no gateway, nothing between the plugin and the internet:

```js
async function sendTelegram(text, opts) {
  const res = await fetch(
    `https://api.telegram.org/bot${opts.telegramBotToken}/sendMessage`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: opts.telegramChatId, text }),
      signal: AbortSignal.timeout(10000),
    }
  );
  if (!res.ok) throw new Error(`telegram sendMessage failed: HTTP ${res.status}`);
}
```

Two details in that function are load-bearing. **The bot token is in the request URL**, so the error path checks `res.status` by hand and never surfaces `res.url` or a raw transport error — a rejected fetch whose message carried the URL would write the token verbatim into the server log. And `deliver()` is fire-and-forget rather than awaited, so a wedged gateway can't serialize a later row's siren behind an earlier row's hook timeout.

Verified the way you'd want it verified — stop the gateway, inject a real distress notification, watch what happens:

```console
$ systemctl --user stop <agent-gateway>
$ node scripts/inject-test-notification.js --path test.hardLane \
    --state alarm --method visual,sound --message "TEST - ignore"

# SignalK log:
delivery error on the hook lane: fetch failed
# Telegram: the siren arrived anyway.
```

## Why it matters, and the gotchas nearby

**The routing rule binds every path that can reach a human, not just the router.** The plugin is not the only thing that reads the notifications tree — there's also a once-daily dead man's switch, an independent agent run whose whole job is to notice that an event-driven router has gone quiet (a router that has stopped emitting is indistinguishable from a calm boat). It reads SignalK on its own, so it needed its own copy of the `method` rule. It didn't have one, and on its first real scheduled fire it happily paged me about the standing zone `warn` that the router had been correctly ignoring. The rule now lives in three implementations that must stay in step, and "anything new that reads the notifications tree and can reach a human gets the rule before it ships" is a written policy rather than a thing I remember.

**A correct config file is not evidence a lane is live.** I spent an evening debugging a soft lane whose on-disk config was perfect — URL, token, body extras all set — and which routed nothing and logged nothing. The plugin instance was still holding pre-save config; the last relevant line in the server log was from before the edit. The only positive evidence a lane will deliver is the startup line:

```js
if (!currentOptions.telegramBotToken || !currentOptions.telegramChatId) {
  app.error('no Telegram bot token/chat id — the hard lane (siren) will NOT deliver');
}
if (!currentOptions.hookUrl || !currentOptions.hookToken) {
  app.error('no agent hook URL/token — the soft lane will NOT deliver');
}
```

```console
$ docker logs signalk | grep notification-router
signalk-notification-router: no agent hook URL/token — the soft lane will NOT deliver
```

That line, after the restart that followed the config save, is the check. Nothing else is.

**`method` gates before severity, and it gates silently.** A test notification at `alert` with `method: ["visual"]` is dropped by `classify` on purpose, with no log line at all — correct behaviour that is completely indistinguishable from a broken lane while you're testing one. Test with an injector that sets `method` explicitly:

```bash
SIGNALK_TOKEN=... node scripts/inject-test-notification.js \
  --path test.softLane --state warn --method visual,sound --message "TEST - ignore"
```

(A `PUT` to the notifications REST path returns `404` — no handler is registered. The delta WebSocket is the only way in.)

**The lane split survived the rewrite, which is the real test of it.** All of the above started life as a Python sidecar polling SignalK's REST API every 5 seconds, walking the notification tree, and hand-rolling edge detection. Moving it into an in-process SignalK plugin deleted the poll timer, the tree walk, the edge-trigger bookkeeping, a container, and a `network_mode: host` workaround — the delta subscription gives you all of it. The one property I refused to let dissolve in the port was the hard lane's short dependency chain. In-process is fine (if SignalK is down there are no notifications to route), but the siren still goes straight out to the Bot API rather than being routed through the agent for tidiness.

## Close

This is the notification plumbing for an all-electric charter catamaran, where "the anchor is dragging" has to reach a phone whether or not a language model is having a good night. The plugin is MIT and on npm as [`@sailingnaturali/signalk-notification-router`](https://www.npmjs.com/package/@sailingnaturali/signalk-notification-router) — source on [GitHub](https://github.com/sailingnaturali/signalk-notification-router), including the `classify` and `armFlush` code above and the tests around them.

*Related:* [Push SignalK alarms to your phone with a zero-dependency relay]({% post_url 2026-06-05-signalk-ntfy-push-notifications-to-phone-zero-dependency-relay %}) · [The NMEA 2000 paradox has an open-source answer]({% post_url 2026-07-11-nmea-2000-paradox-alarm-fatigue-signalk-open-source-severity-notifications-plain-language-voice-alerts-vendor-lock-in %})
