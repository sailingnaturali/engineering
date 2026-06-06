---
layout: post
title: "API Error 400: Output blocked by content filtering policy — why Claude won't transcribe your PDF, and what to do instead"
description: "Asking Claude to transcribe a document verbatim (PDF to markdown) gets hard-blocked by Anthropic's output-side anti-regurgitation filter: 'API Error: 400 Output blocked by content filtering policy'. It is license-blind — public-domain US-government text trips it exactly like copyrighted prose — and retrying never works because the task shape is the trigger. The fix: stop routing source text through model output. Have Claude write a deterministic parser, and let the parser write the files. With receipts from building an open-source navigation-rules vault."
tags:
  - ai
  - claude
  - anthropic
  - llm
  - mcp
  - python
date: 2026-06-06
canonical: "https://engineering.sailingnaturali.com/output-blocked-by-content-filtering-policy-verbatim-transcription-deterministic-extraction/"
---

We needed a public, machine-readable vault of the navigation rules of the road — COLREGS rule text — to back an MCP server for a boat agent. The obvious plan: hand Claude the USCG *Navigation Rules and Regulations Handbook* PDF and ask it to transcribe each rule into a clean markdown file. The text is a US Government work in the public domain. Free to copy, free to redistribute.

Claude read the whole PDF, started writing, and then the Anthropic API hard-blocked it:

```
API Error: 400 Output blocked by content filtering policy
```

It blocked again. And again. Eleven blocked responses across two sessions before we gave up on transcription entirely. This post is the dead-end in full — the attempts, the repeating error, and the fix that turned out to be the better architecture anyway: **don't route source text through model output. Have the model write a parser, and let the parser write the files.**

## Problem

The symptom is a `400` from the Messages API mid-task, surfaced by whatever's driving the model (Claude Code, an SDK call, an agent loop) as:

```
API Error: 400 Output blocked by content filtering policy
```

It fires *late* — after the model has read the source document and started emitting. The read succeeds. The generation is what dies. And it is sticky: once your task is "read this document and write out its text," every subsequent response in the session tends to get blocked too, including replies that contain no document text at all.

This is not a rate limit, not a context-length error, not a malformed request. It's an **output-side classifier**. Anthropic documents it plainly in their privacy center:

> Claude's purpose is to generate new content and ideas, not to reproduce content that already exists.

It's an anti-regurgitation guard. It watches the *output* stream for sustained verbatim reproduction of source material and trips when it sees it. Two consequences fall straight out of that design, and both bit us:

1. **It is license-blind.** The classifier can't see provenance or licensing. Public-domain USCG rule text trips it exactly like copyrighted prose would. "But this is legal to copy" is not an argument the filter can hear.
2. **It is API-level, so you can't route around it.** Subagents, different sessions, retries — they all hit the same classifier. The trigger is the *shape of the task* (long verbatim copying into output), not a transient.

You're far from alone if you've hit this. It's a long-running source of false positives in Claude Code — [generating a LICENSE file](https://github.com/anthropics/claude-code/issues/18542), [adding a Mozilla license](https://github.com/anthropics/claude-code/issues/4210), [the Contributor Covenant code of conduct](https://github.com/anthropics/claude-code/issues/60361), [extracting a peer-reviewed paper](https://github.com/anthropics/claude-code/issues/24869), even [benign markdown edits](https://github.com/anthropics/claude-code/issues/41197). The common thread in all of them: the model was about to emit a long span that closely matches existing text.

## Diagnosis

The mental model that unlocks the fix: **the filter cares about your output, not your intent.** It does not matter that the text is public domain. It does not matter that you have the file open in front of you. It does not matter that *you* extracted the text and you're just asking the model to echo it back. If a long verbatim span of pre-existing material flows through the model's output, the classifier can trip.

That last point is the one people miss. We tripped it once when the assistant *merely echoed already-extracted vault text back into chat while summarizing progress*. The text had already been pulled out of the PDF by other means — the model was just quoting it in conversation. Output is output. Where the text came from is invisible to the classifier.

So "transcribe this PDF to markdown" is a near-perfect trigger. It is, by definition, a request to emit a long verbatim span of an existing document. The task and the thing the filter blocks are the same task.

## What we tried (and why it failed)

### Attempt 1 — just transcribe it

Point the model at the PDF, ask for clean markdown per rule. Here's a reconstructed version of the task list it built (the structure is real; the wording is reconstructed, not a verbatim transcript):

```
TODO
[ ] Transcribe Rules 1–13  → rules/international/rule-01.md … rule-13.md
[ ] Transcribe Rules 14–31
[ ] Transcribe Rules 32–38
[ ] Transcribe Annexes I–V  (PDF pages 121–146)
```

It picked up task 1, read the pages, started writing — and:

```
API Error: 400 Output blocked by content filtering policy
```

In one session, 11 rule files landed before the wall went up; the rest were abandoned. In a later, dedicated transcription session it was worse — **six blocked responses, zero files written.** Every single response after it picked up the first task got blocked.

### Attempt 2 — retry

The instinct on a `400` is to retry. So we retried. Same task, fresh response:

```
API Error: 400 Output blocked by content filtering policy
```

Retrying never works here, and now you know why: the trigger is the task shape, not a transient fault. Same input, same classifier, same block. We even asked the model, in plain chat with no document text in the reply, *"are you working, or are we stuck?"* — and **that** got blocked too, because the session was now anchored on a verbatim-reproduction task.

### Attempt 3 — dispatch a subagent

Maybe a fresh subagent with a tighter prompt would behave. We dispatched one whose whole job was authoring rule files. It got two blocks of its own:

