---
layout: post
title: "plugins.allow is exclusive: the warning's suggested fix disabled 44 plugins"
description: "OpenClaw logs 'plugins.allow is empty; discovered non-bundled plugins may auto-load' every turn and suggests a one-entry allowlist. Taking the suggestion on a live gateway collapsed enabled plugins from 47 to 3, because plugins.allow is an exclusive allowlist over all plugins including the ~46 bundled ones — killing the fallback model provider and bundle-mcp, the MCP bridge. Plus the activation asymmetry (naming a channel rescues its plugin, naming an mcp.servers entry does not), and why the fix was a 30-line comment recording the decision to ignore the warning."
date: 2026-08-11
tags:
  - openclaw
  - plugins
  - config
  - agents
  - mcp
  - ai
  - selfhosted
  - llm
  - marine
---

> A config warning told me, every single turn, that `plugins.allow` was empty — and helpfully printed the one-line fix. I pasted it onto the live box. Enabled plugins went **47 → 3**, because `plugins.allow` is an *exclusive* allowlist over **all** plugins, including the ~46 that ship bundled. The two that mattered were the fallback model provider and `bundle-mcp`, the plugin every MCP tool hangs off. Reverted in a minute. The durable fix wasn't code — it was a comment in the config recording *why* the warning stays unfixed. [Jump to the fix](#the-fix).

