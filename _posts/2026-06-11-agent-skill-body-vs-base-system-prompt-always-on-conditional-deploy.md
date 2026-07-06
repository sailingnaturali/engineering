---
layout: post
title: "Why your agent ignores its skill body but obeys the system prompt"
description: "An AI agent kept calling things by the wrong name even after we fixed the skill prompt and confirmed the runtime SKILL.md was correct. The request dump proved the skill body wasn't even in the prompt for most queries — only the always-on base persona was. Two lessons: put always-on invariants in the always-on layer, and give every runtime prompt artifact a deploy step or it drifts from your repo."
date: 2026-06-11
tags:
  - ai
  - agents
  - skills
  - selfhosted
  - prompt-engineering
  - llm
---

{% raw %}
You edit a skill's prompt to fix a behaviour. You confirm the change is in the file the runtime loads. You restart. The agent does the old thing anyway. Not *sometimes* — reliably, for most queries.

The instinct is to edit the prompt harder. The actual problem was that the prompt you edited wasn't in the request at all. On a skill/agent framework with a base system prompt plus conditionally-loaded skill bodies, **a lot of your "prompt" only loads when a skill triggers** — and if the rule needs to hold on *every* query, it has to live in the always-on layer instead. The second half of the same bug: the always-on file had no deploy step, so the running copy had silently drifted from the repo.

This is framework-general. We hit it on a local [Hermes](https://github.com/NousResearch/Hermes) agent, but the same shape applies to anything with the now-common base-prompt-plus-`SKILL.md` split — [Claude Agent Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview), [Gemini CLI skills](https://geminicli.com/docs/cli/skills/), VS Code agent skills, and others.

## Problem

Our agent stack has a shared persona (`SOUL.md`) and per-agent skills (Navigator, Engineer, Logbook). The persona names the vessel and sets the voice; each skill layers on its own job. We changed the vessel name in the Navigator skill body, deployed it, confirmed the runtime file on disk:

```bash
$ grep -n "VESSEL_NAME_HERE\|aboard" ~/.hermes/skills/naturali/navigator/SKILL.md
1:Navigator agent aboard s/v Naturali.
```

Correct name, correct file, correct path. Restart. Then ask it a plain question:

```
> how's our depth?
Aboard s/v Wrongboat, depth is 8.2 metres below the keel, Captain.
```

Still the old name. The file the runtime loads says the right thing. The agent says the wrong thing. Editing the skill body again — any number of times — changed nothing for this query.

## Diagnosis

Stop theorising about what the model "should" see and look at what it *actually* received. Hermes writes a full request dump per call; most frameworks have an equivalent (a debug log, `--print-prompt`, a proxy capture). Dump the request and grep it:

```bash
$ ls -t ~/.hermes/sessions/request_dump_*.json | head -1
/Users/me/.hermes/sessions/request_dump_1733270400.json

$ grep -o "ship's computer" ~/.hermes/sessions/request_dump_*.json | tail -1
ship's computer            # <-- base persona text IS present

$ grep -o "Navigator agent aboard" ~/.hermes/sessions/request_dump_*.json | tail -1
                           # <-- nothing. the skill body is NOT in the prompt
```

There it is. For a plain `"how's our depth?"`, the **base persona was in the prompt and the Navigator skill body was not.** The query didn't activate the Navigator skill, so its `SKILL.md` body never got loaded — and the vessel name we'd been so carefully editing lived only in that body.

This is exactly the [progressive disclosure](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) model these frameworks are built on, stated plainly in Anthropic's own Agent Skills docs:

> **Level 1: Metadata (always loaded)** ... Claude loads this metadata at startup and includes it in the system prompt.
> **Level 2: Instructions (loaded when triggered)** ... When you request something that matches a Skill's description, Claude reads SKILL.md from the filesystem. Only then does this content enter the context window.

So a skill's `name`/`description` is always in context (that's how the model knows the skill exists), but the **body** — your actual instructions — only loads when that skill fires. The base system prompt, by contrast, is on every single request. If an instruction must always apply, it belongs in the always-on layer. Vessel identity is an always-apply rule. It was in the wrong layer.

The wrong name was the *symptom* that exposed this, but the principle generalises to every always-on invariant: identity, time/units discipline, and anti-fabrication rules all silently fail to apply on any query that doesn't trigger the skill that contained them.

## What we tried (and why it failed)

### Attempt 1 — edit the skill body and redeploy

```bash
# fixed the name in the skill source, redeployed
$ scripts/deploy-navigator.sh
deploy-navigator: wrote ~/.hermes/skills/naturali/navigator/SKILL.md (vessel: Naturali)
```

```
> how's our depth?
Aboard s/v Wrongboat, depth is 8.2 metres below the keel, Captain.
```

