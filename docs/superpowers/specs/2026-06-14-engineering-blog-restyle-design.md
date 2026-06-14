# Engineering blog restyle — design

**Date:** 2026-06-14
**Repo:** `engineering/` (Jekyll, GitHub Pages native build, engineering.sailingnaturali.com)
**Goal:** Make the engineering blog feel connected to the Sailing Naturali brand — a darker-toned variant of the brand palette — and fix the weak, light code blocks. Keep deploys zero-maintenance.

## Context (verified 2026-06-14)

- Theme: **minima 2.5.1** (pinned by `github-pages 232`). Stock, zero customization → spartan.
- minima 2.5.1 has **no skins directory**, so the existing `minima: skin: dark` in `_config.yml` is a **no-op**; the live site is light classic minima.
- minima 2.5.1 has **no `custom-head.html` hook** — adding fonts requires overriding `_includes/head.html`.
- Customization mechanism: a repo-local `assets/main.scss` shadows the gem's; it does `@import "minima";` then our overrides (later cascade wins).
- Brand palette + type system: canonical in `planning/brand-palette.md`, shipped in `web/src/styles.css`. Brand site is light (off-white/navy); this blog is the **dark** counterpart, which the palette doc explicitly supports ("Navy … dark sections"; "On navy: Off-White, Sky, or Leaf Green for text").
- Rouge markup: inline code = `code.language-*.highlighter-rouge`; block = `div.language-*.highlighter-rouge > div.highlight > pre.highlight > code` with token spans (`.k`, `.s`, `.nf`, `.c`, …).

## Approach

**Option 1 — minima overrides** (no new build step; deploys stay automatic). Escalate to **Option 3 — custom theme on Pages** *only* if a target surface resists CSS-only styling. No GitHub Actions.

### Files added/changed (repo-local)

1. **`assets/main.scss`** — `---` front matter, `@import "minima";`, then the full brand override layer (all CSS below). Uses explicit palette hex (no dependence on minima SCSS vars).
2. **`_includes/head.html`** — copy of minima 2.5.1's head.html with brand font `<link>`s injected (Google Fonts: Fraunces, Geist, Geist Mono; limited weights). Everything else identical to the gem's.
3. **`_config.yml`** — remove the dead `minima: skin: dark` block; add `docs` to `exclude` so this spec isn't published.

No `_layouts` overrides. `_includes/social.html` (existing footer customization) is untouched.

## Visual design — "Slate Dim" dark

**Palette (decided via mockups):**

| Token | Hex | Use |
|---|---|---|
| page ground | `#18222D` | body background |
| recessed surface | `#0E1B25` | code panels, cards |
| hairline border | `#24384A` | code/table/section borders |
| body text | `#C8D2DA` | paragraphs |
| heading text | `#E9EEF2` | h1–h6 |
| muted / meta | `#7F97A8` (steel) | dates, captions, nav idle |
| link | `#9CC87C` (leaf) | links |
| link hover | `#58A058` (signal green) | hover/focus |
| brand rule | `#006030` (forest green) | header accent, dividers, code left-edge |

**Type system (brand):** Fraunces → headings/post titles; Geist → body + nav; Geist Mono → code, post dates, eyebrow labels. Loaded in `head.html`.

## Surfaces (CSS only)

- **Site header:** dark bar (`#0E1B25`), Fraunces wordmark, forest-green accent rule under it, nav links steel→leaf on hover.
- **Home post list:** clean rows — Geist Mono date eyebrow (steel), Fraunces title link (leaf), Geist excerpt (body), generous vertical rhythm. (minima's `home` layout already emits date/title/excerpt; restyle only.)
- **Post page:** stronger header (Fraunces title, mono meta line); styled blockquotes (leaf left-rule), tables (hairline borders, dark header row), inline code chips.
- **Footer:** dark treatment matching the header; existing `social.html` icons inherit via `currentColor`.

## Code blocks ("Header + accent bar" — chosen)

- Block: `.highlighter-rouge .highlight` → recessed `#0E1B25` panel, `1px #24384A` border, **`3px #006030` left edge**, radius 7px.
- **Language label header:** a strip above `pre`, rendered with CSS `::before` on `.language-<lang> .highlight` for the common languages (shell, bash, console, ts/typescript, js/javascript, json, yaml, python, ruby, html, css, diff). Mono, small, steel on `#11212D`, bottom hairline. Unlisted languages simply get no label (graceful).
- **Syntax mapping (Rouge token classes):** keywords/idents (`.k`,`.kd`,`.nf`,`.nx`) leaf-green `#9CC87C`; strings (`.s`,`.s1`,`.s2`,`.dl`) lighter green `#A8D088`; functions/builtins steel-sky `#7FB0D0`; comments (`.c`,`.c1`,`.cm`) muted `#6F8596`; numbers/constants steel; shell prompt forest-green.
- **Inline code:** `code.highlighter-rouge` not inside `.highlight` → subtle `#0E1B25` chip, leaf-tinted text, `#24384A` hairline, small padding.

## Guardrails

- **Contrast:** verify body (`#C8D2DA`), headings (`#E9EEF2`), and links (`#9CC87C`) on `#18222D`, plus syntax tokens on `#0E1B25`, hit **WCAG AA** before finalizing; nudge hex if any fail.
- **Motion:** respect `prefers-reduced-motion` (minima is largely static; no new motion introduced).
- **Verification:** build locally (`bundle exec jekyll build`) and eyeball home + a real post (e.g. the DSC post, which has fenced code) before commit; confirm language labels render and no minima rule bleeds through light.

## Out of scope (now)

Homepage hero/intro, custom post layouts, richer nav/site structure — these belong to "full rework" / Option 3, only if we later choose to escalate.