```
API Error: 400 Output blocked by content filtering policy
```

The filter is API-level. A subagent is just more Messages API calls — it routes through the exact same classifier. There is no "inner" model that isn't filtered.

The tally across two sessions: **11 blocked responses.** Five on the first day (two of them inside the dispatched subagent, one when the assistant only *echoed* already-extracted text), six on the dedicated retry session with no progress at all. The lesson finally landed: you cannot make this task work by asking more nicely, from a different agent, or one more time. The task itself is the thing being blocked.

## The fix

Stop sending source text through model output. **Have the model write a parser; let the parser write the files.** The model's output is now Python — novel code, which the filter has no quarrel with — and the rule prose flows file-to-file via `pdftotext` and XML parsing, never touching the model's output stream.

For this vault, three deterministic extractors, one orchestrator. Prefer structured authoritative sources over the PDF where they exist — better provenance *and* machine-parseable:

```python
# scripts/build_vault.py — Claude wrote this; it does the extraction, not the model
for part in ECFR_PARTS:                       # 33 CFR 83–88, eCFR versioner API XML
    xml_text = ecfr_path(sources, part).read_text()
    if part == 83:
        docs += ecfr.parse_rules(xml_text, url, retrieved)   # US Inland rules
    else:
        docs.append(ecfr.parse_annex(xml_text, part, url, retrieved))

docs += justice.parse_schedule(justice_xml, retrieved)       # Justice Laws XML → Canadian

pages = handbook.international_pages(
    handbook.split_pages(handbook.run_pdftotext(str(handbook_pdf))))
docs += handbook.parse_international(pages, handbook_pdf.name)  # pdftotext text layer → International
```

The three sources, each chosen to be machine-parseable:

```
US Inland   →  eCFR versioner API XML (33 CFR Parts 83–88)         → rules/inland/*.md
Canadian    →  Justice Laws XML (C.R.C., c. 1416)                  → rules/canadian/*.md
International →  pdftotext on the USCG handbook's text layer        → rules/international/*.md
```

One command rebuilds the whole vault:

```bash
uv run python scripts/build_vault.py \
  --handbook "/path/to/Nav Rules Handbook_Corrected_08-12-2024.pdf"
```

Result: **135 generated files, zero filter errors** — handling the exact same material that blocked 11 times when it went through model output. Each file is a small markdown doc with a structural frontmatter block and the rule body (frontmatter shape only, no rule prose):

```yaml
---
number: '5'
regime: international
part: B
title: Look-out
verified: false
source_pdf: Nav Rules Handbook_Corrected_08-12-2024.pdf p. 19
---
```

The one-line reason it works: **the model's output is the parser (novel code), and the corpus text moves file-to-file without ever being emitted by the model.**

## Why it matters / gotchas

**This is the better architecture for a safety-critical corpus anyway.** The filter forced an upgrade:

- **No hallucination or paraphrase risk.** A deterministic parser copies bytes; it doesn't "mostly" reproduce a rule. For navigation rules — where a dropped *not* changes who gives way — that's not a nicety.
- **Byte-identical rebuilds.** Pin the sources, re-run, get the same vault. The build here is all-or-nothing: it validates the full rule set (expected rule numbers per regime, non-empty prose, no print artifacts, plausible titles) *before* writing a single file.
- **Human review shrinks.** Instead of proofreading every transcribed line, a reviewer spot-checks the parser against a sample. Deterministic extraction means a clean sample validates the whole batch.

A few traps we hit, useful if you go this route:

- **Review by diff and sampling, never by printing.** Echoing extracted prose back into the conversation re-trips the filter *even after a clean build*. Verification asserts structure — counts, rule numbers, titles, first characters — never long prose strings. The Canadian parser, for instance, enforces a fidelity invariant: it raises if flattening a provision loses any word character (`re.sub(r"\W", "", ...)` on input vs. output must match), so correctness is a code assertion, not a human reading the text.
- **Real-source XML has dialects.** The eCFR tables are HTML-style `TR`/`TD`, not the CALS `ROW`/`ENT` you might assume from other government XML — we silently dropped a whole table before catching it in review. `EXTRACT` blocks nest and need recursion. The handbook's text layer wraps section headings mid-line, producing fragments that masquerade as content. Determinism doesn't mean trivial; it means *debuggable* — the failures are in code you can read and test, not in a model's mood this turn.
- **It fails closed, loudly.** A parser that hits an unhandled element raises with the tag name so you go look, rather than quietly emitting a paraphrase. That's the opposite of the transcription failure mode, where the model would happily "fix up" text it found awkward.

The general rule, well beyond rules of the road: **any "build a structured corpus from a document" task — re-ingesting a pilot book, turning equipment manuals into spec cards — should extract deterministically, not transcribe.** If the source is copyrighted, the filter will trip *harder*, and you want the deterministic pipeline regardless, for fidelity. The output filter is annoying when it false-positives on a LICENSE file, but on a corpus-ingestion task it's pointing you at the architecture you should have picked first.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran — a stack of MCP servers behind a local LLM and a Home Assistant voice front-end, one of which answers questions about the navigation rules of the road. The vault and its build pipeline are open source: [github.com/sailingnaturali/colregs-vault](https://github.com/sailingnaturali/colregs-vault) (the deterministic `scripts/build_vault.py`), consumed by [colregs-mcp](https://github.com/sailingnaturali/colregs-mcp). If you've been fighting `Output blocked by content filtering policy` on a transcription task, the move is the same: stop transcribing, start parsing.
