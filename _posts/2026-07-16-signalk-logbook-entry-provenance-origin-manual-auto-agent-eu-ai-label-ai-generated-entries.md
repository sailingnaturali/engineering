---
layout: post
title: "When AI agents write the ship's log, record who wrote what"
description: "Three writers share one YAML logbook: humans, vessel automation, and an AI voice agent. We added an origin field — manual | auto | agent — to signalk-logbook (0.11.0), with the EU's recommended AI-transparency label on agent-written entries, author-convention heuristics for legacy archives, delegated author on POST /logs, and a spoken 'Logged as…' attribution flow with a voice-correction path."
date: 2026-07-16
tags:
  - ai
  - agents
  - signalk
  - mcp
  - open-source
  - provenance
  - voice-assistant
---

> **TL;DR** — When humans, vessel automation, and an AI agent all write the
> same logbook, you need per-entry provenance. We added an optional
> `origin: manual | auto | agent` field upstream in
> [signalk-logbook](https://github.com/meri-imperiumi/signalk-logbook)
> ([PR #88](https://github.com/meri-imperiumi/signalk-logbook/pull/88),
> released in 0.11.0), made consumers derive it from author conventions for
> legacy entries, and put the EU's recommended AI label on agent-written
> lines. [Jump to the design](#the-design).

Our ship's log has three kinds of writers. A human types (or dictates) a
line. The logbook plugin itself writes unattended entries — hourly underway
logs, notification state changes, crew changes. And our voice agent writes
entries through the REST API: "log this moment", drill summaries, distress
receptions. All three land in the same per-day YAML files.

The question this post answers: **six months from now, reading a day back,
how do you know which lines a human actually wrote?**

## Problem

Here's a day file from our archive before this work. Three entries, three
different writers — and the only provenance is accidental:

```yaml
- datetime: '2026-06-11T08:01:00.000Z'
  text: 'Motoring at 6.1kt'
  author: ''                    # plugin's own hourly writer
- datetime: '2026-06-11T09:14:00.000Z'
  text: 'MOB drill completed, 4 min recovery [drill:mob]'
  author: 'hermes'              # the agent's API token principal
- datetime: '2026-06-11T10:02:00.000Z'
  text: 'Sail change, reefed main'
  author: 'bryan'               # a person, via the web UI
```

The empty author means "the plugin wrote it" only because the plugin's
unattended writers happen to call `stateToEntry(state, text)` without an
author. The agent entries say `hermes` only because that's the name on the
authentication token the MCP server holds. Nothing in the data model says
*this line was composed by an AI*. Readers — agents summarizing a passage,
a morning briefing, a human reviewing the log — cannot reliably tell a
human-authored line from machine output.

That used to be a nice-to-have. It increasingly isn't: agent-written records
need labeling. The EU has published
[recommended icons for labelling AI-generated content](https://digital-strategy.ec.europa.eu/en/policies/eu-icons-labelling-ai-generated-content),
and a logbook is exactly the kind of record where "who wrote this" matters
for trust and for corrections.

## Designs we rejected

**Overloading `author`.** Stuffing provenance into the author string
(`author: "bryan (via agent)"`) destroys the one clean signal the archive
already has, and every consumer grows a parser.

**A structured `source` object.** `source: {kind: agent, model: …,
version: …}` is the flexible version nobody asked for. One enum answers the
actual question; a nested object is schema surface you maintain forever.

**Asking the speaker to identify themselves.** For voice entries, "who is
this?" before every log line is terrible ergonomics, and our STT stack
(Whisper) has no speaker recognition anyway. Assume-and-confirm beats
interrogate (more below).

## The design

One optional enum, and a sharp rule for what it means:

> **`author` = who is responsible. `origin` = who composed the words.**

This is the watchkeeper model from paper logbooks: the officer on watch
signs the page even when the instruments took the reading. Responsibility
and authorship are different columns.

- `manual` — a person composed the text. Typed *or dictated*: a
  voice-dictated line is `manual`, because the voice pipeline is just the
  pen.
- `agent` — an AI composed the text (drill summaries, `mark_moment`
  phrasings).
- `auto` — unattended machinery (hourly logs, notification triggers).

The dictation point is the subtle one. If you classify by *transport*
(API-written = machine), every voice entry becomes machine output and the
label loses its meaning. Classify by *who chose the words*.

### Forward-compatible rollout

The archive had 72 entries and zero explicit provenance. We refused to
migrate files, and we didn't want to block on the upstream release either.
So the rollout is two-sided:

1. **Writers stamp `origin` now.** Our MCP server started sending
   `origin: "agent"` in POST bodies before upstream knew the field existed —
   the server's field whitelist silently dropped it, a harmless no-op. The
   day the upstream release landed on the boat server, the stamps became
   effective. No coordination needed.
2. **Consumers derive `origin` for legacy entries** from the author
   conventions the archive already encodes. Explicit field wins when
   present; heuristics fill the past.

## Upstream: PR #88

[PR #88](https://github.com/meri-imperiumi/signalk-logbook/pull/88) (merged,
released in signalk-logbook 0.11.0) adds the field end to end. The core is
one parameter:

```js
// plugin/format.js
module.exports = function stateToEntry(state, text, author = '', origin = 'manual') {
  const data = {
    datetime: state['navigation.datetime'] || new Date().toISOString(),
    text,
    author,
    origin,
  };
  // …
```

The unattended writers — notification entries, trigger entries (autopilot,
crew, sail changes), the hourly underway log — pass `origin: 'auto'`.
`POST /logs` accepts both `author` and `origin` in the body:

```js
// plugin/entryFields.js
if (typeof body.author === 'string' && body.author.length >= 1) {
  // Delegation: an authenticated client (voice assistant, crew app) writes
  // the line on behalf of the person who authored it.
  entry.author = body.author;
}
if (['manual', 'auto', 'agent'].includes(body.origin)) {
  entry.origin = body.origin;
}
```

The `author` half matters as much as the `origin` half: it lets an
authenticated client write a line *on someone's behalf* and sign it for
them. `PUT` already honored a body-supplied author; this made `POST`
consistent. Invalid origins are ignored rather than erroring — an optional
provenance field should never bounce a log entry.

Two improvements came out of review with the maintainer:

**Legacy entries get a definite origin at read time.** Rather than making
every consumer handle "field absent", the plugin defaults it when reading —
same pattern as its read-time `category` default:

```js
// plugin/Log.js — reading a stored day file
origin: entry.origin || (entry.author ? 'manual' : 'auto'),
```

Stored origins are preserved; authorless legacy entries read as `auto`
(they were the plugin's own), authored ones as `manual`. Consumers always
see a definite value.

**Agent entries get the EU AI label in the UI.** The maintainer pointed at
the [EU's AI-content labelling icons](https://digital-strategy.ec.europa.eu/en/policies/eu-icons-labelling-ai-generated-content);
the badge renders next to the author on `agent` entries in the logbook
table, timeline, and entry viewer:

```jsx
// src/components/OriginBadge.jsx
function OriginBadge(props) {
  if (props.origin !== 'agent') {
    return null;
  }
  return (
    <svg role="img" aria-label="AI-generated entry" /* inlined EU "AI" icon */>
      <title>AI-generated entry</title>
      {/* … */}
    </svg>
  );
}
```

The tooltip text is deliberate — the EU's own testing found icon + text
label beats the icon alone. `manual` and `auto` entries render untouched:
the label marks AI output, it doesn't decorate everything.

A companion PR,
[#92](https://github.com/meri-imperiumi/signalk-logbook/pull/92), rounds out
the responsibility side: it snapshots `communication.skipperName` into every
entry next to the existing `crewNames`, and logs skipper handoffs
automatically. With authorship (`origin`), responsibility (`author`), and
command (`skipperName`) each in their own field, you can derive things like
skipper-vs-crew days for sea-service records straight from the log.

## Consumer side: deriving origin in the MCP server

[logbook-mcp](https://github.com/sailingnaturali/logbook-mcp) is the tool
surface our agents use. Its read path implements the legacy heuristic —
explicit field first, then author conventions:

```python
def derive_origin(
    entry: dict,
    agent_authors: frozenset[str] = DEFAULT_AGENT_AUTHORS,   # {"hermes", "poseidon"}
    auto_authors: frozenset[str] = frozenset(),
) -> str:
    origin = entry.get("origin")
    if origin in ORIGINS:
        return origin            # explicit field wins (post-upstream entries)
    author = entry.get("author") or ""
    if not author:
        return "auto"            # the plugin's own unattended writers
    if author in agent_authors:
        return "agent"           # a known agent token principal
    if author in auto_authors:
        return "auto"            # a known automation token principal
    return "manual"              # any other author is a person
```

The principal lists are configuration, because they're deployment facts:
*your* agent tokens have *your* names. Every entry returned by
`read_entries` carries a derived `origin`, and the tool grew an `origin`
filter so "show me only the human entries from Tuesday" is one call.

The write path stamps by composition, per the manual-vs-agent rule:

```python
# mark_moment: default origin="agent" — the agent composed the phrasing.
# A dictated line passes origin="manual" — the human composed it.
await client.post_entry(text, category=category, origin=origin)
```

And [signalk-distress-core](https://github.com/sailingnaturali/signalk-distress-core)
— the shared library behind our DSC and AIS-distress plugins, which writes
received distress traffic into the logbook — stamps `auto`:

```js
// lib/logbook.js — a DSC reception is a plugin-automatic reaction,
// not agent reasoning. Ignored by signalk-logbook until its
// origin-field PR ships, then explicit.
origin: 'auto',
```

That last classification is worth pausing on. The distress writer runs
inside an "AI stack", but no model composes those lines — a parser does.
`origin` describes the composer, not the vibe of the system it lives in.

## Voice attribution: assume, confirm, correct

The `author` delegation in POST unlocked the piece users actually feel.
When someone dictates a log entry, the stack has no speaker ID — so the
agent *assumes* the author (the person on watch; solo default today) and
says the assumption out loud. `mark_moment`'s return value is a
ready-to-speak confirmation that ends with the attribution:

```text
Logged. Entry 4. 14:32. 48.76°N 123.2°W. Logged as Bryan.
```

If the assumption is wrong, the speaker just says so, and the correction
path is its own tool:

```python
async def amend_entry_author(client, entry_id: str, author: str) -> dict:
    """Reattribute an existing entry — the voice-correction path."""
    # fetch the day, find the entry, PUT it back with the corrected author
    ...
    return {
        "id": entry_id,
        "author": author,
        "confirmation": f"Corrected. Entry now logged as {author}.",
    }
```

"No, that was Sarah" → `amend_entry_author` → "Corrected. Entry now logged
as Sarah." Assume-and-confirm costs one spoken clause; interrogating the
speaker before every entry would cost the feature.

One implementation wrinkle: at the time we shipped this, upstream `POST`
couldn't set `author` yet (only `PUT` honored it), so `mark_moment` POSTs
the entry and then PUTs it back with the body-supplied author. That
two-step still works against older servers — same forward-compatibility
posture as the origin stamps.

## Why it matters / gotchas

- **Provenance you don't record at write time is provenance you reconstruct
  forever.** Our 72-entry archive is small enough that author heuristics
  recover it. At 10,000 entries with rotated token names, it wouldn't be.
  Writers stamp going forward; heuristics are strictly for the past.
- **Classify by composer, not transport.** API-written ≠ machine-written
  (dictation), and inside-an-AI-stack ≠ AI-composed (the DSC parser). Get
  this wrong and the AI label becomes noise.
- **Absent optional fields should default at read time, in one place.** The
  read-time default (`entry.origin || (entry.author ? 'manual' : 'auto')`)
  means no consumer ever branches on "field missing". Cheap in the plugin,
  expensive everywhere else.
- **Ship writers before the schema lands.** A field the server's whitelist
  drops is a free forward-compatibility bet: harmless today, effective the
  day the upstream release deploys — with no lockstep upgrade.
- **Labeling agent output is becoming table stakes.** The EU publishes
  ready-made icons for exactly this; wiring one into a hobby-scale marine
  plugin took ~30 lines. If your agents write records humans later trust,
  there's little excuse not to.

We run this stack on the boat-agent system behind an all-electric charter
catamaran project — the ship's log is on the ship, and now it tells you who
held the pen. The MCP side lives at
[sailingnaturali/logbook-mcp](https://github.com/sailingnaturali/logbook-mcp).

*Related: how the logbook ended up on the SignalK server in the first
place — [Adopt vs build: why we deleted our working logbook for SignalK]({% post_url 2026-06-06-adopt-vs-build-ships-log-signalk-logbook-mcp %}).*
