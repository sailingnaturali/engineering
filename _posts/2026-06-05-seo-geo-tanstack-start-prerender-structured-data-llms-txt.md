---
layout: post
title: "SEO and GEO on TanStack Start: prerender to static"
description: "TanStack Start client-renders by default, which is exactly what classic search (Googlebot) and answer engines (GPTBot, PerplexityBot, ClaudeBot) both choke on. The single highest-leverage fix is prerender-to-static. Here's the working prerender config, JSON-LD via route head.scripts, a build-time sitemap/robots/llms.txt module, the macOS grep gotcha that makes a correct build look broken, and the Cloudflare-grey-cloud cutover that keeps your TLS cert and canonical intact."
tags:
  - tanstack-start
  - seo
  - geo
  - prerendering
  - llms-txt
  - selfhosted
  - ai
date: 2026-06-05
canonical: "https://engineering.sailingnaturali.com/seo-geo-tanstack-start-prerender-structured-data-llms-txt/"
---

We moved the Sailing Naturali apex site off Squarespace and onto a code-owned [TanStack Start](https://tanstack.com/start) app on Vercel. The point wasn't to save the $28/month — it was to stop editing the site through a GUI and start editing it through a git repo: content as files, every change a PR, every PR a Vercel preview, merge to ship. The repo is public: [github.com/sailingnaturali/web](https://github.com/sailingnaturali/web).

The interesting part wasn't the migration. It was discovering that **SEO and GEO are the same problem wearing two hats**, that TanStack Start ships with the one default that breaks both, and that fixing it is a single config block. This is the broke → tried → fixed of getting search engines *and* answer engines to actually see a TanStack Start site — plus the verification gotchas that made a *correct* build look broken.

## Problem

The classic SEO checklist (title, meta description, canonical, Open Graph, structured data) and the newer GEO checklist (be legible to GPTBot, PerplexityBot, ClaudeBot, Google AI Overviews) read like two different jobs. They are not. They share one spine:

**A bot fetches a URL and has to understand the page from the bytes it gets back — without running your JavaScript.** Googlebot *can* render JS, but defers it and penalizes you for the round trip. The answer-engine crawlers largely don't render at all. So whether you're chasing a blue link or a cited sentence in an AI answer, the win condition is identical: **return clean, fully-rendered HTML with good structured data on the first request.**

TanStack Start, by default, does the opposite. It client-renders. Build the site, open the production HTML, and the body is an empty shell:

```html
<!-- .output/public/index.html — client-rendered default -->
<body>
  <div id="root"></div>
  <script type="module" src="/assets/entry-client-xxxx.js"></script>
</body>
```

That's what every bot sees: an empty `<div id="root">` and a script tag. Googlebot queues it for deferred rendering; GPTBot and PerplexityBot see nothing worth quoting. You can have perfect meta tags and it doesn't matter, because the content the page is *about* never made it into the response.

## Diagnosis

The fix is not "add more meta tags." It's "stop shipping an empty root div." Once the rendered text and the structured data are in the static HTML, both checklists collapse into one:

- **Classic SEO** wants `<title>`, `<meta name="description">`, `<link rel="canonical">`, OG/Twitter cards, and Schema.org JSON-LD — all in the first response.
- **GEO** wants the same first-response HTML to be *content-complete* (the prose is actually there) plus a machine-readable map of the site so answer engines know what you are and which pages matter.

Both are downstream of one decision: **prerender to static at build time.** Everything else — JSON-LD, sitemap, `llms.txt` — layers on top of prerendered HTML and is nearly free once the prerender works. So prerendering is the highest-leverage move, and it's where we started.

## What we tried (and why it failed)

### Attempt 1 — meta tags first, prerender "later"

The tempting order is to nail the `head` (title/description/canonical/OG) first because it's the visible SEO surface, and treat prerendering as a perf optimization for later. We wired up a `pageHead()` helper and shipped it on a client-rendered build.

Result: the meta tags were correct, and the page body was still empty to a bot.

```bash
# build, then look at what a crawler actually receives
$ pnpm build
$ grep -a "all-electric" .output/public/index.html
# (no output — the page's actual content isn't in the HTML)
```

Lesson: meta tags describe a page whose content isn't there. For Googlebot it's a deferred-render penalty; for a non-rendering answer-engine crawler it's invisible. Ordering matters — prerender is the prerequisite, not the polish.

### Attempt 2 — enable prerender, but verify with plain `grep`

We turned on prerendering (config below), rebuilt, and checked the output. On macOS:

```bash
$ grep "all-electric" .output/public/index.html
Binary file .output/public/index.html matches
```

…and worse, a phrase grep came back empty:

```bash
$ grep "can't" .output/public/index.html
# (no output)
```

That looked like the prerender had failed — empty matches and a "binary file" warning. It hadn't. Two separate verification traps, both of which make a *correct* build look broken (diagnosed in the gotchas below). We nearly reverted a working config because the check lied.

### Attempt 3 — local install fails on a build-script gate

With prerendering on, a fresh local install started failing where CI on Vercel didn't:

```
 ERR_PNPM_IGNORED_BUILDS  Ignored build scripts: esbuild.
Run "pnpm approve-builds" to pick which dependencies should be allowed
to run scripts, or set them in the dependenciesMeta field of package.json.
```

The reflex is to re-add the old `pnpm.onlyBuiltDependencies` array to `package.json` — and on a current pnpm that field is ignored there, so nothing changes. The approval setting has moved out of `package.json` and into `pnpm-workspace.yaml` (fix below). This one didn't bite on Vercel — only locally — which is exactly the kind of environment skew that eats an afternoon.

## The fix

### 1. Prerender to static (the whole ballgame)

In `vite.config.ts`, enable prerendering on the TanStack Start plugin and add the `nitro` plugin for the Vercel target:

```ts
// vite.config.ts
import { defineConfig } from 'vite'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import { nitro } from 'nitro/vite'

export default defineConfig({
  plugins: [
    tanstackStart({
      prerender: {
        enabled: true,
        autoSubfolderIndex: true,        // /about -> /about/index.html
        autoStaticPathsDiscovery: true,  // find routes automatically
        crawlLinks: true,                // follow <a> tags and prerender them too
        concurrency: 14,
      },
    }),
    nitro(),
  ],
})
```

Now the build emits real HTML, content and all. Verify it (correctly — see gotchas):

```bash
$ pnpm build
$ grep -a "all-electric" .output/public/index.html
... an all-electric charter catamaran ...   # rendered text, not an empty root div
```

That's the entire premise of the post in one config block. Everything below is layering.

### 2. JSON-LD via route `head.scripts` — it really does prerender

You do *not* need to hand-render a `<script type="application/ld+json">` in your component body. TanStack Start's route `head.scripts` emits inline JSON-LD straight into the prerendered `<head>`:

```ts
// src/routes/index.tsx (abridged) — the home route carries the site-level JSON-LD
import { pageHead, organizationJsonLd, websiteJsonLd } from '../lib/seo'

export const Route = createFileRoute('/')({
  head: () => ({
    ...pageHead(home),
    scripts: [
      { type: 'application/ld+json', children: JSON.stringify(organizationJsonLd()) },
      { type: 'application/ld+json', children: JSON.stringify(websiteJsonLd()) },
    ],
  }),
})
```

Verified in the static output — two inline JSON-LD blocks (Organization + WebSite) land in the `<head>` of `.output/public/index.html`:

```bash
$ grep -a -o 'application/ld+json' .output/public/index.html | wc -l
       2
```

If a future version regresses this, the fallback is a script tag rendered in the component body:

```tsx
<script
  type="application/ld+json"
  dangerouslySetInnerHTML={{ __html: JSON.stringify(organizationJsonLd()) }}
/>
```

### 3. A single source of truth, and build-time SEO assets

Two small modules keep this maintainable so adding a page doesn't mean editing five files:

- `src/lib/site.ts` — `siteConfig` plus a `pages` registry. Adding a page is one row; the sitemap and `llms.txt` follow from it.
- `src/lib/seo.ts` — `pageHead()` (title/description/canonical/OG/Twitter) and `organizationJsonLd()` / `websiteJsonLd()`.
- `src/lib/seo-assets.ts` — pure builder functions for `sitemap.xml`, `robots.txt`, and `llms.txt`.

The assets are generated at build time, before `vite build`, by a small script run through `tsx`:

```jsonc
// package.json
{
  "scripts": {
    "build": "tsx scripts/generate-seo-assets.mjs && vite build"
  }
}
```

Because the builders are pure functions over the `pages` registry, the sitemap and `llms.txt` can't drift from the actual site — they're derived from the same data the router uses.

### 4. `llms.txt` — the GEO-specific lever

`llms.txt` ([llmstxt.org](https://llmstxt.org/), Jeremy Howard's spec) is a plain-Markdown map of the site for answer engines: a one-line description, then the core pages with short summaries. It's the GEO analogue of `robots.txt`/`sitemap.xml` — instead of telling crawlers where they *may* go, it tells models what you *are* and which pages matter:

```markdown
# Sailing Naturali

> A tech exec is using AI leverage to build a premium all-electric sailing
> charter in the Pacific Northwest — the kind of business AI can't deliver.

## Pages

- [Sailing Naturali — an all-electric charter, built with AI](https://sailingnaturali.com): ...
```

(That's the live [`/llms.txt`](https://sailingnaturali.com/llms.txt) today — one page, because the site launched as one page. As routes land in the `pages` registry, the file grows with them for free.)

Honest caveat: adoption is uneven and Google has publicly said `llms.txt` is *not required*. We ship it anyway because it's a build-time-generated byproduct of the `pages` registry — near-zero cost, plausible upside, trivially removable. Treat it as future-proofing, not a silver bullet.

### 5. The pnpm build-script gate

Move the build-script approval out of `package.json` (where pnpm 11 silently ignores it — that's the deprecation warning you keep seeing) and into `pnpm-workspace.yaml`. On pnpm 11 the mechanism is an `allowBuilds` map of booleans:

```yaml
# pnpm-workspace.yaml
allowBuilds:
  esbuild: true
  lightningcss: true
```

After this, `pnpm install` runs the postinstall (esbuild fetches its platform binary) and `pnpm build` works with no `--config.verify-deps-before-run=false` escape hatch. (On older pnpm 10 the equivalent was an `onlyBuiltDependencies` *array* in the same file — check your pnpm major; the durable point is *the setting lives in `pnpm-workspace.yaml`, not `package.json`*.)

### 6. The cutover — keep your TLS cert and your canonical

DNS lives on Cloudflare. The trap is the orange cloud: if Cloudflare proxies the records, Vercel can't complete the ACME challenge to provision its own TLS cert. Set the relevant records to **DNS-only (grey cloud)** so Vercel owns TLS end to end:

```
# Cloudflare DNS — all DNS-only (grey cloud)
A      @      76.76.21.21            ; apex -> Vercel (use the IP Vercel shows you)
CNAME  www    cname.vercel-dns.com   ; www -> 307 redirect to apex
```

(`76.76.21.21` is Vercel's standard apex IP, but it assigns from an Anycast pool — use whatever value the Vercel domain dashboard hands you rather than copying this one.)

Two things that make the cutover boring instead of scary:

- **Canonical points at the apex from day one.** `og:url` and `<link rel="canonical">` are built from `siteConfig.url` (the apex), not the request host — so even on the `*.vercel.app` preview, search sees the apex as canonical. The moment DNS flips, the right canonical is already in the HTML; no duplicate-content window.
- **Email and verification survive the host swap.** `MX`, `SPF`, `DKIM`, and the DNS-based `google-site-verification` TXT record are independent of where the website is hosted. Leave them in place and they ride through the cutover untouched.

## Why it matters / gotchas

The two verification traps from Attempt 2 are worth their own section, because they make a *correct* build look like a failure and will send you reverting good code:

**Gotcha #1 — macOS/BSD `grep` reports a correct build as "binary."** Nitro emits `index.html` as a single long UTF-8 line packed with em-dashes and inline scripts. BSD `grep` (the macOS default) sniffs that as binary and prints `Binary file ... matches` instead of the line — or, with some flags, silently nothing. Force text mode:

```bash
$ grep -a "all-electric" .output/public/index.html   # -a = treat as text
```

**Gotcha #2 — React HTML-escapes apostrophes, so your grep misses real content.** React renders `can't` as `can&#x27;t` in the static HTML. A naive `grep "can't"` (or `grep "can.t"`) finds nothing and you conclude the prerender dropped the content. It didn't — grep an apostrophe-free phrase:

```bash
$ grep -a "all-electric charter" .output/public/index.html   # no apostrophe, matches
```

Both of these bite hardest precisely when the build is *correct*, which is the worst time to get a false negative.

The deeper lesson is the spine itself: **don't model SEO and GEO as two backlogs.** They're one — get clean, content-complete, well-structured HTML into the first response — and on TanStack Start that reduces to flipping prerendering on and then layering cheap, build-time-generated assets on top. The framework gives you the hard parts (typed `head`, JSON-LD in `head.scripts`, Nitro prerendering, link crawling); you supply a single source of truth so the derived assets can't drift. Worth reading alongside this: the official [TanStack Start SEO](https://tanstack.com/start/latest/docs/framework/react/guide/seo) and [LLMO](https://tanstack.com/start/latest/docs/framework/react/guide/llmo) guides, which land on the same conclusion from the framework side.

## Close

This is the apex marketing site for an all-electric charter catamaran we're building in the open — but the site itself is just a TanStack Start app, and the SEO/GEO module is reusable on any TanStack Start project. It's all in the public repo: [github.com/sailingnaturali/web](https://github.com/sailingnaturali/web).
