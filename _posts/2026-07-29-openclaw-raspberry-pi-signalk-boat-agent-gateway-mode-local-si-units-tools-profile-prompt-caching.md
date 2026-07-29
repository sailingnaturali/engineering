---
layout: post
title: "Running OpenClaw on a Raspberry Pi alongside SignalK"
description: "A setup guide for OpenClaw — a self-hosted agent gateway — on a Raspberry Pi 5 next to SignalK, DM'd over Telegram, reading live vessel data over HTTP. Gotchas up front: the 'Gateway start blocked: set gateway.mode=local' error, SI-unit conversion (m/s, radians, Kelvin), no /signalk/v2/history without InfluxDB, and a Chesterton's-fence with the ollama plugin. Plus token tuning: skill vs AGENTS.md, tools.profile savings, and Anthropic prompt caching."
date: 2026-07-29
tags:
  - openclaw
  - signalk
  - raspberry-pi
  - ai
  - agents
  - selfhosted
  - marine
  - telegram
  - prompt-caching
  - llm
---

{% raw %}
> Running [OpenClaw](https://docs.openclaw.ai) — a self-hosted, multi-channel agent gateway — on a Raspberry Pi 5 next to [SignalK](https://signalk.org), so you can DM the boat over Telegram and get live vessel readings back. The traps that cost me time are up front — the `gateway.mode` start-block, SI-unit conversion, no history without InfluxDB, and a Chesterton's-fence with the `ollama` plugin — then the walkthrough, then what I found tuning the standing prompt down. [Jump to the gotchas](#gotchas-first).

There's no existing writeup for this combination anywhere I could find, so here's the whole thing: what to know before you start, the setup that actually works, and the token-cost tuning that made it cheap enough to leave running.

## The build

OpenClaw is a Node/TypeScript daemon you run on your own hardware; you talk to an LLM-backed agent over chat channels (Telegram, Slack, etc.). SignalK is the open marine data server that normalises NMEA 2000/0183 into one JSON model. Put them on the same Pi and you get a boat assistant you DM from your phone that can read live vessel state.

They share the box but stay in their own lanes. OpenClaw reads SignalK over HTTP — it does not run inside the marine stack:

```text
  Raspberry Pi 5 (8 GB)
  ┌─────────────────────────────────────────────┐
  │  SignalK (Docker)          OpenClaw (native) │
  │  localhost:3000  ◀── HTTP ──  gateway daemon │
  │  + InfluxDB/Grafana           (systemd user) │
  └─────────────────────────────────────────────┘
            ▲                          ▲
       NMEA 2000/0183            Telegram DM
```

SignalK is typically already running in Docker on `localhost:3000` next to InfluxDB and Grafana. OpenClaw installs natively alongside it. No MCP server, no plugin inside SignalK — the agent just curls the SignalK REST API.

## Gotchas first

These are the ones that don't show up until you hit them.

### 1. The gateway won't start without `gateway.mode`

If the config is missing `gateway.mode`, the daemon refuses to start:

```text
Gateway start blocked: set gateway.mode=local
```

Onboarding sets this for you. But if you hand-edit the config and drop the key — or a tool rewrites it — OpenClaw treats the missing key as suspicious/clobbered config and blocks the start rather than guessing. The fix is one command:

```bash
openclaw config set gateway.mode local
```

(Or re-run onboarding with `openclaw onboard --mode local`.) See the [gateway troubleshooting docs](https://docs.openclaw.ai/gateway/troubleshooting).

### 2. SignalK values are SI — the agent must convert

SignalK stores everything in SI units. A raw read *looks* fine and is silently wrong for a human:

```text
speed      → m/s     (× 1.94384 for knots)
angles     → radians (× 57.2958 for degrees)
temperature→ Kelvin  (− 273.15 for °C)
depth      → metres
```

So `environment.wind.speedApparent` comes back as `8.5` — that's 8.5 **m/s**, i.e. ~16.5 knots, not 8.5 knots. If you don't tell the agent to convert, it will happily report the SI number as if it were the human unit. Bake the conversions into the agent's instructions (or a skill), and spell out the target units.

### 3. No history without InfluxDB

SignalK's REST API serves live values fine anonymously. But the history endpoint returns a 404 unless the InfluxDB-backed history plugin is running:

```bash
$ curl -s http://localhost:3000/signalk/v2/history/values?paths=electrical.batteries.house.stateOfCharge
# 404 unless signalk-to-influxdb (+ history API) is installed and running
```

Without it the agent is live-only — it answers "what's the depth *now*," not "what was the minimum overnight." If you want the agent to reason over trends, stand up the history plugin first; otherwise scope its instructions to present-tense questions.

### 4. `jq` isn't installed by default

Raspberry Pi OS ships without `jq`. If your agent instructions pipe curl through `jq`, they'll fail on a fresh box:

```bash
$ curl -s http://localhost:3000/signalk/v1/api/vessels/self/environment/depth/belowTransducer | jq .value
bash: jq: command not found
```

Two options: `sudo apt install jq`, or just don't — hand the agent the raw JSON and let it parse. An LLM reads `{ "value": 4.2, "timestamp": "…" }` without help. I went with raw JSON; one fewer moving part on the boat.

### 5. Chesterton's fence — the `ollama` plugin does more than you think

I disabled the `ollama` plugin assuming it was only a (dead, for me) web-search provider. Later a local Ollama model failed to load:

```text
No API provider registered for api: ollama
```

The `ollama` plugin *also* registers the Ollama API runtime — the thing that lets you use Ollama as a **model backend**, not just a search tool. Disabling it pulled the backend out from under the model. The lesson is the old one: don't disable a plugin until you know *everything* it provides. (Re-enabling it fixed the load.)

## The walkthrough

### Install (native)

OpenClaw supports Docker, but on a Pi that's already running SignalK's own Docker stack I installed OpenClaw natively and let it manage its own daemon — it keeps the marine containers isolated and the agent's lifecycle separate. The installer targets Node 24 by default (the supported range is Node 22.22.3+, 24.15+, or 25.9+) and handles the runtime for you:

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
# or: npm install -g openclaw@latest
```

Then the guided setup — it walks you through auth (an Anthropic API key, or an OAuth login), model choice, and the daemon:

```bash
openclaw onboard
openclaw onboard --install-daemon   # installs a systemd user service
```

On a headless Pi, the user service dies at logout unless you enable lingering:

```bash
sudo loginctl enable-linger "$USER"
```

That's the piece that makes it survive a reboot. See the [install docs](https://docs.openclaw.ai/install).

### Telegram

Make a bot with [@BotFather](https://t.me/BotFather), then point OpenClaw at the token — either in config or via env:

```bash
openclaw config set channels.telegram.botToken "<BOT_TOKEN>"
# or export TELEGRAM_BOT_TOKEN=<BOT_TOKEN>
```

Keep DMs gated with pairing so a stranger who finds the bot can't drive your boat:

```jsonc
// channels.telegram
{ "dmPolicy": "pairing" }
```

DM the bot, then approve the code it gives you (codes expire after an hour):

```bash
openclaw pairing approve telegram <CODE>
```

Details in the [Telegram channel docs](https://docs.openclaw.ai/channels/telegram).

### Reading SignalK over HTTP — no MCP needed

SignalK's REST API is anonymous when `allow_readonly` is on, so you don't need a custom SignalK MCP server for reads. Give the agent the `exec` tool and let it curl. A SignalK dotted path maps straight to URL slashes:

```bash
# environment.depth.belowTransducer  →  .../environment/depth/belowTransducer
curl -s http://localhost:3000/signalk/v1/api/vessels/self/environment/depth/belowTransducer
```

```json
{ "value": 4.2, "timestamp": "2026-07-27T00:00:00Z", "meta": { "units": "m" } }
```

Grab a whole subtree in one call:

```bash
curl -s http://localhost:3000/signalk/v1/api/vessels/self/electrical
```

The one prerequisite: `exec` only exists in certain tool profiles — which is the first tuning finding below.

## Tuning finding 1 — skill vs the agent file

OpenClaw injects workspace files into context every turn: a `SOUL.md` persona and an `AGENTS.md` instruction/memory file. Skills live at `workspace/skills/<name>/SKILL.md` — the skill's name+description is advertised every turn, but its body loads on demand when the skill fires.

So where do the SignalK-reading instructions belong — always-on in `AGENTS.md`, or in a `SKILL.md`? Intuition says the skill: pay for the body only when you use it. I measured prompt tokens per turn both ways:

| Turn | in AGENTS.md (always-on) | as a skill (on-demand) | Δ |
|---|---|---|---|
| No-tool question | 13,808 | 13,380 | −428 (skill wins) |
| Single boat read | 14,070 | 14,427 | +357 (skill loses) |
| Multi boat read | 16,134 | 16,628 | +494 (skill loses) |

Counterintuitive but consistent: **for an agent whose whole job is this domain, the always-on agent file is slightly cheaper.** The skill's *description* still sits in context every turn (alongside every other skill's), and loading its *body* on a domain turn costs more than the tiny always-on snippet it replaced. The skill only wins when most turns *don't* touch the domain — and for a boat agent, most turns do.

(This is the same always-on-vs-conditional split we hit on a different framework — see the related post below.)

## Tuning finding 2 — cutting the ~14k standing prompt

Every turn, even a no-tool question, carries a ~14k-token standing prompt: base preamble + tool schemas + workspace files. That's structural to a general-purpose gateway. Three things I tried to shrink it, in order of what actually worked.

### What worked — the tool profile

OpenClaw gates tools by `tools.profile`: `minimal` (just `session_status`), `coding` (filesystem + runtime/`exec` + web + more), `messaging`, and `full`. **Only `coding` grants both `exec` and filesystem** — which is why the SignalK-over-curl approach needs it.

But `coding` also drags in a pile of dev-tool schemas a boat agent never calls. If all you need is shell + file read/write, drop to `minimal` and additively re-allow just those two groups:

```jsonc
// tools
{
  "profile": "minimal",
  "alsoAllow": ["group:runtime", "group:fs"]
}
```

`group:runtime` is `exec`/process; `group:fs` is read/write/edit. That cut **~5,000 tokens/turn (~25%)** — pure schema for tools the agent never uses — with zero functional loss. See the [tool-profile docs](https://docs.openclaw.ai/gateway/config-tools).

### What did NOT work — disabling plugins

I assumed the loaded plugins (browser, canvas, phone-control, talk-voice…) were bloating the prompt. Disabling four of them saved **~270 tokens** — nothing.

Why: tool schemas are gated by tool *policy*, not plugin *state*. Once the `minimal` profile excludes a tool, its schema is already gone whether or not the plugin loads. So:

> Disabling a plugin does not save prompt tokens if the profile already denies its tools.

(Still disable unused plugins — for the Pi's RAM, CPU, and boot time. Just don't expect a token win.)

### The real lever — caching, not token count

The standing prompt bills at full price only on a *cold* turn. OpenClaw auto-injects Anthropic `cache_control` on the stable prefix, so the ~14k reads from cache at ~10% on warm turns. I watched it in one session: the cold turn *wrote* ~14k tokens to cache; the next same-session turn *read* ~14k from cache and *wrote* only ~150.

For bursty use — messages minutes apart, which is exactly how you DM a boat — the default 5-minute cache TTL keeps cold-starting. Bump it:

```jsonc
// long cache retention → 1h TTL
{ "cacheRetention": "long" }
```

One version caveat: OpenClaw is careful to order the stable context files ahead of the churny heartbeat file so heartbeat updates don't bust the cached prefix — but older builds had a cache-busting bug where a per-message value landed *inside* the cached block and re-wrote the whole prefix every turn. If your "cached" reads look like full-price writes, check your version. See the [prompt-caching docs](https://docs.openclaw.ai/reference/prompt-caching).

## Bonus — a watch that stays quiet

Once the agent can read SignalK, a natural next step is a scheduled check that only speaks when something's wrong. OpenClaw's cron supports a deterministic `--trigger-script` gate: the script inspects SignalK (any non-`normal` notification, or a battery/depth/tank threshold), returns `{ fire, message?, state? }`, and the agent only composes a Telegram heads-up when `fire` is true — de-duped on `state` so it alerts on *change*, not every tick. A watch that's silent when all's well. That's its own post; the [cron docs](https://docs.openclaw.ai/automation/cron-jobs) have the shape.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran, where "what's our depth?" should be a Telegram DM away and the standing prompt cheap enough to leave running on a Pi. If you're standing this up yourself, the two references worth bookmarking are the [OpenClaw docs](https://docs.openclaw.ai) and [signalk.org](https://signalk.org) — the rest is the six lines of gotchas above.
{% endraw %}

*Related: [Why your agent ignores its skill body but obeys the system prompt]({% post_url 2026-06-11-agent-skill-body-vs-base-system-prompt-always-on-conditional-deploy %}) — the always-on-vs-conditional split behind tuning finding 1; and [Why we kept named MCP tools despite a 96% token saving]({% post_url 2026-06-06-signalk-mcp-named-tools-vs-execute-code-token-efficiency-voice-agent %}) — the tokens-vs-reliability tradeoff for boat agents.*
