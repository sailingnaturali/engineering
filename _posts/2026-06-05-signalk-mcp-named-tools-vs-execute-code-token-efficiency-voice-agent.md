---
layout: post
title: "Named MCP tools vs a single execute_code tool: why we kept discrete SignalK tools over a 96% token saving"
description: "VesselSense's signalk-mcp-server exposes one execute_code tool running agent-written JavaScript in a V8 isolate, claiming a 90–96% token reduction over named MCP tools. For a frontier model that's a real win. For our voice-first agent on a small local model it doesn't bind — a named tool with one argument beats asking an 8B to write correct JavaScript for 'what's my battery?'. Here's the adopt-vs-keep evaluation, the speech-contract and circuit-breaker reasons code execution fails for this agent, and a decision framework other MCP authors can reuse."
tags:
  - mcp
  - signalk
  - ai
  - voice-assistant
  - llm
  - tool-use
  - marine
date: 2026-06-05
canonical: "https://engineering.sailingnaturali.com/signalk-mcp-named-tools-vs-execute-code-token-efficiency-voice-agent/"
---

The boat-agent stack here runs on a prime directive: if there's something usable out there, improve it; build our own only as a last resort. So when we needed a SignalK MCP server, the honest first move wasn't to write one — it was to evaluate the one that already exists.

