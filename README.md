# Sailing Naturali — Engineering Blog

Developer-facing engineering blog for [Sailing Naturali](https://sailingnaturali.com).
Built with Jekyll, served by GitHub Pages at
**[engineering.sailingnaturali.com](https://engineering.sailingnaturali.com)**.

It's the developer-facing sibling of the exec-facing Substack: code-heavy posts
about building the boat-agent / marine-AI-ops stack (Home Assistant, SignalK,
MCP servers, local LLM, NMEA marine data), aimed at the self-hosted / HA / maker
crowd. Design rationale lives in the `planning` repo:
`docs/superpowers/specs/2026-06-01-engineering-blog-and-scribe-agent-design.md`.

## How it's built & served

- **Static-site generator:** Jekyll (`minima` theme).
- **Build:** native GitHub Pages build — pushing to `main` rebuilds and
  publishes. No GitHub Actions workflow. Plugins are limited to the
  [Pages whitelist](https://pages.github.com/versions/); we use `jekyll-seo-tag`,
  `jekyll-feed`, and `jekyll-sitemap`.
- **Domain:** the `CNAME` file pins `engineering.sailingnaturali.com`. DNS is a
  `CNAME engineering → sailingnaturali.github.io` record.

## Writing a post

Posts are Markdown files in `_posts/`, named `YYYY-MM-DD-slug.md`. Front matter:

```yaml
---
layout: post
title: "Clear and useful, one topic, ~8–12 words — keep the core keyword, drop the long tail"
description: "1–2 sentence SEO description. Name the real symptoms and versions — this is where the full googled error strings live."
date: 2026-06-01
tags: [homeassistant, selfhosted, ai]
---
```

URLs are `/:title/` (the slug from the filename), so build the slug from a full
SEO headline — pack in the error strings and versions there. The slug and
description carry the SEO load, which frees `title:` to be clear and useful (one
topic, ~8–12 words, core keyword in, long tail out). Slug = SEO; title = human.
`jekyll-seo-tag` derives the canonical URL automatically — don't set one unless
the post is syndicated and canonical lives elsewhere.

### House style

- **Code first.** Every config, command, error, and change is a copy-pasteable
  block, never described in prose.
- **broke → tried → fixed.** The "what we tried (and why it failed)" beat is
  mandatory — it's the highest-trust, highest-SEO part of the post.
- Direct, technical, no marketing fluff. Close with a short, non-salesy line
  connecting back to the project.

### The Scribe workflow

Drafts are produced on-demand by the **Scribe** agent (lives in the `planning`
repo at `.claude/agents/scribe.md`) from finished engineering work and
`docs/agent-lessons.md`. The Scribe opens a PR against this repo; a human reviews
voice/accuracy and merges. Never reproduces anything from the private
`infrastructure` repo.

## Local preview

```bash
bundle install
bundle exec jekyll serve   # http://localhost:4000
```
