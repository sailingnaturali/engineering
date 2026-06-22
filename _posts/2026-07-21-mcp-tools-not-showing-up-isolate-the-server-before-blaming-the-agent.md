---
layout: post
title: "MCP tools not showing up? Isolate the server before blaming the agent — and don't trust the agent's self-report"
description: "When an LLM agent says an MCP tool isn't available or 'only one server is connected,' the instinct is to restart the runtime or blame the MCP server. But the agent's self-report about its own toolset is unreliable, and a malformed test invocation fakes an 'MCP unreachable' symptom. The fix: isolate the layer — test the server standalone with mcp test / MCP Inspector, then reproduce with the exact production invocation."
date: 2026-07-21
tags:
  - mcp
  - ai
  - agents
  - debugging
  - selfhosted
---

You add a new MCP server, or a new tool to an existing one. You ask the agent to use it and it says the tool isn't available — or worse, it confidently reports that "only the HTTP server is connected" and the new stdio servers aren't live. The instinct is to blame the MCP server or bounce the runtime. Resist it. The agent's narration about its own toolset is not ground truth, and a malformed test invocation will happily manufacture a fake "MCP unreachable" symptom. Here's the broke → tried → fixed of a debugging session that burned time on exactly this.

## Problem

We'd just added a second stdio MCP server and a new tool. To smoke-test it, we hand-typed a quick probe at the agent runtime and asked it to use the new capability. The agent came back with this:

```
Those tools aren't in my live toolset right now — only the
Home Assistant (HTTP/SSE) server is connected. I'll read the
files directly instead.
```

It then shelled out to read files off disk to answer the question — being resourceful, which made it *look* like the tools genuinely weren't wired up. Two new stdio servers, both apparently invisible to the session, while the one HTTP/SSE server was fine. That sure reads like the stdio MCP servers aren't connecting.

That self-report is the trap. Treating "the agent says the tools aren't available" as a diagnosis — instead of a symptom — is what sent us down the wrong path.

## Diagnosis

There are two failure modes here and they look identical from the agent's chair:

1. **The MCP server actually isn't connecting** (bad command path, crash on startup, transport mismatch).
2. **The session never loaded the toolset**, because the way you invoked the agent doesn't load tools the way the production path does — wrong flags, wrong profile/skill selector, a different transport. The server is fine; your *probe* is malformed.

The agent can't tell these apart for you, and it will narrate either one as "tools not available." Worse, an LLM describing its own capabilities is itself a confabulation risk — it pattern-completes a plausible story ("only the HTTP server is live") around the fact that some tools didn't show up. That story is not evidence about server health.

So the discipline is: **don't ask the agent whether the server is up. Ask the server.** Isolate the layer before you touch anything.

## What we tried (and why it failed)

### Dead-end 1 — trusted the agent's "tools unavailable"

We took the self-report at face value. The agent said the stdio servers weren't connected, so we assumed they weren't connected. This is the root mistake every later dead-end inherits from — we let the agent's narration stand in for a connectivity check. It is not one.

### Dead-end 2 — restarted the long-running gateway daemon

"Tools didn't load? Refresh them — restart the runtime." So we bounced the long-running agent gateway daemon, the shape of which is:

```bash
# generic shape — restart the long-running agent runtime/gateway
<runtime> gateway restart
```

Then re-ran the same probe. No change:

```
Still only the Home Assistant server is connected — the other
tools aren't in my toolset.
```

Restarting a daemon to "refresh tools" is a guess, not a diagnosis. If the server were genuinely stale you'd want evidence of that *first*. We had none — we were rebooting on a hunch, and the hunch was wrong. (It also cost real time: a gateway restart drops every in-flight session.)

### Dead-end 3 — re-probed ad-hoc, still "unavailable"

We re-ran the hand-typed probe a few more times, tweaking the wording, still getting "tools not available." At this point it looks airtight: server's been restarted, agent still can't see the tools, therefore the server must be broken. Every signal pointed at the MCP server — and every signal was coming through the same malformed probe, so they were all the same false negative wearing different hats.

## The fix

Stop reasoning through the agent. **Isolate the layer**, then reproduce the *exact* production invocation.

### Step 1 — test the MCP server standalone

Spawn the server fresh, outside any agent session, and ask it to enumerate its tools. Most runtimes ship a connectivity check that does exactly this; the vendor-neutral tool is the [MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector).

