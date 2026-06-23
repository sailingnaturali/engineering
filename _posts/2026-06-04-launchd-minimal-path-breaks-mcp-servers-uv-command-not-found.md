---
layout: post
title: "launchd's minimal PATH breaks MCP servers: uv command not found"
description: "When a launchd-managed agent spawns a stdio MCP server with `command: uv`, the server dies with `uv: command not found` under launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) — uv lives in ~/.local/bin, which isn't on it. There's no stack trace surfaced; the model just reports the tools aren't available. Works in your shell, fails under launchd. Here's the trap and the fix: absolute paths, plus a one-liner to reproduce it."
date: 2026-06-04
tags:
  - macos
  - launchd
  - mcp
  - selfhosted
  - ai
  - automation
---

A stdio MCP server is just a subprocess. Your agent runtime runs something like
`uv run my-mcp-server`, talks to it over stdin/stdout, and exposes its tools to
the model. That works perfectly when you launch the agent from your terminal.
Move the same agent under a launchd service — a `LaunchAgent`, a daily job, a
bridge that restarts on crash — and the MCP tools vanish. No crash, no stack
trace, no log line. The model just says it doesn't have the tools. This is the
broke → tried → fixed of why.

## Problem

We run a local AI agent (Hermes) that loads several MCP servers over stdio. Each
one is declared in config with a `command:` that gets `exec`'d as a subprocess.
The natural way to write it — the way that works at the prompt — is to name the
launcher and let `PATH` resolve it:

```yaml
# agent config — mcp_servers
mcp_servers:
  signalk:
    command: uv          # <-- resolved via PATH
    args: ["run", "signalk-mcp-server"]
  weather:
    command: uv
    args: ["run", "weather-mcp-server"]
```

Run the agent by hand and every tool is live. Then we wired the agent into a
launchd-managed pipeline — a daily job kicked off by a `LaunchAgent` — and the
agent came up *fine*, answered normally, but reported it had no SignalK or
weather tools. Asked for a sensor reading, the model says some version of:

```
I don't have a tool available to read that.
```

That's the whole symptom. The agent process is healthy. The conversation works.
There is **no error in the agent log, no traceback, no "spawn failed"** — the MCP
servers simply aren't there. And the tell that sends everyone down the wrong path:
run the exact same agent from an interactive shell and it works every time.

## Diagnosis

launchd does not give your process the environment from your shell. It gives it a
**minimal PATH**:

```
/usr/bin:/bin:/usr/sbin:/sbin
```

No `~/.local/bin`. No `/usr/local/bin`. No `/opt/homebrew/bin`. None of the
`PATH` edits from your `.zshrc` / `.zprofile`, because launchd doesn't source a
login shell. So when launchd `exec`s the agent and the agent tries to spawn
`command: uv`, the lookup fails:

```
$ which uv
/Users/you/.local/bin/uv      # in your shell
                              # ...not on launchd's PATH
```

`uv` (installed by the standalone installer) lives in `~/.local/bin`. So does the
agent binary itself (`hermes`), and plenty of other modern CLIs. Under launchd,
`uv` is simply *not found*.

The reason this is so disorienting is **where** the failure lands. The agent
launches the MCP server as a child process and treats "couldn't start" as
"server not available" — exactly the same state as a server you didn't configure.
A stdio MCP transport that can't `exec` its command doesn't throw up into your
chat loop; it just never produces a tool list. So the model is told nothing is
there, and faithfully reports nothing is there. The root cause (`ENOENT` on `uv`)
is three layers down and never surfaces.

Two facts combine into the trap:

1. **launchd's PATH is minimal and doesn't include `~/.local/bin`** — this is by
   design ([launchd.info](https://www.launchd.info/), and Apple's
   [`launchd.plist`](https://keith.github.io/xcode-man-pages/launchd.plist.5.html)
   `EnvironmentVariables` key is the supported way to change it).
2. **A failed MCP subprocess spawn degrades silently to "tool unavailable"** —
   no different from a server you never configured.

## What we tried (and why it failed)

Because the symptom is "MCP tools missing," every instinct points at the MCP
layer. All of these were dead ends.

### Attempt 1 — restart the MCP server / restart the agent

The reflex: it's a stale or crashed server, bounce it.

```bash
# restart the agent's MCP gateway, reload config, retry
hermes gateway restart
```

Result: no change. The tools are still missing under launchd, and — the
confusing part — *they were never actually crashing*. There was nothing to
restart, because nothing had started. Restarting a process that fails to spawn
just fails to spawn again, identically and silently.

### Attempt 2 — assume the config / transport is wrong

Next suspicion: a bad server entry, wrong transport, a typo in the command. So we
re-read the config, double-checked the MCP server URLs and args, tried an
HTTP/SSE server instead of stdio to see if stdio was the problem:

```yaml
  signalk:
    command: uv
    args: ["run", "signalk-mcp-server"]   # looks correct...
```

Result: the config is *correct*. Run the agent in a terminal with this exact
config and all tools enumerate. The transport is fine; stdio is fine; the args
are fine. Every direct test of the configuration passes — because every direct
test runs in *your* shell, with *your* PATH.

### Attempt 3 — chase a phantom server outage

If the agent says the server's unavailable, maybe the server is down. So we went
looking for a crashed backend, a port conflict, a wedged process. There was
nothing to find: the standalone MCP smoke test connects and lists its tools just
fine, because it, too, runs in an interactive shell:

```bash
$ hermes mcp test signalk      # run by hand → works
✓ connected, 7 tools
```

Every isolated test passed. That's the signature of this bug, and it's worth
saying plainly:

> **Interactive shell: works. Under launchd: fails. Same machine, same config,
> same binary.** When you see that split, stop debugging the application and
> start debugging the environment — specifically `PATH`.

We were debugging MCP for an hour. The bug was never in MCP.

## The fix

Don't rely on `PATH` resolution for anything a launchd-managed process spawns.
Use **absolute paths** in every `command:` entry:

```yaml
# agent config — mcp_servers, launchd-safe
mcp_servers:
  signalk:
    command: /Users/you/.local/bin/uv     # absolute — no PATH lookup
    args: ["run", "signalk-mcp-server"]
  weather:
    command: /Users/you/.local/bin/uv
    args: ["run", "weather-mcp-server"]
```

One line on why: an absolute path skips `PATH` lookup entirely, so launchd's
stripped environment can't break it. (Find the real path with `which uv` in your
shell — typically `~/.local/bin/uv` for the standalone installer,
`/opt/homebrew/bin/uv` under Homebrew on Apple Silicon.)

**Reproduce it before you "fix" it.** This one-liner runs any command under
launchd's exact minimal PATH, so you can confirm the failure (and confirm the
fix) without deploying through launchd:

