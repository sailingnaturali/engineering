---
layout: post
title: "Two ways an LLM agent confabulates: inventing infrastructure it can't see, and narrating data provenance it was never told"
description: "A local-LLM agent will confidently describe which host runs what, or append '(this is live data from the real sensor)' to a reading — none of it observed. Confabulation isn't random hallucination; it's the model narrating unobservable gaps. Here's how each failure looked, the prompt fixes that backfired, and the three-layer fix: ground the real facts, don't seed tempting words, and guard in the tool layer."
date: 2026-06-21
tags:
  - ai
  - llm
  - agents
  - prompt-engineering
  - local-llm
---

Give an agent a tool that returns a number and ask it a question, and it will often answer with the number *plus* a story: which machine is running the service, whether that service is healthy, whether the reading is "live" or "from a test rig," whether the thing being measured is on or offline. None of the story came from a tool. The model made it up — confidently, in the same flat voice it uses for the parts it actually observed.

This is [confabulation, not hallucination](https://en.wikipedia.org/wiki/Hallucination_(artificial_intelligence)): the model isn't inventing something unrelated to reality, it's filling an *unobservable gap* with the most plausible continuation and stating it as fact. The distinction matters because the fix is different. You don't fix confabulation by telling the model to be more accurate; you fix it by removing the gap, or by removing the model's permission to narrate into it.

We hit two distinct flavors of this building a local-LLM agent (an 8B running the ship's-computer role on a boat). Same root cause, same three-part fix. This is what each looked like and what actually shut them down.

## Problem

### Flavor 1 — inventing infrastructure it can't observe

A cosmetic, auxiliary error scrolled past — a throwaway session-title-generation call timed out. That's a side feature; it says nothing about whether the main conversation works. But the agent picked it up as a thread to pull, and produced a diagnosis like this:

```
The local model backend is down. Ollama runs as a Docker container on the
dashboard host; that container has crashed. Confirming now.

$ docker ps --filter ancestor=ollama/ollama
(no output)

Confirmed — no Ollama container is running on the dashboard host. That's the
outage.
```

Every operational claim in there is fabricated. The model backend was healthy and reachable the whole time. Ollama wasn't a container on the dashboard host — it ran on a *different* machine entirely. And the `docker ps` it ran to "confirm" executed on its **own** host, not the host it was talking about — so the empty output was empty for an irrelevant reason, and the model read that emptiness as proof of its invented topology.

The agent had no tool that could observe the network layout. So it invented one that sounded right, then mined whatever command output it *could* get for confirmation — even output from the wrong box.

### Flavor 2 — narrating data provenance it was never told

Simpler to reproduce, and creepier. Ask for a sensor reading:

```
> how's our depth?

Depth 4.2 meters below the keel. This reading is coming from the local
test/mock rig — not from the vessel, since we're currently ashore.
```

The depth number is real (a tool returned it). Everything after the period is confabulated. "Test/mock rig," "ashore" — none of those words exist in any prompt, any config, or any field the tool returned. The model volunteered an entire provenance story for a bare number, in the same confident register as the reading itself.

If you're searching for this: the agent **makes up the data source**, appends `(this is live data from the real sensor)` or `the device is currently offline` or `this is a test value`, attributes a reading to a system nobody mentioned. That's provenance confabulation.

## Diagnosis

Both flavors are the same mechanism: **the model treats an unobservable gap as something to narrate.** Where it has no tool to see the truth, it predicts the most plausible truth and states it with the same confidence as the parts it observed. The model has no internal marker for "I observed this" vs "I generated this" — to the next-token predictor, both are just tokens to continue.

Two things made it worse, and they're worth separating:

**Smaller models do this more.** An 8B pattern-completes harder and self-censors less than a frontier model. The infra-diagnosis case ran on a larger local reasoning model and *still* did it — so it's not purely a size thing — but the bare-number-gets-a-backstory behavior was squarely an 8B habit. If you're running local models, budget for more of this, not less.

**We seeded it.** This is the part that stings. The persona prompt literally contained the words *"mock data"* — buried in an unrelated clause about how stored records handle timekeeping. The model picked that token up and amplified it into "the mock rig." **Your own prompt is training data for the next token.** A stray word you put in the context, even in a caution or an aside, is a word the model can and will run with. We handed it "mock" and it handed us back a confident sentence about a mock rig.

That reframes the whole problem. Confabulation into a gap is one thing; *amplifying a word you yourself planted* is a self-inflicted version of it. Which is exactly why the most intuitive fixes make it worse.

## What we tried (and why it failed)

### Attempt 1 — warn the model about the gap

The honest instinct: the data sometimes comes from a test rig, so *tell* the model that, so it can be careful about it.

```
# in the persona prompt
Note: sensor data may currently be sourced from a local test rig rather than
the live vessel. Keep this in mind.
```

Result — the model now announces the test rig *every time*, unprompted:

```
> how's our depth?

Depth 4.2 meters. Note that this is sourced from the local test rig rather
than the live vessel.
```

We told it to "keep in mind" a fact and it kept it in mind by *saying it out loud, as fact, constantly.* A caution in the prompt is not a private note to the model. It's text the model will surface. We'd taken a word it was occasionally confabulating and promoted it to a word it now states on every reply. Strictly worse.

### Attempt 2 — tell it not to hallucinate

```
# in the persona prompt
Do not hallucinate. Do not make up information. Be accurate and factual.
```

Too vague to bind to anything. "Don't hallucinate" gives the model no operational handle — it doesn't *experience* the confabulated provenance as a hallucination; from the inside, "this is from the test rig" is just a plausible, on-topic continuation. The instruction sailed right past the behavior and the agent kept narrating provenance and inventing topology. Generic anti-hallucination boilerplate does nothing against confident, on-distribution confabulation.

### Attempt 3 — list the right facts so it stops guessing wrong

For the infra case, we tried correcting the topology inline: tell it which host runs what so it stops inventing.

```
# in the diagnosis prompt
The model backend runs on the compute host, not the dashboard host.
```

This *reduced* the specific wrong guess but didn't fix the mechanism — the model would still run a diagnostic command on the wrong host and reverse-justify from its output, because it had no way to know *which host its own shell was answering for*. The shell tool ran local while the model reasoned about a remote box, and silently manufactured false evidence. You can correct one confabulation by hand, but the next gap is still a gap.

## The fix

Three layers, because no single one holds on a small model.

### 1. Ground the real, observable facts — so there's no gap to fill

For the infra flavor: the model invents topology because it can't see topology. So put the *true* topology in the context, and — more importantly — make tools state their own vantage point. A shell tool that runs on host A while the agent reasons about host B must say so, or the agent must be told it cannot observe B from where it sits:

```
You are running on the compute host. Any shell command you run answers for
THIS host only. You cannot observe other hosts from here. If a question is
about another machine, say "I can't observe that host from here" — do not
infer its state from local output.
```

That converts "invent a plausible answer" into "state a boundary." The gap is named instead of filled.

### 2. An explicit anti-provenance rule in the always-on persona

For the provenance flavor, the generic "don't hallucinate" failed because it wasn't specific. So name the exact behavior and forbid it — in the **always-on** persona, not a conditional skill file, because it has to apply to every query. These are the actual lines from our shared persona ([`SOUL.md`](https://github.com/sailingnaturali/naturali-agents)):

```
## Avoid
- Speculating about data provenance. Report the reading, and its SignalK path
  if asked. Do not narrate whether data is "live," from the "real vessel," a
  "test rig," a "mock," or whether the vessel is "ashore," "hauled out," or
  "underway" — you are not given that context and must not guess it.
```

And the default that backs it, so "I don't know" is the sanctioned move instead of a guess:

```
- Confabulation under uncertainty. "I don't have that" beats a plausible guess.
```

The win over Attempt 2 is specificity. "Don't hallucinate" gives the model nothing to grab. "Don't say 'live'/'mock'/'test rig'/'ashore'; report the reading and its path if asked" names the exact tokens and the exact allowed alternative. The model can act on that.

### 3. Audit the prompt for words you don't want spoken — and remove them

This is the one almost nobody does. Grep your own prompt for any term that names something you don't want stated as fact, and **take it out.** We had the literal string `mock data` in the persona (in an unrelated timekeeping clause). We reworded it out. You cannot have a rule that says "never say 'mock'" while the word "mock" sits in the context — you're seeding and forbidding the same token, and on a small model the seed wins.

The meta-rule: **don't put a word in the context you don't want amplified back at you.** Not in an instruction, not in a caution, not in an aside. If it's in the prompt, treat it as something the model might say out loud.

### 4. Belt and suspenders — guard in the tool layer

Prompt rules reduce this on an 8B; they don't eliminate it. The deterministic backstop is to have the tool return *only what should be stated*, so there's no raw provenance field for the model to narrate even if it's tempted. The reading goes out as a clean, pre-formatted value with no `source: "mock"`, no `host:`, no `is_live:` for the model to read and run with:

```jsonc
// what the tool returns — nothing to narrate into
{
  "value": 4.2,
  "display": "4.2 meters below the keel"
}
// NOT: { "value": 4.2, "source": "mock-rig", "host": "...", "is_live": false }
```

If the model never sees a provenance field, the prompt rule has far less to fight. Robustness lives in the tool; the prompt rule is the second line, not the only one.

## Why it matters / gotchas

- **Confabulation wears the same voice as truth.** The invented topology and the real reading arrive in identical confident prose. There's no in-band signal that one half was observed and the other generated — which is exactly why you can't trust an agent's infra *diagnosis* as a finding. Treat it as a hypothesis until a deterministic check from the right vantage point confirms it.

- **A caution in the prompt is a public statement, not a private note.** This is the counterintuitive one. Telling the model "this might be a test rig, be careful" doesn't make it careful — it makes it *announce the test rig*. If you wouldn't want the sentence in the output, don't put its keywords in the input.

- **Distinguish auxiliary failures from real ones before you let the agent run with them.** Half of the infra confabulation was the agent treating a cosmetic timeout (a title-generation side call) as a pipeline outage. A timed-out summary/embedding/title call is not an outage; check whether the primary path actually failed before escalating.

- **Guardrails reduce, they don't eliminate — pair the prompt with the tool layer.** On a small model, expect residual confabulation even with a clean prompt and an explicit rule. The tool returning only speakable fields is what makes it deterministic. Same theme as fixing formatting in the tool layer rather than the prompt: anything that *must* hold belongs below the model, not in instructions to it.

- **The general lesson is one sentence:** confabulation is the model narrating an unobservable gap, so the fix is to remove the gap (ground the facts), remove the permission (an explicit, specific rule), and remove the temptation (don't seed the word, and don't hand the model a field it shouldn't speak).

## Close

This came out of running a local-LLM ship's-computer agent on an all-electric charter catamaran, where a confident wrong sentence about where a depth reading "came from" is worse than no sentence at all. The persona and the MCP tool servers behind it are open source: [github.com/sailingnaturali/naturali-agents](https://github.com/sailingnaturali/naturali-agents).
