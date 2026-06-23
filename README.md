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
title: "A specific, searchable title — include the error string people google"
description: "1–2 sentence SEO description. Name the real symptoms and versions."
date: 2026-06-01
tags: [homeassistant, selfhosted, ai]
---
```

URLs are `/:title/` (the slug from the filename), so make the slug searchable.
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

## Syndication to dev.to

Published posts are mirrored to [dev.to](https://dev.to) as a distribution
channel; **the blog stays canonical** (each dev.to article sets `canonical_url`
back here). `.github/workflows/crosspost.yml` runs after a successful Pages
deploy and calls `bin/crosspost-devto`, which:

- lists what's already on dev.to and creates only the missing posts (idempotent,
  create-only — re-runs are no-ops, edits are not re-pushed),
- sets `canonical_url`, derives ≤4 dev.to tags from the post's front matter
  (first four, lowercased, non-alphanumerics stripped), and rewrites
  root-relative links to absolute.

One-time setup: generate a dev.to API key (dev.to → Settings → Extensions →
API Keys) and add it as the repo secret `DEVTO_API_KEY`
(`gh secret set DEVTO_API_KEY`). Dry-run anytime via the workflow's manual
"Run workflow" button (check *dry_run*) or locally:

```bash
DEVTO_API_KEY=... bin/crosspost-devto --dry-run
```

Logic lives in `lib/devto/`; tests in `test/devto/` run with
`ruby -e 'Dir.glob("test/**/*_test.rb").each { |f| require File.expand_path(f) }'`.

## Local preview

```bash
bundle install
bundle exec jekyll serve   # http://localhost:4000
```
