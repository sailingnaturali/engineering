---
layout: post
title: "Discrete tools vs execute_code: two ways to put your boat's SignalK on MCP, and when each wins"
description: "There were two ways to expose SignalK marine data to an AI agent over MCP: VesselSense's single execute_code tool that lets the model write JavaScript, or discrete named tools like read_sensor and battery_state. We built the second — not because it's better, but because voice-first agents on small models need reliability and a speech contract more than they need query flexibility. A real comparison, with the failure modes."
tags:
  - ai
  - mcp
  - signalk
  - voice-assistant
  - tool-use
  - llm
date: 2026-06-06
canonical: "https://engineering.sailingnaturali.com/discrete-tools-vs-execute-code-mcp-for-voice-agents/"
---

When we wanted our boat agents to read SignalK — wind, position, battery,
depth — over MCP, there was already a capable server for it:
[VesselSense/signalk-mcp-server](https://github.com/VesselSense/signalk-mcp-server)
(TypeScript, MIT). It's well built. Our prime directive says use existing
tools before building your own, and we take that seriously — our ship's log
is [someone else's plugin](https://github.com/meri-imperiumi/signalk-logbook)
for exactly that reason.

We built a separate server anyway:
[signalk-mcp](https://github.com/sailingnaturali/signalk-mcp). This post is
the honest version of why — because the two servers represent two genuinely
different answers to the same design question, and which one you want depends
entirely on what's driving it.

## The design question

How much of the query should the *model* write?

**VesselSense answers: all of it.** It exposes a single `execute_code` tool.
The agent writes JavaScript, which runs in a sandboxed V8 isolate with access
to the SignalK data model. One tool definition in the context window, unlimited
query flexibility. Want the average of three battery banks, but only if the
engine is off? Write the code. No server release needed.

**signalk-mcp answers: none of it.** It exposes discrete, named tools —
`read_sensor(path)`, `battery_state(bank)`, `depth_state()`,
`get_active_alarms()` — each with a one-argument schema and a fixed response
shape. The flexibility ceiling is whatever tools the server ships.

## Why execute_code wins with frontier models

If your agent is a frontier model, `execute_code` is hard to beat:

- **Token efficiency.** One tool definition instead of a dozen. For long
  agent sessions, tool schemas are recurring context-window rent.
- **No n+1 round trips.** A composite question ("compare house and starter
  bank voltage trends") is one code block, not four tool calls.
- **No server roadmap coupling.** The model can answer questions the server
  authors never anticipated.

A big model writes small JavaScript correctly nearly every time. The
flexibility is real and the costs are low.

## Why discrete tools win on a boat

Our target runtime is the opposite end of the spectrum: a voice assistant on
the boat, designed to run against small local models, with a text-to-speech
front-end and a sailor's attention split between the agent and the water.
Two things dominate that design, and neither is token efficiency:

**1. Reliability.** "What's my battery?" must work every time, in swell,
on the local model. A named tool with one validated argument is a much
smaller ask than writing correct JavaScript against a data model the agent
half-remembers. And the failure modes differ in kind: a wrong tool argument
fails *loudly* at the schema validator; subtly wrong JavaScript fails
*quietly* with a plausible-looking number. On a boat, the quiet failure is
the dangerous one.

**2. A speech contract.** Every signalk-mcp value carries a `display` string
the agent speaks verbatim — `"16.5 knots"`, `"48.8 North, 123.1 West"`,
spelled-out units, no symbols a TTS engine mispronounces, no radians, no
Kelvin. The server formats; the model relays. We've
[written before](/fix-llm-formatting-in-the-tool-layer-not-the-prompt/) about
why this belongs in the tool layer and not the prompt: prompt-level formatting
rules are model-dependent and leak. With `execute_code`, the model touches raw
SignalK values (SI units, decimal degrees, ISO timestamps) on every query, so
every query is a fresh chance to mispronounce the data. With discrete tools,
the raw values never reach the model at all.

That second point keeps proving itself. The same week we wrote this, we
watched a capable cloud model restyle a coordinate string three different
ways through three increasingly strict prompt instructions — and stop only
when the tool returned one pre-assembled sentence to relay. Models reformat
whatever they're allowed to reassemble. Tools that want deterministic output
must hand over finished strings.

## So which one do you want?

| | execute_code (VesselSense) | discrete tools (signalk-mcp) |
|---|---|---|
| Best driver | frontier model | small/local or voice-first model |
| Query flexibility | unlimited | fixed tool surface |
| Context cost | one tool schema | one schema per tool |
| Composite queries | one call | several calls |
| Failure mode | quiet (wrong code, plausible output) | loud (schema rejection) |
| TTS output | model formats raw values | server-formatted `display` strings |
| New question support | immediate | needs a server release |

Neither column is "better." If you're driving SignalK with a frontier model
and want maximum flexibility, use VesselSense — genuinely. If you want
simple, reliable, speakable tools for a voice-first agent, that's what
signalk-mcp is for.

The deeper takeaway isn't about boats: **tool design is model-targeting.**
The same backend deserves a different MCP surface depending on who's calling.
Token-efficient power tools for big models; validated, pre-formatted,
single-purpose tools for small ones. Pick the surface for the agent you
actually run.
