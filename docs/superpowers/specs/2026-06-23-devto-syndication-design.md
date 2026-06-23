# dev.to syndication via the Articles API

**Date:** 2026-06-23
**Status:** Approved — ready for implementation plan
**Repo:** `engineering/` (engineering.sailingnaturali.com)

## Goal

Syndicate engineering-blog posts to [dev.to](https://dev.to) as a distribution
channel while **the blog stays canonical**. Every dev.to article carries a
`canonical_url` pointing back to `engineering.sailingnaturali.com`, so Google
credits the blog's domain and dev.to becomes a backlink + audience source rather
than a competing copy.

Primary goal (user-confirmed): **SEO + reach, blog canonical** — not maximizing
dev.to-native engagement, not a co-equal mirror.

## Non-goals (v1)

- **No updates to already-syndicated posts.** Create-only. Editing a post on the
  blog does not re-push to dev.to. (Future: PUT-by-id; see Future work.)
- **No dev.to-side draft review gate.** Posts publish live (`published: true`);
  voice/accuracy is already reviewed in the blog PR.
- **No org posting / series grouping.** Personal account, no `organization_id`,
  no dev.to series. Both are trivial opt-ins later.
- **No change to Jekyll post front matter.** The blog is already self-canonical
  via `jekyll-seo-tag`; canonical *lives* at the blog. We set `canonical_url`
  only on the dev.to side.

## Architecture

Two pieces: a CI trigger and a reconcile script. The script does all the work and
is runnable locally; the workflow is a thin wrapper that runs it after a
successful deploy.

### 1. Trigger — `.github/workflows/crosspost.yml`

A **separate** workflow from the existing `pages.yml`, chained after it:

```yaml
name: Cross-post to dev.to

on:
  workflow_run:
    workflows: ["Deploy site to Pages"]
    types: [completed]
  workflow_dispatch:
    inputs:
      dry_run:
        description: "List what would be created without posting"
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  crosspost:
    runs-on: ubuntu-latest
    # Only after a real deploy succeeded on main → canonical URL is live before
    # dev.to fetches it, and a failed build never cross-posts.
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.head_branch == 'main')
    steps:
      - uses: actions/checkout@v5
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
      - run: bin/crosspost-devto ${{ (inputs.dry_run && '--dry-run') || '' }}
        env:
          DEVTO_API_KEY: ${{ secrets.DEVTO_API_KEY }}
```

Rationale for a separate workflow (not a job appended to `pages.yml`):

- The `DEVTO_API_KEY` secret stays out of the Pages-permissioned job
  (`pages: write` / `id-token: write`). Cross-posting needs only `contents: read`.
- `workflow_run` guarantees the canonical URL is already published before dev.to
  is told about it.
- A failed Jekyll build never triggers a cross-post.
- Pinned actions match the repo convention; dependabot already bumps them.

### 2. Reconcile script — `bin/crosspost-devto` (Ruby, stdlib only)

Ruby to match the repo toolchain (`ruby/setup-ruby` is already provisioned in
CI). Standard library only — `net/http`, `json`, `yaml`, `uri` — **no new gems**,
so local `bin/crosspost-devto` matches CI exactly.

It is a **reconcile**, not a per-post push:

1. Load every publishable post in `_posts/*.md`. Skip `published: false` and
   future-dated posts, matching what Jekyll actually publishes.
2. For each, compute its canonical URL:
   `https://engineering.sailingnaturali.com/<slug>/`
   where `<slug>` is the filename minus the `YYYY-MM-DD-` prefix and `.md`
   suffix (matching `permalink: /:title/`).
3. `GET https://dev.to/api/articles/me?per_page=1000` (header
   `api-key: $DEVTO_API_KEY`) → set of `canonical_url`s already on dev.to.
4. For each post whose canonical URL is **not** in that set: transform the body
   and `POST https://dev.to/api/articles` with `published: true`. Space creates
   ~2s apart (rate-limit courtesy).

Properties:

- **Idempotent / create-only.** Re-running is a no-op; existing dev.to articles
  are never modified, so any dev.to-side edits survive.
- **Backfill is automatic.** The 3 existing posts are created on the first
  successful run via the same path — no special-case backfill code.

### 3. Pure transform functions (the unit-tested core)

- `parse_post(path) -> {title, slug, date, tags, body, published?}`
  Splits YAML front matter from body; derives slug from filename.
- `derive_tags(tags) -> Array(<=4)` — lowercase each, strip `[^a-z0-9]`, dedupe,
  drop empties, keep the **first 4**. (dev.to caps at 4 tags and silently strips
  non-alphanumerics, e.g. `voice-assistant` → `voiceassistant`.) Authoring
  contract: order the most important tag first.
- `absolutize(body, site_url) -> String` — rewrite root-relative Markdown links
  and images (`](/…)`, and `src="/…"` in any inline HTML) to absolute URLs under
  `site_url`. Leave external links (`http(s)://…`), protocol-relative, and
  in-page anchors (`#…`) untouched.
- `build_payload(post, canonical) -> Hash` —
  `{article: {title:, body_markdown:, canonical_url:, tags:, published: true}}`.

### 4. Safety / error handling

- If `GET /articles/me` fails (non-2xx / network error) → **abort before any
  create.** Never risk duplicates from an incomplete existing-set.
- Non-2xx on a create → fail the job (surfaces in Actions). Other posts in the
  same run that already succeeded stay created (create-only makes a partial run
  safe to re-run).
- `429 Too Many Requests` → one backoff + retry, then fail if still 429.
- `--dry-run` (and the `workflow_dispatch` `dry_run` input) prints the
  create/skip plan without POSTing.
- Missing `DEVTO_API_KEY` → fail fast with a clear message.

## Testing (TDD)

Write failing tests first, then implement. Minitest (ships with Ruby), HTTP layer
stubbed.

Pure-function unit tests (the logic that actually breaks):

- `derive_tags`: hyphen squashing (`voice-assistant`→`voiceassistant`),
  truncation to 4, dedupe after squashing, empty/whitespace tags dropped,
  order preserved.
- `absolutize`: root-relative link rewrite, root-relative image rewrite,
  external/anchor/protocol-relative left untouched, code-fence contents not
  mangled (only link/image syntax targeted).
- `parse_post`: front-matter split, slug derivation from filename,
  `published: false` skipped, future-dated skipped, missing-`date` handling.
- Reconcile/dedupe: a post whose canonical is in the existing set is skipped; a
  new one is selected for create (POST stubbed and asserted on payload shape).

Integration edge covered by `--dry-run` against the real `_posts/`.

## One-time setup (manual, by Bryan)

1. dev.to → **Settings → Extensions → API Keys → Generate API Key.**
2. Add it as the repo secret `DEVTO_API_KEY`
   (`gh secret set DEVTO_API_KEY -R sailingnaturali/engineering`).
3. First run (next deploy to `main`, or a manual `workflow_dispatch`) backfills
   the existing posts.

## Future work (explicitly deferred)

- **Update propagation** — map canonical → dev.to article id from
  `GET /articles/me`, `PUT /articles/{id}` to sync edits. Needs a policy for not
  clobbering dev.to-side changes.
- **Front-matter tag override** — honor optional `devto_tags: [...]` verbatim,
  falling back to `derive_tags`. Add if an auto-squashed tag ever reads badly.
- **Series / org posting** — `series:` and `organization_id` are one-line
  additions to `build_payload` if engagement strategy changes.
- **Draft mode** — flip the `published` default if a dev.to-side review gate is
  ever wanted.