No change. The file is right; the query just never loads it. You can edit a conditionally-loaded body forever and it will never affect a query that doesn't trigger the skill.

### Attempt 2 — assume the file didn't deploy and re-check the disk

```bash
$ cat ~/.hermes/skills/naturali/navigator/SKILL.md | head -1
Navigator agent aboard s/v Naturali.
```

The runtime file was correct the whole time. This rules out a deploy failure and is the moment that *should* have redirected us to "is this file even being loaded?" instead of "is this file correct?" — two very different questions. We'd been answering the wrong one.

### Attempt 3 — add the identity rule to the skill body harder

We considered duplicating the name/identity statement into every skill body so at least the loaded skill would carry it. That "works" only for queries that trigger *a* skill, leaves bare/social/ambiguous queries (which trigger none) still wrong, and creates N copies of an invariant to keep in sync — the classic drift trap. It treats the symptom. The rule isn't per-skill; it's always-on. It belongs in the one prompt that's always-on.

## The fix

Move always-on invariants into the always-on layer (the base persona), and template the vessel name so nothing is hardcoded:

```markdown
<!-- SOUL.md — the base persona, loaded on EVERY request -->
You are the ship's computer aboard s/v {{VESSEL_NAME}}.
You address the user as "Captain."
Never speak a raw UTC timestamp in conversation.
Report a reading and its source path; never narrate whether data is
"live," from a "mock," or whether the vessel is "ashore" — you aren't
given that and must not guess it.
```

Then give that file a real deploy step — substituting the name from one source of truth — instead of hand-placing it once:

```bash
# scripts/deploy-soul.sh
vessel_name="$(resolve_vessel_name "$repo_root")"   # reads the active vessel profile
sed "s|{{VESSEL_NAME}}|$vessel_name|g" "$repo_root/SOUL.md" > "$HERMES_HOME/SOUL.md"
```

```
> how's our depth?
Aboard s/v Naturali, depth is 8.2 metres below the keel, Captain.
```

Right name, on a query that triggers no skill — because the identity now rides on the always-on persona, not a conditional body.

The skill body keeps only what's genuinely conditional — operational hints that are *fine* to load only when the skill fires:

```markdown
<!-- skills/navigator/body.md — loaded only when Navigator triggers -->
For "how's our depth?", read environment.depth.belowKeel, not belowTransducer.
```

## Why it matters / gotchas

**Sort every prompt rule into always-on vs conditional, and place it accordingly.** Ask one question of each rule: *does this need to hold on a query that triggers no skill?* If yes, it goes in the base prompt (or, for data-shape rules, the deterministic tool layer — but that's [another post](/ha-2026.5-hassil-3-wildcard-voice-routing-missinglisterror/)). If it's only relevant inside a task, the skill body is the right, token-cheap home. Identity, safety, units, and anti-fabrication rules are almost always the former.

**Dump the request before you touch a prompt.** "The prompt says X but the agent does Y" has two failure modes that look identical from the outside: the prompt is wrong, or the prompt isn't loaded. Only the request dump tells them apart. We burned two debug cycles editing a file that was never in the request. One `grep` of the dumped prompt would have caught it immediately.

**Every runtime prompt artifact needs a deploy step, or it rots.** The second half of this bug: our `~/.hermes/SOUL.md` had been hand-placed once, months earlier, and named a since-renamed boat. Only the *skill* had a deploy script, so only the skill tracked the repo. A prompt file you copy into place by hand has no mechanism to tell you it diverged — it silently runs stale. We fixed it by giving `SOUL.md` the same treatment the skill already had:

```bash
# .git/hooks/pre-commit — redeploy whatever source changed
if echo "$changed" | grep -Eq '^(SOUL\.md$|scripts/(deploy-soul|vessel-name)\.sh$)'; then
  scripts/deploy-soul.sh    # base persona redeployed on every relevant commit
fi
if echo "$changed" | grep -Eq '^skills/navigator/'; then
  scripts/deploy-navigator.sh
fi
```

Now a commit that edits either source redeploys it. The runtime can't drift from the repo without a commit saying so.

**One source of truth for shared values.** The vessel name resolves from the active vessel profile — the same profile that seeds the data-layer base values — so the boat is named identically in the data model and in the persona, and switching boats needs zero prompt edits. Don't hardcode a value that appears in two layers; template both from one resolver. A hardcoded value in two places is a drift waiting to happen.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran — a local LLM with a shared persona and per-job skills over a marine data bus — where the agent had better call the boat by its actual name, on every query, not just navigation ones. The agent skills and deploy scripts are open source: [github.com/sailingnaturali/naturali-agents](https://github.com/sailingnaturali/naturali-agents).
{% endraw %}
