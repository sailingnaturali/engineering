---
layout: post
title: "Your remote coding agent has the repo, not the machine — Tailscale is the missing half"
description: "A cloud coding session can clone your repo, edit across every package, run the tests, and open the PR — all driven from a phone. Then you ask it to show you the thing running and hit a wall: the sandbox has your code, never your machine. The repo is portable; the running system isn't. A per-host tailnet is what closes that gap, and it's the same tunnel that already reaches a boat stranded behind Starlink CGNAT."
date: 2026-07-11
tags:
  - ai
  - agents
  - tailscale
  - selfhosted
  - remote-dev
  - devops
---

You can now run a coding agent as a *remote session* — a cloud sandbox that clones your repo, edits across every package, runs the tests, and opens the PR, all driven from a phone app while you're nowhere near a desk. It's genuinely good. Then you ask it to show you the proof-of-concept actually running, and nothing happens.

That's not a bug. The session has your **repo**. It never had your **machine**. The repo is portable — it travels into any sandbox as a git clone. The *running system* — your dev server on `localhost`, the service on your LAN, the device behind your home router — does not. Most of the time the repo is all the agent needs. The exception is the one that matters: anything you want to *look at running*.

This is framework-general. It applies to any cloud-hosted agent session — [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) remote sessions, cloud dev environments, an agent in a CI runner. The shape is always the same: portable code, stranded runtime.

## Problem

Our org is ~20 repos — SignalK plugins, MCP servers, Home Assistant config, the web app. A remote session anchored at the top-level repo, with a workspace `CLAUDE.md` that the sibling repos inherit, gives the agent cross-repo context for free. Reading, refactoring, testing, PRs — none of that needs anything but the code. It works beautifully from the dock.

Then the work produces something you have to *see*:

- a web POC whose dev server you actually want to click through
- a live service to hit — in our case the boat's SignalK server on the Pi, plus Home Assistant
- anything bound to `localhost` on the real box

The cloud sandbox can reach none of it. The Pi is the sharp version: it sits behind Starlink, which is [CGNAT](https://tailscale.com/blog/how-nat-traversal-works) — there is no inbound route to it from the public internet *at all*. But even the Studio in the next room is unreachable from a sandbox that only has your source tree. Different distances, same wall.

## The two planes

The fix starts as a naming exercise. Stop treating "the work" as one thing. There are two planes:

1. **Driving the work** — repo-bounded, runs anywhere. Phone app, cloud session, no machine required.
2. **The running system** — a real host plus its network. The dev server, the LAN service, the device.

The remote agent owns plane 1 completely. Plane 2 needs an actual box. The mistake is expecting the cloud session to deliver both — it structurally can't, and editing prompts won't change that. What you need is a path *from where you are* back to the machine that runs things.

## The bridge

A per-host [tailnet](https://tailscale.com/kb/1136/tailnet) puts the real machines and your phone on one private network. No subnet routes, no public exposure, no port-forwarding — each host joins individually and gets a stable address and a MagicDNS name:

```
$ tailscale status
100.126.222.111  studio         clarkbw@  macOS  -
100.104.78.15    homeassistant  clarkbw@  linux  -
100.92.194.27    iphone181      clarkbw@  iOS    -
100.115.37.115   naturalaspi    clarkbw@  linux  -
```

Now the POC runs on the real machine — the Studio — and you reach it from the phone. Bind the dev server to all interfaces and hit the MagicDNS name:

```bash
# on the Studio
$ python3 -m http.server 8911 --bind 0.0.0.0
```

```
# from the phone (or anywhere on the tailnet)
$ curl http://studio.tailb19444.ts.net:8911/
<h1>POC reachable over the tailnet</h1>
```

That's the whole trick. The cloud session does the repo work and lands the branch; the Studio runs it; the tailnet carries the one hop from your phone to the running thing. Same tunnel reaches `naturalaspi` — the SignalK server the public internet can't touch — because to the tailnet, CGNAT isn't there. The boat being unreachable from the outside was never a special case; it's just the most extreme point on the same line, and the bridge that fixes the Studio fixes the boat too.

## Why anchor at the org repo

One detail makes the remote half pull its weight: anchor the session at the **top-level org repo**, not an individual package. A workspace `CLAUDE.md` there — inherited by every sibling via a symlink — means one session reasons across all ~20 repos instead of one. The agent that just edited a plugin already knows where the MCP server and the HA config live. Without the anchor you're back to one-repo-at-a-time, and the remote session stops being worth driving from a phone.

## Takeaway

A remote coding agent is two things welded together, and it only ships one of them to the cloud. Give it the **repo** *and* a **tunnel home** — anchor the session at the org repo so it spans everything, and put your machines plus your phone on a tailnet so "go look at it running" is one hop away. Do both and dev-from-the-dock stops being a demo. Do only the first and you'll keep hitting the wall where the code is right there and the running system is nowhere.
