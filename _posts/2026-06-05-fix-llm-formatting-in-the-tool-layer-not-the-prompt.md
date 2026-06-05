---
layout: post
title: "Fix LLM formatting in the tool layer, not the prompt: stop your MCP voice agent reading raw lat/long, ISO timestamps, and SOC fractions"
description: "If your MCP-backed voice agent reads '48.76 degrees north, 123.04...' or 'state of charge zero point six eight' out loud, the fix is not another prompt rule. Prompt formatting instructions are model-dependent and leak — the model reformats any raw field it can still see. Format in the MCP tool response instead: a display field, removing raw fields, and naming keys so they don't leak. With code examples from our open-source signalk-mcp and logbook-mcp servers."
tags:
  - ai
  - mcp
  - voice-assistant
  - llm
  - claude
  - tool-use
date: 2026-06-05
canonical: "https://engineering.sailingnaturali.com/fix-llm-formatting-in-the-tool-layer-not-the-prompt/"
---

If you point an LLM agent at an MCP server and then route its replies through text-to-speech, you will eventually hear it say something like:

> "Your position is forty-eight point seven six degrees north, one two three point zero four degrees west, and state of charge is zero point six eight."

That is a raw latitude/longitude pair and a 0–1 fraction being read aloud verbatim. The instinct is to fix it in the prompt — "always speak the battery as a percentage," "format position as degrees north and west." That instinct is a trap. This is the broke → tried → fixed of getting clean spoken output, and the punchline is: **format in the tool response, not in the prompt.**

This is a design post, not a single-bug writeup, but it maps to the same arc — a wrong behaviour, a dead-end that looks right, and a fix that actually holds.

## Problem

The boat agents here run on a local LLM with a Home Assistant voice front-end, backed by a set of MCP servers. The agent calls a tool, gets JSON back, composes a reply, and TTS speaks it. The trouble starts with what's in that JSON.

SignalK stores everything in SI units, so a wind-speed read comes back as bare metres-per-second:

```json
{ "path": "environment.wind.speedApparent", "value": 8.5, "timestamp": "2026-05-18T00:00:00Z" }
```

A battery state-of-charge comes back as a 0–1 fraction:

```json
{ "capacity": { "stateOfCharge": { "value": 0.68 } } }
```

A position comes back as a coordinate dict:

```json
{ "value": { "latitude": 48.7601, "longitude": -123.0410 } }
```

A timestamp comes back as ISO 8601 UTC:

```json
{ "timestamp": "2026-06-01T19:30:00Z" }
```

Feed any of those to an LLM and tell it to talk, and you get raw values spoken aloud:

```
"Eight point five."                                # the raw m/s, not knots
"State of charge zero point six eight."            # wrong — should be 68%
"Forty-eight point seven six zero one degrees      # unspeakable
 north, negative one two three point zero four
 one zero degrees..."
"Twenty twenty-six dash zero six dash zero one     # reads the ISO string
 tee nineteen thirty zero zero zed."
```

The model is not malfunctioning. It is doing exactly what an LLM does: it sees a number it recognizes as a coordinate or a fraction, and it renders it however it feels like this turn.

## Diagnosis

Here is the part that took a couple of cycles to internalize: **the model reformats raw data it can see, regardless of your instructions, because it "knows" what that data is.** It has seen a billion latitudes. It knows `0.68` near a key called `stateOfCharge` is a fraction. It knows an ISO timestamp. So it will "helpfully" expand, convert, or mangle the raw field — and which way it mangles depends on the model, the temperature, and the phase of the moon.

That means a prompt rule isn't a fix, it's a suggestion the model is free to ignore the moment the raw value is still in front of it. You can't reliably instruct the model *not* to reformat data it can plainly read. The only reliable lever is the data itself: **don't put the raw value where the model will narrate it.**

## What we tried (and why it failed)

### The dead-end: fix it in the prompt

The obvious first move is to add formatting rules to the agent's system prompt:

```text
# system prompt — formatting rules (the dead-end)
When you report battery state of charge, always say it as a
percentage (e.g. "68 percent"), never as a decimal.
When you report position, say it as degrees north and degrees
west, rounded to two decimals (e.g. "48.76 north, 123.04 west").
When you report a time, say the local time, never the UTC
timestamp.
Speak wind speed in knots.
```

On the model and temperature you tested it on, this *mostly* works. Ship it, and within a day TTS says:

```
"State of charge is zero point six eight."
```

…because on this turn the model decided the decimal was fine. Tighten the rule, add an example, and now it works again — until you swap the local model for a different size, or the cloud model ships a new version, and the behaviour drifts back. Every fix is per-model and per-temperature.

It also doesn't compose. Each new field is a new rule:

```text
# ...and it keeps growing
Depth is in meters; say it in feet if under 10 meters...
Heading is degrees true; say "degrees" not "degrees true"...
Distance to waypoint is in meters; say nautical miles if over 1000...
```

The prompt becomes a pile of unit-conversion rules, the model still leaks one of them on any given turn, and you're playing whack-a-mole against a non-deterministic narrator. The root cause — the raw value is right there in the tool result — is untouched. This is a structural dead-end, not a tuning problem.

## The fix

Move the formatting into the **tool response**. Three techniques, in order of preference. All three are from our public MCP servers, so the real tool and field names below are fine to copy.

### 1. Pre-format a `display` field

Give the model a string that is already correct to read aloud, and let the raw value ride alongside for any code that needs to compute on it.

`read_sensor` (signalk-mcp) — the SI value rides alongside a pre-converted `display`:

```json
{
  "path": "environment.wind.speedApparent",
  "value": 8.5,
  "display": "16.5 knots",
  "unit": "knots",
  "timestamp": "2026-05-18T00:00:00Z"
}
```

