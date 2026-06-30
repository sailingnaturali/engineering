---
layout: post
title: "A hands-free npm publish pipeline for SignalK plugins"
description: "Publishing one SignalK plugin to npm is easy; keeping a fleet of them shipping hands-free and scoring 100 in the SignalK plugin registry is where people stall. The full workflow — npm OIDC trusted publishing (no NPM_TOKEN, no OTP in CI), the new-package first-publish chicken-and-egg and its ENEEDAUTH tell, gh release create as the publish trigger, the reusable plugin-ci.yml pinned to a release SHA (worth +10 / -10 on the registry score), and a dependabot config that keeps the pin current without dragging it onto signalk-server's stray v6.6.6 tag. Plus where the deterministic CI ends and a Claude skill's judgment begins."
tags:
  - signalk
  - npm
  - oidc
  - trusted-publishing
  - github-actions
  - dependabot
  - ci-cd
  - marine
date: 2026-06-23
---

Publishing a SignalK plugin to npm *once* is easy: `npm publish`, type your OTP,
done. Keeping **eight** of them shipping hands-free — each one auto-published on a
tag, cross-tested on five platforms, and scoring 100 in the
[SignalK plugin registry](https://signalk.org/signalk-plugin-registry/) — is a
different problem, and it's the one we keep seeing people stall on. This is the
whole pipeline we run for the `@sailingnaturali/*` plugins, end to end.

## A pipeline is two kinds of work

The useful lens, before any YAML: a publish pipeline is **deterministic plumbing**
plus **judgment**, and they want opposite tools.

The plumbing is mechanical. Given a git tag: check out, build, run the tests on
Linux/macOS/Windows, publish with provenance, no human in the loop. The inputs are
clean and the steps never vary. That belongs in CI — flat YAML, and **no AI, ever**.
Reaching for a model to do a job a `Makefile` can do is how you get a slower, less
reliable `Makefile`.

The other half is judgment. *Is this change worth cutting a release?* *What actually
goes in the notes?* *The registry says 90 — which of the gaps matters, and is that
`npm audit` advisory a real ship-blocker or dev-only noise?* *Dependabot wants to bump
the CI pin to a "newer" tag — is that tag a trap?* None of those reduce to a clean
rule over clean input. You can spend a week trying to encode "is this release-worthy"
as a deterministic check and still be wrong on the first weird case.

This is the same line we draw on the boat. Deterministic code reads the NMEA bus,
computes SignalK deltas, and fires the alarm chain — the inputs are structured and
the logic is fixed, so an LLM there would only add latency and failure modes. But
the moment the input is a human asking a fuzzy question, or a judgment call over
messy state, that's where the agent earns its place. **Drive toward deterministic
code wherever the inputs let you; don't burn cycles forcing non-deterministic
judgment through deterministic code.** Put the judgment behind a model, and make the
seam explicit.

In this pipeline the seam is a set of **Claude Code skills**. The deterministic half
lives in four workflow files. The judgment half lives in three skills that wrap those
workflows and supply the parts a YAML file can't.

## The judgment half: three composable skills

We don't keep this workflow in a README that nobody re-reads. We keep it as three
skills, each doing one job, each invokable on demand
([they're public](https://github.com/sailingnaturali/claude-skills)):

- **`signalk-plugin`** — authoring + the publish decision: the `@signalk/server-api`
  patterns that actually work, the package scaffold, when a change warrants a release.
- **`npm-oidc-publish`** — the OIDC trusted-publishing flow, including the new-package
  chicken-and-egg that has no deterministic shortcut.
- **`signalk-registry`** — reads the plugin's **live** registry score, then judges which
  locally-fixable gaps to close before the next nightly re-test.

A skill is the right container precisely because each of these mixes a deterministic
core (a command to run, a file to write) with a judgment the model has to make
(*should we*, *which one*, *is this advisory real*). The deterministic core could be a
script; the judgment around it is why it's a skill and not a `cron` job.

## Scaffold (and the `files` array that ships nothing)

Public repo, npm package, MIT, zero runtime deps where you can manage it. The one
that bites everyone:

```json
{
  "name": "signalk-<name>",
  "files": ["index.js"],
  "keywords": ["signalk-node-server-plugin", "signalk-category-utility"],
  "license": "MIT"
}
```

If `"files"` is missing, the package ships **nothing** — your `.gitignore` excludes the
build output, and npm honours it. The `signalk-node-server-plugin` keyword is what
surfaces the package in the in-server App Store. For a TypeScript plugin, ship the
build with `"files": ["dist"]` and a `"prepare": "npm run build"` so `npm publish`
builds first; for a scoped package add `"publishConfig": { "access": "public" }`.

(One authoring trap worth its own note: serve plugin data via
`app.registerResourceProvider`, **not** `registerWithRouter` — the latter's
`/plugins/<id>/*` routes are admin-gated, so every reader would need a token. That, and
the rest of the `@signalk/server-api` patterns, is the `signalk-plugin` skill's job; the
[DSC plugin post]({% post_url 2026-06-11-signalk-dsc-distress-call-logging-nmea0183-dse-pgn-129808 %})
shows it in anger.)

## First publish: the chicken-and-egg

This is the step that has *no* deterministic shortcut, which is exactly why it lives in
a skill instead of a script. npm's trusted publishing lets a GitHub Actions workflow
`npm publish` with **no `NPM_TOKEN` and no OTP** — it authenticates over OIDC and stamps
provenance automatically. But you **cannot configure a trusted publisher for a package
that doesn't exist on npm yet**, and the OIDC publish needs that config to exist. So the
*first* publish of any new package is manual, once:

```bash
npm publish --otp=<code>     # creates 0.1.0, the only time you'll type an OTP
```

Then, on npmjs.com → the package → **Settings → Trusted Publisher → GitHub Actions**,
register the repo (`owner/repo`), the **workflow filename** (`publish.yml`), and leave
the environment blank. From here on it's hands-free.

The tell that this is misconfigured: the CI `npm publish` fails with **`ENEEDAUTH`**
("requires you to be logged in") while `npm ci` and `npm test` pass. That's never a code
problem — it means the trusted publisher isn't registered, or the workflow filename / repo
on npm doesn't match the one actually running.

## OIDC: the publish workflow

`.github/workflows/publish.yml` — the entire deterministic half of publishing:

```yaml
name: publish
on:
  release:
    types: [published]
permissions:
  contents: read
  id-token: write   # <- this line is what enables OIDC
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v6
        with:
          node-version: 24      # npm >= 11.5 supports OIDC; node 24 is safe
      - run: npm ci             # needs a committed package-lock.json
      - run: npm test
      - run: npm publish        # no token, no --otp; provenance is automatic
```

One gotcha that looks like a failure and isn't: after `npm publish` prints
`+ <pkg>@<ver>`, the npmjs.com **website** shows the release immediately, but the
**registry API** (`npm view`, `registry.npmjs.org/<pkg>`) can 404 for a few minutes —
worst for a *scoped* package's first publish. That's propagation, not a failed publish.
Trust the `+ <pkg>@<ver>` line.

## Continuous mode: the release *is* the trigger

With OIDC wired, shipping a new version is one deterministic command — no local build,
no token, no OTP:

```bash
gh release create v0.5.2 --notes "Set current directions from CHS metadata"
```

That `release: published` event fires `publish.yml`, which publishes over OIDC. Two
things fall out of doing it this way:

- The **GitHub Release doubles as the changelog**. The registry docks −5 for a missing
  changelog, and it counts a release tagged `v<version>` as satisfying that — so the
  same `gh release create` that publishes the package also closes the changelog gap. One
  action, two boxes ticked.
- *Whether* to cut the release, and what the notes say, is the judgment the
  `signalk-plugin` skill owns. The command is deterministic; the decision to run it is not.

## The workflows that keep it honest

Three more files run on every push and PR — all deterministic, all in YAML.

`test.yml` is the ordinary CI gate:

```yaml
name: test
on:
  push: { branches: [main] }
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v6
        with: { node-version: 20 }
      - run: npm ci
      - run: npm run build
      - run: npm test
```

`plugin-ci.yml` is the one most plugins skip, and it's worth real points. SignalK
publishes a **reusable** workflow that cross-tests your plugin on Linux x64/arm64,
macOS, Windows, and armv7/Venus OS (the Cerbo). Running it earns the registry's
plugin-ci credit — **+10**, and its *absence* is a flat **−10**, which alone caps an
otherwise-perfect plugin at 90:

```yaml
name: SignalK Plugin CI
on:
  push: { branches: ['**'] }
  pull_request: { branches: ['**'] }
jobs:
  plugin-ci:
    uses: SignalK/signalk-server/.github/workflows/plugin-ci.yml@3645160b235364e1fd3afe1f2f6b2270b8194b7d # v2.28.0
```

**Pin to a release commit SHA, never `@master`** — supply-chain safety and
reproducibility. The trailing `# v2.28.0` comment is how a human (or Dependabot) knows
what the SHA means.

## Tracking updates without dragging in a dead tag

A pinned SHA is safe but it goes stale — when signalk-server cuts a release, your pin
silently falls behind. The deterministic fix is `dependabot.yml`, which opens a grouped
weekly PR to bump every action you pin, including the reusable workflow:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    groups:
      github-actions:
        patterns: ["*"]
    ignore:
      # signalk-server carries a stray ancient v6.6.6 tag (a 2019 commit with no
      # plugin-ci.yml) that outranks the real 2.x release line by semver, so
      # dependabot "upgrades" the reusable-workflow pin to a dead ref and the
      # workflow fails to load (0s failure). Ignore majors: the real releases are
      # 2.x minors, which dependabot still tracks; a genuine 3.0 we bump by hand.
      - dependency-name: "SignalK/signalk-server*"
        update-types: ["version-update:semver-major"]
```

That `ignore` block is the whole point of this section. signalk-server carries a stray
**`v6.6.6`** tag — a 2019 commit, no `plugin-ci.yml` in it — that outranks the real
`2.x` release line by raw semver. Left alone, Dependabot helpfully "upgrades" your pin to
that dead ref, the reusable workflow can't be loaded, and CI fails in 0 seconds. Ignoring
the *major* bump keeps Dependabot tracking the real `2.x` minors while refusing the trap;
a genuine `3.0` is rare enough to bump by hand. This is the kind of failure mode that's
obvious in hindsight and invisible up front — exactly what you want captured in a config
comment so nobody rediscovers it.

## The score is a checkable bar, not a vibe

All of the above exists to hit one number. The registry scores every plugin 0–100 and
re-tests nightly:

| Category | Points | Where it runs |
|----------|--------|----------------|
| Installs / Loads / Activates / Schema | 55 | Registry harness (live server) |
| Tests pass | 25 | Registry harness |
| Security audit | 0–20 | Local |
| Changelog | −5 if missing | Local |
| Screenshots | −5 if missing | Local |
| Plugin-CI | **−10 if missing** | Local (the workflow file) |

The 80 harness points run against a live SignalK server — you can't reproduce them
locally, but the registry serves each plugin's result as JSON, so you can *read* them.
The rest you fix in the repo before the next nightly. Without `plugin-ci.yml` the ceiling
is 90, not 100; that surprises people who've done everything else right.

This is where the `signalk-registry` skill closes the loop, and where the deterministic /
judgment split shows up one last time. Reading the published score is deterministic — it's
an HTTP GET and some JSON:

```bash
PKG=$(node -p "require('./package.json').name")
SLUG=$(printf '%s' "$PKG" | sed 's/^@//; s#/#__#')   # @scope/name -> scope__name
curl -s "https://signalk.org/signalk-plugin-registry/plugins/$SLUG.json"
```

What to *do* with it is the judgment: is that lone `moderate` advisory dev-only noise
(esbuild, vitest — never shipped) or a real ship-blocker? Is the pin behind the latest
release, and does that release even contain `plugin-ci.yml` at the new ref? Those are the
calls the skill makes, so "publish to 100" becomes something you can actually check on
demand instead of a number you hope is still true.

## The shape of it

```
gh release create vX.Y.Z ─→ publish.yml ─(OIDC, no token)─→ npm  + provenance
                          └─ Release = changelog (−5 gap closed)

push / PR ─→ test.yml          (build + unit tests)
          └─ plugin-ci.yml     (5-platform reusable CI, +10 / −10, pinned SHA)

weekly ───→ dependabot.yml     (bumps the pin; ignores the v6.6.6 trap)

on demand ─→ signalk-registry skill  (reads live score, judges the gaps)
```

Four deterministic YAML files do the plumbing; three skills supply the judgment the
YAML can't. That's the same bet we make everywhere on this stack — an all-electric
charter catamaran whose ops run on exactly this division of labour: deterministic code
where the inputs are clean, a model where they aren't, and a clear seam between the two.
The skills are [public](https://github.com/sailingnaturali/claude-skills); a plugin that
runs the whole pipeline is [`signalk-currents`](https://github.com/sailingnaturali/signalk-currents).
