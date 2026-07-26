---
layout: post
title: "Where a received distress call belongs in the SignalK data model"
description: "A MAYDAY, SART, MOB, or EPIRB beacon heard from another MMSI is not your vessel's own alarm state. Why signalk-dsc and signalk-ais-distress moved self-side alarms from notifications.dsc.* / notifications.ais.distress.* to notifications.received.*, and why they also write vessels.<mmsi>.notifications.mob / notifications.distress into the source vessel's own context."
tags:
  - signalk
  - marine
  - dsc
  - ais
  - sart
  - mob
  - epirb
  - notifications
  - data-model
date: 2026-07-26
---

> **TL;DR** — a distress alert heard *from another vessel* is not your boat's own alarm state, so don't raise it as plain `notifications.*` on self. The convention we landed on ([signalk-dsc](https://github.com/sailingnaturali/signalk-dsc) v0.9.0, [signalk-ais-distress](https://github.com/sailingnaturali/signalk-ais-distress) v0.5.0): raise the self-side alarm under **`notifications.received.*`** ("received about another vessel"), and *also* write the state record into the **source vessel's own context** — `vessels.<mmsi>.notifications.mob` for MOB, `notifications.distress` for SART/EPIRB. [Jump to the convention](#the-convention-two-writes).

Our stack has two plugins that hear other people's emergencies. [`signalk-dsc`](https://github.com/sailingnaturali/signalk-dsc) receives VHF DSC calls — a MAYDAY on channel 70 arrives as `$--DSC` sentences or PGN 129808. [`signalk-ais-distress`](https://github.com/sailingnaturali/signalk-ais-distress) alerts on AIS survival beacons — SART, MOB, and EPIRB devices, recognizable by their MMSI prefixes (970 / 972 / 974). Both are built on a shared library, [`signalk-distress-core`](https://github.com/sailingnaturali/signalk-distress-core).

Both plugins originally did the obvious thing: raise a notification under your own vessel.

```
# signalk-dsc ≤ 0.6.x — a received MAYDAY, raised on self
vessels.self.notifications.dsc.distress                state: emergency

# signalk-ais-distress ≤ 0.2.x — a heard MOB beacon, raised on self
vessels.self.notifications.ais.distress.mob            state: emergency
```

That fires the alarm chain, which is the point. But it puts *someone else's emergency* in the same subtree as *your own vessel's* alarm state, and that conflation bites.

## The problem: `notifications.*` on self means "something is wrong with MY boat"

In the SignalK data model, notifications are per-context. `vessels.self.notifications.mob` means **your** crew is in the water. `vessels.self.notifications.grounding` means **you** are aground. The spec's alarm vocabulary (`mob`, `fire`, `sinking`, `flooding`, `collision`, `grounding`, `listing`, `adrift`, `piracy`, `abandon`) describes the vessel the notification hangs off.

Everything downstream is built on that reading:

- **Annunciators and dashboards** render `vessels.self.notifications.*` as own-vessel health. With the old paths, a boat sinking three miles away shows up looking like *your* hull alarm.
- **Muting and acknowledgment** are own-vessel operations. "Silence my alarms" should not be able to swallow a stranger's MAYDAY — and conversely, a received alert you've assessed shouldn't keep tripping logic that watches self state.
- **Automations** keying on self notifications (shutdowns, all-hands triggers) must be able to tell "we are in distress" from "we heard distress."

`notifications.dsc.distress` under self says the first thing when it means the second. This came up in discussion with the SignalK community, and talking it through made the distinction crisp: a distress heard from another MMSI is *data about that vessel*, received by you — not your state.

## What we considered

**Leave it on self under `notifications.dsc.*` (status quo).** Fires the alarm chain, but conflates own-vessel and other-vessel state — the whole problem above.

**Write it *only* into the source vessel's context.** The spec-pure answer: a notification under `vessels.<mmsi>` is that vessel's alarm. But nothing on your boat subscribes to arbitrary other-vessel notification paths, so your own annunciator never fires — a MAYDAY you heard and silently filed is worse than the conflation. And it doesn't even cover every case: a SART or personal EPIRB isn't necessarily a vessel at all.

**Invent device-type leaves in the target context** (`notifications.sart`, `notifications.epirb`). Not spec natures, and a beacon with a 972 MMSI may be a crew-worn personal device — a device-type leaf misdescribes what's happening (a *person in the water*, a *station in distress*), and consumers would have to learn our invented vocabulary.

None of the single-write options work, which is the actual finding: **actuation and state are different consumers, and they want the record in different places.**

## The convention: two writes

**Write 1 — self, under `notifications.received.*`.** This is the actuation layer: the path your own alarm chain, voice pipeline, and annunciators subscribe to. The `received` segment says exactly what it is — received *about another vessel*. Each call raises its *own* per-call path — the leaf is `<transport>-<id>`, so two concurrent MAYDAYs never stomp one key:

```
# signalk-dsc 0.9.0 — one alarm per call, at its own path
vessels.self.notifications.received.distress.dsc-<id>     state: emergency
vessels.self.notifications.received.urgency.dsc-<id>      state: alarm
vessels.self.notifications.received.safety.dsc-<id>       state: warn

# signalk-ais-distress 0.5.0 — SART, MOB, and EPIRB all raise under distress
vessels.self.notifications.received.distress.ais-<id>     state: emergency
vessels.self.notifications.received.<category>.ais-<id>   # AIS Msg 14 relays
```

`<id>` is `<receivedAt>-<mmsi>` with the ISO timestamp's `.` and `:` stripped, so the whole id stays a single path segment instead of splitting into extra ones.

Clearing now has **two levels**:

- **Per-call ack** — a PUT to the exact per-call path you see (`notifications.received.distress.ais-<id>`) clears *that one call* and stamps the store so a restart re-raise skips it. This is SignalK's standard notification-ack: you acknowledge the alarm in front of you, and only it.
- **Bulk clear-by-category** — a PUT to a fixed control path drops *every* live call of that category at once:

```
# control paths — PUT clears all live calls of that type (transport-first)
vessels.self.notifications.received.dsc.<category>            # dsc.distress / .urgency / .safety
vessels.self.notifications.received.ais.distress.<beacon>     # ais.distress.sart / .mob / .epirb
vessels.self.notifications.received.ais.broadcast.<category>  # AIS Msg 14 relays
```

Note the segment order flips: a *raised* alarm is category-first (`received.distress.dsc-<id>`); a *control* path is transport-first (`received.dsc.distress`). Either way you're managing your *response* to someone else's emergency, not your own vessel's condition.

**Write 2 — the source's own context.** This is the interoperable state record: the distress hung on the vessel it's actually about, exactly as if that vessel had raised it — which, over the radio, it did. From `signalk-ais-distress`:

```js
// Mirror signalk-dsc: besides the self alarm, surface the distress in the
// *source vessel's* context, so a consumer reading that AIS target sees its
// emergency — as if the vessel raised it. The self notifications.received.*
// alarm is the actuation layer our own annunciator subscribes to; this is
// the interoperable state record.
function notifyTarget(event) {
  if (!event.mmsi) return;
  const leaf = event.deviceBeacon === 'mob' ? 'mob' : 'distress';
  const value = { state: 'emergency', method: ['visual', 'sound'], message: event.message };
  if (event.receivedAt) value.timestamp = event.receivedAt;
  app.handleMessage(plugin.id, {
    context: `vessels.urn:mrn:imo:mmsi:${event.mmsi}`,
    updates: [{ values: [{ path: `notifications.${leaf}`, value }] }],
  });
  // Also feed the flat legacy self-key so existing MOB subscribers (e.g.
  // meshtastic waypoint minting) keep firing until they migrate to the
  // received.* / per-vessel scheme (SK spec thread 2026-07-15). Default
  // context is self — this is the one deliberate own-vessel double-write.
  if (leaf === 'mob') {
    app.handleMessage(plugin.id, {
      updates: [{ values: [{ path: 'notifications.mob', value }] }],
    });
  }
}
```

So a heard MOB beacon (fake MMSI for illustration) produces three writes — the per-call self alarm, the source-context state record, and the legacy self-key shim:

```
vessels.self.notifications.received.distress.ais-<id>     ← your alarm fires
vessels.urn:mrn:imo:mmsi:972999999.notifications.mob      ← the beacon's own state
vessels.self.notifications.mob                            ← legacy self-key (back-compat)
```

## Why those leaves

**MOB → `notifications.mob`.** It's a real spec nature, and it's what existing consumers key on — [`signalk-meshtastic`](https://github.com/meri-imperiumi/signalk-meshtastic)-style bridges watch other-vessel `notifications.mob` to mint a MOB waypoint on the mesh. Using the spec leaf means those consumers work with no knowledge of our plugin.

**SART/EPIRB → `notifications.distress`.** These beacons carry no nature-of-distress, and the source may be a personal device rather than a vessel — so neither a nature leaf nor a device-type leaf is honest. `distress` states the one thing actually known: this station is in distress.

**DSC → `notifications.<nature>` under the caller.** A DSC distress alert *does* carry a nature-of-distress code, and the ITU table maps almost one-to-one onto the spec's alarm vocabulary — `sinking`, `fire`, `flooding`, `grounding`, `mob`, and so on. So `signalk-dsc` writes the caller-context record at the real nature:

```
vessels.self.notifications.received.distress.dsc-<id>      ← your alarm fires
sar.urn:mrn:imo:mmsi:366999999.notifications.sinking       ← the caller's own state
```

Note the context prefix: a DSC **distress** caller is emitted under the Search-and-Rescue context (`sar.` instead of `vessels.`), which chartplotters like Freeboard-SK render as a distress/SaR target rather than an ordinary AIS contact. Urgency and safety callers stay under `vessels.` like any other contact.

## Two more beats from the same release train

**Received alerts survive a restart.** SignalK notifications are in-memory — a server bounce mid-incident would silently drop an active MAYDAY. Both plugins re-raise every still-fresh, un-acked call on startup, each at its own per-call path (details in the [original signalk-dsc post]({% post_url 2026-06-11-signalk-dsc-distress-call-logging-nmea0183-dse-pgn-129808 %})); a per-call ack stamps the store so the re-raise skips one you've already handled.

**Distress *relays* get attributed to the casualty, not the relaying station.** A coast station retransmitting a distress alert puts the *casualty's* MMSI, nature, and position in different sentence fields than a first-hand alert — the stock parser read the relay's fields as if they were the casualty's, pinning the emergency on the coast station. Fixed upstream in [SignalK/nmea0183-signalk#344](https://github.com/SignalK/nmea0183-signalk/pull/344).

## The shape of it

| Heard | Self (actuation, one per call) | Source's own context (state) |
|---|---|---|
| DSC distress (Ch 70 / PGN 129808) | `notifications.received.distress.dsc-<id>` | `sar.<mmsi>` → `notifications.<nature>` |
| DSC urgency / safety | `notifications.received.<category>.dsc-<id>` | `vessels.<mmsi>` → position only |
| AIS SART / EPIRB (970 / 974) | `notifications.received.distress.ais-<id>` | `vessels.<mmsi>` → `notifications.distress` |
| AIS MOB (972) | `notifications.received.distress.ais-<id>` | `vessels.<mmsi>` → `notifications.mob` (+ legacy `notifications.mob` on self) |
| AIS Msg 14 broadcast | `notifications.received.<category>.ais-<id>` | — |

The "Self" column is the *raised* per-call path; a PUT there acks that one call. The matching **bulk clear-by-category control paths** are transport-first and category-tailed — `notifications.received.dsc.<category>`, `notifications.received.ais.distress.<beacon>`, `notifications.received.ais.broadcast.<category>` — and a PUT to one drops every live call of that type.

One rule underneath all of it: **a notification's context names whose emergency it is.** Self gets the `received.*` alarm because *you* need to act; the source context gets the spec-native record because *they* are the ones in distress. The one deliberate exception is MOB: alongside the source-context `notifications.mob`, both plugins *also* write a flat `notifications.mob` on **self** — a back-compat shim so existing MOB subscribers (meshtastic waypoint minting) keep firing until they migrate to the `received.*` / per-vessel scheme. It bends the rule on purpose, and it's the one place a received alarm still lands on a bare self path.

This is one piece of an all-electric charter-catamaran ops stack — when the radio hears someone in trouble, the data model should say so without claiming the trouble is yours. Code: [`signalk-dsc`](https://github.com/sailingnaturali/signalk-dsc), [`signalk-ais-distress`](https://github.com/sailingnaturali/signalk-ais-distress), shared [`signalk-distress-core`](https://github.com/sailingnaturali/signalk-distress-core).

*Related: [Logging VHF DSC distress calls in SignalK (PGN 129808)]({% post_url 2026-06-11-signalk-dsc-distress-call-logging-nmea0183-dse-pgn-129808 %})*
