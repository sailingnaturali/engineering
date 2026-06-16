---
layout: post
title: "A 404 isn't a tool failure: how raise_for_status on a missing path trips the MCP circuit breaker and eats your valid reads"
description: "In an agent + MCP stack, a 404 from an upstream HTTP API usually means 'this value isn't published' — a normal not-available result, not a failure. If your tool layer calls raise_for_status() on every response, a burst of 404s (an agent guessing paths) trips the client's consecutive-failure circuit breaker, which then silently drops your valid reads too. Here's the broke → tried → fixed: treat 404 as a null result, keep raising on 5xx."
date: 2026-06-16
tags:
  - mcp
  - ai
  - agents
  - api
  - selfhosted
---

An agent intermittently "loses" a tool. It reads a sensor fine ten times, then
flatly claims the value is unavailable — for a path you can see returning data in
the upstream server's own UI. Restart the session and it works again, for a
while. The cause isn't the tool and isn't the server: it's a `raise_for_status()`
in the HTTP client turning a perfectly normal **404 ("not published")** into a
tool *failure*, and a burst of those tripping the agent runtime's
**consecutive-failure circuit breaker** — which then suppresses the *valid* calls
queued behind them.

This is the broke → tried → fixed of an MCP tool that wraps an HTTP API where
"absent" is a legitimate answer.

## Problem

