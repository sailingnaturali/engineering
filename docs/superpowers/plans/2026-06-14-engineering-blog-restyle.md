# Engineering Blog Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reskin the engineering blog into a dark, on-brand "Slate Dim" theme with strong, branded code blocks — using minima overrides only, no build-step change.

**Architecture:** Repo-local `assets/main.scss` shadows the minima gem's stylesheet (`@import "minima";` then a brand override layer of plain CSS). Brand fonts load via an overridden `_includes/head.html` (minima 2.5.1 has no `custom-head` hook). No `_layouts` overrides; existing `_includes/social.html` is untouched.

**Tech Stack:** Jekyll + minima 2.5.1 (github-pages 232), Rouge syntax highlighter, Sass (Jekyll built-in), Google Fonts (Fraunces, Geist, Geist Mono).

**Reference:** Spec at `docs/superpowers/specs/2026-06-14-engineering-blog-restyle-design.md`.

**Verification loop (used by every task):**
- Build: `bundle exec jekyll build`
- Inspect compiled CSS: `_site/assets/main.css`; compiled HTML: `_site/index.html`, a post under `_site/<slug>/index.html`.
- Live view over Tailscale: `bundle exec jekyll serve --host 0.0.0.0 --port 4000 --livereload` → open `http://studio.tailb19444.ts.net:4000`.

---

## File Structure

- **Create** `assets/main.scss` — front matter + `@import "minima";` + the full brand override layer. Single source of all custom CSS.
- **Create** `_includes/head.html` — copy of minima 2.5.1's head.html with brand font `<link>`s added.
- **Modify** `_config.yml` — remove the dead `minima: skin: dark` block (no-op in 2.5.1).

All work happens on the existing `engineering-dark-restyle` branch.

---

### Task 1: Setup, baseline build, config cleanup

**Files:**
- Modify: `_config.yml`
- Create: `assets/main.scss`

- [ ] **Step 1: Install deps and confirm a clean baseline build**

Run:
```bash
cd ~/src/sailingnaturali/engineering
bundle install
bundle exec jekyll build
```
Expected: build completes, `_site/` regenerated, no errors.

- [ ] **Step 2: Remove the dead `skin: dark` block from `_config.yml`**

In `_config.yml`, delete these two lines (minima 2.5.1 ships no skins, so this is a no-op that misleads):
```yaml
minima:
  skin: dark
```
Leave `theme: minima` intact.

- [ ] **Step 3: Create `assets/main.scss` with front matter + import**