[VesselSense/signalk-mcp-server](https://github.com/VesselSense/signalk-mcp-server) (TypeScript, MIT) is good work. It exposes SignalK to an agent through a single `execute_code` tool: the model writes JavaScript, the server runs it in a sandboxed V8 isolate (`isolated-vm`), and only the result comes back. Its README claims a **90–96% token reduction** versus traditional named MCP tools — 2,000 tokens down to 120 for a vessel-state query, 13,000 down to 300 for a multi-call workflow. Those numbers are plausible, and they line up with the broader industry result that [code execution beats tool-calling on token efficiency](https://www.anthropic.com/engineering/code-execution-with-mcp) for complex multi-step work.

We read it, ran the numbers against our own agent, and **kept our discrete-named-tool [`signalk-mcp`](https://github.com/sailingnaturali/signalk-mcp) anyway** — then harvested three of VesselSense's ideas into our roadmap. This post is that evaluation: the two philosophies, why the obvious-sounding win doesn't bind for a voice-first agent, and a decision framework you can reuse before you adopt-or-build your own MCP server.

This is a design-reasoning post, not a debugging saga, but it maps to the same arc: a question, the dead-end that looks like an obvious yes, and the call that actually held.

## The question

Two SignalK MCP servers, two genuinely different designs:

```text
VesselSense/signalk-mcp-server      sailingnaturali/signalk-mcp
─────────────────────────────       ───────────────────────────
one tool: execute_code              discrete named tools:
  → agent writes JavaScript           read_sensor(path)
  → runs in a V8 isolate              battery_state(bank)
  → queries SignalK, returns          depth_state()
    only the result                   get_route()
                                      get_local_time()
TypeScript / Node + isolated-vm       list_paths(prefix)
claims 90–96% fewer tokens            get_active_alarms()
                                    Python, end-to-end
```

The adopt-vs-keep question: **does the token-efficiency win bind for our agent?** If it does, adopting beats maintaining a second server. If it doesn't, the directive doesn't compel adoption — it compels building the right thing for the target.

The target matters more than anything else here. Our design anchor is a **voice-first agent on a small local model** — Hermes 3 8B driving a text-to-speech front end on a boat. Not a frontier model in a chat window. That single fact decides the whole evaluation.

## Two valid philosophies, different targets

`execute_code` is clever, and the token math is real. When an agent needs to fetch every AIS target, filter to the close ones, sort by CPA, and format a summary, the named-tool pattern pays the full input+output token cost of every intermediate call — the model emits a structured call, the whole result flows back into context, repeat. Code execution collapses that into one script and one aggregated result. On a frontier model doing complex, multi-step marine queries, the 90–96% claim is believable.

But the saving is *paid for in one currency: the agent must reliably write correct code.* That's a cheap price for a frontier model and an expensive one for an 8B. The capability gap here is not subtle. From the field:

> Small models like llama3.2:3b and llama3.1:8b support tool calling specs but fail inconsistently in practice, especially on sequential or multi-entity commands… Tool calling is the biggest capability gap between local and cloud models — the plumbing exists but model reliability doesn't yet.

If a small model is shaky at emitting a *structured tool call*, asking it to emit *correct JavaScript* is strictly harder. `execute_code` doesn't reduce the model's burden for our agent — it raises it. The token budget was never our binding constraint; reliability is.

So the comparison isn't "which design is better." It's:

- **Frontier model, complex queries, token budget is the constraint** → `execute_code` wins. Adopt VesselSense.
- **Small local model, voice front end, reliability is the constraint** → discrete named tools win. A named tool with one argument — `battery_state("house")` — is the most robust thing you can hand an 8B. It cannot get the JavaScript wrong because there is no JavaScript.

Both are correct. They're tuned for different agents.

## Why the token win doesn't bind #1: the speech contract

Here's the part the token comparison silently drops. Our tools don't return raw SignalK — every value carries a TTS-safe `display` string the agent can speak verbatim. SignalK stores everything in SI units and terse codes; a TTS engine mispronounces all of it. Our [response contract](https://github.com/sailingnaturali/signalk-mcp/blob/main/SPEC.md) makes the spoken form a first-class field:

```json
{
  "path": "environment.wind.speedApparent",
  "value": 8.5,
  "display": "16.5 knots",
  "unit": "knots",
  "timestamp": "2026-05-18T00:00:00Z"
}
```

```json
{
  "bank": "house",
  "soc_fraction": 0.68,
  "voltage": 12.84,
  "current": -8.2,
  "display": "68 percent, 12.8 volts, 8.2 amps discharging",
  "timestamp": "2026-05-14T18:00:00Z"
}
```

The rules behind that `display`: spelled-out units (`"knots"`, never `"kn"`), spelled-out compass points (`"North-East"`, never `"NE"`), cardinal-name lat/lon, no `°T` suffix a TTS engine reads as letters, no ISO timestamp narrated digit by digit. Position is the instructive case — the raw `{latitude, longitude}` dict stays in `value` for programmatic use, but the agent speaks `display`, never the raw pair.

`execute_code` returns whatever the agent's script returns — raw SignalK. That pushes all of this formatting onto the agent, which is **exactly the layer that fails on a small model.** We've written before about why [formatting belongs in the tool layer, not the prompt](https://engineering.sailingnaturali.com/fix-llm-formatting-in-the-tool-layer-not-the-prompt/): a prompt rule is advisory and leaks; the tool response is deterministic. `execute_code` is the maximal version of pushing formatting onto the model — it doesn't just leak the contract, it has no place to put one. For a voice-first agent that's disqualifying, and no token saving buys it back.

## Why the token win doesn't bind #2: 404-as-null and the circuit breaker

The second structural reason is error handling. A SignalK **404 is not an error** in our client — it means the vessel doesn't publish that path (no such sensor, or a guessed path). The client returns a clean null instead of raising:

```python
# read_sensor on a path the vessel doesn't publish
{ "path": "navigation.headingTrue", "value": None, "display": None,
  "unit": None, "timestamp": None }   # not an exception
```

This is deliberate, and it's a small-model lesson. Agent runtimes commonly run a **per-tool circuit breaker** — ours (Hermes) trips after 3 consecutive same-tool failures. A small model fanning out across guessed paths on an unfamiliar vessel — `headingTrue`, `headingMagnetic`, `courseOverGroundTrue` — on a boat with no compass would generate a burst of 404s, each counted as a tool failure. That trips the breaker and blocks the *valid* reads queued behind it. Returning a clean null keeps a missing path a *successful* call, so the breaker never trips on absence.

Under `execute_code`, a missing path is whatever the SignalK client throws inside the isolate, and the agent has to catch and interpret it in code it wrote — on a model that's already at the edge of writing correct code. The named-tool design makes "this sensor doesn't exist" a normal, non-fatal result by construction. That's a reusable lesson for any MCP author building for small models: **decide what your tool does on absence, and make absence a success, not a fault.**

## The coverage audit: receipts, not vibes

A "prefer adopting" directive still demands a coverage audit — does the existing tool actually do the job, or does it leave the work to the agent? We diffed feature by feature.

**Active alarms.** VesselSense's `getActiveAlarms()` returns alarms with their state and leaves filtering and sorting to client-side code in the isolate — its own example filters with `a.state === "alarm" || a.state === "emergency"` *in agent-written JS.* Normal-state notifications stay in the result; there's no severity ordering. Ours does that work in the tool, so the agent never writes a filter:

```python
# signalk-mcp: get_active_alarms does the filtering + ordering in-tool
_ALARM_SEVERITY = {"emergency": 0, "alarm": 1, "warn": 2, "alert": 3}
_INACTIVE_STATES = {"normal", "nominal"}

# normal/nominal dropped; rows sorted worst-severity-first
rows.sort(key=lambda r: _ALARM_SEVERITY.get(r["state"], 99))
```

It also strips the `notifications.` prefix off each path so the result feeds straight into our downstream alarm-explanation tooling. Worst-first, normal filtered out, paths cleaned — no JavaScript required.

**Missing tools.** VesselSense's `getVesselState` dumps the SignalK tree and lets the agent dig. We have no equivalent dump tool — instead we ship purpose-built ones the dump would otherwise require the agent to assemble: `battery_state`, `depth_state` (under-keel clearance first, so the agent answers "how close are we to running aground?" without draft math), `get_route`, `get_local_time` (GPS-aware timezone). Each returns the speakable, contract-compliant answer directly.

The pattern across the audit: VesselSense pushes the last mile of work — filter, sort, format, interpret — into agent-written code, which is exactly the work a small model is worst at. That's not a flaw in VesselSense; it's the correct division of labor *for a frontier model.* It's the wrong division for ours.

## The maturity audit (still matters under "prefer adopting")

Adopting code means inheriting its maintenance. The public signals on the upstream repo, at evaluation time:

```text
last push      2025-11-26   (6+ months dormant)
stars          8
MCP SDK        @modelcontextprotocol/sdk pinned ^0.5.0  (two majors behind)
license        MIT in package.json; no LICENSE file in the repo tree
runtime        Node + native isolated-vm  (our stack is Python end to end)
```

None of these is damning on its own. Together they say: adopting means taking on a dormant codebase, in a second language runtime, with a native sandbox dependency (`isolated-vm`), pinned to an MCP SDK two majors back — to gain a token efficiency our agent doesn't spend. The maintenance cost is real and the benefit doesn't land. That's the directive *not* compelling adoption, on the merits.

## The decision framework (reuse this)

Strip out the marine specifics and this is a general adopt-vs-build checklist for an MCP server:

1. **Name the target agent first.** Frontier model or small/local? Chat or voice/TTS? The target decides which currency you're optimizing — tokens or reliability. Most disagreements about MCP design are actually disagreements about the target.
2. **Identify the binding constraint.** Is your token budget the wall, or is model reliability the wall? `execute_code` trades reliability for tokens. Only adopt it if tokens are the wall.
3. **Check who does the last mile.** Does the existing tool filter/sort/format/interpret, or hand that to agent-written code? For a small model, every line of last-mile code you push to the agent is a failure mode.
4. **Check the output contract.** If output is consumed by something with formatting needs (TTS, a strict downstream parser), a raw-data tool externalizes that contract onto the model. Named tools can bake it in.
5. **Decide what absence means.** Make "the thing isn't there" a successful result, not an exception — especially behind a circuit breaker, especially for a model that guesses paths.
6. **Run the maturity audit anyway.** Dormancy, pinned-back SDKs, a second runtime, native deps. Adopting is inheriting.
7. **Steelman, then harvest.** If you build your own, still mine the alternative for ideas. A "no" on the architecture isn't a "no" on every idea in it.

## The honest steelman, and what we harvested

We didn't dismiss VesselSense — we mined it. Three ideas went straight onto our roadmap from reading their server:

- **`get_active_alarms`** — shipped (v0.5.0). Active notifications, worst-severity-first, normal filtered out, paths prefix-stripped for downstream tooling.
- **`list_paths`** — shipped (v0.3.0). Path discovery so the agent can explore an unfamiliar SignalK tree without guessing — and without tripping the 404 circuit breaker.
- **AIS targets** — open on the roadmap, with the same speech contract (`"cargo vessel, 1.2 nautical miles, bearing North-East"`).

And `execute_code` stays on the watch-list. The day we add a **cloud-reasoning layer** — a frontier model doing complex multi-step marine analysis where the token budget genuinely is the wall — code execution is the right tool and we'll reach for it. The evaluation isn't "named tools are better." It's "named tools are better *for this agent*, and here's exactly when that flips."

If you're driving SignalK with a frontier model and want maximum query flexibility, VesselSense is likely the better choice — it's well-built and worth your time. If you want simple, reliable, speakable tools for a local or voice-first agent, that's the niche our server fills.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran, where the agent runs on a small local model behind a Home Assistant voice front end, and "what's our battery?" has to come back as something a human can hear — reliably, every time, on an 8B. The server is open source, and so is the comparison baked into its README: [github.com/sailingnaturali/signalk-mcp](https://github.com/sailingnaturali/signalk-mcp). Go read VesselSense too — different target, good work.