The stack: a small local model asks a question, the agent runtime fans it out
into several tool calls, each tool call hits an MCP server, and the MCP server
reads an upstream HTTP API. In our case the upstream is [SignalK](https://signalk.org/)
(a marine data server) and the tool is `read_sensor(path)` — but nothing here is
marine-specific. Substitute any HTTP API where a missing key returns 404.

The symptom, from the agent transcript:

```
user: how's our course and speed?
agent: Speed over ground is 6.1 knots. Course is unavailable right now.
```

Course was *not* unavailable. The upstream server was serving
`navigation.courseOverGroundTrue` = 205° the entire time — you can watch it tick
in the server's own data browser. Yet the agent says "unavailable," and a minute
later the same question answers correctly. Intermittent, path-specific,
self-healing. The worst kind.

The naive client — the one almost everyone writes first — looks like this:

```python
async def get_value(self, path: str) -> dict:
    url = f"{self.base_url}/api/vessels/self/{path.replace('.', '/')}"
    resp = await self._http.get(url)
    resp.raise_for_status()      # <-- every non-2xx becomes an exception
    return resp.json()
```

`raise_for_status()` raises `HTTPStatusError` on **any** 4xx/5xx. The MCP tool
that calls `get_value` lets that exception propagate, so the runtime records the
tool call as a failure. That seems reasonable — until you look at *what* is
404ing and *how often*.

## Diagnosis

Two facts collide.

**Fact 1: a 404 here means "this path isn't published," which is normal.** A
boat with no electronic compass doesn't publish `navigation.headingMagnetic`. A
vessel at anchor doesn't publish `navigation.courseOverGroundTrue` (no course
when you're not moving). The server's REST API answers those with a 404. That's
not an error condition — it's the API's way of saying *I don't have that*. The
same is true of countless HTTP APIs: 404 on a resource that doesn't exist is an
expected, information-bearing answer, not a fault.

**Fact 2: the agent generates 404s in bursts, by design.** Ask a small model
(this bit us on a local ~30B) "course and speed?" and it doesn't know the exact
paths, so it *guesses* — fanning out parallel calls:

```
read_sensor("navigation.headingTrue")        -> 404  (no compass)
read_sensor("navigation.headingMagnetic")    -> 404  (no compass)
read_sensor("sensors.depth")                 -> 404  (wrong namespace)
read_sensor("navigation.courseOverGroundTrue") -> 200, 205°   <-- the good one
```

Three guesses 404, then the *correct* path is queued right behind them. With the
naive client, those three 404s are three raised exceptions — three recorded
**tool failures in a row**.

Now bring in the runtime. Agent runtimes run a per-tool **circuit breaker**: after
N consecutive failures of the same tool, the breaker *opens* and the runtime
stops dispatching that tool for a cooldown, returning an immediate
"tool unavailable" instead of calling it. The widely-cited default is **N = 3**
([circuit breaker for repeated tool failures in agent loops](https://github.com/openclaw/openclaw/issues/67399);
[MCP circuit breaker pattern](https://dev.to/neurolink/mcp-circuit-breaker-preventing-cascading-failures-in-ai-tool-calls-4bi4)).
Ours was exactly 3.

So: three guessed-path 404s trip the breaker, the breaker opens, and the *valid*
`courseOverGroundTrue` read queued behind them never gets dispatched. The agent
is handed "tool unavailable" for a path that was serving data the whole time. The
model's bad guessing is the *trigger*, but `raise_for_status()` on a 404 is what
makes it *fatal* instead of harmless.

It even masquerades as a server crash. In the upstream access log, the server
happily answers requests up to the last 404 — and then sees *nothing*. The later
requests never left the client, because the breaker opened on the client side.
Don't go chasing a phantom upstream outage; check the runtime's failure counter.

## What we tried (and why it failed)

### Attempt 1 — raise on every non-2xx (the starting point)

```python
resp = await self._http.get(url)
resp.raise_for_status()   # raises HTTPStatusError on 404 just like on 500
return resp.json()
```

This is the bug. `raise_for_status()` makes no distinction between "the resource
isn't there" (404) and "the server is broken" (500). Every guessed path becomes a
tool failure. Three in a row → breaker open → valid reads dropped. The contract is
wrong at the source: we're reporting *absence* as *failure*.

### Attempt 2 — just bump the breaker threshold

If 3 is too few, raise it:

```yaml
# agent runtime config
tool_failures:
  same_tool_failure: 8    # was 3
```

This doesn't fix anything — it raises the price of admission. A chattier model, or
a question that fans out into more guesses, still walks past 8. Worse, you've now
*blunted the breaker for real outages*: when the upstream genuinely goes down, the
runtime now eats 8 failed calls before protecting itself. You've traded a
false-positive problem for a slower true-positive. The breaker isn't the thing
that's wrong; the failure *classification* feeding it is.

### Attempt 3 — retry the failed calls

Wrap the call in a retry so a "transient" failure gets another shot:

```python
for attempt in range(3):
    resp = await self._http.get(url)
    if resp.status_code < 400:
        return resp.json()
    await asyncio.sleep(0.2 * attempt)
resp.raise_for_status()
```

A 404 is not transient. The path that isn't published at 0 ms is still not
published at 600 ms. All this does is turn three fast 404s into nine slow ones —
*more* failures toward the breaker, plus latency, and the breaker still opens.
Retrying is the right tool for timeouts and 5xx; it's the wrong tool for "the
resource doesn't exist."

### Attempt 4 — fix it in the prompt

Tell the model the exact paths so it stops guessing:

```
When asked for course, read navigation.courseOverGroundTrue.
When asked for heading, read navigation.headingTrue.
Never read sensors.depth; use environment.depth.belowTransducer.
```

Path hints *reduce* guessing, and they're worth having — but they're
model-dependent and fragile, and they don't make the tool layer safe. A different
model, a reworded question, a path the hint list forgot, and you're back to a
404 burst tripping the breaker. Breaker-safety has to live in the deterministic
tool layer, not in a prompt the next model release might ignore.

## The fix

Treat 404 as a **null-valued result**, not an error. Return `{"value": None}`
instead of raising — and keep raising on everything that's a *real* fault (5xx,
connection errors, timeouts), because those are exactly what the breaker *should*
see and act on.

```python
async def get_value(self, path: str) -> dict:
    """Fetch a value object from the upstream API.

    A 404 means the upstream simply doesn't publish that path — a normal
    "not available" result, not a failure. We return a null-valued dict
    rather than raising, so missing/guessed paths don't register as tool
    failures (which can trip the client's consecutive-failure circuit
    breaker). Any other HTTP error (5xx, etc.) is a real fault and still
    raises.
    """
    url = f"{self.base_url}/api/vessels/self/{path.replace('.', '/')}"
    resp = await self._http.get(url)
    if resp.status_code == 404:
        return {"value": None, "timestamp": None}
    resp.raise_for_status()   # 5xx / other faults still raise — breaker still works
    return resp.json()
```

One branch. Check for 404 *before* `raise_for_status()`, return a null result, and
let `raise_for_status()` handle the genuinely-broken cases. The breaker still
protects you against a real upstream outage (a string of 500s still trips it), but
a guess-storm of "not published" paths now flows through harmlessly as
`value=None`.

Apply the same rule to any endpoint where absence is a valid answer — a tree-walk
for path discovery, a sub-resource fetch, etc.:

```python
async def get_subtree(self, root: str) -> dict:
    resp = await self._http.get(f"{self.base_url}/api/.../{root}")
    if resp.status_code == 404:
        return {}            # nothing published there yet — empty, not broken
    resp.raise_for_status()
    return resp.json()
```

There's a quiet bonus: a **present-but-null** value (e.g. course while stationary,
which the API returns as `null`) and an **absent** path (404) now surface as the
*same* shape — `value=None`. The agent gets one consistent "unavailable" concept
to reason about, instead of one path that returns `null` and another that throws.

## Why it matters / gotchas

This generalizes past SignalK to **any** agent/MCP tool sitting over an HTTP API
where "absent" is a legitimate result. The pattern is always the same:

- **Distinguish "absent" from "broken" at the HTTP boundary.** 404 (and often an
  empty 200) means *the data isn't there* — an answer, not a failure. 5xx,
  connection refused, and timeouts mean *the system is broken* — those are
  failures, and the breaker should see them. Collapsing the two with a blanket
  `raise_for_status()` is the root mistake.
- **Circuit breakers amplify a mislabeled error into cascading tool loss.** A
  breaker is a multiplier: misclassify one normal response as a failure and the
  breaker turns a handful of them into *every* subsequent call failing for a
  cooldown window. The blast radius of "404 raises" is not one bad read — it's all
  the good reads behind it.
- **Agents guess; assume bursts of "not found."** Any model driving a path- or
  ID-addressed API will probe wrong keys, especially smaller local models. Don't
  treat that as pathological — treat *absence* as a first-class, non-failing
  result so guessing is cheap.
- **Don't blunt the breaker to paper over this.** Raising the threshold or
  retrying 404s both make the breaker worse at its actual job (catching real
  outages) while only delaying the false trip. Fix the classification, not the
  breaker.
- **It looks like an upstream crash but isn't.** When the breaker opens
  client-side, the upstream's access log just goes quiet — the later requests
  never leave the agent. Check the runtime's failure counter before you go
  debugging a server that's perfectly healthy.

The one-line test for whether a status code should raise: *would a healthy system,
correctly used, ever return this?* For 404-on-a-missing-resource, the answer is
yes — so it must not raise.

## Close

This came out of building the AI ops layer for an all-electric charter catamaran —
a local LLM driving MCP tools over a SignalK marine-data server. The tool that
wraps SignalK is open source, 404-handling and all:
[github.com/sailingnaturali/signalk-mcp](https://github.com/sailingnaturali/signalk-mcp).
