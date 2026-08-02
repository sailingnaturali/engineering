---
layout: post
title: "MCP server or a curl recipe in AGENTS.md? Measure the breakeven"
description: "The MCP-vs-CLI argument says tool schemas are a token tax and a curl recipe in AGENTS.md is cheaper. Measured on a 7-tool signalk-mcp server against the equivalent curl+jq prose: 874 tokens of tool schema vs 466 of prose, but 92-token tool results vs 431–627-token raw SignalK REST responses. Breakeven is about one tool call per turn — and with prompt caching, measured at a 0.175x effective multiplier over 3,782 real requests, one read every five or six turns. Then the part tokens don't measure: transducerToKeel is stored negative, and the intuitive subtraction reports 2.24 m more under-keel clearance than the boat has."
date: 2026-08-02
tags:
  - mcp
  - agents
  - ai
  - llm
  - signalk
  - prompt-caching
  - selfhosted
  - marine
  - tokens
---

> The current consensus is that MCP is a token tax and you should just tell the agent to `curl` the API from its `AGENTS.md`. I measured both, for the same capability, against the same server. The tool schemas cost **+408 tokens standing** and save **~340–420 tokens per read**, so the breakeven is roughly **one tool call per turn** — and with prompt caching (measured, not assumed: a 0.175× effective multiplier across 3,782 real requests) it moves to **one read every five or six turns**. But the tokens are the easy half and they nearly cancel. What actually decided it was a minus sign. [Jump to the breakeven formula](#the-breakeven-formula).

There's a good argument going around that MCP servers are a context-window tax — [tool schemas at ~550–1,400 tokens each](https://layered.dev/mcp-tool-schema-bloat-the-hidden-token-tax-and-how-to-fix-it/), [benchmarks putting MCP at 4–32× the token cost of an equivalent CLI](https://www.firecrawl.dev/blog/mcp-vs-cli), a [spec issue open on the overhead itself](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/2808). The conclusion people draw is: skip the server, describe the API in your agent file, let the model shell out.

I have the same capability implemented both ways, so I measured it instead of arguing about it.

## Two ways to let an agent read a boat

The job: an agent that can answer "how much water under the keel?" and "how's the house bank?" from a [SignalK](https://signalk.org) server — the open marine data server that normalises NMEA 2000/0183 into one JSON tree.

**Option A — an MCP server.** `signalk-mcp` exposes seven named tools. The schemas sit in the prompt every turn:

```python
types.Tool(
    name="depth_state",
    description=(
        "Use this for 'what's our depth?' / 'how much under the keel?' / "
        "'how close are we to running aground?' — returns water depth with "
        "under-keel clearance first. below_keel_m IS the clearance under the "
        "hull (no draft math needed). Do NOT read depth via read_sensor: the "
        "raw transducer path (environment.depth.belowTransducer) is NOT "
        "under-keel depth and will mislead. Do not guess depth paths or "
        "compute clearance yourself; call this."
    ),
    inputSchema={"type": "object", "properties": {}},
),
```

Seven of those: `get_active_alarms`, `read_sensor`, `get_route`, `battery_state`, `depth_state`, `get_local_time`, `list_paths`.

**Option B — a prose recipe in the agent file.** No server, no schemas. The agent gets shell access and a section in its always-on `AGENTS.md`:

```markdown
## Reading the boat (SignalK)

Boat data lives in SignalK on `http://localhost:3000` (anonymous reads, no auth).
Use the exec tool with `curl`. `jq` is available for filtering.

- One value: `curl -s http://localhost:3000/signalk/v1/api/vessels/self/<path> | jq '.value'`
  where the SignalK dotted path becomes slashes.
- A whole group at once (fewer calls):
  `curl -s http://localhost:3000/signalk/v1/api/vessels/self/electrical | jq`
- Top-level groups: `navigation`, `environment`, `electrical`, `propulsion`,
  `tanks`, `watermaker`, `communication`, `design`, `notifications`.
- **Units are SI:** speed m/s, angles **radians**, depth meters, temperature
  **Kelvin**. Convert for the Captain — knots, degrees, °C.
  (m/s→kn ×1.94384; rad→deg ×57.2958; K→°C −273.15.)
- **Battery current sign: positive = charging** (Victron convention).
- History (`/signalk/v2/history/…`) is not available — answer "now."
- **Never fabricate.** If curl fails or a path is missing, say so.
```

Both are always-on. Both answer the same questions. Now the receipts.

## Round 1 — standing cost, the part everyone measures

This is what you pay every turn, including turns where nobody asks about the boat.

| | tokens/turn |
|---|---|
| MCP: seven tool schemas | **874** |
| Agent file: the SignalK section | **466** |
| **Δ — agent file wins** | **−408** |

How I counted — `tiktoken`, `cl100k_base`, pulling the tool definitions straight out of the source with `ast` so there's no hand-transcription:

```python
import ast, tiktoken
enc = tiktoken.get_encoding("cl100k_base")
src = open("src/signalk_mcp/server.py").read()
tools = [{kw.arg: ast.literal_eval(kw.value) for kw in node.keywords}
         for node in ast.walk(ast.parse(src))
         if isinstance(node, ast.Call)
         and getattr(node.func, "attr", None) == "Tool"]
print(len(enc.encode(open("AGENTS.md").read())))
```

One honest note on the 874: that's the `_list_tools()` definition block as written. Serialised to JSON it's 845; namespaced the way a client renders it (`mcp__signalk__depth_state`) it's 887. So call it **845–890 depending on your client** — the spread doesn't move anything below.

So far the MCP-is-a-tax crowd is right. 408 tokens a turn, forever, is a real cost.

## Round 2 — the part the benchmarks skip

The CLI benchmarks usually stop at the schema. But a tool call has a *result*, and the result also lands in the context window.

Here is what `curl` gets back for depth — the whole reason the recipe exists:

```json
{
    "transducerToKeel": {
        "meta": {
            "description": "Depth from the transducer to the bottom of the keel",
            "units": "m",
            "displayUnits": {
                "category": "depth",
                "targetUnit": "m",
                "formula": "value",
                "inverseFormula": "value",
                "symbol": "m",
                "displayFormat": "0.0"
            }
        },
        "value": -1.12,
        "$source": "defaults",
        "timestamp": "2026-08-01T13:35:02.076Z"
    },
    "surfaceToTransducer": { ...same meta block again... },
    "belowTransducer":     { ...same meta block again... },
    "belowKeel":           { ...plus alarmMethod, warnMethod, three zones... },
    "belowSurface":        { ...same meta block again... }
}
```

515 tokens, of which the five `value` fields are about a dozen. Everything else is `meta` — `description`, `units`, and a `displayUnits` object carrying `formula`, `inverseFormula`, `symbol` and `displayFormat` — repeated per leaf. The agent pays for all of it and then has to find the numbers inside.

The MCP tool returns this instead:

```json
{
  "below_keel_m": 36.42532195742289,
  "below_surface_m": 37.795321957422885,
  "below_transducer_m": 37.545321957422885,
  "display": "36.4 metres under the keel, 37.8 metres total depth",
  "timestamp": "2026-08-01T18:37:26.629Z"
}
```

92 tokens. Same numbers, plus a TTS-safe sentence the voice pipeline can read out verbatim.

| read | raw `curl` response | MCP tool result | ratio |
|---|---|---|---|
| `environment/depth` | 515 | 92 | 5.6× |
| `electrical` | 431 | 93 | 4.6× |
| `navigation` | 627 | ~92 | 6.8× |

You can't `jq` your way out of most of this, either. Piping to `jq '.value'` works for a single leaf, but the recipe's own advice — grab the whole subtree in one call to save round trips — is exactly the case where the meta bloat arrives in full.

## The breakeven formula

Two levers pulling opposite directions. Set them against each other.

Let **ΔS** = the standing-cost difference (schemas − prose) and **ΔR** = the per-read saving (raw response − tool result). Cost per turn at *k* reads:

```text
agent file:   P + k · raw
MCP server:   S + k · tool

MCP is cheaper when   S + k·tool  <  P + k·raw
                             k    >  (S − P) / (raw − tool)
                             k*   =  ΔS / ΔR
```

For this pair: **k\* = 408 / ~400 ≈ 1.02 reads per turn.**

That's the finding. Not "MCP good" or "MCP is a tax" — *it pays for itself at roughly one tool call per turn.*

Which cuts cleanly in both directions:

- A general-purpose agent that touches the boat on one turn in twenty: the agent file is cheaper, and it isn't close.
- An agent whose entire job is the boat, where essentially every turn is a read: the MCP wins outright.

My constants aren't yours. Run the same three measurements on your own server — schema tokens, prose tokens, and a representative raw-vs-tool response pair — and divide. If your API returns lean JSON, ΔR collapses and the prose recipe wins at almost any *k*. If your API is as metadata-heavy as SignalK's, ΔR is large and k\* drops below 1.

## Prompt caching moves k\*, and I measured by how much

The standing cost is the MCP's only loss — and it's the exact part that caches. Tool schemas are a stable prefix. The per-read saving is on churny tokens that never cache. So caching should shrink ΔS and leave ΔR alone, which moves k\* down.

The tempting shortcut is to call cached tokens "10% of input" and be done. That's wrong, because it only counts the read side. A cache entry has to be *written* first, and writes cost **more** than uncached input.

So rather than assume a hit rate, I aggregated the `usage` field across the **40 most recent agent session transcripts** for this project — **3,782 billed requests** on a real runtime with `signalk-mcp` attached:

```text
cache READ    698,670,375 tokens   94.33% of input-side
cache WRITE    41,945,413 tokens    5.66%
uncached input     29,139 tokens    ~0.00%

cold requests (zero cache read):  150 / 3,782  =  4.0%
```

Every write in that sample was **1-hour TTL** (`ephemeral_1h_input_tokens`; `ephemeral_5m` was zero), which matters — the price multiplier depends on TTL. Per the [prompt-caching docs](https://docs.claude.com/en/docs/build-with-claude/prompt-caching): cache read **0.1×** base input, 5-minute write **1.25×**, 1-hour write **2×**.

A standing block gets written on cold turns and read on warm ones, so its effective multiplier is `cold × write + warm × read`:

| | measured |
|---|---|
| cold turns | 4.0% |
| warm turns | 96.0% |
| **standing-block effective multiplier (1h TTL — what we ran)** | **0.175×** |
| the same block at 5-minute TTL | 0.146× |
| blended multiplier across all input-side tokens | 0.208× |

Apply that to the 408-token standing delta and re-run the formula:

```text
408 × 0.175  =  ~72 effective tokens

k* = 72 / 400  ≈  0.18 reads per turn
```

**About one boat read every five or six turns.** Not the one-in-ten you get from the flat-10% shortcut — the write side is the expensive half and at 1-hour TTL it costs 2×.

Caching still makes the MCP case *stronger*, just less dramatically than the naive math suggests. And it's conservative in the MCP's favour for a second reason the formula doesn't capture: a tool result is uncached only on the turn it *arrives*. After that it joins the cached prefix at 0.175× for the rest of the session. The ~400-tokens-per-read saving counts only the first turn; the MCP's leaner results keep paying rent afterwards.

Three things to be honest about before you reuse the 0.175×:

- **That's a hot session.** 96% warm is what sustained back-to-back work produces. A boat agent DM'd over Telegram with minutes between messages cold-starts far more often — the 5-minute TTL expiring between turns is a problem I've [hit before]({% post_url 2026-07-29-openclaw-raspberry-pi-signalk-boat-agent-gateway-mode-local-si-units-tools-profile-prompt-caching %}). So 0.175× is the *favourable* end. A bursty agent lands nearer the uncached case — which widens the MCP's advantage rather than narrowing it: the standing penalty grows back toward 408, but so does the value of never re-sending 500-token blobs.
- **Runtime attribution:** these are Claude Code sessions carrying the MCP, not the boat agent itself. Real cache behaviour of a real agent holding these schemas — but I didn't instrument the boat agent, and I'm not claiming I did.
- **The 1-hour TTL is a property of this session,** not a universal default. On the 5-minute default the multiplier is 0.146× and the standing penalty is ~59 tokens, a slightly cheaper MCP.

One takeaway for reading other people's numbers: the MCP-vs-CLI benchmarks I can find quote schema cost **uncached**. On this measured multiplier that overstates the standing penalty by about 5.7×.

## The half that tokens don't measure

Here's the thing that actually decided it, live off the boat's `environment.depth` tree:

```text
environment.depth.belowTransducer   =  38.5187
environment.depth.transducerToKeel  =  -1.12      <-- stored NEGATIVE
```

The keel offset is stored as a **negative** number. Under-keel clearance is therefore an *addition*:

```text
belowTransducer + transducerToKeel  =  38.5187 + (-1.12)  =  37.40 m   ✅
```

An agent reading the raw tree and doing the obvious thing — *depth below the transducer, minus the keel offset* — gets:

```text
38.5187 - (-1.12)  =  39.64 m   ❌
```

**It reports 2.24 metres more clearance than the boat actually has, and the error points toward grounding.** In 38 m of water that's a rounding error. In 3 m it's the whole margin, delivered in a confident voice.

Nothing in the token comparison sees this. The wrong answer costs the same as the right one.

The MCP does the arithmetic in Python, where it can't be dropped:

```python
below_keel = below_keel_obj.get("value")   # SignalK's own belowKeel leaf
...
"display": _depth_display(below_keel, below_surface, below_transducer),
```

— and the tool description spends tokens specifically to stop the model freelancing: *"Do NOT read depth via read_sensor: the raw transducer path is NOT under-keel depth and will mislead. Do not guess depth paths or compute clearance yourself; call this."* That instruction is part of the 874. It's not schema bloat; it's the thing being bought.

## What the prose recipe is really asking for

Look back at the agent file with this in mind. Every bullet is a rule the model has to *remember and apply by hand*, on every read, forever:

```text
m/s → knots          × 1.94384
radians → degrees    × 57.2958
Kelvin → °C          − 273.15
battery current      positive = charging (Victron convention)
```

Four conversions, plus a sign convention, plus the keel-offset sign that isn't even in the list because nobody thought to write it down. Each is a coin flip on a bad turn — a long context, a distracting question, a smaller model. And the failure is silent: the model returns a number, not an error. "38 degrees" when the value was radians reads perfectly plausibly.

In Python those are five lines that execute the same way every time:

```python
if tail in _SPEED_KEYS:
    return f"{value * 1.94384:.1f} knots", "knots"
if tail in _BEARING_KEYS:
    deg = math.degrees(value) % 360
    return f"{deg:.1f}° ({_degrees_to_compass(deg)})", "°"
if tail == "temperature":
    return f"{value - 273.15:.1f}°C", "°C"
```

So the summary is: **the agent file is cheaper to carry and more expensive to be wrong with.** The token comparison is the easy half and it nearly cancels. The deciding factor is where the domain knowledge lives — in prose the model may skip, or in code it can't.

## Caveats, before you quote my numbers

- **The vessel is ashore.** This is Phase 0; the SignalK server runs a mock vessel plugin. The token counts, response shapes and the `transducerToKeel` sign convention are all real. The *readings* are synthetic — nobody is in 38 m of water off Boundary Pass right now.
- **cl100k_base is a proxy.** Your model's tokenizer will give slightly different numbers. The ratios hold; the absolutes won't.
- **874 vs 466 is my seven-tool server against my recipe.** The formula generalises. The constants absolutely do not.
- **This is not a controlled A/B.** The two setups differ in more than MCP-vs-file — different runtimes, Python vs `curl`. It's a like-for-like cost comparison of two ways to give an agent the same capability, not a single-variable experiment.

## Where it lands

I kept the MCP server, and the reason isn't the tokens — on tokens it's a coin flip that caching tips slightly my way. I kept it because `depth_state` cannot get the sign wrong, and a prose bullet can.

The rule of thumb I'd offer: **compute k\* = ΔS / ΔR before you argue about it**, and then ask the question the tokens can't answer — *is there any arithmetic in this domain that the model must not get wrong?* If yes, that decides it regardless of which side of the breakeven you land on.

The server is [`signalk-mcp`](https://github.com/sailingnaturali/signalk-mcp) (MIT), part of the agent stack I'm building for an all-electric charter catamaran that doesn't exist yet.

*Related: [Why we kept named MCP tools despite a 96% token saving]({% post_url 2026-06-06-signalk-mcp-named-tools-vs-execute-code-token-efficiency-voice-agent %}) — the same tradeoff one level down, inside the MCP server; [Running OpenClaw on a Raspberry Pi alongside SignalK]({% post_url 2026-07-29-openclaw-raspberry-pi-signalk-boat-agent-gateway-mode-local-si-units-tools-profile-prompt-caching %}) — where the curl recipe comes from, plus AGENTS.md vs SKILL.md measured the same way; and [Why your agent ignores its skill body but obeys the system prompt]({% post_url 2026-06-11-agent-skill-body-vs-base-system-prompt-always-on-conditional-deploy %}) — always-on vs conditional, the first axis of this question.*
