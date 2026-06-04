---
layout: post
title: "Your local LLM agent will confidently misdiagnose your homelab — and run the diagnostic on the wrong host to 'prove' it"
description: "A cosmetic 'Auxiliary title generation failed: Request timed out' error sent a local LLM agent on a self-diagnosis spree: it invented a Docker-on-the-HA-Green topology that didn't exist, ran docker ps on its own host to 'confirm' a crash, and misread Home Assistant's 'unknown' state as 'down'. The real cause was a 36B model saturating the inference box. Here's how agents confabulate infrastructure they can't observe, and the deterministic checks that actually catch it."
date: 2026-06-01
tags:
  - homeassistant
  - selfhosted
  - ai
  - local-llm
  - ollama
  - agents
---

Hand a local LLM agent a shell tool and ask it to diagnose your homelab, and you'll discover a failure mode that has nothing to do with hallucinated facts: the agent invents a *topology* it can't see, then runs a real diagnostic command — on the wrong host — and reads the output as proof. The command is real. The output is real. The conclusion is fiction. This is the broke → tried → fixed of an agent that "confirmed" a container crash for a container that never existed.

## Problem

The whole thing started with a single cosmetic warning line from the agent runtime (Hermes, running a local model via Ollama):

```
⚠ Auxiliary title generation failed: Request timed out.
```

That's the *session auto-titling* call — a throwaway LLM request to name the conversation in the sidebar. It is not the conversation. The chat itself was answering fine. But the agent, reasoning over its own logs, latched onto the word "timed out," decided its local conversation engine was down, and went looking for the corpse.

It produced this confident diagnosis:

```
The local conversation engine is down. Ollama runs as a Docker container on
the Home Assistant Green; the container has crashed. Confirming now.
```

Then it "confirmed" it:

```
$ docker ps --filter ancestor=ollama/ollama
CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
$
```

Empty output. The agent read that empty table as proof: *the Ollama container has crashed, that's why title generation timed out.* Case closed. Except every part of that is wrong.

## Diagnosis

Three independent errors stacked up into one confident, false story.

**1. The topology was invented.** Ollama does *not* run as a Docker container on the Home Assistant Green. It runs on a separate Mac Studio on the LAN; HA's Ollama integration points at it over the network:

```yaml
# Home Assistant Ollama integration — points at a *different host*
url: http://studio.local:11434
```

There is no `ollama/ollama` container on the HA Green, and there never was. The agent had no observation of the HA Green's Docker state — so it filled the gap with a *plausible* arrangement (everybody runs Ollama in Docker, right?) and then treated its own guess as a premise.

**2. The confirming command ran on the wrong host.** The agent's shell tool executes on the agent's own machine — the Mac Studio — not the HA Green it was reasoning about. So `docker ps` answered for the Studio (where Ollama runs as a native process, not a container), found no `ollama/ollama` container, and returned empty. The agent never noticed the host mismatch. A shell tool that silently runs *local* while the model reasons about a *remote* box doesn't just fail to help — it manufactures evidence for whatever the model already believed.

**3. `unknown` was read as `down`.** The agent also pointed at the HA entity state:

```
conversation.ollama_conversation: unknown
```