`battery_state` (signalk-mcp) — `display` is a full spoken summary, with the units spelled out so TTS reads them naturally:

```json
{
  "bank": "house",
  "soc_fraction": 0.68,
  "voltage": 12.84,
  "current": -8.2,
  "display": "68 percent, 12.8 volts, 8.2 amps discharging",
  "timestamp": "2026-05-14T18:00:00Z"
}
```

`mark_moment` (logbook-mcp):

```json
{
  "id": 7,
  "entry_display": "Entry 7",
  "text": "Beautiful sunset off Discovery Island",
  "timestamp": "2026-06-01T19:30:00Z",
  "position": { "longitude": -123.04, "latitude": 48.42 },
  "position_display": "48.4 North, 123.0 West"
}
```

The model reaches for the obvious field to speak, and the obvious field is now the right one. This is the highest-leverage move and should be the default for anything that has a "natural" spoken form.

### 2. Remove the raw field entirely

A `display` field still leaves the raw value sitting in the JSON, and a model can still decide to narrate `soc_fraction` instead of `display`. When there is no good reason to return the raw value at all, **don't.**

`get_local_time` (signalk-mcp) returns no `utc` field — only the already-local, already-formatted time and the timezone it resolved to. There is no UTC string or ISO timestamp for the model to read aloud:

```json
{
  "iana_timezone": "America/Vancouver",
  "display": "19:30"
}
```

(`display` is `HH:MM` in 24-hour local time; the tool resolves the timezone from the vessel's GPS position and falls back to `"UTC"` with no fix.)

Position is the instructive exception. The same principle *suggests* dropping the raw lat/lon — but here it collides with a real need: agents calling `read_sensor("navigation.position")` need actual coordinates for programmatic use (computing a distance, feeding the next tool), not just a string to speak. So `read_sensor` deliberately keeps the raw dict in `value` and leans on technique 1 (a good `display`) for the spoken form:

```json
{
  "path": "navigation.position",
  "value": { "latitude": 48.76, "longitude": -123.05 },
  "display": "48.7600 North, 123.0500 West",
  "unit": "°",
  "timestamp": "2026-05-18T00:00:00Z"
}
```

That is the trade-off technique 2 forces you to make explicit: **remove the raw field when nothing downstream needs it; keep it — and accept you're back to relying on technique 1 — when something does.** `get_local_time` has no consumer for a UTC string, so it drops it outright and unspeakable output becomes impossible. Position has real consumers for the coordinates, so it keeps them and accepts the residual risk that a model *could* expand the dict into "negative one two three point zero five degrees." Knowing which case you're in is the real decision — not reflexively stripping every raw field.

### 3. Name keys so they don't leak

Key names leak into speech too — a model will sometimes narrate the field name, and a key that reads like a sentence fragment ("state of charge…", "timezone…") invites it. Name any key whose value isn't meant to be spoken so it reads as an opaque identifier, not prose. The two raw fields in these servers are named exactly this way:

```text
soc_fraction    # not "state_of_charge": "soc fraction" won't get read as prose,
                # and it signals "this is a 0–1 number, not the thing to speak"
iana_timezone   # not "timezone": "America/Vancouver" is a machine value, and the
                # name says so — the spoken value lives in `display`
```

The naming also encodes intent for the next person reading the schema: `soc_fraction` says *this is a 0–1 number, the percentage is in `display`.* The spoken form always lives in a `display`/`*_display` field; the raw fields carry names that read as machine values. If a key's name would be spoken naturally, that's the smell — rename it or drop it.

## Why it matters / the one place a prompt rule is fine

The principle generalizes past voice and past marine data: **anywhere an LLM tool result feeds generated output, formatting belongs in the tool response, because that's the only layer that's deterministic.** The prompt is advisory; the tool result is data. Put the contract in the data.

There is exactly one place where a prompt instruction is the right tool — and it's worth calling out so you don't over-rotate into "never touch the prompt":

**When the agent composes a confirmation sentence and reformats a value it already holds in context.** Say `mark_moment` already gives back `position_display: "48.4 North, 123.0 West"`, but the agent is writing a full confirmation like *"Marked. We're at forty-eight point four north, one twenty-three west."* That is sentence structure, not a unit conversion — the model is arranging a value it legitimately has, into prose. A single, one-line format instruction tied to that specific tool response is fine there:

```text
# acceptable prompt rule — sentence structure, not unit conversion
After mark_moment, confirm using position_display verbatim,
phrased as "<position_display>".
```

The line to hold: a prompt rule that says *how to arrange values into a sentence* is fine. A prompt rule that says *convert this unit / expand this fraction / reformat this timestamp* is the dead-end — that always belongs in the tool response. If you find yourself writing a conversion rule in the prompt, that's the signal to go fix the tool instead.

A couple of nearby traps:

- **A `display` field alone is not airtight.** As long as the raw field is still in the payload (technique 1), a model *can* still read it. Remove the raw field (technique 2) whenever nothing downstream needs it — that's the only way to make unspeakable output impossible rather than merely discouraged. When something genuinely needs the raw value (position's coordinates), you're knowingly back to relying on `display`; that's a deliberate trade-off, not an oversight.
- **Test on more than one model.** The whole reason prompt rules fail is cross-model drift. Your tool-layer fix should be verified the same way — swap the local model, bump the cloud model version, confirm the JSON still speaks correctly. If it's in the tool response, it will; that's the point.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran — a local LLM, SignalK, and a stack of MCP servers behind a Home Assistant voice front-end, where "what's our position" has to come back as something a human can actually hear. The servers the examples above are pulled from are open source: [github.com/sailingnaturali](https://github.com/sailingnaturali) (`signalk-mcp`, `logbook-mcp`).
