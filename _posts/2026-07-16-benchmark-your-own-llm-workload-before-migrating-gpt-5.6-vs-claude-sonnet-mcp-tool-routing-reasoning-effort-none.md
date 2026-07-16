---
layout: post
title: "Bench your own workload before you switch LLM vendors"
description: "When GPT-5.6 (Sol, Terra, Luna) shipped, we benched all three tiers against our incumbent Claude Sonnet 4.6 on the one thing our voice boat-agent needs: routing correctly across 74 MCP tools. Result: 38.5% vs 92.3% correctness on our 13-ask golden set — under the constraint that GPT-5.6 tool calling on /v1/chat/completions requires reasoning_effort 'none'. Not a capability benchmark; a narrow fit-for-workload test, plus the harness fixes (Bearer auth, reasoning_effort passthrough) a real bench surfaces."
date: 2026-07-16
tags:
  - ai
  - llm
  - mcp
  - tool-use
  - benchmarks
  - voice-assistant
---

> **TL;DR:** Before migrating our voice boat-agent off Claude Sonnet, we ran the
> new GPT-5.6 tiers through the same tool-routing benchmark the incumbent runs:
> 13 real asks, 74 MCP tool schemas, scored on whether the model calls the right
> tools. GPT-5.6 scored 38.5% vs Sonnet's 92.3% *on our workload, under our
> integration constraints* — so no migration. [Jump to the numbers](#the-numbers).
> The transferable part isn't the score, it's the method.

**What this is not — read this before the numbers.** This is *not* a model
benchmark, and it says nothing about GPT-5.6's overall quality. It is a narrow,
specific fit-for-workload test: can a candidate model, dropped into *our*
integration path (an OpenAI-compatible `/v1/chat/completions` runner, which
forces `reasoning_effort: "none"` when tools are present — more on that below),
route a voice agent's asks to the right tools across *our* 74-tool MCP surface?
GPT-5.6's full tool-calling story lives in the Responses API, which our runner
doesn't speak. The result generalizes to nothing beyond "not a drop-in swap for
this system, today." If you take a headline score away from this post, you've
misread it. Take the method.

## The temptation

Every time a new flagship model ships, the same question shows up: *should we
migrate?* The leaderboards look great. The pricing looks great. The blog posts
are glowing.

None of that measures your workload.

Our workload is a voice agent on a boat. The architecture pushes determinism
into code — spoken phrasing is templates, tool results are formatted in the
tool layer, composition happens in composed tools. The LLM's actual job is
narrow: **hear an ask, pick the right MCP tool(s), call them with workable
args.** "What's the current at Boundary Pass?" must route to
`currents.get_gate_current`, not to a generic sensor read. That's it. Peak
reasoning is not on the critical path; tool-routing correctness and latency
are.

No public leaderboard scores "routes correctly across our 74 marine MCP tool
schemas." So we built the bench once, and now every candidate model gets the
same 15-minute test before any migration conversation is allowed to continue.

## The decision rule

The swap rule is written down as code, not vibes. A candidate replaces the
incumbent only if it's faster *and* holds correctness within tolerance *and* is
stable:

```python
def compare(incumbent: Scorecard, candidate: Scorecard, eps: float = 0.05) -> Verdict:
    if candidate.error_rate > 0:
        return Verdict(False, f"candidate not session-stable "
                              f"(error_rate={candidate.error_rate:.2f})")
    if candidate.latency_p50 >= incumbent.latency_p50:
        return Verdict(False, f"candidate not faster "
                              f"(p50 {candidate.latency_p50:.2f}s vs "
                              f"incumbent {incumbent.latency_p50:.2f}s)")
    if candidate.correctness < incumbent.correctness - eps:
        return Verdict(False, f"candidate correctness below tolerance "
                              f"({candidate.correctness:.2f} < "
                              f"{incumbent.correctness:.2f} - {eps})")
    return Verdict(True, ...)
```

Note what this optimizes: **speed at a correctness bar**, not peak capability.
We *want* to be persuaded by a faster model. The voice loop has a <5 s warm-hop
target; the incumbent's p50 is over 8 s. A candidate that's 3× faster and
routes tools correctly wins the slot immediately. The bar is the incumbent's
correctness minus ε, because prose quality is deterministic downstream — the
model only has to string the right tools.

## The harness

The bench (`python -m poseidon.bench` in
[naturali-agents](https://github.com/sailingnaturali/naturali-agents)) drives a
golden set of 13 asks, each annotated with the expected tool call(s):

```json
{
  "id": "current-boundary",
  "category": "navigator",
  "prompt": "What's the current doing at Boundary Pass?",
  "expected_tools": ["mcp__currents__get_gate_current"]
},
{
  "id": "safe-to-anchor",
  "category": "navigator-multi",
  "prompt": "Is it safe to anchor here tonight given the weather and current?",
  "expected_tools": ["mcp__pilotbook__assess_anchorage"]
}
```

The incumbent runs through its production backend (the Claude Agent SDK). Any
candidate runs through a flat OpenAI-compatible runner — same asks, same 74
tool schemas exported from the production MCP server config, same
recall-based scoring (did the right tools get called; extra exploratory calls
don't penalize):

```bash
# incumbent baseline (SDK backend)
uv run python -m poseidon.bench --model claude-sonnet-4-6

# candidate (any OpenAI-compatible endpoint: hosted or local Ollama)
uv run python -m poseidon.bench --backend openai \
  --base-url https://api.openai.com/v1 \
  --model gpt-5.6-terra --reasoning-effort none \
  --baseline dev/bench-results/2026-07-12-claude-sonnet-4-6.json
```

The `--baseline` flag makes the run print the swap verdict directly. One
command, a scorecard, an answer.

## What the bench surfaced before it produced a number

The runner was originally built for local Ollama models. Pointing it at a
hosted endpoint broke twice — and both breaks are exactly the kind of
integration detail a real bench surfaces and a leaderboard never will.

**1. Hosted endpoints need auth; Ollama had let us be lazy.** First run: HTTP
401. Ollama ignores the `Authorization` header entirely, so the harness had
never sent one. The fix is small and keeps local runs working:

```python
def auth_headers() -> dict[str, str]:
    """Bearer auth for hosted OpenAI-compatible endpoints; empty for local
    (Ollama ignores auth)."""
    key = os.environ.get("OPENAI_API_KEY", "")
    return {"Authorization": f"Bearer {key}"} if key else {}
```

**2. GPT-5.6 rejects function tools on `/v1/chat/completions` unless
`reasoning_effort` is `"none"`.** With auth fixed, requests carrying our
`tools` array were rejected until we sent `reasoning_effort: "none"`. Full
reasoning *plus* tools is a Responses-API feature; on the Chat Completions
surface you pick one. So the payload builder grew a passthrough:

```python
def chat_payload(model, messages, schemas, reasoning_effort=None) -> dict:
    """reasoning_effort is passed only when set — GPT-5.6+ rejects function
    tools unless it's 'none' (full reasoning + tools needs the Responses
    API, which this runner predates)."""
    payload = {"model": model, "messages": messages, "tools": schemas,
               "tool_choice": "auto", "stream": False}
    if reasoning_effort is not None:
        payload["reasoning_effort"] = reasoning_effort
    return payload
```

That second fix matters for reading the results honestly: it means every
GPT-5.6 number below was produced **with reasoning off**, because that's the
only mode the OpenAI-compatible surface we integrate against permits with
tools. It's a real constraint of the drop-in path we'd actually deploy — the
same seam a local model or any OpenAI-compatible engine would use — but it is
a constraint, and we recorded it as such.

## The numbers

Same day, same 13-ask golden set, same live MCP stack, all three GPT-5.6 tiers
plus a fresh incumbent baseline:

| Model | Correctness | Error rate | p50 warm hop | p95 | Swap verdict (ε=0.05) |
|---|---|---|---|---|---|
| claude-sonnet-4-6 (incumbent) | **92.3%** | 0% | 8.62 s | 18.23 s | — |
| gpt-5.6-sol (reasoning none) | 38.5% | 0% | **3.40 s** | 9.64 s | SWAP=False |
| gpt-5.6-terra (reasoning none) | 38.5% | 0% | **2.32 s** | 7.35 s | SWAP=False |
| gpt-5.6-luna (reasoning none) | 46.2% | 0% | **2.79 s** | 10.99 s | SWAP=False |

Two things are true at once here, and both matter.

**Latency is excellent.** Every GPT-5.6 tier demolishes our <5 s voice-loop
target that the incumbent misses. Terra's p50 of 2.32 s is the fastest
tool-calling turn we've measured on this workload, cloud or local. If
correctness had held, this would have been an easy swap — that's what the
decision rule is *for*.

**Routing collapsed.** The failure isn't a near-miss on a couple of hard asks;
it's qualitative. With reasoning off, all three tiers reach for the generic
`mcp__signalk__read_sensor` on nearly everything. From the Terra scorecard:

```text
| ask             | expected                              | observed                    |   |
|-----------------|---------------------------------------|-----------------------------|---|
| wind-forecast   | mcp__weather__get_marine_forecast     | mcp__signalk__read_sensor   | ✗ |
| currents-nearby | mcp__currents__currents_near          | mcp__signalk__read_sensor   | ✗ |
| tide-heights    | mcp__currents__get_tide_heights       | mcp__signalk__read_sensor   | ✗ |
| anchorage-near  | mcp__pilotbook__find_anchorages_near  | mcp__signalk__read_sensor   | ✗ |
| safe-to-anchor  | mcp__pilotbook__assess_anchorage      | mcp__signalk__read_sensor   | ✗ |
```

A wind *forecast* question answered from a live sensor read. An anchorage
question answered from a sensor read. Eight of thirteen asks on Terra route to
the wrong subsystem the same way; Sol and Luna show the same shape. Direct
single-tool asks ("what's my depth") still land — it's the *routing across a
wide tool surface* that goes.

We'd seen this exact failure shape before, in small local models — the
generic-over-specific tool grab is what an 8B does under pressure. Seeing it
here says something useful and narrow: **whatever makes a model good at
picking one tool out of 74 was, on this surface and in this mode, doing that
work in the part we had to turn off.**

## The fairness caveat, again

Worth restating at the point of maximum temptation to over-read: the
candidates ran under the constraint the OpenAI-compatible surface imposes
(tools ⇒ reasoning none). GPT-5.6's designed tool-calling path — reasoning
plus tool use — lives in the Responses API, which our runner, and any
drop-in OpenAI-compatible engine seam like ours, doesn't speak. A fair
re-test requires porting the runner to the Responses API. That's real work
with no current payoff, so we recorded it as the *retest condition* instead of
doing it: if the runner grows a Responses backend, or an OpenAI-compatible
endpoint ships that allows tools with reasoning on, GPT-5.6 gets re-benched.

That's also the honest framing of the whole result: **we didn't measure what
GPT-5.6 can do; we measured what it does when dropped into our seam.** For a
migration decision, that's the measurement that matters — you migrate onto
your integration path, not onto the vendor's best-case demo path.

## Why it matters

- **The bar is yours, not the leaderboard's.** Our agent doesn't need chart-top
  reasoning; it needs to pick `get_tide_heights` over `read_sensor` at 2 a.m.
  in a voice loop. No public eval scores that. Yours scores whatever *your*
  system actually spends the model on — write that down as a golden set and a
  decision rule while nobody's pressuring you to migrate.
- **The bench is cheap once it exists.** This entire gate — three models,
  fresh baseline, scorecards, verdicts — was about 15 minutes of wall time and
  negligible API spend. The two harness fixes above were most of the effort,
  and they're paid for now.
- **A bench finds integration truth before migration finds it for you.** The
  Bearer-auth gap and the `reasoning_effort` constraint surfaced in a
  15-minute bench. The alternative was discovering them mid-migration, after
  the decision was already emotionally made.
- **Negative results are a deliverable.** The verdict lives in a dated
  scorecard and an architecture decision record. Next time a model ships, the
  conversation starts from "run the bench," not from scratch.

The harness, golden set, and swap rule are in
[naturali-agents](https://github.com/sailingnaturali/naturali-agents) —
`poseidon/bench/`. This came out of building the AI ops layer for an
all-electric charter catamaran, where the conversation engine is a pluggable
part and the tool surface is the product.

*Related:*
[Discrete MCP tools vs execute_code: when each wins]({% post_url 2026-06-06-discrete-tools-vs-execute-code-mcp-for-voice-agents %}) ·
[Fix LLM formatting in the tool layer, not the prompt]({% post_url 2026-06-05-fix-llm-formatting-in-the-tool-layer-not-the-prompt %})
