---
layout: post
title: "The NMEA 2000 paradox has an open-source answer"
description: "A response to Galvanic Works' 'The NMEA 2000 Paradox.' Their diagnosis is right: identical beeps for sinking and full waste tanks cause alarm fatigue, humans can't monitor dozens of NMEA 2000 data streams, alerts fail under stress, and vendor gateways lock the data up. Every one of those failure modes already has a working open-source counterpart: SignalK notification severity states mapped to push priority, an AI agent that watches the alarms, voice-sized plain-language alerts (DSC/AIS distress included), and a stack that integrates with existing gear instead of replacing it. With code."
date: 2026-07-11
tags:
  - signalk
  - nmea2000
  - marine
  - alarms
  - notifications
  - voice-assistant
  - ai
  - open-source
  - self-hosted
---

> Galvanic Works published [The NMEA 2000 Paradox](https://galvanicworks.com/blog/the-nmea-2000-paradox) — a sharp problem statement about why boats drowning in data still fail their owners: identical beeps for everything, humans as the monitoring system, alerts that collapse under stress, and vendor lock-in. I agree with essentially all of it. This post is the other half: each failure mode they name, next to the open-source code that already addresses it.

Galvanic Works is a marine-safety startup, and their post is the best short statement of the problem I've seen from anyone, commercial or open source. The line that should be framed on every marine electronics bench:

> The boat is sinking: beep-beep. The waste tank is full: beep-beep.

Their catalog of failure modes: **identical alerts** train sailors to ignore alarms; **humans can't monitor dozens of simultaneous data streams**, least of all under stress; alerts aren't **plain language** when it matters; and **proprietary gateways and manufacturer apps** keep the data locked up. They're building a commercial product around fixing this. I've spent the season building the open-source version — a [SignalK](https://signalk.org)-based stack with an AI agent on top — and their post reads like my design doc's problem section. So, receipts.

## Identical beeps: severity is data, not a sound

The beep-beep problem isn't a hardware limitation — it's a data-model failure, and SignalK already fixed the model. Every SignalK notification carries an explicit severity `state` and delivery `method`:

```json
{
  "path": "notifications.mob",
  "value": {
    "state": "emergency",
    "method": ["visual", "sound"],
    "message": "Man overboard!"
  }
}
```

`normal` → `alert` → `warn` → `alarm` → `emergency`. Once severity is data, nothing downstream ever has to emit the same beep twice. My [signalk-ntfy-relay](https://github.com/sailingnaturali/signalk-ntfy-relay) maps it straight onto [ntfy](https://ntfy.sh) push priority, so a sinking boat interrupts your phone's do-not-disturb and a full waste tank does not:

| Signal K state | ntfy priority | tag |
|----------------|---------------|-----|
| `emergency` | 5 (max) | 🆘 `sos` |
| `alarm` | 4 (high) | 🚨 `rotating_light` |
| `warn` | 3 (default) | ⚠️ `warning` |
| `alert` | 2 (low) | ℹ️ `information_source` |
| cleared (`normal`) | 1 (min) | ✅ `white_check_mark` |

Two details matter as much as the mapping. The relay **edge-triggers** — one push when an alarm becomes active, not a repeat while it persists (repetition is how you train people to ignore alarms). And **clearing is a first-class event** (`notifyOnClear`), because "the alarm stopped" is information too, and a system that only ever escalates erodes trust.

## You are not the monitoring system

Their sharpest observation: humans can't watch dozens of streams, and "during an emergency, our brains become 10 times smaller." Agreed — so don't make the human the monitor. My watchstander is an AI agent with two MCP tools in a loop: [`signalk-mcp`](https://github.com/sailingnaturali/signalk-mcp)'s `get_active_alarms` pulls every live notification off the bus, and [`vessel-knowledge-mcp`](https://github.com/sailingnaturali/vessel-knowledge-mcp)'s `explain_notification` joins each one against the vessel's own equipment registry — so the agent doesn't just relay `notifications.electrical.batteries.house.voltage`, it knows *which* battery bank, what chemistry, what the manufacturer's floor is, and what to do about it.

The alarms themselves are plain SignalK **zones** — declarative thresholds in any path's metadata, set from the admin UI, no code:

```json
{
  "electrical.batteries.house.voltage": {
    "meta": {
      "zones": [
        { "lower": 12.0, "upper": 12.4, "state": "warn",  "message": "House bank low" },
        { "upper": 12.0,                "state": "alarm", "message": "House bank critically low" }
      ]
    }
  }
}
```

The agent's job starts where the zone ends: triage, explanation, and a spoken sentence — not another beep.

One lesson I learned the hard way belongs in any writeup of this problem: the alarm pipeline itself is a thing that fails, silently, precisely because a healthy boat fires no alarms. I wrote that one up separately — the relay now heartbeats its own delivery path and raises `notifications.ntfyRelay.deliveryFailed` when the path to your phone goes dark.

## Plain language under stress

The stress-communication point is where most builders get it wrong by adding detail. The discipline that works is subtraction. My distress plugins ([signalk-dsc](https://github.com/sailingnaturali/signalk-dsc), [signalk-ais-distress](https://github.com/sailingnaturali/signalk-ais-distress)) render a **voice-sized message** — type, vessel, situation, range and direction from own position, action, and nothing else:

> DSC distress alert: vessel Wind Chaser, sinking, 2.3 nautical miles northwest. Monitor channel 16.

No MMSI read aloud. No raw coordinates. No "kn" — units are spoken in full because a stressed human parsing text-to-speech shouldn't decode abbreviations. The full detail (MMSI, coordinates, reported time, transport) goes to the call log and an automatic logbook entry, where detail belongs. The agent's own persona rules enforce the same budget conversationally: three sentences is the norm, because every reply is spoken aloud.

The test for any alert is whether it works for a tired human at 0300. Everything that fails that test still gets captured — just not spoken.

## Lock-in: integrate, don't replace

Their fourth complaint — expensive gateways, manufacturer-specific apps, PGN translation configured per vendor — is the one the open-source world solved most thoroughly, because it's the reason SignalK exists. The server sits **beside** the existing electronics as one more bus citizen: NMEA 2000 and 0183 in, one open JSON data model out, every vendor's PGNs normalized to the same paths. Nothing gets replaced; the chartplotter keeps working; the data stops being captive.

To be fair to the hardware reality: you still need a physical bus interface (a CAN adapter or Pi HAT, tens of dollars, not hundreds) — the open stack removes the *software* toll, which is where the lock-in actually lives. Every piece named in this post is MIT-licensed and on npm under [`@sailingnaturali`](https://www.npmjs.com/org/sailingnaturali); the alarm model and zones are stock SignalK.

## The gap they're right about

One item in their post names something the open stack genuinely doesn't have: **trend analytics over accumulated history** — battery degradation curves, maintenance forecasting from engine metrics. The storage half exists (SignalK-to-InfluxDB is mature), but the analysis layer — "your house bank has lost 11% capacity since spring, book a load test" — is unbuilt in the open as far as I can tell. That's a real gap, it's the kind of thing a commercial player may well do first, and I'd love to be wrong about nobody having built it. If you have, say so.

## Where this lands

Full disclosure: my boat is ashore, and most of what this server reports is a mocked vessel on a bench.

The RF half, though, stopped being hypothetical while this post sat in draft. A VHF receiver went onto the bench rig in late July, and real AIS is now flowing into SignalK from it — live targets, real MMSIs, actual traffic moving around the harbour. (The first read was structured garbage. The RS422 differential pair was reversed; the fix was swapping two wires, after a couple of hours of blaming the baud rate.) Position still comes from the mock, because a radio indoors has no sky view, and the DSC watch hasn't had its live soak test yet. So the alarm plumbing above is working code against real radio traffic — and still not sea miles.

But that's rather the point of doing it in the open. Galvanic Works wrote an excellent diagnosis and is building their answer as a product; I'm building mine as a pile of MIT-licensed SignalK plugins and MCP servers anyone can install tonight. Boats get safer both ways, and the more people naming the beep-beep problem out loud, the fewer identical beeps get shipped. Diagnosis fully endorsed — here's the source.

*Related:* [Monitor the delivery path, not just the alarm]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}) · [DSC distress calls into SignalK]({% post_url 2026-06-11-signalk-dsc-distress-call-logging-nmea0183-dse-pgn-129808 %})
