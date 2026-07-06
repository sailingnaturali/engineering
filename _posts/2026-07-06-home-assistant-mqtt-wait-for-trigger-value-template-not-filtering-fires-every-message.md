---
layout: post
title: "MQTT value_template doesn't filter: our wait fired on every message"
description: "An MQTT wait_for_trigger that 'matched' a JSON trace_id passed every end-to-end test for two days — and had never filtered anything. Three stacked gotchas: value_template transforms instead of filters without payload:, templates render native types so a boolean never matches a string payload, and script variables aren't in scope in the per-message value_template render. The working fix is a repeat/until loop."
date: 2026-07-06
tags:
  - homeassistant
  - mqtt
  - automation
  - voice-assistant
  - templates
  - selfhosted
---

> **TL;DR:** An MQTT trigger's `value_template` is a payload *transformer*, not a filter — with no `payload:` key the trigger fires on **every** message on the topic. And script variables aren't in scope in the per-message render, so a trigger-level match on a runtime variable isn't expressible at all. Fire on everything and loop with `repeat`/`until` instead — [jump to the fix](#the-fix).

{% raw %}
A Home Assistant script that does a synchronous MQTT round-trip — publish a question, `wait_for_trigger` on the reply topic for the message whose JSON payload carries the matching `trace_id` — passed every end-to-end test for two days. Then a second producer started publishing on the reply topic, and the wait matched the wrong message instantly. The "filter" had never filtered anything, and fixing it properly took peeling three separate layers of HA template semantics. This is the broke → tried → fixed.

## Problem

The setup: a voice query is published to an ask topic with a generated `trace_id`; an agent daemon answers on a shared say topic; the script waits for the reply that carries the same `trace_id` back, then speaks it.

```yaml
# script: ask the agent, wait for the matching reply
- variables:
    trace_id: "{{ now().timestamp() | round(3) }}-{{ range(1000, 9999) | random }}"
- action: mqtt.publish
  data:
    topic: naturali/intents/ask
    payload: '{"text": "{{ text }}", "trace_id": "{{ trace_id }}"}'
- wait_for_trigger:
    - trigger: mqtt
      topic: naturali/agents/+/say
      value_template: "{{ value_json is defined and value_json.trace_id | default('') == trace_id }}"
  timeout: "00:01:15"
  continue_on_timeout: true
# ...then speak wait.trigger.payload_json.text
```

This worked in every trial. Then the daemon gained interim acknowledgments — it now publishes "Let me check the pilot book." on the same say topic *before* the final answer, so the user isn't sitting in silence during a long tool call. Interim messages carry no `trace_id` at all.

The moment that shipped, the voice satellite started speaking the interim acknowledgment *as the answer*, and the real answer never arrived. The script trace shows the wait happily matching a payload that doesn't even contain a `trace_id`:

```yaml
wait:
  completed: true
  trigger:
    payload: '{"text": "Let me check the pilot book.", "interim": true}'
```

`value_json.trace_id | default('') == trace_id` should be false for that payload. The wait completed anyway.

## Diagnosis

An MQTT trigger's `value_template` is not a filter. The [trigger docs](https://www.home-assistant.io/docs/automation/trigger/#mqtt-trigger) say exactly what it is, if you read it the right way:

> The `payload` option can be combined with a `value_template` to process the message received on the given MQTT topic **before matching it with the payload**.

`value_template` is a payload *transformer*: it rewrites the incoming message, and the rewritten result is then compared against the `payload:` key. **With no `payload:` key, nothing is ever compared, and the trigger fires on every message on the topic.** Our template rendered `True` or `False` per message and the result was thrown away — the trigger fired regardless.

So why did it pass two days of end-to-end trials? Because under the old traffic mix, the reply was the *only* message ever published on the say topic. "Fire on everything" and "fire on the matching reply" are observationally identical when there's exactly one message. The filter was unverified the whole time; the interim messages just made it visible.

This is the opposite of a template `condition`, where `value_template` rendering truthy *is* the gate. Same key name, different semantics per context — that asymmetry is the root trap here.

## What we tried (and why it failed)

### Attempt 1 — add `payload: "True"` so the boolean has to match

If the rendered template is compared against `payload:`, then requiring the render to equal `"True"` should turn the existing boolean template into a filter:

```yaml
- wait_for_trigger:
    - trigger: mqtt
      topic: naturali/agents/+/say
      payload: "True"
      value_template: "{{ value_json is defined and value_json.trace_id | default('') == trace_id }}"
  timeout: "00:01:15"
  continue_on_timeout: true
```

Result: the wait matched *nothing*. Every ask now timed out:

```yaml
wait:
  completed: false
  trigger: null
```

Why: Home Assistant templates render **native types**. That template returns the boolean `True`, not the string `"True"`, and a boolean never equals the string payload it's compared against. The trigger went from matching everything to matching nothing — which at least proved the comparison was now happening.

### Attempt 2 — render an explicit string instead of a boolean

Fine — sidestep the type problem by rendering a sentinel string and matching on that:

```yaml
- wait_for_trigger:
    - trigger: mqtt
      topic: naturali/agents/+/say
      payload: "reply-match"
      value_template: >-
        {{ 'reply-match' if (value_json is defined
           and value_json.trace_id | default('') == trace_id)
           else 'reply-skip' }}
  timeout: "00:01:15"
  continue_on_timeout: true
```