![Taking the warning's suggested one-entry plugins.allow list collapsed enabled plugins from 47 to 3, and the two casualties that mattered were the fallback model provider and the MCP bridge.](/assets/img/2026-08-11-plugins-allow-exclusive-allowlist-config-warning-suggested-fix-breaks-production-disables-bundled-plugins-openclaw-mcp-bridge-fallback-provider/enabled-plugins-before-after.svg)

The setup: [OpenClaw](https://docs.openclaw.ai) running as an agent gateway on a Raspberry Pi next to a [SignalK](https://signalk.org) server, so I can DM a boat and ask it how much water is under the keel. I wrote up [that build]({% post_url 2026-07-29-openclaw-raspberry-pi-signalk-boat-agent-gateway-mode-local-si-units-tools-profile-prompt-caching %}) already. This post is about one line of its log output.

## The problem: a warning with a fix attached

Every turn, the gateway logged this:

```text
plugins.allow is empty; discovered non-bundled plugins may auto-load: deepseek
```

That string is [documented behaviour](https://docs.openclaw.ai/tools/plugin): "When `plugins.allow` is unset and non-bundled plugins are auto-discovered from the workspace or global plugin roots, startup logs `plugins.allow is empty; discovered non-bundled plugins may auto-load: ...`".

It's a reasonable warning. Without an allowlist, a plugin that appears in a discovery root gets loaded without anyone approving it. And the fix looks trivial — there is exactly one non-bundled plugin on the box, `deepseek`, the provider for the primary model. So: allow it, and nothing else can sneak in.

```json
{
  "plugins": {
    "allow": ["deepseek"]
  }
}
```

One key. One value. The thing the warning is asking for. I put it on the live gateway.

## What it actually did

```console
$ openclaw plugins list --enabled | wc -l
3
```

Three. It had been 47, out of 68 discovered.

The agent still answered on Telegram, cheerfully, in a way that made it look fine. Ask it for the depth and it no longer had a depth tool.

## Diagnosis: "allow" is exclusive over *everything*

The mental model I had — and I suspect it's the common one — is that an allowlist governs the *untrusted* things: the plugins that show up from outside, the ones the warning is literally about. Bundled plugins ship with the product; you don't allowlist your own dependencies.

That is not what the key means. From the [plugin docs](https://docs.openclaw.ai/tools/plugin):

> `plugins.allow` is an exclusive allowlist. Plugin-owned tools outside the allowlist stay unavailable even when `tools.allow` includes `"*"`.

"Exclusive" is the whole story, and it's exclusive over the *entire* inventory. The docs say so in the places where it bites a specific feature rather than in the place where you'd go looking. On [ACP agents](https://docs.openclaw.ai/tools/acp-agents):

> If `plugins.allow` is set, it is a restrictive plugin inventory and **must** include `acpx`, or the installed ACP backend is intentionally blocked

And in the Codex setup notes: enable the bundled `codex` plugin first, *and* include `codex` in `plugins.allow` if your config uses a restrictive allowlist. Both of those are bundled plugins. Both need to be in the list.

So `"allow": ["deepseek"]` doesn't mean "of the discovered plugins, permit deepseek." It means **"the set of plugins on this system is: deepseek."** Everything else is out, including 46 things I never chose to install and never thought of as plugins at all — because they arrived as part of the product.

The warning wasn't wrong. The suggestion was a correct fix for a narrower config than mine.

### The asymmetry that makes it survivable — and confusing

Three plugins survived, not one. `deepseek`, because I allowed it. And then `telegram` and `memory-core`, which I hadn't.

They survived because of an escape hatch the docs call auto-activation:

> Bundled opt-in plugins can auto-activate when config names one of their owned surfaces, such as a provider/model ref, channel config, CLI backend, or agent harness runtime.

My config has a `channels.telegram` block, so the telegram plugin came back on its own. The [browser plugin docs](https://docs.openclaw.ai/tools/browser) state the same rule explicitly and confirm it beats the allowlist: an explicit root `browser` block "activates the bundled browser plugin even under a restrictive `plugins.allow`".

Now read that list of owned surfaces again — provider refs, channel config, CLI backends, agent harness runtimes. **MCP servers are not on it.**

![Under a restrictive allowlist, naming a chat channel in config auto-activates its plugin, but naming an MCP server does not auto-activate the MCP bridge plugin, so every MCP tool disappears.](/assets/img/2026-08-11-plugins-allow-exclusive-allowlist-config-warning-suggested-fix-breaks-production-disables-bundled-plugins-openclaw-mcp-bridge-fallback-provider/activation-asymmetry.svg)

My config names both of these:

```json
{
  "channels": {
    "telegram": { "enabled": true }
  },
  "mcp": {
    "servers": {
      "signalk": { "command": "uvx", "args": ["signalk-mcp"] }
    }
  }
}
```

Naming the channel rescued its plugin from the allowlist. Naming the MCP server did not rescue `bundle-mcp` — the bundled plugin that exposes MCP server tools to the model. The MCP servers still launched. They still connected. They still passed their health probes. Their tools were simply not in the request. The [MCP configuration page](https://docs.openclaw.ai/tools/mcp) never mentions that a plugin is in that path at all, which is exactly why you don't think to check it.

The two lanes fail differently, and that's the trap: the lane that keeps working is the one you'd *notice* — messages still arrive, the agent still talks. The lane that goes dark is the one you have to go looking for.

### What the two casualties actually cost

`bundle-mcp` was the visible one. The other was worse and would have been invisible for months:

- **`anthropic-provider`** — the fallback model. The gateway runs a primary provider with a second one configured behind it precisely so that a provider outage or a lapsed key *degrades* instead of leaving the boat with no agent. With the allowlist on, the fallback plugin is not loaded. There is no fallback. Nothing tells you this; you find out the next time the primary is down, which is the worst possible moment and also the only moment it matters.
- **`bundle-mcp`** — every tool from every MCP server. The agent goes blind to the vessel and answers from general knowledge instead, which reads as fluent and is exactly as useful as it sounds.

A resilience feature that silently stops being loaded is worse than never having configured it, because you stop budgeting for the failure it was supposed to absorb.

## What I tried, and why each was wrong

**1. The suggested one-entry list.** Above. 47 → 3.

**2. "Fine — I'll list the ones I actually use."**

```json
{
  "plugins": {
    "allow": ["deepseek", "anthropic-provider", "bundle-mcp", "telegram", "memory-core"]
  }
}
```

This is the seductive one, and it's a trap with a delay fuse. It fixes today's breakage and leaves ~42 bundled plugins off. Some of those are load-bearing in ways that don't show up in a smoke test — they're the ones behind a feature you use twice a year. Worse, the list is now a snapshot: the next OpenClaw upgrade that adds or renames a bundled plugin ships it into a gateway that is configured to refuse it, and the failure surfaces as "that feature just doesn't work anymore" with no error and no obvious link to a config file you last touched in August.

**3. "Then enumerate all of them."** Read `openclaw plugins list`, paste all ~46 bundled ids plus the one real one, done:

```console
$ openclaw plugins list --json | jq -r '.[].id' | wc -l
68
```

Correct, and I'd have to re-audit that list on every upgrade forever. That's a standing maintenance tax to close a hole I hadn't yet measured. So I measured it.

**4. Actually reading what the warning protects against.** The risk is: a plugin lands in a discovery root and auto-loads without approval. Discovery reads configured paths, workspace roots, the global plugin root under `~/.openclaw`, and the bundled set. On this box, the only thing that ever writes a non-bundled plugin into the global root is `openclaw plugins install` — which is already a privileged, deliberate act by someone with a shell on the machine. Someone who can run that can also edit the allowlist. The allowlist is not a boundary against them.

So the hole is real, and on this deployment it is one notch of defence-in-depth behind an act that already implies full control of the host. The cost of closing it is a hand-maintained 47-line inventory re-audited on every upgrade. That trade doesn't clear.

## The fix

Don't set the key. Write down *why*.

```jsonc
// Plugin policy. `plugins.allow` is deliberately ABSENT — do not add it.
//
// Every turn logs:
//   plugins.allow is empty; discovered non-bundled plugins may auto-load: <id>
// and suggests `"plugins": { "allow": ["<id>"] }`. That suggestion breaks
// this gateway. Tried on the live box 2026-08-10: allow is an EXCLUSIVE
// allowlist over ALL plugins, including the ~46 bundled ones. Enabled
// collapsed 47 -> 3. Survivors: the one allowed id, plus telegram and
// memory-core, which auto-activate because config names a surface they own.
//
// What it costs if anyone tries it again:
//   anthropic-provider  the fallback model — a primary outage now leaves
//                       no agent at all, and nothing warns you
//   bundle-mcp          every MCP tool — the agent goes blind to the vessel
//
// Note the asymmetry: naming `channels.telegram` auto-activates telegram,
// but naming `mcp.servers.<name>` does NOT auto-activate bundle-mcp.
//
// The hole the warning points at is real but small: discovery only picks up
// non-bundled plugins from the global root, which nothing writes to except
// `openclaw plugins install` — already a privileged act. Closing it properly
// means listing all ~46 bundled ids and re-auditing them every upgrade.
// Not worth it. Living with the warning is the considered choice.
```

That comment is the actual deliverable. The code change was deleting three lines.

And the one-command check, before and after any plugin-policy edit:

```console
$ openclaw plugins list --enabled | wc -l
47
```

If that number moves and you didn't intend it to, stop. It's the cheapest possible canary for a class of change whose failure mode is silence.

## Why it matters

**An allowlist that includes the batteries is a different feature than one that doesn't.** Before you set one, find out whether it governs the things that arrived *from outside* or the things that arrived *in the box*. "Exclusive" is doing enormous work in that sentence, and the difference between the two readings is the difference between a two-item list and a 47-item one. The fastest way to find out is to count enabled units before and after on something you can revert in a minute — not to reason about it from the key name.

**Suggested fixes in warnings are written for the median config.** A warning that prints a ready-to-paste snippet is a genuinely good affordance, and the snippet was right for a gateway whose plugin inventory is small. Mine isn't. A one-line remediation is a hypothesis about your setup, not a patch.

**The generalizable one: record why you ignored the linter.** Every long-lived system accumulates warnings that are correct in the abstract and wrong to act on here. If the only artifact of "we looked into this and decided to live with it" is a chat log, then the decision has a half-life of about a month — after which someone (possibly you, possibly an agent with config-write tools) sees a helpful suggestion in a log, applies it, and re-discovers the outage from first principles. Suppressing the warning would have been worse: it hides the tradeoff instead of documenting it. A comment at the exact place someone would make the change is the cheapest durable defence there is. Mine is 30 lines guarding a key that isn't there.

There's a marine version of the same lesson: a persistent alarm nobody can explain gets muted, and then the one that mattered gets muted with it — [alarm fatigue by design]({% post_url 2026-07-11-nmea-2000-paradox-alarm-fatigue-signalk-open-source-severity-notifications-plain-language-voice-alerts-vendor-lock-in %}). The software version is quieter and the failure is the same shape.

## The bit that should worry you

Nothing errored. The gateway started clean, the agent replied on the channel it always replies on, and the only symptom of losing 44 plugins was an answer that didn't have any vessel data behind it. Two of the three things that survived survived *by accident* — because their config keys happened to be on the auto-activation list.

I caught it in a minute because I ran the count. If I'd just sent one test message, I'd have shipped a gateway with no model fallback and no vessel access and called the warning fixed.

The gateway watches an all-electric charter catamaran that doesn't exist yet; the MCP server it went blind to is [`signalk-mcp`](https://github.com/sailingnaturali/signalk-mcp) (MIT).

*Related: [Running OpenClaw on a Raspberry Pi alongside SignalK]({% post_url 2026-07-29-openclaw-raspberry-pi-signalk-boat-agent-gateway-mode-local-si-units-tools-profile-prompt-caching %}) — the build this config belongs to, including the `tools.profile` gotcha that hides MCP tools a second, unrelated way; [When MCP tools break, isolate the server before blaming the agent]({% post_url 2026-06-23-mcp-tools-not-showing-up-isolate-the-server-before-blaming-the-agent %}) — the debugging order for exactly this symptom; and [MCP server or a curl recipe in AGENTS.md?]({% post_url 2026-08-02-do-i-need-an-mcp-server-vs-agents-md-curl-recipe-mcp-vs-cli-tool-schema-token-cost-breakeven %}) — what those MCP tools were costing and earning in the first place.*
