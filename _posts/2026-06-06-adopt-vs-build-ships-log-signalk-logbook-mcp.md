---
layout: post
title: "We deleted our working logbook: an adopt-vs-build audit of the SignalK logbook ecosystem"
description: "Our logbook-mcp had a working SQLite store, tests, and a voice agent writing to it. We deleted the storage layer anyway, after auditing meri-imperiumi/signalk-logbook, Saillogger, and postgsail. How we ran the adopt-vs-build decision, why the ship's log belongs on the ship, and the four undocumented integration quirks we hit wiring an MCP server to someone else's plugin — bare 201s, a mandatory 'optional' field, cookie-based author attribution, and an admin-only route gate."
tags:
  - ai
  - mcp
  - signalk
  - open-source
  - architecture
  - voice-assistant
date: 2026-06-06
canonical: "https://engineering.sailingnaturali.com/adopt-vs-build-ships-log-signalk-logbook-mcp/"
---

Our boat agents log moments by voice: "log this moment" → an entry with
position, time, and conditions. The first version of
[logbook-mcp](https://github.com/sailingnaturali/logbook-mcp) backed that
with SQLite on the agent machine. It worked. It had tests. It shipped.

Then we audited it against the SignalK logbook ecosystem and deleted the
entire storage layer.

## The audit

Our prime directive is *use or improve existing tools before building our
own*. Applied honestly, that means auditing your own working code against
the ecosystem — not just once at design time, but again when you learn the
ecosystem better. Three candidates:

**[meri-imperiumi/signalk-logbook](https://github.com/meri-imperiumi/signalk-logbook)**
— a semi-automatic electronic logbook that runs *on* the SignalK server.
Per-day YAML files, a REST API with an OpenAPI spec, a webapp in the SignalK
admin UI, and semi-automatic entries (hourly while underway, trip start/end).
The killer feature: `POST /logs` takes just the entry text, and the plugin
snapshots position, heading, speed, wind, and barometer from the live bus
server-side.

**Saillogger** — polished automatic trip capture, but your log lives in
their cloud. Wrong shape for a local-first agent that needs to read and
write programmatically.

**[postgsail](https://github.com/xbgmsharp/signalk-postgsail)** — a
self-hosted Postgres + PostgREST + Grafana stack. Powerful trip analytics,
but a whole infrastructure tier to operate, aimed at dashboards rather than
agent-written narrative entries.

**Keep ours** — full control, no network dependency, no third-party risk.
But we'd be rebuilding, worse, what already exists: no UI, no auto-entries,
no enrichment — and the log would die with the laptop instead of living on
the boat.

## The deciding argument

A ship's log belongs to the ship. Storing it in SQLite on the agent machine
was always slightly wrong; we just hadn't said it out loud. signalk-logbook
puts the entries on the vessel's own server as human-readable YAML — files
that remain trivially parseable decades from now even if every tool in this
post is abandoned.

That reframing also clarified what was actually *ours*: not entry storage,
but the agent-facing tool surface and (on the roadmap) USCG/Transport Canada
sea-time accounting — which nothing in the ecosystem does. So logbook-mcp
became ~200 lines of stateless glue: `mark_moment` and `read_entries` over
the plugin's REST API, with sea-service form export later *derived from*
the plugin's entries instead of kept in a parallel store. One source of
truth; the only code we maintain is the genuinely novel part.

## What adoption actually cost: four undocumented quirks

Adopting someone else's plugin is not free. The OpenAPI spec got us 80% of
the way; live integration against the real server found the rest:

1. **`POST /logs` returns a bare `201` with no body.** You don't get the
   created entry back — so confirming "what did I just write?" means
   re-fetching the day and taking the newest entry (with a previous-UTC-day
   fallback for midnight races).
2. **The "optional" `ago` field is mandatory in practice.** The spec marks
   it optional; the code calls `buffer.get(req.body.ago)` whenever its
   15-minute state buffer is non-empty, and `buffer.get(undefined)` throws.
   Send `ago: 0` always.
3. **Author attribution reads a cookie, not the Authorization header.** The
   plugin derives the entry author from `parseJwt(req.cookies.JAUTHENTICATION)`.
   Our client sends the token both ways: header for the server's auth gate,
   cookie for the plugin.
4. **All `/plugins/*` REST routes are admin-gated.** signalk-server's
   `adminAuthenticationMiddleware` guards every plugin route — device access
   tokens and read/write user tokens get 401 no matter what permissions you
   grant them. The agent's token must belong to an admin user. We verified
   this in the server source after two very confusing rounds of token
   provisioning.

None of these are complaints — they're the normal cost of integrating with
real software, and they're all documented now (in our
[SPEC](https://github.com/sailingnaturali/logbook-mcp/blob/main/SPEC.md) and
in this post, which is the writeup we wish we'd found). The total was still
a fraction of what maintaining our own store, schema migrations, UI, and
auto-entry pipeline would cost.

## Where the line actually is

The audit's useful output wasn't "adopt" — it was a cleaner boundary:

- **Theirs:** entry storage, enrichment, semi-automatic entries, the
  curation UI. Commodity for us; their core competence.
- **Ours:** the agent tool surface (validated schemas, TTS-safe
  [`display` strings](/fix-llm-formatting-in-the-tool-layer-not-the-prompt/),
  honest error states that never claim an unrecorded moment was logged),
  and the sea-time/licensing layer nothing else provides.

If you're holding working code you built before you knew the ecosystem,
the audit is still worth running. The sunk cost is real but small; ours
was one evening, and we traded a database for two hundred lines of glue
and a log that lives where it should — on the boat.
