---
layout: post
title: "httpx async requests to a .local hostname time out on macOS"
description: "Every httpx.AsyncClient request to a .local (mDNS/Bonjour) hostname raises httpx.ConnectTimeout on macOS, while curl and sync requests to the same URL work fine. getaddrinfo returns an IPv6 candidate first and the async Happy Eyeballs connect waits out the full connect timeout on the unroutable IPv6 path before trying IPv4. The fix: resolve the .local host to its IPv4 address once at the URL boundary — plus what happens when the same 30-line patch is needed across five repos."
date: 2026-07-28
tags:
  - python
  - httpx
  - macos
  - mdns
  - ipv6
  - mcp
  - networking
---

> **TL;DR** — On macOS, `httpx.AsyncClient` requests to a `.local` (mDNS/Bonjour)
> hostname raise `httpx.ConnectTimeout` even though the host is up and `curl`
> works instantly. `getaddrinfo` puts an IPv6 candidate first, and the async
> connect burns the whole connect timeout on that unroutable path before IPv4
> gets a turn. Resolve the `.local` host to IPv4 yourself, once, at the URL
> boundary — the system resolver handles mDNS fine — and rewrite the URL.
> [Jump to the fix](#the-fix).

Our boat's AI agent talks to a [SignalK](https://signalk.org/) server on a
Raspberry Pi through a fleet of MCP servers — vessel data, logbook, tidal
currents, weather. All of them are thin Python services that reach the Pi over
HTTP with `httpx.AsyncClient`, and all of them address it by its mDNS name,
`boat-server.local`. One day, running the fleet from a Mac, every single tool
call timed out. Not one server — all of them, silently, the same way.

## Problem

The client code is as plain as HTTP gets:

```python
import httpx

client = httpx.AsyncClient(timeout=5.0)
resp = await client.get("http://boat-server.local:3000/signalk/v1/api/vessels/self")
```

And every call dies like this:

```
  File ".../httpx/_transports/default.py", line 101, in map_httpcore_exceptions
    raise mapped_exc(message) from exc
httpx.ConnectTimeout
```

Five seconds per request, every request, `httpx.ConnectTimeout` at the end of
it. From the agent's point of view the whole tool surface is just... gone. It
answers questions with "I couldn't reach the vessel data server" while the
server sits there, healthy, twenty feet away.

The part that sends you down the wrong path: **everything else can reach it.**

```console
$ curl -s http://boat-server.local:3000/signalk/v1/api/vessels/self | head -c 60
{"name":"Naturali","mmsi":"368...
$ ping boat-server.local
64 bytes from 192.168.1.20: icmp_seq=0 ttl=64 time=4.2 ms
```

Instant. So the server is fine, mDNS resolution is fine, the network is fine —
only the async Python path fails.

## Diagnosis

Ask the resolver what it actually returns for the name:

```console
$ python3 -c "import socket; \
    [print(ai[0].name, ai[4][0]) for ai in \
     socket.getaddrinfo('boat-server.local', 3000, type=socket.SOCK_STREAM)]"
AF_INET6 fe80::dea6:32ff:fe12:3456
AF_INET  192.168.1.20
```

There it is. On macOS, `getaddrinfo` for the `.local` name returns **an IPv6
candidate first** — here a link-local `fe80::` address — and the IPv4 address
second. The IPv6 candidate is not usefully routable from the client (a
link-local address needs a scope/zone ID to be connectable, and the resolved
candidate doesn't carry a working one), so connecting to it goes nowhere: no
refusal, no reset, just silence until the timeout.

Modern clients are supposed to shrug this off. That's the whole point of
[Happy Eyeballs (RFC 8305)](https://datatracker.ietf.org/doc/html/rfc8305):
start with the first address family, and if it hasn't connected within a couple
hundred milliseconds, race the other one in parallel. `curl` does exactly this,
which is why it never blinks. The async Python stack is *supposed* to do it too
— anyio [implements Happy Eyeballs in `connect_tcp()`](https://github.com/agronholm/anyio/issues/69)
with a 250 ms stagger.

What we observed instead: the async connect sat on the dead IPv6 attempt for
the **full connect timeout** before IPv4 ever got a useful turn — so with a 5 s
timeout, every request was `ConnectTimeout`, 100% reproducible. Whatever the
stagger did under the hood, the practical behaviour on macOS with a `.local`
name was "wait out IPv6, then die."

And it hit **every MCP server in the fleet at once**, because they all shared
the same idiom: `SIGNALK_URL=http://boat-server.local:3000` in the environment,
`httpx.AsyncClient` in the client. We found it because an agent benchmark run
suddenly scored terribly — the model was doing everything right and the tools
were timing out underneath it.

## What we tried (and why it failed)

**Blame the server.** Restarted SignalK, checked its logs, hit the REST API
from three other machines. All fine — of course it was; `curl` from the same
Mac already proved that. Time spent anyway: too much.

**Raise the timeout.**

```python
client = httpx.AsyncClient(timeout=30.0)
```

This just moves the pain. The connect still burns the IPv6 attempt first, so
every cold request eats seconds before doing anything useful — and this stack
answers *voice* queries with a hard latency budget of a few seconds total. A
"fix" that spends the entire budget waiting on a dead address family is a
failure with extra steps.

**Hardcode the IP.**

```bash
SIGNALK_URL=http://192.168.1.20:3000
```

Works instantly — which confirms the diagnosis: connect to the IPv4 address and
there's nothing wrong at all. But the Pi's address comes from DHCP, and the
entire reason the config says `boat-server.local` is so nobody maintains an IP
address by hand. Hardcoding it trades a bug for a chore.

**Force IPv4 in the transport.** httpx has a
[documented knob](https://www.python-httpx.org/advanced/transports/) for
exactly this:

```python
transport = httpx.AsyncHTTPTransport(local_address="0.0.0.0")
client = httpx.AsyncClient(transport=transport)
```

Binding the local side to `0.0.0.0` restricts connections to IPv4, and it does
work. But it has to be threaded through **every** `AsyncClient` construction
site, in every service — including ones where the client is built deep inside a
helper. And it turns off IPv6 for *all* destinations that client touches, not
just the one broken `.local` name. We wanted the fix at the one place all the
services already share: the URL.

## The fix

Resolve the `.local` host to its IPv4 address **once, at the URL boundary**,
and hand httpx a URL with the IP already in it. The synchronous system resolver
handles mDNS perfectly well — the problem was never resolution, it was which
candidate the async connect tried first.

```python
import socket
from urllib.parse import urlsplit, urlunsplit


def resolve_local_host(base_url: str) -> str:
    """Resolve a .local (mDNS) host in base_url to its IPv4 address.

    Non-.local hosts, empty input, and resolution failures are returned
    unchanged so httpx still gets its normal shot.
    """
    parts = urlsplit(base_url)
    host = parts.hostname
    if not host or not host.endswith(".local"):
        return base_url
    try:
        infos = socket.getaddrinfo(host, parts.port, socket.AF_INET,
                                   socket.SOCK_STREAM)
    except (socket.gaierror, OSError):
        return base_url
    if not infos:
        return base_url
    ip = infos[0][4][0]
    netloc = ip if parts.port is None else f"{ip}:{parts.port}"
    return urlunsplit((parts.scheme, netloc, parts.path, parts.query,
                       parts.fragment))
```

Call it where the URL enters the process:

```python
base_url = resolve_local_host(os.environ.get("SIGNALK_URL",
                                             "http://boat-server.local:3000"))
client = httpx.AsyncClient(base_url=base_url, timeout=5.0)
```

Passing `socket.AF_INET` to `getaddrinfo` asks for IPv4 candidates only, so
there is no IPv6 address to trip over. Every request connects in milliseconds.

Two properties made this the right shape:

- **It's a pass-through.** Non-`.local` hosts come back untouched. Resolution
  failures come back untouched — httpx gets its normal shot and produces its
  normal error, instead of this helper inventing a new failure mode.
- **It's at the boundary.** One call where config becomes a client, instead of
  a transport flag threaded through every constructor.

## One fix, five repos: when a patch becomes a library

The first version of that function was pasted inline into the SignalK MCP
server, with a docstring and a small test file. Then the logbook server needed
it. Then currents. Then weather. Same commit message four times:

```
fix(client): resolve .local mDNS host to IPv4 (macOS httpx async/IPv6 hang)
```

Copy-pasting a fix across a fleet is fine exactly once — it's how you learn the
fix is actually cross-cutting. The fourth paste is the signal: this is a shared
library now. Ours is
[`naturali-mcp-netutil`](https://github.com/sailingnaturali/naturali-mcp-netutil)
— one function, stdlib-only, MIT, with the whole *why* in the README.

We deliberately did **not** publish it to PyPI. Consumers pull it as a
[uv git source](https://docs.astral.sh/uv/concepts/projects/dependencies/#git)
pinned to a tag:

```toml
dependencies = ["naturali-mcp-netutil>=0.1.0"]

[tool.uv.sources]
naturali-mcp-netutil = { git = "https://github.com/sailingnaturali/naturali-mcp-netutil", tag = "v0.1.0" }
```

The reasoning: this package has exactly four consumers, all ours. A PyPI
release adds packaging ceremony, a public namespace entry, and an implied
support surface — for a 30-line function nobody outside the fleet should
depend on. The git source gets pinned in each consumer's `uv.lock`, so builds
are just as reproducible, and if the helper ever grows a real audience,
publishing it properly later costs nothing. Publish when someone else needs
it, not when you do.

## Why it matters / gotchas

- **The failure is silent at the layer you're watching.** An MCP tool that
  times out doesn't crash anything — the agent just reports it can't get the
  data, which reads like a model problem or a server problem. If every tool
  backed by the same host degrades at once, suspect the network path before
  either.
- **"curl works" localizes the bug better than any log.** Same URL, same
  machine, different HTTP stack → the bug lives in the stack, not the server.
  That one console line should have saved the first hour.
- **`getaddrinfo` order is the whole game.** Async connect logic believes the
  resolver's ordering. When the first candidate is unroutable-but-silent (no
  RST, just a black hole), timeouts get charged to whoever is first in line.
- **The fix outlived the problem.** We later retired mDNS naming entirely —
  the fleet now reaches the boat server by a stable DNS name on a private
  tailnet, and `.local` no longer appears in any config. The resolver stayed:
  because it passes every non-`.local` URL through unchanged, it costs nothing,
  and it still guards anyone who points a config at a Bonjour name. A fix
  that's a pass-through survives its own obsolescence.

## Close

This came out of building the AI ops layer for an all-electric charter
catamaran — a stack of open-source MCP servers between the agent and the boat's
SignalK data. The resolver and the servers it guards are public:
[naturali-mcp-netutil](https://github.com/sailingnaturali/naturali-mcp-netutil),
[signalk-mcp](https://github.com/sailingnaturali/signalk-mcp), and the rest at
[github.com/sailingnaturali](https://github.com/sailingnaturali).

*Related: [launchd's minimal PATH breaks MCP servers: uv command not found]({% post_url 2026-06-04-launchd-minimal-path-breaks-mcp-servers-uv-command-not-found %}) — the other way an environment silently kills an MCP fleet — and [when MCP tools break, isolate the server before blaming the agent]({% post_url 2026-06-23-mcp-tools-not-showing-up-isolate-the-server-before-blaming-the-agent %}) for the debugging discipline that finds this class of bug.*