```bash
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin uv --version
# uv: command not found      <-- reproduces the launchd failure

/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /Users/you/.local/bin/uv --version
# uv 0.x.y                   <-- absolute path works
```

If you'd rather keep `command: uv` readable, the alternative is to hand launchd a
richer PATH via the plist `EnvironmentVariables` key (this affects the whole job,
not just one command):

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>PATH</key>
  <string>/Users/you/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
</dict>
```

Both work. We chose absolute paths in the command entries because the failure
mode they prevent is silent, and an absolute path is self-documenting: it can't
drift when someone edits their shell profile.

### The robust version: resolve the path yourself and fail loudly

For subprocesses *you* spawn in your own code (a generator, a build step, a
bridge), hardcoding an absolute path is brittle across machines. Better: resolve
via `which`, fall back to the known install dir, and **raise a clear error if the
binary genuinely isn't there** — so a missing tool is loud, not a mystery:

```python
import shutil
from pathlib import Path

def resolve_cli(name: str) -> str:
    """Find a CLI on PATH, fall back to ~/.local/bin, else fail loudly."""
    exe = shutil.which(name)
    if exe:
        return exe
    fallback = Path(f"~/.local/bin/{name}").expanduser()
    if fallback.exists():
        return str(fallback)
    raise FileNotFoundError(
        f"{name} not found on PATH or ~/.local/bin — install it "
        f"(e.g. `uv tool install {name}`) or add its dir to PATH."
    )

# subprocess.run([resolve_cli("vessel-knowledge"), "zones", ...])
```

The `~/.local/bin` fallback covers launchd's stripped PATH; the explicit
`FileNotFoundError` turns the *next* occurrence of this bug from a silent
"tools unavailable" into a one-line error that names the missing binary.

## Why it matters / gotchas

- **This is not specific to MCP, uv, or even macOS.** Any process spawned by
  launchd, `cron`, or a systemd unit that resets `PATH` (`User=` services often
  do) gets a stripped environment. Anything that worked because your shell profile
  put a directory on `PATH` — `uv`, `pipx` shims, `node` via a version manager,
  `brew`-installed tools — can vanish the moment it's launched by a scheduler
  instead of by you. The MCP server is just the messenger.

- **The real lesson is the silent-failure shape, not the PATH fact.** Plenty of
  people know launchd has a minimal PATH. What costs the hours is that a failed
  subprocess spawn surfaces as "feature not available" with no error, two or
  three layers up from the cause. When a launchd-run thing behaves as if a whole
  capability is missing, suspect a child process that couldn't `exec` before you
  suspect the capability.

- **"Works in my shell" is not a test of a launchd job.** Your interactive shell
  has a PATH a scheduler never will. Always test scheduled work under the
  scheduler's environment — the `/usr/bin/env -i PATH=...` one-liner above is the
  cheapest way to do it.

- **Fail loudly when a required binary is missing.** The fix that prevents the
  recurrence isn't the absolute path; it's the `FileNotFoundError`. A tool that
  silently degrades when a dependency is absent will cost someone this exact hour
  again. Make "binary not found" a loud, specific error.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran —
a local LLM, SignalK, and a stack of MCP servers, with a daily briefing kicked
off by a launchd job. "Why does the agent lose its tools only when the scheduler
starts it" turned out to be a one-word answer: `PATH`. The MCP servers behind it
are open source — [github.com/sailingnaturali/signalk-mcp](https://github.com/sailingnaturali/signalk-mcp)
is a representative stdio server, and the rest live at
[github.com/sailingnaturali](https://github.com/sailingnaturali).
