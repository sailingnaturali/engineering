---
layout: post
title: "The marine SignalK + MCP landscape: what exists, what's actually novel"
description: "A prior-art map of marine MCP servers and SignalK AI integrations: PostgSail's MCP, NOAA Tides & Currents MCP, generic weather MCPs, VesselSense, d3kOS — mapped against a seven-server fleet (NDBC buoy reality-check, tidal currents, COLREGs, anchorage ranking). What turned out genuinely novel, what a pre-build ecosystem scan would have caught, and why the scan belongs at the start of every build domain."
tags:
  - mcp
  - signalk
  - marine
  - ai
  - open-source
  - architecture
date: 2026-07-21
---

> **TL;DR** — We shipped seven marine MCP servers, *then* ran the ecosystem
> scan we should have run first. The good news: the niche is sparse, and the
> capabilities we bet on (NDBC buoy reality-check, tidal currents, COLREGs
> rule text, anchorage comfort ranking) turned out to have no prior art
> anywhere in the MCP ecosystem. The bad news: a one-evening scan would still
> have changed several decisions. [Jump to the map](#the-map).

This stack runs on a prime directive: *use or improve existing tools before
building your own*. We applied it per-component — it's why we
[deleted our working logbook for signalk-logbook]({% post_url 2026-06-06-adopt-vs-build-ships-log-signalk-logbook-mcp %})
and why the
[weather server got audited against three existing weather MCPs]({% post_url 2026-06-06-marine-weather-mcp-buoy-ground-truth-ndbc-spec-swell-wind-waves %}).
What we never did was scan the *whole* ecosystem at once: every marine MCP
server, every SignalK AI integration, every plugin adjacent to what we were
building.

When we finally ran that scan — seven servers deep — the honest question was:
*how much did we just rebuild?* This post is the answer, published as the map
we wish we'd found.

## The map

Everything here is public; links go to the repos. "Novel" means we found no
prior art doing the capability, in any MCP server, as of the scan.

| Ours | Nearest prior art | Verdict |
|---|---|---|
| [currents-mcp](https://github.com/sailingnaturali/currents-mcp) + [signalk-currents](https://github.com/sailingnaturali/signalk-currents) (tidal currents, gates, slack windows) | [openwatersio/signalk-tides](https://github.com/openwatersio/signalk-tides) — tide *height* only | **Novel.** Nobody else does tidal *currents*. We forked the right tide base and contributed upstream. |
| [weather-mcp](https://github.com/sailingnaturali/weather-mcp) (marine forecast + NDBC buoy reality-check) | [weather-mcp/weather-mcp](https://github.com/weather-mcp/weather-mcp) (generic, 17 tools); [NOAA-TidesAndCurrents-MCP](https://github.com/RyanCardin15/NOAA-TidesAndCurrents-MCP) | **NDBC reality-check is novel** — no MCP anywhere ingests NDBC observations and diffs them against the forecast. The generic ones were worth studying as tool-design baselines, though. |
| [pilotbook-mcp](https://github.com/sailingnaturali/pilotbook-mcp) (anchorage search + comfort ranking) | [itemir/signalk-console](https://github.com/itemir/signalk-console) (ActiveCaptain POI display) | **Novel.** No searchable pilot-book with conditions-aware comfort ranking exists; the closest thing is a passive POI widget. |
| [colregs-mcp](https://github.com/sailingnaturali/colregs-mcp) (nav-rules reference + compliance) | [VladimirKalachikhin/collision-detector](https://github.com/VladimirKalachikhin/collision-detector) (geometric CPA, no rule text) | **Novel.** The only other collision-reasoning attempt is pure geometry — nobody else encodes the COLREGs rule text for agents. |
| [logbook-mcp](https://github.com/sailingnaturali/logbook-mcp) (over [signalk-logbook](https://github.com/meri-imperiumi/signalk-logbook)) | **[PostgSail](https://github.com/xbgmsharp/signalk-postgsail)** + [postgsail-mcp-server](https://github.com/xbgmsharp/postgsail-mcp-server) | **Should have found PostgSail pre-build.** Complementary in the end — it's historical-DB analytics, ours is live capture — but this is the one a scan would have flagged first. |
| [vessel-knowledge-mcp](https://github.com/sailingnaturali/vessel-knowledge-mcp) (equipment spec cards, alarm explain) | [joelkoz/signalk-hour-meter](https://github.com/joelkoz/signalk-hour-meter) (engine hours off SignalK paths) | **Knowledge-cards-as-MCP is novel**; hour-meter is direct prior art for one planned sub-feature (engine-hours) — see below for why it's reference-only. |
| [signalk-ntfy-relay](https://github.com/sailingnaturali/signalk-ntfy-relay) (push notifications) | [itemir/signalk-notifications](https://github.com/itemir/signalk-notifications) (Pushover); [sbender9/signalk-push-notifications](https://github.com/sbender9/signalk-push-notifications) (SNS) | **ntfy backend is novel** — everyone else routes through Pushover or SNS. Same job, different (self-hostable, zero-account) delivery path. |
| [signalk-mcp](https://github.com/sailingnaturali/signalk-mcp) (live vessel data + alarms for agents) | VesselSense (the one serious SignalK-MCP peer, code-execution architecture); [SignalK/signalk-server#1867](https://github.com/SignalK/signalk-server/issues/1867) (native MCP endpoint — open, unassigned) | Peer exists with an opposite tool philosophy — we compared [discrete named tools vs execute-code]({% post_url 2026-06-06-signalk-mcp-named-tools-vs-execute-code-token-efficiency-voice-agent %}) at length. Upstream native MCP is still an open issue, so the space is genuinely unclaimed. |

Also on the map, outside the fleet's footprint:

- **[d3kOS](https://github.com/SkipperDon/d3kOS)** — a Raspberry Pi AI helm
  computer: offline voice, engine-diagnostics RAG over PDF manuals, bow-camera
  object detection. The manual-RAG and bow-cam pieces are ahead of anything we
  run; worth watching.
- **Windward MAI Expert** — commercial, fleet-scale "alarm → agentic
  enrichment → narrative brief." Not something a cruiser can run, but it
  independently validates the alarm-triage agent pattern.
- **Saillogger's AIS MCP** — a narrow stub today, from the same author as
  signalk-console.

## What the scan actually found

**1. We didn't wholesale rebuild — the niche really is sparse.** Four of
seven servers had *no* prior art. That surprised us: MCP servers exist for
seemingly everything, but "marine + operational + agent-facing" is nearly
empty. If you're building here, the ecosystem-scan cost is one evening and
the field is still mostly unclaimed.

**2. The one real miss was PostgSail.** An Apache-2.0 voyage database with
its own actively maintained MCP server — voyage history, trip summaries,
monitoring, maintenance notes — and we found it *after* shipping our logbook
integration. The post-hoc assessment landed on "don't adopt the stack, borrow
the tool design" (it's a whole Postgres/Timescale/Grafana tier, aimed at
dashboards; our log lives on the vessel as YAML). But that's a verdict we got
lucky on. A pre-build scan makes it a decision instead of a coin flip.

**3. Licensing is part of prior art.** `signalk-hour-meter` looked like an
adopt candidate for engine-hours — until the scan showed it dormant for
years and, critically, **unlicensed**. No license means all-rights-reserved:
you can read the pattern, you cannot ship the code. That single check
converted "adopt" into "pattern reference only" in one minute. Check the
license *before* you get attached.

**4. A name collision is not a collaboration target.** There's an active,
polished, generic `weather-mcp` org whose README states its marine data is
"not suitable for navigation" — the exact opposite of an on-boat operational
tool, and no buoy observations at all. Same name, disjoint philosophy. The
practical lesson: when your repo name is saturated (8+ unrelated
`weather-mcp`s exist), always qualify yours by org in docs and cross-refs.

**5. The people map is half the value.** The scan's most useful output
wasn't code at all — it was discovering we were *already running* several
ecosystem authors' work without having realized it: the logbook plugin we
adopted, the Victron plugin on our eval list, the radar server we assessed.
A prior-art scan doubles as a map of whose work you depend on, which is
exactly who you should be talking to, contributing back to, and crediting.

## The lesson, operationalized

The scan cost one evening of agent-assisted searching across GitHub topics,
the SignalK plugin registry, and the MCP directories. In a *sparse* niche it
still: flagged one should-have-assessed project, killed one adoption on
licensing, mapped a peer's opposite architecture, and revealed three upstream
dependencies we hadn't consciously chosen.

So it's now a checklist step, not a retrospective:

```text
New build domain?
1. Scan first: GitHub topic search + MCP directories + the
   SignalK plugin registry (appstore), BEFORE the design doc.
2. For each hit: license, last commit, maintainer posture,
   philosophy fit (operational vs informational).
3. Record the verdict per alternative — adopt / borrow the
   design / pattern-reference-only / novel, with reasons.
4. Re-run the audit when you know the ecosystem better.
   (Verdicts age: one "stalled" project on our June map
   shipped new releases within a month.)
```

Step 3 is the part that compounds: the recorded verdicts are what let us
answer "how much did we rebuild?" with a table instead of a feeling — and
they're what this post is made of.

Everything above ships from [github.com/sailingnaturali](https://github.com/sailingnaturali),
built for an all-electric sailboat's agent stack — if you're building in the
marine-MCP space, the map says there's plenty of open water.

*Related:*
[adopt vs build: the ship's logbook]({% post_url 2026-06-06-adopt-vs-build-ships-log-signalk-logbook-mcp %}) ·
[the NDBC buoy reality-check how-to]({% post_url 2026-06-06-marine-weather-mcp-buoy-ground-truth-ndbc-spec-swell-wind-waves %}) ·
[named tools vs execute-code for voice agents]({% post_url 2026-06-06-signalk-mcp-named-tools-vs-execute-code-token-efficiency-voice-agent %})
