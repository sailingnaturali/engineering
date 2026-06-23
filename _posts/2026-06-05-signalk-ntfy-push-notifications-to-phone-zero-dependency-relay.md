---
layout: post
title: "Push SignalK alarms to your phone with a zero-dependency relay"
description: "SignalK raises alarms into notifications.* but nothing pushes them to your phone away from the chartplotter. We evaluated the existing options — a stale signalk-pushover-notification-relay and an early signalk-ntfy proof-of-concept that pulls in node-fetch and ws — and built our own focused, zero-dependency signalk-ntfy-relay instead. Here's what we tried, why each fell short, and the edge-triggered severity-to-priority design we shipped, with real code."
tags:
  - signalk
  - ntfy
  - push-notifications
  - notifications
  - marine
  - self-hosted
date: 2026-06-05
canonical: "https://engineering.sailingnaturali.com/signalk-ntfy-push-notifications-to-phone-zero-dependency-relay/"
---

SignalK knows when something is wrong. It raises alarms into its `notifications.*` tree with a clear severity ladder:

```
nominal < normal < alert < warn < alarm < emergency
```

A low-battery condition shows up as a `warn`; a man-overboard lands at `notifications.mob` with state `emergency`. The data is right there, structured and timestamped:

```json
{
  "notifications": {
    "mob": {
      "value": {
        "state": "emergency",
        "method": ["visual", "sound"],
        "message": "Man overboard"
      },
      "timestamp": "2026-06-01T19:30:00Z"
    }
  }
}
```

The problem: **nothing pushes those alarms to your phone when you're not standing in front of the chartplotter.** If you're below, ashore, or asleep, the alarm fires into the void. We wanted one dependable thing — a SignalK notification turning into a push on a phone — and we wanted it on a safety path, which raises the bar.

