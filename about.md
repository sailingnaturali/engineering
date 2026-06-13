---
layout: page
title: About
permalink: /about/
---

This is the developer-facing engineering blog for **Sailing Naturali**, a
premium eco-charter operation in the Pacific Northwest running aboard an
all-electric aluminium catamaran.

The boat runs on an AI ops layer — the operations are automated so the humans
can deliver the experience. Building that surfaces real, non-obvious technical
problems: Home Assistant voice routing, SignalK marine data, custom
[MCP servers](https://github.com/sailingnaturali), local LLM inference, tides,
weather, and the rules of the road. When a fix would have cost another builder
hours, it goes here.

## What you'll find

- The **broke → tried → fixed** arc, with copy-pasteable code at every step.
- Deliberately searchable — we write for the error string you just pasted into
  Google.
- The dead-ends included on purpose. The failed attempt is usually the most
  useful part.

## The stack

Open source first: [Signal K](https://signalk.org) for marine data, Home Assistant
for voice and dashboards, the
[Model Context Protocol](https://modelcontextprotocol.io) to wire agents to both,
the Claude API for reasoning, and Whisper, Piper, and Ollama for the local pieces —
on NMEA 2000, Oceanvolt electric propulsion, Victron power, and Starlink.

What nothing existing covered, we built and published — the MCP servers and SignalK
plugins under [github.com/sailingnaturali](https://github.com/sailingnaturali). The
full map, built and adopted, lives on the
[org profile](https://github.com/sailingnaturali).

The exec-facing side of the story — why an all-electric charter business, the
financials, the build — lives at
[sailingnaturali.com](https://sailingnaturali.com).

<sub>Posts here are drafted by an AI "Scribe" from finished engineering work and
reviewed by a human before publishing. AI does the operations; humans deliver
the experience.</sub>
