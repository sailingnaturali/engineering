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
- **Build:** `.github/workflows/pages.yml` — pushing to `main` builds with the
  `github-pages` gem and deploys to Pages (replaced the auto-managed
  "Deploy from a branch" build so the actions are pinned and dependabot-bumped).
  Plugins are limited to the
  [Pages whitelist](https://pages.github.com/versions/); we use `jekyll-seo-tag`,
  `jekyll-feed`, and `jekyll-sitemap`.
- **PR checks:** `.github/workflows/ci.yml` runs on every PR: the same Jekyll
  build, `script/lint-liquid.py` (the Liquid guard, see **Liquid vs. template
  code** below, plus the figure-path check from **Figures**), and
  the devto unit tests. A red check means the merge would break the deploy or
  the published content — fix before merging.
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
- **The fix up top.** Open with a 2–3 line TL;DR of the fix for the searcher
  who arrived from an error string and wants the answer now; the full arc below
  is what keeps them.
- **Link related posts** with `{% post_url YYYY-MM-DD-slug %}` (never a
  hardcoded URL — `post_url` fails the build on a typo and survives renames).
- **Every post ships figures** — see **Figures** below. These posts are long and
  code-dense; unbroken, they read as work.
- Direct, technical, no marketing fluff. Close with a short, non-salesy line
  connecting back to the project.

### Figures

One figure minimum, usually two or three, spaced so no full screen is text-only.
What earns one: **the result** (a chart of the numbers the post is about, placed
right under the TL;DR — it's the hook and the link-preview image), **the
mechanism** (the boxes the data crosses and where it broke, in Diagnosis), or
**state a snippet can't show** (a capability ladder, the timeline of a race). A
diagram that restates a code block in rounded rectangles is noise — skip it.

Figures are **hand-written SVG**, not generated images and not mermaid (mermaid
isn't on the Pages plugin whitelist and dev.to won't render it either). SVG is
text: it diffs in review, stays sharp, costs nothing to serve, and its labels are
indexable. They live per-post and are referenced root-relative:

```
assets/img/<post-slug>/<figure-name>.svg
```
```markdown
![Full sentence stating what the figure shows and what it proves.](/assets/img/<post-slug>/alarm-path.svg)
```

The leading slash is required: GitHub resolves it against the repo root so the
figure renders in the PR blob preview, and the dev.to crosspost rewrites it to an
absolute URL on the way out.

The blog is dark, so draw for a dark ground and **paint the background
explicitly** — the same file has to survive GitHub's and dev.to's chrome.
Palette (`--sn-*` in `assets/main.scss`; canonical source
`planning/brand-palette.md`): ground `#0E1B25`, panel `#11212D`, borders
`#24384A`, labels `#C8D2DA`, titles `#E9EEF2`, muted/"before" `#7F97A8`,
accent/"after" `#88B868`, second accent `#58A058`, third series `#5888A8`,
failure `#C86A5A`. **System fonts only** — an SVG loaded through `<img>` can't
reach the page's webfonts — nothing below 13px, no `<script>`, no
`<foreignObject>`, no remote references, and never encode meaning in colour
alone. Alt text is an SEO surface: a full sentence naming the finding, mirrored
into the SVG's `aria-label`, and containing **no `]`** (the dev.to absolutizer
matches `\[[^\]]*\]\(`, so a bracket stops the rewrite and syndicates a relative
path). The figure ground is deliberately darker than the page ground (`#18222D`)
— a figure reads as a card, like a code block, not a seamless illustration.

`script/lint-liquid.py` fails on a figure path with no file behind it (Jekyll
builds a missing image silently, and merge = publish).

### Liquid vs. template code

GitHub Pages runs **Liquid over every post body** before Markdown. A post that
shows Jinja2 / Home Assistant / Go-template syntax will have its `{{ … }}`
silently rendered to empty strings (blanking the code blocks readers came for),
and some constructs (`default({})`) are hard Liquid syntax errors that fail the
whole deploy.

**Rule: if the body contains `{{` or `{%`, wrap it in `{% raw %}` …
`{% endraw %}`.** Put intentional Liquid — the `{% post_url %}` links above —
*outside* the raw block (e.g. close the block before the related-links line).
`script/lint-liquid.py` enforces this and runs in CI; the dev.to crosspost
strips the raw guards on the way out.

### The Scribe workflow

Drafts are produced on-demand by the **Scribe** agent (lives in the `planning`
repo at `.claude/agents/scribe.md`) from finished engineering work and
`docs/agent-lessons.md`. The Scribe opens a PR against this repo; a human reviews
voice/accuracy and merges. Never reproduces anything from the private
`infrastructure` repo.

Each post branch adds **exactly one `_posts/` file, plus that post's figures
under `assets/img/<slug>/`** — staged PRs hang open for weeks while `main`
moves, and a branch that carries anything unrelated will drag stale edits in at
merge time.

### Publishing

Merge = publish. `script/publish.py` runs the whole checklist for a staged PR:

```bash
python3 script/publish.py mqtt                 # rebase on main, bump date to
                                               # today, lint + build, push, merge
python3 script/publish.py mqtt --date 2026-07-07
python3 script/publish.py mqtt --no-merge      # push the rebuilt branch only
```

It refuses branches that touch more than their one post file. `script/bump.py`
is the date-bump step on its own. After publishing, move the post to Published
in the planning repo's `engineering-blog-schedule.md`.

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

dev.to throttles article creation (300-second windows, strict for new accounts),
so a single run only gets a couple of posts through before a `429`. That's treated
as "done for now" — the run logs what's left and exits successfully — and an
hourly `schedule:` trigger drains any backlog a few posts at a time. Steady state
(one new post per deploy) goes out on the after-deploy run and never trips the
limit.

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
