---
layout: post
title: "A config warning on stdout made a healthy alarm lane look dead"
description: "A CLI printed a Config warnings box to stdout instead of stderr, so a shell pipeline parsing its output got box-drawing characters where data rows should be and an awk filter returned nothing — which read as 'no agent runs, the alarm lane is down' rather than 'your shell is missing an env var'. Two config credentials became secret references and failed on two different channels: SecretRefUnavailableError loud on stderr, 'Missing env var' quiet on stdout. 2>/dev/null hides the loud one and leaves the silent one. Plus a --selftest that passed while genuinely broken because it grepped for a warning-box title the other subcommand never prints, and the root-cause fix that deleted the wrapper entirely."
date: 2026-08-11
tags:
  - cli
  - shell
  - bash
  - stdout
  - stderr
  - debugging
  - devops
  - self-hosted
  - testing
---

> **TL;DR** — A CLI reported a missing environment variable by printing a
> `Config warnings` box to **stdout**. My pipeline was parsing that stdout, so
> `awk` got box-drawing characters where data rows should be and matched
> nothing. "Nothing" read as *the alarm lane is dead*, not *your shell is
> missing an env var*. Forty minutes and one false outage report later:
> **prefix the environment for any command whose output you parse, not just
> the ones that need the secret.** [Jump to the fix](#the-fix).

![One missing environment variable fails on two channels: the typed secret reference throws a loud SecretRefUnavailableError on stderr, while the string-only field prints a Config warnings box to stdout that lands inside the parsed data rows, so an awk filter returns nothing and a healthy alarm lane reads as down.](/assets/img/config-warning-on-stdout-corrupts-parsed-output-stderr-vs-stdout-diagnostics-awk-returns-nothing-2-dev-null-hides-loud-failure-cli-selftest-negative-control-env-prefix-parsed-commands/two-channels.svg)

## The problem

I run an agent gateway on a small boat server. It has an audit log, and the
cheapest health check for "are the agents actually running" is a one-liner over
the CLI:

```bash
gwcli audit --limit 12 | awk '$2=="agent_run"'
```

Which, one morning, returned nothing at all. No error. Exit code 0. Just an
empty result where a dozen rows had been the week before.

The obvious reading — the one I made, and the one that cost the morning — is
that there were no agent runs. Alarms flow through that gateway, so "no agent
runs" means the soft alarm lane is down: a low-battery or depth alarm on the
boat would raise, publish, and reach nobody. That's a real outage on the boat's
safety path, so it got reported as one.

The lane was healthy the entire time. The hook was firing about twelve seconds
after each test alarm, which is exactly the coalesce window. Nothing was down.

Here is what the command actually printed, once I stopped piping it:

```console
$ gwcli audit --limit 12
┌ Config warnings ───────────────────────────────────┐
│ ! hooks.token: Missing env var GW_HOOKS_TOKEN      │
└────────────────────────────────────────────────────┘
ts                    kind        agent    status
2026-08-10T06:12:04Z  agent_run   watch    ok
2026-08-10T06:24:11Z  agent_run   watch    ok
```

The rows were there. So was a warning box, printed **to stdout**, sitting on top
of them. `awk '$2=="agent_run"'` doesn't crash on box-drawing characters; it just
doesn't match them, and it never got the chance to be confused, because in the
real invocation the box was all there was.

## Diagnosis

The day before, I'd moved two credentials out of the gateway's config file and
into secret references, so the config could go under version control:

```jsonc
// ~/.gwcli/config.json
{
  "gateway": { "auth": { "token": { "$secret": "GW_AUTH_TOKEN" } } },
  "hooks":   { "token": "${GW_HOOKS_TOKEN}" }
}
```

Note the two forms. That asymmetry looks like sloppiness and it is not — more on
that below. The secrets themselves lived in an env file that the gateway's
launcher script sourced before exec'ing the daemon:

```bash
# run-gateway.sh
set -a; . "$HOME/.gwcli/secrets.env"; set +a
exec gwcli gateway
```

The daemon was fine, because the daemon goes through that script. **A bare
`gwcli ...` typed in a shell, or run over SSH, does not.** And with the env
missing, the two fields fail in two completely different, differently-visible
ways:

| Field | Form | Channel | What you get |
|---|---|---|---|
| `gateway.auth.token` | typed secret ref | **stderr** | `SecretRefUnavailableError: ... unavailable in this command path` |
| `hooks.token` | `${VAR}` string | **stdout** | a `Config warnings` box, mixed into the data you were parsing |

The stderr one is a good failure. It's loud, it names the field, and it stops
you. The stdout one is the dangerous half: it doesn't stop anything, it doesn't
look like an error to a program, and it arrives *inside the data stream*. Every
consumer that treats stdout as structured output — `awk`, `jq`, `grep -c`, a
Python `subprocess.run(...).stdout` — silently ingests a diagnostic as content.

And the two compound in the worst possible way, which is the part I'd want
another builder to take away:

```bash
# a completely normal scripting reflex
gwcli audit --limit 12 2>/dev/null | awk '$2=="agent_run"'
```

`2>/dev/null` suppresses the one failure that would have told me what was wrong,
and leaves the one that corrupts the answer. A clean-looking pipeline, producing
wrong data, with no visible error anywhere. That is a very hard thing to
distrust at 6 a.m.

## What I tried, and why it failed

**Attempt 1: prefix the env only where the secret is needed.** My first mental
model was "this command reads the audit log, it doesn't need the gateway token,
so it doesn't need the env." Wrong — the config is parsed on *every* invocation,
so an unresolvable reference warns on every invocation, whether or not the
subcommand touches it:

```console
$ gwcli audit --limit 12 | awk '$2=="agent_run"'     # env not prefixed
                                                      # (nothing — the box isn't a match)
$ set -a; . ~/.gwcli/secrets.env; set +a
$ gwcli audit --limit 12 | awk '$2=="agent_run"'     # env prefixed
2026-08-10T06:12:04Z  agent_run   watch    ok
2026-08-10T06:24:11Z  agent_run   watch    ok
```

Same command, same server, same healthy lane. The only variable was my shell.

**Attempt 2: a wrapper, so the prefix stops being something to remember.** A
tiny script that sources the env and execs the real binary:

```bash
#!/usr/bin/env bash
# gw — run gwcli with secrets resolved
set -euo pipefail
set -a; . "$HOME/.gwcli/secrets.env"; set +a
exec gwcli "$@"
```

This works, and it survived the day. But it only helps the caller who remembers
to type `gw` instead of `gwcli`, which is the same class of discipline that
failed in the first place.

**Attempt 3: a `--selftest` that asserts the environment instead of trusting
it** — meant for the top of any script that parses this CLI's output. This is
the one worth writing down, because it **passed while genuinely broken**.

The CLI reports the identical condition in two different formats depending on
the subcommand:

```console
$ gwcli audit
┌ Config warnings ───────────────────────────────────┐
│ ! hooks.token: Missing env var GW_HOOKS_TOKEN      │
└────────────────────────────────────────────────────┘

$ gwcli config validate
1 warning(s): ! hooks.token: Missing env var GW_HOOKS_TOKEN
```

I wrote the check against `config validate` — the subcommand whose entire job is
to answer this question — and grepped for the string I'd been staring at all
morning:

```bash
# before — passes with the token genuinely missing
out="$(gwcli config validate 2>/dev/null || true)"
if grep -qi "Config warnings" <<<"$out"; then
  echo "SELFTEST FAIL"; exit 1
fi
echo "SELFTEST PASS"
```

`config validate` never prints `Config warnings`. The grep cannot match. The
selftest passed instantly and cleanly with a required credential absent — the
exact state it existed to catch. Note it also carries the `2>/dev/null` reflex,
so the loud channel was gone there too.

What caught it was not review and not a test. It was running the **negative
control**: unsetting the variable on purpose and watching whether the check went
red. It didn't.

```bash
# after — match the substring both formats actually contain
if grep -qi "missing env var" <<<"$out"; then
```

## The fix

The real fix landed a day later, and it deleted the wrapper's entire reason to
exist.

Buried in the gateway's own configuration docs: the CLI **auto-loads a dotenv
file from its config directory on every invocation** — daemon, CLI, cron,
service unit, all of them. The secrets file already existed. It was just named
something the tool didn't know to read.

```bash
mv ~/.gwcli/secrets.env ~/.gwcli/.env      # that exact filename is the fix
chmod 600 ~/.gwcli/.env
```

```console
$ gwcli audit --limit 12 | awk '$2=="agent_run"'   # plain shell, no prefix, no wrapper
2026-08-10T06:12:04Z  agent_run   watch    ok
2026-08-10T06:24:11Z  agent_run   watch    ok
```

Both credentials now resolve for anyone who runs the binary, from anywhere. The
launcher script stopped sourcing anything. The wrapper survives for exactly one
unrelated reason — `PATH`, because the Node version manager puts the binary in a
directory that only an interactive shell's rc file adds, so `ssh host 'gwcli …'`
gets `command not found`. That's a different bug wearing the same coat.

![Before the fix only the launcher script sourced the secrets file, so a bare CLI invocation loaded nothing and printed config warnings to stdout; after renaming the file to the dotenv path the CLI auto-loads on every invocation, every path resolves both credentials and the wrapper's reason to exist disappears.](/assets/img/config-warning-on-stdout-corrupts-parsed-output-stderr-vs-stdout-diagnostics-awk-returns-nothing-2-dev-null-hides-loud-failure-cli-selftest-negative-control-env-prefix-parsed-commands/env-resolution.svg)

The selftest stayed, because renaming a file doesn't stop it going missing or a
key rotating out:

```bash
gwcli config validate 2>/dev/null | grep -qi "missing env var" && exit 1
```

## Why it matters, and the gotchas around it

**Prefix the env for any command whose output you parse, not just the ones that
need the secret.** That's the rule I'd hand to anyone else running a CLI inside
a pipeline. It's counter-intuitive precisely because the failing subcommand had
nothing to do with the missing credential.

**Diagnostics belong on stderr — and you are not in control of that.** This is
the oldest rule in the Unix toolbox and every CLI breaks it eventually, usually
via a pretty-printing layer that wraps `console.log`. Assume a tool you depend
on will one day put a banner in your data. The defences are cheap: pass whatever
`--json` / `--quiet` / `--no-color` flag exists and parse a structured format
rather than a table; or fail loudly when the shape is wrong, instead of treating
an empty match as a fact.

**An empty result is not evidence.** `awk` matching zero rows means "no rows
matched", which covers *there is no data*, *the data moved*, and *what I handed
you wasn't data at all*. My health check couldn't tell those apart, and the one
it silently chose was the alarming one. A parse that can return empty needs a
sanity assertion — did the header row arrive? — before its emptiness is allowed
to mean anything.

**`2>/dev/null` is a load-bearing decision, not punctuation.** In this incident
it was the difference between a five-second diagnosis and a false outage report.
If you're silencing stderr because a command is chatty, silence it *after*
you've checked the exit code, or route it to a file you actually read.

**You haven't tested a check until you've watched it fail.** Break the thing on
purpose, confirm red, put it back, confirm green. A selftest that passes when
broken is worse than no selftest — it converts an unknown into a false known,
and it is exactly the kind of green tick you'd cite while reporting an outage
that isn't happening.

**One deliberate non-fix.** The two-form asymmetry in the config — one field a
typed secret-reference object, the other a `${VAR}` string — is schema-forced,
not style drift: the second field's schema is string-only and cannot take the
object form, which is *why* it's the one that emits a warning rather than
throwing. That's now a comment in the config, because it reads as an
inconsistency and the obvious "cleanup" would put the whole failure straight
back.

This is part of the agent stack I'm building for an all-electric charter
catamaran that doesn't exist yet — the same lane the false report was about is
the one that carries [SignalK](https://github.com/sailingnaturali/signalk-mcp)
alarms to a phone. It stayed up. My confidence in my own health check did not.

*Related: [Monitor the delivery path, not just the alarm]({% post_url 2026-07-01-ntfy-401-silent-push-failure-delivery-path-health-check-heartbeat-dead-mans-switch %}) — the same alarm lane failing for real, and why a quiet system produces nothing to notice; and [Running OpenClaw on a Raspberry Pi alongside SignalK]({% post_url 2026-07-29-openclaw-raspberry-pi-signalk-boat-agent-gateway-mode-local-si-units-tools-profile-prompt-caching %}) — the gateway this CLI drives.*