If your runtime has a built-in check (generic shape — it spawns the server fresh, bypassing the session):

```bash
<runtime> mcp test <server>
```

Or talk to the server directly with the MCP Inspector — no runtime involved at all. The CLI mode is perfect for a connectivity assertion:

```bash
# list the tools a stdio server actually exposes, runtime out of the picture
npx @modelcontextprotocol/inspector --cli \
  <your-server-launch-command> --method tools/list
```

(`npx @modelcontextprotocol/inspector` with no `--cli` opens the browser UI at `http://localhost:6274` — connect, open the **Tools** tab, click **List Tools**.)

The output settles it immediately:

```
Connected.
server: signalk          → 7 tools discovered: read_sensor, battery_state,
                            get_route, get_active_alarms, ...
server: vessel_knowledge → 4 tools discovered: find_equipment, get_equipment, ...
```

Both servers connect and enumerate every tool. **The servers were fine the entire time** — through all three dead-ends. That one command would have saved the gateway restart and every ad-hoc re-probe.

### Step 2 — reproduce with the exact production invocation

If the server lists its tools standalone, the bug (if any) is in *how the session loads them*, not the server. So stop hand-typing variants and run the agent the way production runs it — same skill/profile selector, same flags, same transport.

Our production path (a voice/MQTT bridge) launches the agent in oneshot mode with a **namespaced skill selector** and the query passed via the query flag. The malformed probe had used a bare, non-namespaced selector and the wrong flag — which loads a different toolset (or none of the stdio toolsets). The shape that matters:

```bash
# WRONG — ad-hoc probe: bare/non-namespaced selector, wrong flag.
# Loads a different profile; stdio toolsets never attach.
<runtime> chat -m <model> -z "use the new tool"

# RIGHT — the exact production invocation: namespaced skill selector
# (profile/<skill>) + the real query flag, oneshot.
<runtime> chat -Q -s profile/<skill> -q "use the new tool"
```

Run the right one and the agent calls the tools on the first try — no restart, no file-reading workaround:

```
[tool] get_active_alarms → none active
[tool] find_equipment("Bellmarine") → bellmarine-ddw-10
... rated temperature zones: ...
```

The fix was a one-line change to the invocation. The server never moved.

**The one rule that would have short-circuited all of it:** don't restart a daemon to "refresh tools" before the server is *proven* stale. Prove it with a standalone `mcp test` / Inspector run first.

## Why it matters / gotchas

- **The agent's self-report about its own toolset is not ground truth.** An LLM narrating "only X is connected" is pattern-completing a story around missing tools, not reading a connection table. Treat it as a symptom to investigate, never as a diagnosis.
- **A malformed probe fakes "MCP unreachable."** Wrong flags, a non-namespaced skill/profile selector, or a different transport will load none of the tools you expect — and produce the *exact* symptom of a dead server. If you debug through an ad-hoc invocation, you can chase a server that was never broken.
- **stdio vs SSE/HTTP transports attach differently.** It's common to see the HTTP/SSE server present while stdio servers are absent in a session — that asymmetry usually means the session/launch path, not the stdio servers. (See the [Cursor forum](https://forum.cursor.com/t/mcp-server-connected-green-dot-and-tools-discovered-in-logs-but-0-tools-in-ui-and-agent/160620) threads where a server is "connected, tools discovered in logs" but shows 0 tools to the agent — same shape.)
- **Restarting the runtime is a guess, not a diagnosis.** It feels productive and occasionally papers over the real issue, which is worse — it teaches you the wrong fix. Isolate first; the standalone server check is two commands and removes an entire branch of the search tree.
- **This applies to any MCP host** — Claude Desktop, Cursor, IDE integrations, custom agents. The Inspector talks to your server with zero host involved, which is precisely why it's the right first probe: it can't be fooled by the host's session quirks.

The order is the whole lesson: **server (standalone) → invocation (exact production form) → only then the runtime.** Don't bounce the daemon until the first two are ruled out.

## Close

This came out of wiring MCP servers into a ship's-computer agent for an all-electric charter catamaran — SignalK, vessel-knowledge, and tide/weather tools behind a local LLM. When the agent said it couldn't see them, the servers had been fine all along; the probe was wrong. The MCP servers behind it are open source: [github.com/sailingnaturali/signalk-mcp](https://github.com/sailingnaturali/signalk-mcp).
