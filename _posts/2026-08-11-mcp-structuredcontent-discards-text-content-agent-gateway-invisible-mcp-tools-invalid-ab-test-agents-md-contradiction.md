---
layout: post
title: "The A/B that measured nothing: three ways my agent experiment was invalid"
description: "I ran an A/B on MCP tool output shape — rendered sentence vs raw JSON — and it was invalid three separate times. The tools were never called (tools.profile minimal plus a tools.alsoAllow list missing bundle-mcp leaves MCP tools connected but filtered out); OpenClaw discards a tool's text content blocks when structuredContent is present, so both arms were byte-identical; and when it finally measured, sentence-first scored 1/5 against 3/5 for the plain JSON dump. The real lever was a contradicting paragraph in AGENTS.md, which took verbatim adherence to 6/6."
date: 2026-08-11
tags:
  - mcp
  - ai
  - llm
  - agents
  - openclaw
  - tool-use
  - benchmarking
  - signalk
  - selfhosted
---

> I set out to test whether an MCP tool should return a rendered sentence or raw SI numbers. The experiment was invalid three times, for three unrelated reasons: the tools had never been called (a gateway tool-policy gap), the two arms were byte-identical at the model (the gateway drops a tool's text `content` when `structuredContent` is present), and once it genuinely measured, the new shape *lost*. What actually fixed the behaviour was deleting a stale paragraph in the workspace instructions that told the model to do the opposite. [Jump to the fix](#the-fix).

![Verbatim adherence to the MCP tool's rendered display string went from an unmeasurable zero, through 1 of 5 for the sentence-first payload and 3 of 5 for the plain JSON dump, to 6 of 6 once a contradicting instruction was removed from the agent's workspace file.](/assets/img/mcp-structuredcontent-discards-text-content-agent-gateway-invisible-mcp-tools-invalid-ab-test-agents-md-contradiction/adherence-by-arm.svg)

Two months ago I published a post here with a confident thesis:

> **Move the formatting into the tool response.** […] a prompt rule isn't a fix, it's a suggestion the model is free to ignore the moment the raw value is still in front of it. You can't reliably instruct the model *not* to reformat data it can plainly read. The only reliable lever is the data itself.
>
> — [Fix LLM formatting in the tool layer, not the prompt]({% post_url 2026-06-05-fix-llm-formatting-in-the-tool-layer-not-the-prompt %}), 2026-06-05

I still think that's mostly right. But when I finally tried to *measure* it — on a second agent runtime, with a different model — the experiment fell over three times before it produced a single valid number, and when it did produce one, the number pointed the other way. This is the write-up of the three invalidities, because each one is a trap you can hit on your own stack, and the second one is a genuine gotcha for anyone writing MCP servers.

## Problem

The stack: a set of MCP servers over a boat's [SignalK](https://signalk.org) data, driving a voice-and-chat agent. Following the June post, every tool returns a pre-rendered `display` string next to the raw SI fields:

```json
{
  "bank": "house",
  "soc_fraction": 0.65,
  "voltage": 12.39,
  "current": -2.95,
  "display": "65 percent, 12.4 volts, 3.0 amps discharging",
  "timestamp": "2026-08-10T04:00:00Z"
}
```

The agent's persona file carries a verbatim carve-out — quote the `display` string, don't re-render from the raw fields. Asked "depth and house battery?", the agent answered:

```text
65% SOC, 12.39 V, -2.95 A
```

Raw SI, units abbreviated the way a datasheet does and a person doesn't, and a negative amperage — which the persona explicitly forbids, because "minus two point nine five amps" is not how you tell someone the battery is discharging. One run even helpfully *explained* the minus sign.

So: `display` exists, the rule exists, and the model ignores both. Reproduced on two models — a small fast open-weights one and a large cloud one. Asked to quote the rules back, both reproduced them verbatim, then broke them in the next sentence.

## Diagnosis

My hypothesis, straight out of the June post: `display` is losing an attention contest. It sits *below* the raw fields in the JSON dump, so a model reading top-down meets `soc_fraction` first, decides it knows what a 0–1 fraction is, and renders from that. Fix the shape — put the sentence first, or in its own content block — and the failure mode disappears.

That hypothesis was testable. What I didn't check was whether anything in the chain between the tool and the model would let me test it. Three things wouldn't:

![Three separate breaks between an MCP tool and the model: the gateway tool policy filtered the MCP tools out entirely, the gateway result formatter dropped the tool's text content in favour of structuredContent, and the workspace instructions file told the model to convert SI units, contradicting the persona rule that said to quote the rendered string.](/assets/img/mcp-structuredcontent-discards-text-content-agent-gateway-invisible-mcp-tools-invalid-ab-test-agents-md-contradiction/where-the-ab-broke.svg)

## What I tried (and why it failed)

### Attempt 1 — enforce it harder in the prompt

The first move was the one the June post says not to make, on the theory that this particular rule is about *quoting a string I already hold*, which that post explicitly carves out as a legitimate prompt instruction. So I ported the carve-out into the gateway's persona file:

```text
When a tool returns a `display` string, quote it verbatim.
Never re-render the reading from the raw SI fields beside it.
```

Deployed, loaded, in context — the agent could recite it. It then ignored it, on both models, across two wordings.

Conclusion at the time: prompt-level enforcement of this carve-out does not hold, therefore the structural fix in the tool layer is required. **That conclusion was worthless.** Hold that thought.

### Attempt 2 — return the sentence as `content`, the numbers as `structuredContent`

MCP lets a tool return both an unstructured `content` array and a structured `structuredContent` object. That looked perfect: make the text content *be* the answer, and let the numbers ride in the structured half where threshold reasoning can still reach them deliberately.

In the Python MCP SDK that's a tuple return:

```python
@server.call_tool()
async def _call_tool(
    name: str, args: dict | None
) -> list[types.TextContent] | tuple[list[types.TextContent], dict]:
    ...
    # PILOT, depth_state only. `display` sits BELOW the raw SI fields in the
    # JSON dump, so a model reading top-down meets `below_keel_m` first and
    # re-renders from it. Make the rendered sentence the answer instead, and
    # put the numbers in structuredContent — still there for threshold
    # reasoning, but one deliberate reach away.
    if name == "depth_state" and isinstance(result, dict) and result.get("display"):
        return [types.TextContent(type="text", text=result["display"])], result

    return [types.TextContent(type="text", text=json.dumps(result, indent=2))]
```

Deliberately one tool only. The other six kept the old shape, so a single "depth and battery" ask A/B'd both shapes against each other in one reply, on one model, in one turn. Clean design. Five trials per arm. The new shape looked better.

It was measuring nothing. **The gateway renders `structuredContent` and discards the tool's text `content` blocks.** The sentence never reached the model at all; what arrived was the same JSON object the old shape sent, so both arms were byte-identical from the model's side.

![The MCP tool returned a rendered sentence as a text content block alongside structuredContent, but the gateway forwarded only the structuredContent, so the model received the same JSON as the arm the pilot was supposed to beat.](/assets/img/mcp-structuredcontent-discards-text-content-agent-gateway-invisible-mcp-tools-invalid-ab-test-agents-md-contradiction/identical-arms.svg)

This one is worth naming precisely, because it will bite other MCP authors. The gateway here is [OpenClaw](https://docs.openclaw.ai), and as of **v2026.7.1-2** the behaviour is in [`src/agents/agent-bundle-mcp-materialize.ts`](https://github.com/openclaw/openclaw/blob/a89b88ec0ea756c48e2d28f246ac0f325e420c51/src/agents/agent-bundle-mcp-materialize.ts):

```typescript
  const structuredContentBlock =
    params.result.structuredContent !== undefined
      ? ({
          type: "text",
          text: `structuredContent:\n${JSON.stringify(params.result.structuredContent, null, 2)}`,
        } as const)
      : null;
  // Structured results replace mirrored text, but original non-text blocks
  // still carry images, linked resources, and audio that the JSON cannot mirror.
  const normalizedContent: AgentToolResult<unknown>["content"] = structuredContentBlock
    ? [
        structuredContentBlock,
        ...sourceContent
          .filter((block) => block.type !== "text")
          .map(mcpContentBlockToAgentContent),
      ]
    : content.length > 0
      ? content
      : ...
```

`filter((block) => block.type !== "text")` is the whole story: when `structuredContent` is present, every text block is dropped. Images, resource links and audio survive — that carve-out was [added in July 2026](https://github.com/openclaw/openclaw/pull/115521). Text does not.

Two caveats before you copy this into your own mental model:

- **Version-pin it.** This code path has flipped twice in ninety days. Before [#87540](https://github.com/openclaw/openclaw/pull/87540) (merged 2026-05-28) the precedence was the *other* way round — `content` won and `structuredContent` was dropped, which was [filed as a bug](https://github.com/openclaw/openclaw/issues/87511). Don't assume either behaviour without checking the version you're actually running.
- **It's a defensible reading of the spec**, which is what makes it dangerous. The MCP specification says:

  > For backwards compatibility, a tool that returns structured content SHOULD also return the serialized JSON in a TextContent block.
  >
  > — [MCP specification 2025-06-18, Tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#structured-content)

  The spec's own example returns `content: [{"type": "text", "text": "{\"temperature\": 22.5, …}"}]` beside `structuredContent: {"temperature": 22.5, …}` — the same data twice. So a client that has parsed `structuredContent` is entitled to treat the text block as a redundant mirror and drop it. My pilot did the one thing the spec doesn't anticipate: it put *different* information in the two halves. **If your `content` is not a serialization of your `structuredContent`, you are outside what the spec promises, and at least one popular client will silently throw it away.**

### Attempt 3 — sentence first, numbers after, in one text block

Ordering inside a single text block is the only lever that survives every client, so that's what the pilot became:

```python
    if name == "depth_state" and isinstance(result, dict) and result.get("display"):
        rest = {k: v for k, v in result.items() if k != "display"}
        text = f"{result['display']}\n\n{json.dumps(rest, indent=2)}"
        return [types.TextContent(type="text", text=text)]
```

Which produces a payload that is unambiguously different from the control:

```text
3.7 metres under the keel

{
  "below_keel_m": 3.7,
  "depth_m": 5.2,
  ...
}
```

Except the numbers still didn't move, because of the third invalidity — the one that had also voided attempt 1.

### The invalidity underneath the other two: the tools had never been called

Seven MCP tools, all probing healthy, none of them ever invoked. The gateway's tool policy admitted a base profile plus an explicit extra list — and the extra list didn't include the group that MCP server tools live in:

```json
{
  "tools": {
    "profile": "minimal",
    "alsoAllow": ["group:runtime", "group:fs"]
  }
}
```

In OpenClaw, [`tools.profile`](https://docs.openclaw.ai/gateway/config-tools) "sets a base allowlist before `tools.allow`/`tools.deny`", and `minimal` allows `session_status` only. Configured MCP servers are "exposed as plugin-owned tools under the `bundle-mcp` plugin id", and the docs note that the broader profiles — "`coding` and `messaging` also implicitly allow `bundle-mcp`" — do that implicitly. `minimal` does not. The docs even describe the exact symptom, under sandboxing:

> If `mcp.servers` is configured but sandboxed turns only show built-in tools, add `bundle-mcp`, `group:plugins`, or a server-prefixed MCP tool name/glob […] to `tools.sandbox.tools.alsoAllow`

The failure mode is nasty because **nothing errors**. The server connects, `tools/list` succeeds, every health probe is green, and the tools are filtered out before the request ever reaches the model. From the outside it looks identical to a working install. And the agent still answered questions about the boat perfectly well — because the workspace instructions predated the MCP servers and told it to shell out to `curl` against the HTTP API, which it dutifully did.

So no `display` string had ever reached a model. Attempt 1 measured a rule against a payload that didn't exist. Attempt 2's arms were identical for a *second*, independent reason on top of the `structuredContent` one.

The one-line fix is adding the group to the allow list:

```json
{
  "tools": {
    "profile": "minimal",
    "alsoAllow": ["group:runtime", "group:fs", "bundle-mcp"]
  }
}
```

Worth noting on its own: the agent switched from `curl` to `signalk__depth_state` / `signalk__battery_state` **immediately, with no change to the instructions telling it to use `curl`**. Tool availability beat documented instruction. The prose was never what held the MCP path back.

### And then the honest measurement said I was wrong

With the arm genuinely connected, one question exercising both shapes at once, five trials per arm, on the small fast model:

| arm | quoted `display` verbatim |
|-----|---------------------------|
| `battery_state` — plain JSON dump, `display` buried mid-object | **3 / 5** |
| `depth_state` — rendered sentence first, numbers after | **1 / 5** |

Leading with the sentence didn't help. If anything it hurt. Small n, one model, so I won't claim the effect is real in the other direction — but there is no evidence for the hypothesis, and the pilot was carrying a special case in a dispatch function, so it went:

```console
$ git revert --no-edit 4c43abd
$ git log --oneline -1
89d3b40 Revert the depth_state output-shape pilot: measured, did not help
```

## The fix

The lever was neither the prompt nor the payload. It was a **contradiction between them**.

The workspace instructions file — written when the agent read the boat over `curl`, and never revisited after the MCP servers went in — contained this:

```markdown
Units are SI. Convert for the user:
  m/s → kn   × 1.94384
  rad → deg  × 57.2958
  K   → °C   − 273.15
```

That is an explicit, specific, actionable order to re-render raw numbers — which is exactly what the persona's carve-out forbids. The model wasn't being non-compliant. It was obeying the more specific of two conflicting instructions. Rewriting that section to point at the tools instead:

```markdown
Read the vessel through the `signalk__*` tools, not `curl`.
Each returns a `display` string that is already rendered for a
human. Quote it. Do not re-render the reading from the raw SI
fields beside it.
```

Three trials, both tools: **6 / 6 verbatim**. No change to the tool layer at all.

## Why it matters / gotchas

**The generalizable lesson is the failure mode, not the fix:** when an agent ignores a rule, check what *else* in its context tells it to do the opposite before concluding the model is non-compliant. An agent's context is assembled from a persona file, a workspace file, tool descriptions, and tool results, all written at different times by people optimizing for different things. "The model won't follow instructions" is very often "the model is following the other instruction."

That complicates the June post rather than overturning it. Formatting still belongs in the tool response — that's what makes `display` deterministic and available. But the tool layer is not sufficient on its own, because it competes with a prompt surface that can contradict it, and it is not *causally* the lever when a contradiction exists. **Fix the contradiction first, then optimize the payload — and check that the payload is actually arriving.**

The traps nearby, in the order they'll bite you:

- **A healthy tool is not a called tool.** Green probes, successful `tools/list`, and a working agent are all compatible with the model never having seen your tools. Before benchmarking anything about tool *output*, prove a tool was *invoked* — read the session transcript for the call, don't infer it from a plausible answer. (Ours answered correctly the whole time, via `curl`.)
- **Don't put novel information in `content` when you also send `structuredContent`.** The spec frames `content` as a backwards-compatibility mirror, and clients act accordingly. If you need the model to read a rendered string, put it in the one payload every client forwards.
- **A/B'ing two arms of a payload requires proving the arms differ at the model,** not at the server. Log or dump what the client actually forwarded. Mine was a byte-for-byte match across a difference I'd written 40 lines of code to create.
- **Every "the model won't obey" conclusion is provisional until the plumbing is proven.** I wrote a struck-through wrong conclusion into my own docs, twice, on the strength of experiments that hadn't measured anything.

## Close

This is one thread out of building an AI ops layer for an all-electric charter catamaran — MCP servers over SignalK, a self-hosted agent gateway on a Raspberry Pi, and a voice front-end where "what's the battery doing" has to come back as something a human can hear. The server the code above is from is open source: [signalk-mcp](https://github.com/sailingnaturali/signalk-mcp), including [the revert](https://github.com/sailingnaturali/signalk-mcp/commit/89d3b406255aaddedf3e7d51d47b0ad025267f41).

*Related: [Fix LLM formatting in the tool layer, not the prompt]({% post_url 2026-06-05-fix-llm-formatting-in-the-tool-layer-not-the-prompt %}) · [Running OpenClaw on a Raspberry Pi alongside SignalK]({% post_url 2026-07-29-openclaw-raspberry-pi-signalk-boat-agent-gateway-mode-local-si-units-tools-profile-prompt-caching %}) · [When MCP tools break, isolate the server before blaming the agent]({% post_url 2026-06-23-mcp-tools-not-showing-up-isolate-the-server-before-blaming-the-agent %}) · [MCP server or a curl recipe in AGENTS.md? Measure the breakeven]({% post_url 2026-08-02-do-i-need-an-mcp-server-vs-agents-md-curl-recipe-mcp-vs-cli-tool-schema-token-cost-breakeven %})*
