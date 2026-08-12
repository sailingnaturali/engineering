---
layout: post
title: "Enabling Bash costs more context than seven MCP tool schemas"
description: "Part two of the MCP-vs-CLI measurement: a four-arm benchmark (mcp / curl-cold / curl-warm / a purpose-built sk CLI), 12 asks x 3 runs on Claude Sonnet 4.6. MCP was the cheapest arm at ~30-40% less billed input; merely enabling the Bash tool costs ~2,700 tokens of harness prompt against 1,160 for all seven signalk-mcp schemas; and the real bill is eager MCP server loading — ~19,800 fixed tokens from 11 eagerly spawned servers. Plus two bench defects: ResultMessage.total_cost_usd is cumulative per session, so summing it raw is a triangular over-count, and scoring which tool got called instead of what it returned hid an all-nulls battery_state bug for months."
date: 2026-08-11
tags:
  - mcp
  - agents
  - ai
  - llm
  - tokens
  - benchmark
  - signalk
  - claude-agent-sdk
  - selfhosted
---

> Nine days ago I measured MCP tool schemas against a `curl` recipe with a tokenizer and got a near-tie. This time I ran the agent: four arms, same model, same 12 asks, only the delivery mechanism varying. **MCP was the cheapest arm** — 109,779 billed input tokens for a 12-ask conversation against 158,021 for `curl`. The reason is not subtle: **turning on the Bash tool costs ~2,700 tokens of harness prompt, more than all seven MCP schemas combined (1,160).** The thing that actually costs money is neither — it is eagerly loading eleven MCP servers into every turn. [Jump to the numbers](#the-numbers).

[Part one]({% post_url 2026-08-02-do-i-need-an-mcp-server-vs-agents-md-curl-recipe-mcp-vs-cli-tool-schema-token-cost-breakeven %}) counted tokens on a desk: 874 for seven `signalk-mcp` tool schemas, 466 for the equivalent `curl` prose in an agent file, breakeven at about one tool call per turn. Static counting is honest as far as it goes, and it left the obvious question open — *what does an agent actually spend when you hand it a shell instead of a tool?*

So I ran it. This is part two, and the headline number went the other way from the folk wisdom.

![Billed input for one 12-ask conversation: the MCP arm costs 109,779 tokens and 0.1273 dollars, cheaper than curl-cold at 158,021 tokens, the sk CLI at 166,424 and curl-warm at 178,577.](/assets/img/mcp-vs-curl-cli-agent-benchmark-bash-tool-token-cost-mcp-tool-schema-overhead-eager-loading-mcp-servers-total-cost-usd-cumulative/session-cost-by-arm.svg)

## The confound in the version of this I nearly published

The run that started this argument had an agent reading the boat with `curl` and looking cheap doing it. It also happened to be running with a bigger thinking budget than the MCP agent it was being compared against. Two variables, one conclusion, no experiment.

So: four arms, a 2x2 over *where the domain knowledge lives* and *how the agent reaches it*. Model, persona, thinking budget, ask set and vessel are pinned; only the delivery mechanism moves.

| arm | reach | knowledge lives in |
|---|---|---|
| `mcp` | `signalk-mcp`'s 7 shaped tools | tested code |
| `curl-cold` | Bash + the server URL, nothing else | nowhere — the agent discovers it |
| `curl-warm` | Bash + `curl` | the system prompt (paths + SI conversions) |
| `cli` | Bash + `sk`, a CLI over the same `tools.py` | tested code, loaded on call |

All four share one neutral persona and run flat — one agent, no subagents. That is deliberate: the production system prompt names MCP tools by hand and would have biased the Bash arms into failure.

```python
PERSONA = """You are the ship's systems assistant aboard a sailing vessel.

Answer the crew's question in one or two sentences of natural spoken English.
Always give units in full — knots, metres, percent, volts, amps — never raw
symbols or abbreviations.

Use your tools to read live vessel data. Never guess or estimate a reading; if
you cannot get it, say so plainly."""

ARMS = {
    "mcp":       lambda: _options("", ["mcp__signalk"], _signalk_server()),
    "curl-cold": lambda: _options(_CURL_COLD, ["Bash"], {}),
    "curl-warm": lambda: _options(_CURL_WARM, ["Bash"], {}),
    "cli":       lambda: _options(_CLI, ["Bash"], {}),
}
```

`curl-warm` is the interesting arm — it is the [MCP-is-a-tax](https://www.firecrawl.dev/blog/mcp-vs-cli) recommendation implemented properly. Everything `signalk-mcp` encodes in Python gets moved into the prompt instead:

```text
Read a single path with:
  curl -s $SIGNALK_URL/signalk/v1/api/vessels/self/<path/with/slashes>

Do NOT fetch the whole vessels/self tree — it is over 16 KB. Go straight to
the path you need. The paths that matter:

  environment.depth.belowKeel / .belowTransducer / .belowSurface
  environment.wind.speedTrue / .speedApparent / .directionTrue
  electrical.batteries.house.capacity.stateOfCharge / .voltage / .current
  tanks.freshWater.0.currentLevel / tanks.blackWater.0.currentLevel
  navigation.position / .speedOverGround / .headingTrue / .state
  propulsion.port.runTime / propulsion.starboard.runTime

SignalK is strictly SI. You MUST convert before answering:
  speed m/s -> knots (x1.94384)   angles radians -> degrees (x57.2958)
  ratios 0-1 -> percent (x100)    temperature kelvin -> celsius (-273.15)
```

Twelve asks, deliberately loaded with the SI traps — `7569827` seconds of engine time, `5.506` radians of wind direction, `0.265` of a fresh-water tank. Scope is SignalK-only: `curl` has no equivalent for the vault-backed servers, and benchmarking those would be a strawman.

## The numbers

Three full runs, all agreeing. These are run 3, against a vessel motoring in Boundary Pass.

**Per turn — what one ask costs:**

| arm | billed input/ask | Δ | output/ask | p50 | cost/ask | correct |
|---|---|---|---|---|---|---|
| **mcp** | **9,148** | — | 245 | 9.05 s | **$0.0106** | 12/12 |
| curl-cold | 13,168 | +4,020 | 302 | 5.54 s | $0.0159 | 12/12 |
| curl-warm | 14,881 | +5,733 | 404 | 6.40 s | $0.0158 | 12/12 |
| cli | 13,869 | +4,720 | **242** | 5.79 s | $0.0115 | 12/12 |

**Per session — what holding the whole 12-ask conversation costs:**

| arm | billed input total | Δ | output total | session cost |
|---|---|---|---|---|
| **mcp** | **109,779** | — | 2,936 | **$0.1273** |
| curl-cold | 158,021 | +48,242 | 3,621 | $0.1913 |
| curl-warm | 178,577 | +68,798 | 4,847 | $0.1895 |
| cli | 166,424 | +56,645 | **2,902** | $0.1378 |

Both views are here because they answer different questions, and the per-ask mean flatters the expensive arms. A resident tool schema is billed on *every* turn, so its weight grows with the conversation; dividing by ask count divides that back out. The session table is the one that matches a bill: the mcp-vs-curl-cold gap reads as 4k tokens per ask and 48k across one conversation.

Correctness was a wash — **144/144 across three runs**. Every arm turned 7,569,827 s into 2,102.7 hours, 5.506 rad into 315°, 8.51 m/s into 16.5 knots, and all four enumerated both standing restricted-area alarms. Sonnet does not need the conversions done for it. "Shaped tools protect correctness" did not survive contact with the data, at least for this model on non-adversarial asks.

The Bash arms are consistently *faster* (p50 5.5–6.4 s vs 9.05 s) — a real result, and the only column where the CLI story holds up.

## Why raw JSON loses, and keeps losing

A tool schema is written into the prompt once and read from cache on every subsequent turn. A `curl` payload lands in the transcript and is re-read, uncached-then-cached, for the rest of the session. One is a fixed cost; the other is a debt that compounds.

![Cumulative billed input diverges over a 12-ask conversation because every raw curl payload stays in the transcript, ending about 48,000 tokens above the MCP arm.](/assets/img/mcp-vs-curl-cli-agent-benchmark-bash-tool-token-cost-mcp-tool-schema-overhead-eager-loading-mcp-servers-total-cost-usd-cumulative/cumulative-input-by-arm.svg)

That is part one's ΔR — the per-read saving — playing out over a real conversation instead of a single turn. The curl arms started ~6k behind on ask 1 and finished ~48–69k behind.

Note also that `curl-warm` cost *more* than `curl-cold`. Moving the domain knowledge into the prompt is not free: the cheatsheet is resident on every turn, and it bought no correctness, because there was none left to buy.

## The finding that inverts the intuition

The MCP-is-overhead argument treats tool schemas as the thing you pay for and a shell as the thing you get for free. So I measured the standing cost of each configuration directly, with an ask that calls no tool at all — everything in that number is prompt you pay for before anyone says anything.

| configuration | fixed tokens |
|---|---|
| mcp — all 7 `signalk` schemas | **1,160** |
| Bash tool, no guidance | 3,860 |
| Bash + `sk` cheatsheet | 3,943 |
| Bash + paths + unit table | 4,198 |
| **production agent — 11 MCP servers + subagents + crew prompt** | **~19,800** |

**Enabling one Bash tool costs about 2,700 tokens more than all seven MCP schemas combined.** The shell is not free; it arrives with its own harness prompt describing how to use it safely, and that prompt is bigger than the schemas it was supposed to replace. Whatever a CLI saves by not being resident, it spends immediately on being allowed to run at all.

Then there is the last row.

![Fixed prompt overhead: all seven signalk MCP schemas cost 1,160 tokens while merely enabling the Bash tool costs 3,860, and a production agent with 11 eagerly loaded MCP servers carries about 19,800 tokens on every turn.](/assets/img/mcp-vs-curl-cli-agent-benchmark-bash-tool-token-cost-mcp-tool-schema-overhead-eager-loading-mcp-servers-total-cost-usd-cumulative/fixed-prompt-overhead.svg)

**The bill is the fleet, not the protocol.** A flat agent with one MCP server carries 1,160 tokens. The production agent daemon carries ~19,800 — 17x — because it eagerly spawns eleven MCP servers at startup and every one of them registers its schemas into every turn, whatever the question was. Ask it what time it is and you have paid for the COLREGs tool descriptions.

That is an *eager loading* problem, not an MCP problem, and the same servers cost nothing in Claude Code, which loads them lazily. Which is why the answer to "our MCP bill is too high" is almost never "rewrite the servers as CLIs" — it is "stop loading all of them on every turn."

One honest wrinkle in that ~19,800: it is the median of four measurements (19,791 / 19,798 / 19,800 / 19,812). A fifth, taken cold, read 14,912 — on a cold start not every `uv`-spawned server has registered its schemas yet, so an early measurement *understates* the resident cost. If you go measure your own, measure it warm.

## What the bench got wrong, twice

Two defects in my own harness, both of which had been quietly producing plausible numbers.

**1. `total_cost_usd` is cumulative per session.** The SDK's `ResultMessage` reports the cost of the session so far, not of the turn that just finished. Summing it across 12 asks sums a running total — a triangular over-count that inflates a 12-ask session by roughly 6x, and inflates it *more* for the arms with more turns. Every cost number in an earlier draft of this post was wrong in the direction that flattered my hypothesis.

```python
obs.cost_usd = float(getattr(message, "total_cost_usd", 0.0) or 0.0)
...
total = sum(r.cost_usd for r in results)      # WRONG: sums a running total
```

**2. The bench scored which tool got called, not what came back.** This is the one that stings. Scoring compared `observed_tools` against `expected_tools` — the agent called `battery_state`, the corpus said it should call `battery_state`, green. What `battery_state` *returned* was never examined:

```json
{"bank": "0", "state_of_charge_pct": null, "voltage_v": null,
 "current_a": null, "display": "No battery data available"}
```

The tool defaulted to `bank="0"`, the SignalK convention. Our vessel publishes `electrical.batteries.house`. So the shipped tool had been answering "no battery data" on a boat that had been publishing battery data the whole time — for months — behind a green bench.

It survived that long because the corpus ask was *"How's the **house** battery doing?"*. The word "house" made the model pass `bank="house"` explicitly, which worked. The test was handing the agent the answer to the question the tool was failing.

## The fix

Difference the cumulative cost, and keep both views:

```python
# ResultMessage.total_cost_usd is CUMULATIVE for the session, not the turn.
prev_cost = 0.0
for ask in asks:
    result = await _run_one(client, ask)
    result.cost_usd_session = result.cost_usd            # as reported
    result.cost_usd = max(result.cost_usd_session - prev_cost, 0.0)
    prev_cost = result.cost_usd_session
```

There is a free consistency check hiding in keeping both: the differenced per-turn costs must sum to the final cumulative figure, and a test asserts it.

For the scoring bug, the fix is to grade against the world instead of against the transcript. Every ask carries the path its answer lives at, and the runner reads that path off the server itself, next to the agent's turn:

```json
{
  "id": "battery",
  "prompt": "How's the battery doing?",
  "expected_tools": ["mcp__signalk__battery_state"],
  "truth_path": "electrical.batteries.house.capacity.stateOfCharge",
  "truth_unit": "ratio->percent"
}
```

```python
def _fetch_truth(ask: Ask) -> str:
    """Read the ask's answer straight off SignalK, next to the agent's turn.

    Deliberately a raw urllib GET, not signalk-mcp's client: the whole point is
    an independent reading the arms cannot influence.
    """
    url = f"{signalk_url()}/signalk/v1/api/vessels/self/{ask.truth_path.replace('.', '/')}"
    ...
```

Independence matters more than convenience here. If the truth had been fetched through `signalk-mcp`'s own client, the all-nulls bug would have been graded against itself and stayed green a second time.

And the ask lost a word: *"How's the battery doing?"*. The corpus should never contain the hint that papers over the defect.

## Gotchas worth carrying away

- **A benchmark that scores tool identity is a routing test, not a correctness test.** Both are worth having; only one of them notices that the tool returned nulls. If your evals assert "the model called the right function", assume you have a class of bug that is structurally invisible to them.
- **Fix the vessel, not the corpus.** The golden asks had drifted from where the boat was. Editing the expected answers would have been quicker and would have silently broken comparability with every earlier run; moving the vessel back kept a year of results comparable.
- **Session totals, not per-ask means.** Anything resident is billed per turn, so per-ask averaging systematically flatters whichever arm has the fattest resident prompt. Report the number that looks like an invoice.
- **Small models may still want shaped tools.** This is Sonnet, n=12, one vessel. A separate probe against a local Qwen suggests the picture changes below the frontier: raw retrieval was perfect (10/10 — it can fetch a number), but interpreting one — *is the battery charging or discharging?* — scored 3/10 with thinking off and 10/10 with thinking on low. Retrieval is not the hard part; the semantics on top of it are, and that is exactly where a tool that returns `"discharging"` instead of `-3.1` earns its keep. Re-measure before betting an on-vessel local model on these results.
- **The vessel is ashore.** Phase 0: the SignalK server runs a mock vessel plugin. Token counts, response shapes and defects are real; the readings are synthetic.

## Where it lands

I published the argument that MCP is overhead, then built the experiment to prove it, and the experiment said the opposite. MCP was the cheapest arm on both views in all three runs, and the honest version of the CLI case is much narrower than the one I was making: `sk` earns its place for SSH sessions, cron, headless `claude -p` and non-MCP agents — reach an MCP server cannot provide. It is just not a token optimization, which is what I had proposed it as.

The money was never in the protocol. It is in eleven servers loading eagerly, 19,800 tokens deep, on a turn that only needed to know the time.

Both halves are public: [`signalk-mcp`](https://github.com/sailingnaturali/signalk-mcp) is the server, and the four-arm harness lives in [`naturali-agents`](https://github.com/sailingnaturali/naturali-agents) under `poseidon/bench/` — part of the agent stack I'm building for an all-electric charter catamaran that doesn't exist yet.

*Related: [MCP server or a curl recipe in AGENTS.md? Measure the breakeven]({% post_url 2026-08-02-do-i-need-an-mcp-server-vs-agents-md-curl-recipe-mcp-vs-cli-tool-schema-token-cost-breakeven %}) — part one, the static token count and the keel-offset sign that decided it; [Benchmark your own LLM workload before migrating]({% post_url 2026-08-06-benchmark-your-own-llm-workload-before-migrating-gpt-5.6-vs-claude-sonnet-mcp-tool-routing-reasoning-effort-none %}) — the same harness pointed at models instead of tool surfaces; and [Running OpenClaw on a Raspberry Pi alongside SignalK]({% post_url 2026-07-29-openclaw-raspberry-pi-signalk-boat-agent-gateway-mode-local-si-units-tools-profile-prompt-caching %}) — where the curl recipe came from.*