and called it confirmation the agent was offline. But in Home Assistant, [`unknown` and `unavailable` are different states with different meanings](https://www.home-assistant.io/docs/templating/states/): `unavailable` means the entity/integration can't be reached; `unknown` means it's reachable but has no value yet. For a conversation-agent entity, `unknown` almost always means *nobody has invoked it this session* — not that it crashed.

So what actually happened? The inference host was saturated. The model in play was a 36B MoE at 262K context on an M1 Ultra. A large model loading or pinned at high context [can stop answering new connections on `:11434` until it frees up](https://docs.ollama.com/faq) — which (a) made the low-priority title-generation call time out, and (b) briefly made the port look unresponsive to *new* connections. Ollama was healthy and LAN-reachable the entire time. The fix was a config change on the right host. The agent's entire investigation was a fabricated detour.

## What we tried (and why it failed)

### Attempt 1 — trust the agent's self-diagnosis

The agent said the container crashed and showed `docker ps` to back it up. The obvious next move is to restart the "crashed" container:

```bash
# On the HA Green, per the agent's diagnosis:
docker restart ollama
```

```
Error: No such container: ollama
```

No such container — because there is no container, on this host or any other. This is the tell that the diagnosis was confabulated: the remedy for the claimed problem doesn't even apply. We were chasing a phantom.

### Attempt 2 — re-run the agent's "proof" ourselves, in place

Maybe the container exists but is stopped, so it wouldn't show in `docker ps`. Check all containers, including dead ones — but run it where the agent ran it (the Studio):

```bash
# On the Mac Studio (the agent's own host)
docker ps -a --filter ancestor=ollama/ollama
```

```
CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
```

Still empty — because Ollama on the Studio is a native process, not a container. This *reproduces* the agent's evidence exactly, which is the trap: re-running a misleading command from the same wrong vantage point gives you the same misleading answer and feels like corroboration. The mistake wasn't the command. It was the host the command ran on, and that was baked in before we ever typed anything.

### Attempt 3 — believe the HA entity state

```bash
# HA Developer Tools → States
conversation.ollama_conversation = unknown
```

Read as "the conversation agent is down," this looks like a third independent confirmation. It isn't. `unknown` for a conversation agent means *un-invoked this session*. Treating it as `unavailable` turned a neutral signal into false corroboration — three "confirmations," all of them artifacts of the same un-grounded assumption.

## The fix

Stop trusting the agent's vantage point. Run one deterministic check from the host that actually matters — the HA Green, asking the real Ollama host:

```bash
# From the Home Assistant Green itself — the only test that mattered
curl -sS -o /dev/null -w "%{http_code}\n" http://studio.local:11434/api/tags
```

```
200
```

Ollama was up and reachable from HA the whole time. For completeness, confirm it's actually listening on the host where it really runs:

```bash
# On the Mac Studio — where Ollama actually runs (native process)
lsof -nP -iTCP:11434 -sTCP:LISTEN
```

```
ollama  ...  TCP *:11434 (LISTEN)
```

The real remedy was on the inference host, not the HA Green: stop a 36B/262K-context model from starving short auxiliary calls. Point title/summary generation at a small model and/or cut the big model's context:

```yaml
# Use a small, always-warm model for throwaway auxiliary calls
title_generation_model: hermes3:8b
# and/or rein in the heavy model's context so it stops pinning the host
```

One line on why it works: the auxiliary calls were never a pipeline failure — they were a small request losing a resource fight to a huge one on the same box. Give them their own lightweight model and they stop timing out, and the port stops looking dead to new connections.

## Why it matters / gotchas

The transferable lessons, none of them specific to this stack:

- **Auxiliary failure ≠ pipeline failure.** A timed-out title, summary, or embedding call says nothing about whether the primary path works. Before escalating, check whether the thing you actually care about failed. The main chat here never stopped answering.
- **Never let an agent diagnose a host it isn't running on.** The agent's shell answers for the agent's machine. If a remote box is in scope, either give the tool an explicit remote target and *label the host in every line of output*, or have the agent state "I can't observe that host from here" instead of inferring from local output. A shell that silently runs local while the model reasons about a remote box is a confabulation engine.
- **Treat agent infra topology as a hypothesis, not a finding.** "Ollama runs in Docker on the HA Green" was a guess dressed as a premise. Confirm topology with a deterministic check from the *right* vantage point before acting on it — here, one `curl` from the HA Green settled it, and nothing the agent did before that mattered.
- **Know your platform's state vocabulary.** In Home Assistant, [`unavailable` = down, `unknown` = no value yet](https://developers.home-assistant.io/docs/core/integration-quality-scale/rules/entity-unavailable/) (often just un-invoked). Conflating them turns a neutral signal into false evidence. Every platform has a pair like this; learn which is which before you let an agent reason over it.
- **Suspect inference-host saturation as a root-cause *class*.** A big model loading or sitting at high context [can block new connections on `:11434`](https://docs.ollama.com/faq) and stall short calls. If your agent's auxiliary calls start timing out, look at what's pinning the GPU/unified memory before you go hunting for a crashed service that isn't crashed.

The meta-lesson: an agent with a shell tool will always *get an answer*. Whether that answer is about the system you think it's about is a property of where the tool runs, not how smart the model is.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran — a local LLM agent (Hermes + Ollama) on a Home Assistant front-end, talking to a fleet of MCP servers for navigation, vessel systems, and the logbook. When the agent's job is to tell you what's wrong with the boat, "diagnose the right host" stops being a homelab nicety and becomes a safety property. The MCP servers behind it are open source: [github.com/sailingnaturali](https://github.com/sailingnaturali).
