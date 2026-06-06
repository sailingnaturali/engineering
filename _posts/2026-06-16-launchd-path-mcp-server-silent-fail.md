---
layout: post
title: "launchd's minimal PATH silently breaks MCP servers — use full paths"
description: "Your MCP server works by hand but reports no tools when started from a launchd service. The cause is launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which excludes ~/.local/bin and /opt/homebrew/bin, so a bare `command: uv` fails silently. Use absolute paths."
tags: [macos, launchd, mcp, ai, self-hosted, debugging]
date: 2026-06-16
canonical: "https://engineering.sailingnaturali.com/launchd-path-mcp-server-silent-fail/"
---

I run a local LLM agent that talks to a handful of [MCP](https://modelcontextprotocol.io/) servers — tide data, weather, SignalK, a logbook. On my workbench it works perfectly. The moment I moved the agent runtime under a `launchd` service so it would survive a reboot, the model started insisting it had no tools. No crash. No stack trace. No log line. Just a polite agent telling me, repeatedly, that the tools were "unavailable."

That symptom — *works in the terminal, dead under launchd, no error anywhere* — is one of the most time-wasting bugs on macOS, because every instinct points you at the wrong layer. Here's the actual cause and the one-line fix.

## Problem

The agent's MCP config pointed at `uv` to launch each server. Stripped down, the relevant part of `~/.hermes/config.yaml` looked like this:

```yaml
mcp_servers:
  tide:
    command: uv
    args: ["run", "tide-mcp"]
  weather:
    command: uv
    args: ["run", "weather-mcp"]
```

Run the agent by hand in my shell — every tool present, every call works:

```
$ tide.get_tide_heights ...   # works
$ weather.get_marine_forecast ...   # works
```

Run the *same* agent from its launchd service, ask it the same question, and:

> I'm sorry, Captain — I don't have any tools available to answer that.

No error in the agent's own logs. No error in `launchd`'s stderr capture. The MCP servers simply never came up, and the runtime reported the empty tool list to the model as if that were normal.

## Diagnosis

The tell is the gap between "works in my shell" and "dead under launchd." Anything that flips on *who started the process* is an environment problem, and on macOS the environment difference that bites hardest is `PATH`.

Your interactive shell builds up a fat `PATH` from `~/.zprofile`, `~/.zshrc`, Homebrew's `shellenv`, the `uv` installer's snippet, and so on. By the time you type `uv`, your shell resolves it to `~/.local/bin/uv` (or `/opt/homebrew/bin/uv`) without you ever thinking about it.

`launchd` does none of that. A `launchd`-spawned process gets a deliberately minimal PATH:

```
/usr/bin:/bin:/usr/sbin:/sbin
```

That's it. No `~/.local/bin`. No `/opt/homebrew/bin`. No `/usr/local/bin`. So when the runtime tries to spawn `command: uv`, the OS can't resolve `uv` to anything on that PATH and the spawn fails with `ENOENT` ("no such file or directory"). The runtime catches that spawn failure per-server, marks the server as unavailable, and carries on. The model is told there are no tools — which, as far as it knows, is true.

This is the same class of bug behind the perennial [`spawn uvx ENOENT`](https://github.com/orgs/modelcontextprotocol/discussions/20) reports in MCP clients launched from GUI apps: Claude Desktop, Cursor, VS Code. GUI-launched and `launchd`-launched processes share the same minimal-environment fate. The error is real; it's just swallowed before it reaches you.

## What we tried (and why it failed)

**Attempt 1: re-run it by hand.** First instinct — reproduce the failure. Except it doesn't fail by hand:

```
$ uv run tide-mcp
# starts cleanly, serves tools
```

Of course it does — my interactive shell has `~/.local/bin` on `PATH`. Running it manually is exactly the case that *can't* reproduce the bug, so this "test" actively misled me toward thinking the config or the server was fine and the runtime was at fault.

**Attempt 2: blame the config / the server.** I went spelunking through the MCP server code and the agent's tool-discovery logic, assuming a parsing bug or a handshake timeout. Nothing. The servers were fine. The config was fine. I was debugging the wrong process entirely — nothing was wrong with what `launchd` ran, only with whether it could find it.

**Attempt 3: a `PATH` line in the launchd plist.** The "right" fix on paper — set `EnvironmentVariables.PATH` in the `.plist`:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>PATH</key>
  <string>/Users/you/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
</dict>
```

This works, but it's the wrong layer to fix it at. It hard-codes a user-specific path into a service definition, it's invisible to anyone reading the MCP config later, and it papers over *every* PATH-dependent command at once instead of making the dependency explicit. It also means the config's `command: uv` is lying about what it actually needs. I wanted the fix where the problem is.

## The fix

Use absolute paths in every `command:` entry. Find the real path once:

```
$ which uv
/Users/you/.local/bin/uv
```

Then put that in the config — no `PATH` resolution, nothing for `launchd` to get wrong:

```yaml
mcp_servers:
  tide:
    command: /Users/you/.local/bin/uv      # or /opt/homebrew/bin/uv
    args: ["run", "tide-mcp"]
  weather:
    command: /Users/you/.local/bin/uv
    args: ["run", "weather-mcp"]
```

Tools came back immediately. The dependency is now stated in the file that owns it, and it doesn't matter who — `launchd`, a GUI app, cron — does the spawning.

## Why it matters / the diagnostic trick

The fix is trivial. *Finding* it is what eats the afternoon, because the bug is invisible in the only environment where you naturally test (your own shell). So the most valuable thing here isn't the fix — it's a way to reproduce launchd's environment on demand.

`env -i` clears the environment, then you hand it exactly the PATH launchd would give:

```
$ /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin uv run tide-mcp
/usr/bin/env: 'uv': No such file or directory
```

There's your silent failure, made loud. Run the *working* command through the same wrapper and it fails identically — which is the confirmation that PATH, not the server, is the problem. Swap in the absolute path and it starts. Thirty seconds, no plist edits, no guessing.

Two things to keep in mind:

- **This is not MCP-specific.** Any tool or subprocess spawned by a `launchd`-managed process inherits that minimal PATH — build scripts, backup jobs, a Python venv's interpreter, a Node binary, `ffmpeg`. If it works in your terminal and dies under `launchd`, run the `env -i` repro before you touch anything else.
- **`cron` and GUI-app launches have the same problem** with their own minimal environments. Absolute paths in the thing you control (the config, the script) is the portable fix; patching each launcher's environment is not.

I run this stack — a local LLM plus a set of MCP servers — as the operations layer on an all-electric charter catamaran, where "it survives a reboot unattended" is a hard requirement, not a nice-to-have. That's exactly the constraint that forces you off "works in my shell" and onto `launchd`, which is how you meet this bug in the first place. The MCP servers themselves ([tide-mcp](https://github.com/sailingnaturali/tide-mcp), [weather-mcp](https://github.com/sailingnaturali/weather-mcp), and friends) are open source.