Create `assets/main.scss` with EXACTLY this (the empty front matter is required or Jekyll won't compile the Sass):
```scss
---
---

@import "minima";

/* ───────────────────────────────────────────────
   Sailing Naturali — engineering blog brand layer
   Dark "Slate Dim". Overrides minima after import.
   Palette: planning/brand-palette.md
   ─────────────────────────────────────────────── */
:root {
  --sn-ground: #18222D;
  --sn-surface: #0E1B25;
  --sn-surface-2: #11212D;
  --sn-border: #24384A;
  --sn-text: #C8D2DA;
  --sn-head: #E9EEF2;
  --sn-muted: #7F97A8;
  --sn-link: #9CC87C;
  --sn-link-hover: #58A058;
  --sn-rule: #006030;
  --font-display: "Fraunces", ui-serif, Georgia, serif;
  --font-sans: "Geist", ui-sans-serif, system-ui, sans-serif;
  --font-mono: "Geist Mono", ui-monospace, "SF Mono", monospace;
}
```

- [ ] **Step 4: Build and verify the custom stylesheet compiles and is shadowing the gem**

Run:
```bash
bundle exec jekyll build
grep -c -- "--sn-ground" _site/assets/main.css
```
Expected: prints `1` or more. (Custom properties survive Sass compression; a comment might not — so we check for the token, confirming our `assets/main.scss` is shadowing the gem's.)

- [ ] **Step 5: Commit**

```bash
git add _config.yml assets/main.scss
git commit -m "chore: drop dead skin:dark, add brand-layer scaffold to main.scss

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Brand fonts via head.html override

**Files:**
- Create: `_includes/head.html`

- [ ] **Step 1: Create `_includes/head.html` (minima 2.5.1 head + font links)**

Create `_includes/head.html` with EXACTLY this (it is minima 2.5.1's head.html plus the three font lines before the stylesheet):
```html
<head>
  <meta charset="utf-8">
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  {%- seo -%}
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,560;9..144,600&family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="{{ "/assets/main.css" | relative_url }}">
  {%- feed_meta -%}
  {%- if jekyll.environment == 'production' and site.google_analytics -%}
    {%- include google-analytics.html -%}
  {%- endif -%}
</head>
```

- [ ] **Step 2: Build and verify fonts are referenced in output**

Run:
```bash
bundle exec jekyll build
grep -c "fonts.googleapis.com/css2?family=Fraunces" _site/index.html
```
Expected: prints `1` (or higher) — the font link is present in the built head.

- [ ] **Step 3: Commit**

```bash
git add _includes/head.html
git commit -m "feat: load brand fonts (Fraunces, Geist, Geist Mono) via head override

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Base palette + typography layer

**Files:**
- Modify: `assets/main.scss` (append)

- [ ] **Step 1: Append the base layer to `assets/main.scss`**

Append after the `:root{...}` block:
```scss
/* ── Base ─────────────────────────────────────── */
body {
  background: var(--sn-ground);
  color: var(--sn-text);
  font-family: var(--font-sans);
  -webkit-font-smoothing: antialiased;
}
h1, h2, h3, h4, h5, h6 {
  color: var(--sn-head);
  font-family: var(--font-display);
  font-weight: 560;
  letter-spacing: -0.01em;
  line-height: 1.1;
}
a { color: var(--sn-link); text-decoration: none; }
a:hover { color: var(--sn-link-hover); text-decoration: underline; }
hr { border: 0; border-top: 1px solid var(--sn-border); }
strong { color: var(--sn-head); }
::selection { background: var(--sn-link); color: var(--sn-ground); }
:focus-visible { outline: 2px solid var(--sn-link-hover); outline-offset: 3px; }
```

- [ ] **Step 2: Build and verify the dark ground compiled in**

Run:
```bash
bundle exec jekyll build
grep -ci "background: *#18222d" _site/assets/main.css
```
Expected: prints `1` or more.

- [ ] **Step 3: Visual check**

Run `bundle exec jekyll serve --host 0.0.0.0 --port 4000` and open `http://studio.tailb19444.ts.net:4000`. Confirm: dark slate page, light body text, serif headings, leaf-green links. Ctrl-C when done.

- [ ] **Step 4: Commit**

```bash
git add assets/main.scss
git commit -m "feat: dark base palette + brand typography

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Site header + nav

**Files:**
- Modify: `assets/main.scss` (append)

- [ ] **Step 1: Append header/nav styles**

```scss
/* ── Site header ──────────────────────────────── */
.site-header {
  background: var(--sn-surface);
  border-top: 3px solid var(--sn-rule);
  border-bottom: 1px solid var(--sn-border);
}
.site-title,
.site-title:visited {
  color: var(--sn-head);
  font-family: var(--font-display);
  font-weight: 600;
}
.site-title:hover { color: var(--sn-head); text-decoration: none; }
.site-nav { background: transparent; line-height: inherit; }
.site-nav .page-link,
.site-nav .page-link:visited { color: var(--sn-muted); }
.site-nav .page-link:hover { color: var(--sn-link); text-decoration: none; }
@media (max-width: 600px) {
  .site-nav {
    background: var(--sn-surface-2);
    border: 1px solid var(--sn-border);
  }
  .site-nav .menu-icon > svg { fill: var(--sn-muted); }
}
```

- [ ] **Step 2: Build and verify**

Run:
```bash
bundle exec jekyll build
grep -ci "border-top: *3px solid #006030\|border-top:3px solid #006030" _site/assets/main.css
```
Expected: prints `1` or more (the green top rule).

- [ ] **Step 3: Visual check**

Serve and confirm: dark header bar, green top rule, serif wordmark, muted nav links that turn leaf-green on hover. Check mobile width (narrow the window) for the menu.

- [ ] **Step 4: Commit**

```bash
git add assets/main.scss
git commit -m "feat: brand the site header and nav

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Home post list

**Files:**
- Modify: `assets/main.scss` (append)

- [ ] **Step 1: Append home post-list styles**

```scss
/* ── Home post list ───────────────────────────── */
.home .post-list-heading { color: var(--sn-head); }
.post-list { margin-left: 0; list-style: none; }
.post-list > li {
  border-bottom: 1px solid var(--sn-border);
  padding-bottom: 1.5rem;
  margin-bottom: 1.5rem;
}
.post-list > li:last-child { border-bottom: 0; }
.post-meta {
  color: var(--sn-muted);
  font-family: var(--font-mono);
  font-size: 0.78rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}
.post-link {
  display: block;
  margin-top: 0.3rem;
  font-family: var(--font-display);
  font-size: 1.5rem;
  line-height: 1.15;
  color: var(--sn-link);
}
.post-link:hover { color: var(--sn-link-hover); text-decoration: none; }
```

- [ ] **Step 2: Build and verify**

Run:
```bash
bundle exec jekyll build
grep -c "post-link" _site/assets/main.css
```
Expected: prints `1` or more.

- [ ] **Step 3: Visual check**

Serve and confirm the home page is a clean list of rows: mono uppercase date, serif leaf-green title, excerpt below, hairline divider between posts.

- [ ] **Step 4: Commit**

```bash
git add assets/main.scss
git commit -m "feat: restyle home post list into branded rows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Post page — header, blockquote, tables, inline code

**Files:**
- Modify: `assets/main.scss` (append)

- [ ] **Step 1: Append post-content styles**

```scss
/* ── Post page ────────────────────────────────── */
.post-title { color: var(--sn-head); letter-spacing: -0.02em; }
.post-content { color: var(--sn-text); }
.post-content h2,
.post-content h3 { margin-top: 2rem; }

blockquote {
  color: var(--sn-muted);
  background: var(--sn-surface);
  border-left: 4px solid var(--sn-rule);
  padding: 0.6rem 1rem;
  font-style: normal;
}

table { color: var(--sn-text); border-color: var(--sn-border); }
table th {
  background: var(--sn-surface);
  color: var(--sn-head);
  border-color: var(--sn-border);
}
table td { border-color: var(--sn-border); }
table tr:nth-child(even) { background: rgba(255, 255, 255, 0.02); }

/* inline code (not inside a highlight block) */
code.highlighter-rouge {
  background: var(--sn-surface);
  color: var(--sn-link);
  border: 1px solid var(--sn-border);
  border-radius: 4px;
  padding: 0.08em 0.36em;
  font-size: 0.85em;
  font-family: var(--font-mono);
}
```

- [ ] **Step 2: Build and verify**

Run:
```bash
bundle exec jekyll build
grep -c "code.highlighter-rouge" _site/assets/main.css
```
Expected: prints `1` or more.

- [ ] **Step 3: Visual check**

Serve and open a post with prose, a list, and inline `code` (e.g. `/signalk-dsc-distress-call-logging-nmea0183-dse-pgn-129808/`). Confirm: serif title, readable body, green-left blockquote, dark-header tables, inline code chips.

- [ ] **Step 4: Commit**

```bash
git add assets/main.scss
git commit -m "feat: brand post header, blockquotes, tables, inline code

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Code blocks — panel, accent bar, language labels

**Files:**
- Modify: `assets/main.scss` (append)

- [ ] **Step 1: Append code-block container + language-label styles**

```scss
/* ── Code blocks ──────────────────────────────── */
.highlighter-rouge .highlight,
figure.highlight {
  background: var(--sn-surface);
  border: 1px solid var(--sn-border);
  border-left: 3px solid var(--sn-rule);
  border-radius: 7px;
  overflow: hidden;
  margin-bottom: 1.5rem;
}
.highlighter-rouge .highlight pre,
.highlight pre.highlight,
pre {
  background: transparent;
  border: 0;
  margin: 0;
  color: var(--sn-text);
  padding: 14px 16px;
  font-family: var(--font-mono);
  font-size: 0.85rem;
  line-height: 1.55;
}

/* language label header strip (CSS-driven from kramdown's .language-* class) */
[class*="language-"].highlighter-rouge > .highlight::before {
  display: block;
  font-family: var(--font-mono);
  font-size: 0.7rem;
  letter-spacing: 0.06em;
  text-transform: lowercase;
  color: var(--sn-muted);
  background: var(--sn-surface-2);
  border-bottom: 1px solid var(--sn-border);
  padding: 6px 14px;
}
.language-shell   > .highlight::before,
.language-bash    > .highlight::before,
.language-console > .highlight::before,
.language-sh      > .highlight::before { content: "shell"; }
.language-typescript > .highlight::before,
.language-ts         > .highlight::before { content: "typescript"; }
.language-javascript > .highlight::before,
.language-js         > .highlight::before { content: "javascript"; }
.language-json > .highlight::before { content: "json"; }
.language-yaml > .highlight::before,
.language-yml  > .highlight::before { content: "yaml"; }
.language-python > .highlight::before,
.language-py     > .highlight::before { content: "python"; }
.language-ruby > .highlight::before,
.language-rb   > .highlight::before { content: "ruby"; }
.language-html > .highlight::before { content: "html"; }
.language-css  > .highlight::before,
.language-scss > .highlight::before { content: "css"; }
.language-diff > .highlight::before { content: "diff"; }
/* no label for plaintext / unmarked blocks */
.language-plaintext > .highlight::before { content: none; }
```

- [ ] **Step 2: Build and verify the label rule and panel exist**

Run:
```bash
bundle exec jekyll build
grep -c 'content: *"typescript"\|content:"typescript"' _site/assets/main.css
```
Expected: prints `1` or more.

- [ ] **Step 3: Visual check**

Serve and open a post containing a fenced code block with a language (e.g. a ```ruby or ```bash block). Confirm: recessed dark panel, green left edge, a lowercase language label strip across the top, rounded corners. Confirm a plaintext/unmarked block shows NO label strip.

- [ ] **Step 4: Commit**

```bash
git add assets/main.scss
git commit -m "feat: branded code-block panels with language-label headers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Code blocks — Rouge syntax token colors

**Files:**
- Modify: `assets/main.scss` (append)

- [ ] **Step 1: Append the syntax token mapping (overrides minima's light theme)**

```scss
/* ── Syntax tokens (Rouge classes) ────────────── */
.highlight .k, .highlight .kd, .highlight .kn,
.highlight .kp, .highlight .kr, .highlight .kt { color: var(--sn-link); }      /* keywords - leaf */
.highlight .nb, .highlight .nx, .highlight .bp { color: var(--sn-link); }      /* builtins/idents - leaf */
.highlight .s, .highlight .s1, .highlight .s2,
.highlight .sb, .highlight .sc, .highlight .se,
.highlight .dl, .highlight .sr { color: #A8D088; }                              /* strings */
.highlight .nf, .highlight .nd, .highlight .fm { color: #7FB0D0; }              /* functions - steel-sky */
.highlight .c, .highlight .c1, .highlight .cm,
.highlight .cp, .highlight .cs { color: #6F8596; font-style: italic; }          /* comments */
.highlight .mi, .highlight .mf, .highlight .il,
.highlight .no, .highlight .kc { color: #9FC2DA; }                              /* numbers / constants */
.highlight .o, .highlight .ow, .highlight .p { color: var(--sn-text); }         /* operators / punctuation */
.highlight .nt { color: #7FB0D0; }                                              /* HTML/XML tag names */
.highlight .na { color: var(--sn-link); }                                       /* attributes */
.highlight .gp { color: var(--sn-rule); }                                       /* shell prompt */
.highlight .gi { color: #A8D088; }                                              /* diff insert */
.highlight .gd { color: #D08770; }                                              /* diff delete */
.highlight .err { color: var(--sn-text); background: transparent; }             /* don't flag as red */
```

- [ ] **Step 2: Build and verify a token color compiled in**

Run:
```bash
bundle exec jekyll build
grep -ci "#a8d088" _site/assets/main.css
```
Expected: prints `1` or more (string token color).

- [ ] **Step 3: Visual check**

Serve and open a post with a syntax-highlighted block. Confirm: keywords leaf-green, strings lighter green, comments muted italic, functions steel-sky — all legible on the dark panel, nothing washed-out or stuck on minima's light defaults.

- [ ] **Step 4: Commit**

```bash
git add assets/main.scss
git commit -m "feat: brand syntax-highlight token colors on dark

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Footer, contrast audit, reduced motion, final review

**Files:**
- Modify: `assets/main.scss` (append)

- [ ] **Step 1: Append footer + reduced-motion styles**

```scss
/* ── Footer ───────────────────────────────────── */
.site-footer {
  background: var(--sn-surface);
  border-top: 1px solid var(--sn-border);
  color: var(--sn-muted);
}
.site-footer .footer-heading { color: var(--sn-head); }
.site-footer a, .site-footer a:visited { color: var(--sn-text); }
.site-footer a:hover { color: var(--sn-link); }
.social-media-list .svg-icon { fill: var(--sn-muted); }
.social-media-list a:hover .svg-icon { fill: var(--sn-link); }
.feed-subscribe a, .feed-subscribe .svg-icon { color: var(--sn-muted); fill: var(--sn-muted); }

/* ── Motion ───────────────────────────────────── */
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
}
```

- [ ] **Step 2: Build**

Run: `bundle exec jekyll build`
Expected: clean build, no Sass errors.

- [ ] **Step 3: Contrast audit (WCAG AA)**

Check these foreground/background pairs (use any contrast tool, e.g. a browser devtools color picker on the live site, or https://webaim.org/resources/contrastchecker/). Record the ratios:
- Body `#C8D2DA` on `#18222D` — expect ≥ 7:1 (target ≥ 4.5:1 AA)
- Heading `#E9EEF2` on `#18222D` — expect ≥ 10:1
- Link `#9CC87C` on `#18222D` — expect ≥ 4.5:1
- Muted/meta `#7F97A8` on `#18222D` — expect ≥ 4.5:1 (this is the borderline one)
- String token `#A8D088` and comment `#6F8596` on panel `#0E1B25` — expect ≥ 4.5:1 (comment is borderline)

If any pair is below 4.5:1, lighten the foreground (e.g. bump `--sn-muted` toward `#8FA6B8`, or the comment toward `#7E94A6`) in `:root` / the token rule, rebuild, and re-check. Note the final values.

- [ ] **Step 4: Full visual review over Tailscale**

Run `bundle exec jekyll serve --host 0.0.0.0 --port 4000` and review on the device of your choice via `http://studio.tailb19444.ts.net:4000`:
- Home list, a long post, the about page, the footer, mobile width.
- Confirm no light/minima rule bleeds through anywhere (white boxes, blue default links, light code panels).

- [ ] **Step 5: Commit**

```bash
git add assets/main.scss
git commit -m "feat: brand footer; reduced-motion; finalize contrast

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: Push the branch**

```bash
git push
```
Expected: branch updates on `origin/engineering-dark-restyle`.

---

## Notes for the implementer

- **Order matters in `assets/main.scss`:** everything must come AFTER `@import "minima";` so our rules win on cascade. Append in task order.
- **If a surface refuses to restyle via CSS** (a structure minima only exposes in its layouts), that is the trigger to escalate to a custom theme (spec "Option 3") — stop and flag it, don't fight it with `!important` sprawl.
- **Don't touch** `_includes/social.html` (already customized) or add any GitHub Actions workflow.
- The `docs/` dir (specs + this plan) is excluded from the Jekyll build via `_config.yml`, so it won't publish.