This is the broke → tried → fixed of getting **SignalK push notifications to your phone**. The punchline: a one-way SignalK→ntfy relay needs *zero* npm dependencies, so we built [`signalk-ntfy-relay`](https://github.com/sailingnaturali/signalk-ntfy-relay).

## What we evaluated (and why each fell short)

### Option 1: the classic Pushover relay — stale

The most-referenced community answer to "SignalK notification to phone" is a relay plugin that forwards notifications to a push service. The canonical one is [`signalk-pushover-notification-relay`](https://www.npmjs.com/package/signalk-pushover-notification-relay), targeting Pushover.

The architecture is right — subscribe to notifications, POST to a push service. But the receipts are bad:

```console
$ npm view signalk-pushover-notification-relay
signalk-pushover-notification-relay@1.0.0 | ISC | deps: none
published over a year ago

$ # repo: last pushed 2022 — roughly four years stale
```

When we checked, the repo hadn't moved since 2022 and pushover.net was unresponsive. The plugin is fine; the *sink* is the problem. You do not want to hang a safety-relevant alert on a paid, closed service that's unresponsive when you test it, behind a plugin nobody's touched in four years.

That sent us looking for a better sink.

### The better sink: ntfy

[ntfy](https://ntfy.sh) is the right target. It's open-source, free, self-hostable, actively maintained, and has real iOS and Android apps. Most importantly, its publish API is *just an HTTP POST* — title, priority, and tags all ride in headers:

```bash
curl \
  -H "Title: Low battery" \
  -H "Priority: 4" \
  -H "Tags: rotating_light" \
  -H "Authorization: Bearer tk_yourtoken" \
  -d "House bank below 30%" \
  https://ntfy.sh/your-topic
```

Priority is `1` (min) through `5` (max). `Tags` is a comma-separated list of emoji shortcodes that render as icons on the notification. That's the entire contract. No SDK, no handshake — a POST with headers. For a man-overboard you'd send:

```bash
curl -H "Title: MOB" -H "Priority: 5" -H "Tags: sos" \
  -d "Man overboard" https://ntfy.sh/your-topic
```

Self-hostable, free, maintained, and a one-line publish API. That's the sink. Now: who relays SignalK into it?

### Option 2: the existing ntfy plugin — an early POC with the wrong scope

There's already a plugin: [`signalk-ntfy`](https://www.npmjs.com/package/signalk-ntfy) (`Enand-lab/signalk-ntfy`). Verify it yourself — here's what we found:

```console
$ npm view signalk-ntfy
signalk-ntfy@0.0.4 | Apache-2.0 | deps: 2
dependencies:
  node-fetch: ^2.7.0
  ws: ^8.16.0
published 2 months ago

$ # GitHub: ~9 commits, single author, 0 stars / 0 forks
```

This is an early proof-of-concept: `0.0.4`, one author, single-digit commits, effectively no adoption. That alone is reason to be careful on a safety path — but the more interesting issue is *scope*.

`signalk-ntfy` is **bidirectional**. Its headline feature is interactive ntfy buttons whose responses get published *back* into SignalK. That's a neat idea, and it's exactly why it pulls in **two runtime dependencies**:

- `ws` — a WebSocket client to listen for button-press responses coming back from ntfy.
- `node-fetch` — to POST to ntfy.

For a one-way *safety relay*, the bidirectional half is dead weight, and both dependencies exist only to serve it. Worse, for our purposes the POC is *missing the things a relay actually needs*:

- **edge-triggering** — notify on a *state change*, not repeatedly while a condition persists;
- **severity filtering** — a configurable floor so `alert`-level chatter doesn't page you;
- **severity → ntfy priority/tags mapping** — so an `emergency` arrives as priority 5 with an SOS icon;
- **position enrichment** — where was the boat when this fired;
- **tests**.

So the choice was: adopt an immature `0.0.x` and bolt the relay essentials onto a bidirectional architecture we don't want — or build a focused relay.

### Option 3: a generic SignalK→MQTT gateway — wrong shape

We also considered routing notifications through a generic SignalK→MQTT bridge and pushing from there. Wrong shape for a phone push: it speaks a foreign topic scheme, carries no notion of ntfy priority or tags, and pushes the severity→presentation mapping problem somewhere else instead of solving it. A relay should own the SignalK-notification → phone-push semantics end to end.

## The decision: a focused, zero-dependency relay

Here's the key insight that made the whole thing easy: **a one-way SignalK→ntfy relay needs no npm dependencies at all.** Both of the existing plugin's dependencies fall away once you drop the bidirectional feature.

**No `ws`.** A SignalK *plugin* runs in-process inside the SignalK server, so it reads notifications directly through the plugin API — no external WebSocket client. You subscribe to the `notifications.*` subtree:

```js
module.exports = function (app) {
  const plugin = { id: 'signalk-ntfy-relay', name: 'SignalK ntfy relay' };

  plugin.start = function (options) {
    app.subscriptionmanager.subscribe(
      {
        context: 'vessels.self',
        subscribe: [{ path: 'notifications.*', policy: 'instant' }]
      },
      [],                                   // unsubscribes array
      (err) => app.error(err),
      (delta) => handleDelta(app, options, delta)
    );
  };

  return plugin;
};
```

The `ws` dependency in the existing plugin exists only to hear button responses come *back* from ntfy. A relay never listens, so it's gone.

**No `node-fetch`.** Node ships an HTTPS client. The entire ntfy POST is the standard library:

```js
const https = require('node:https');

function postToNtfy({ server, topic, token, title, priority, tags, body }) {
  const url = new URL(topic, server);          // e.g. https://ntfy.sh/your-topic
  const headers = {
    'Title': title,
    'Priority': String(priority),              // 1..5
    'Tags': tags.join(',')                     // emoji shortcodes
  };
  if (token) headers['Authorization'] = `Bearer ${token}`;

  const req = https.request(url, { method: 'POST', headers });
  req.on('error', (err) => app.error(`ntfy post failed: ${err.message}`));
  req.end(body);
}
```

That's it. `node-fetch` was only ever a polyfill for `fetch`/HTTP — and on a modern Node runtime you don't need it for a single POST.

### Edge-triggering: notify on change, not on repeat

The relay essential the POC lacks. SignalK can re-emit a notification delta while a condition holds; you do *not* want a buzz every few seconds for a battery that's still low. Keep an in-memory `Map` of the last state seen per path and only fire on transitions:

```js
const lastState = new Map();   // path -> last notification state

function handleDelta(app, options, delta) {
  for (const update of delta.updates ?? []) {
    for (const { path, value } of update.values ?? []) {
      const state = value?.state ?? 'normal';   // nominal|normal|alert|warn|alarm|emergency
      if (lastState.get(path) === state) continue;   // no change — skip
      lastState.set(path, state);

      if (severityRank(state) < severityRank(options.minSeverity)) continue;
      relay(app, options, path, value, state, update.timestamp);
    }
  }
}
```

One transition, one push. A condition that clears (back to `normal`/`nominal`) is itself a transition — so you can send a "cleared" notification too, instead of leaving a stale alarm on the phone.

### Severity → priority + tags

The mapping that turns a SignalK state into something ntfy renders meaningfully — loud icons for the loud states:

```js
const RANK = {
  nominal: 0, normal: 0, alert: 1, warn: 2, alarm: 3, emergency: 4
};
const severityRank = (s) => RANK[s] ?? 0;

// state -> { ntfy priority (1..5), tags (emoji shortcodes) }
const NTFY = {
  emergency: { priority: 5, tags: ['sos'] },
  alarm:     { priority: 4, tags: ['rotating_light'] },
  warn:      { priority: 3, tags: ['warning'] },
  alert:     { priority: 2, tags: ['information_source'] },
  cleared:   { priority: 1, tags: ['white_check_mark'] }   // back to normal/nominal
};
```

An `emergency` (man-overboard) lands as priority 5 with an SOS icon; a clear comes through as a quiet priority-1 check mark.

### Position enrichment

When something fires, *where were we?* If the vessel has a fix, append a position line to the push body:

```js
function withPosition(app, body) {
  const pos = app.getSelfPath('navigation.position')?.value;
  if (!pos) return body;
  const ns = pos.latitude >= 0 ? 'N' : 'S';
  const ew = pos.longitude >= 0 ? 'E' : 'W';
  return `${body}\n${Math.abs(pos.latitude).toFixed(4)} ${ns}, ` +
         `${Math.abs(pos.longitude).toFixed(4)} ${ew}`;
}
```

### Self-hosted server + token

ntfy is self-hostable, so the server URL and an optional bearer token are config, defaulting to the public instance:

```json
{
  "server": "https://ntfy.sh",
  "topic": "your-topic",
  "token": "tk_optional_for_self_hosted_or_private_topics",
  "minSeverity": "warn"
}
```

## Why zero-dependency is the point, not a flex

It would be easy to read "zero dependencies" as a vanity metric. On a safety path it isn't:

- **Smaller supply-chain and audit surface.** Every dependency is code you didn't write running on the path between "alarm fired" and "phone buzzed." For something safety-relevant, the right number of transitive packages to audit is as close to zero as you can get. With `node:https` and the in-process plugin API, there's nothing to audit but the plugin itself.
- **Nothing to vendor or break on upgrade.** `node-fetch` v2 vs v3 (CommonJS vs ESM), `ws` majors — these are exactly the upgrades that silently break a plugin you forgot you were running. No deps, no upgrade treadmill.
- **Readable end to end.** You can sit down and read the whole relay in one pass and convince yourself it does what it says. That property is worth more on an alarm path than any feature.

The contrast is the whole argument: the existing plugin's two dependencies aren't waste — they earn their keep serving the **bidirectional button** feature. A one-way relay simply doesn't have that feature, so it doesn't pay that cost.

## What we did *not* do, honestly

- **Use `signalk-ntfy` as-is.** An immature `0.0.x` with no adoption, on a safety-relevant path, missing edge-triggering / severity filtering / tests. No.
- **Contribute the changes upstream.** Tempting, but its bidirectional architecture and goals genuinely differ from a one-way relay. Bending a focused relay onto a button-response design — or pushing a from-scratch rewrite into someone else's POC — serves nobody. A separately-publishable, single-purpose relay is cleaner and more reusable for the next person searching "**signalk ntfy**."
- **Build a generic SignalK→MQTT gateway.** Wrong shape (covered above): foreign topic scheme, no severity/priority semantics, just relocates the mapping problem.

## Tests

A safety relay gets tests, and `node:test` ships with Node — so even the test layer adds no dependency:

```js
const { test } = require('node:test');
const assert = require('node:assert');

test('edge-triggering fires once per transition', () => {
  const seen = [];
  const opts = { minSeverity: 'warn', topic: 't', server: 'https://ntfy.sh' };
  const send = (path, v, s) => seen.push(s);

  step(opts, 'notifications.x', 'warn', send);   // fire
  step(opts, 'notifications.x', 'warn', send);   // repeat — skip
  step(opts, 'notifications.x', 'alarm', send);  // change — fire

  assert.deepStrictEqual(seen, ['warn', 'alarm']);
});

test('emergency maps to priority 5 / sos', () => {
  assert.deepStrictEqual(NTFY.emergency, { priority: 5, tags: ['sos'] });
});
```

## Close

This came out of building the AI and notification plumbing for an all-electric sailing charter — where "the battery alarm fired" needs to reach a phone, not just the chartplotter, and the path it travels has to be auditable end to end. `signalk-ntfy-relay` is **MIT-licensed and zero-dependency** — on npm as [`signalk-ntfy-relay`](https://www.npmjs.com/package/signalk-ntfy-relay) and on [GitHub](https://github.com/sailingnaturali/signalk-ntfy-relay). Install it from the SignalK app store (search "ntfy") or with `npm i signalk-ntfy-relay`. If you've been searching for **SignalK push notifications to your phone** — a **SignalK notification relay** that turns a **SignalK alarm into a phone** push — that's what it's for.