Still matched nothing. The template silently rendered `reply-skip` for every message — including the real answer with the correct `trace_id`.

Why: **script variables are not in scope inside an MQTT trigger's `value_template`.** `trace_id` was undefined in that render, so the comparison could never be true. This one is genuinely confusing, because the [script docs](https://www.home-assistant.io/docs/scripts/#wait-for-a-trigger) say:

> All previously defined trigger variables, variables and script variables are passed to the trigger.

That's true — *at trigger setup*. In [the MQTT trigger source](https://github.com/home-assistant/core/blob/dev/homeassistant/components/mqtt/trigger.py), the `topic:` and `payload:` templates are rendered once, when the trigger is attached, with your variables available:

```python
variables = trigger_info.get("variables")
wanted_payload = command_template(None, variables)
topic = topic_template.async_render(variables, limited=True, parse_result=False)
```

But the per-message `value_template` render gets only the payload — no variables parameter at all:

```python
payload := value_template(mqttmsg.payload, PayloadSentinel.DEFAULT)
```

So `value_json` and `value` exist in a `value_template`; your script's `trace_id` does not, and there is no error — `| default('')` swallowed the undefined variable and the else-branch rendered every time. A correct trigger-level match on a runtime variable is simply not expressible here. (Related long-standing report for the trigger's `for:` template: [home-assistant/core#63886](https://github.com/home-assistant/core/issues/63886).)

## The fix

Stop filtering in the trigger entirely. Fire on every message, and loop until the matching one — because a template **condition** in the script body *does* see script variables:

```yaml
- repeat:
    sequence:
      - wait_for_trigger:
          - trigger: mqtt
            topic: naturali/agents/+/say
        timeout: "00:01:15"
        continue_on_timeout: true
    until:
      - condition: template
        value_template: >-
          {{ wait.trigger is none
             or ((wait.trigger.payload_json | default({})).trace_id
                 | default('')) == trace_id }}
```

How it works:

- The bare MQTT trigger matches every say. Each iteration consumes one message.
- The `until` condition exits the loop when the payload's `trace_id` matches — and `trace_id` *is* in scope here, because conditions render with the script's run variables.
- `wait.trigger is none` is the timeout escape: on timeout with `continue_on_timeout: true`, `wait.trigger` is `null`, the condition is true, and the loop exits instead of spinning forever.
- The `wait` variable persists after the `repeat`, so downstream steps are unchanged: a timeout branch still checks `wait.trigger is none`, and the answer still comes out of `wait.trigger.payload_json.text`.

Trace-verified live: the loop consumed two interim messages (`reply-skip` cases, in attempt-2 terms) and exited on the reply carrying the matching `trace_id`, which the satellite then spoke.

One behavior change to be aware of: the timeout is now *per message*, not per wait. A chatty topic can keep the loop alive past the old 75-second ceiling. For an interactive voice round-trip that's acceptable; if you need a hard overall deadline, track `now()` in a variable before the loop and add an elapsed-time clause to the `until`.

## Why it matters / gotchas

**A filter you've never seen reject anything is unverified — even if every end-to-end test passes.** Our trials all published a question and got an answer back; all criteria green, two days running. None of them published a message that *must not* match and watched it get ignored. Selectivity needs a negative case, and a topic with one producer can't generate one by accident.

**New traffic on a shared topic is a breaking change to subscribers.** Every consumer of that topic was implicitly tuned to the old traffic mix — one producer shape for a month. Adding a second message shape broke two consumers in one afternoon: this wait, and the broadcast automation that announces says on the voice satellite. (That second one is its own HA gotcha: calling `assist_satellite.announce` on a satellite during its active voice session kills the session. Interim messages now carry `interim: true` in the payload and the broadcast automation skips them — the payload contract lives in the agent daemon, linked below.)

**HA template semantics differ by context, and the differences are silent.** Three separate live failures, one per assumption:

| Context | `value_template` means | Sees script variables? |
|---|---|---|
| MQTT trigger | transform payload, then compare to `payload:` (no `payload:` → no filtering) | No — per-message render gets payload only |
| Condition | render truthy → pass | Yes |
| Everywhere | renders **native types** — boolean `True` ≠ string `"True"` | — |

None of these failure modes log anything. The trigger that matches everything, the payload that matches nothing, and the variable that silently renders as its default all look identical in the logs — the script trace (`wait.completed`, `wait.trigger`) is where each one actually showed its shape.

## Close

This round-trip is the spine of a voice assistant for an all-electric charter catamaran — a Home Assistant satellite asking an MCP-backed agent about pilot books and tide windows, with MQTT as the seam between them. The agent daemon side, including the say-topic payload contract with the `interim` flag, is open source: [github.com/sailingnaturali](https://github.com/sailingnaturali).
{% endraw %}

*Related: [routing all HA voice to a custom agent with a wildcard sentence]({% post_url 2026-06-01-ha-2026.5-hassil-3-wildcard-voice-routing-missinglisterror %}) — the front half of this pipeline — and [the assist_satellite.announce no-audio gotcha]({% post_url 2026-06-01-home-assistant-nabu-voice-no-audio-assist-satellite-announce %}) on the same satellite.*
