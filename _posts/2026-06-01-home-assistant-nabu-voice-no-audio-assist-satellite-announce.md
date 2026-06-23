---
layout: post
title: "No audio from the Home Assistant Nabu puck: use assist_satellite.announce"
description: "The Home Assistant Voice (Nabu) puck is an assist_satellite entity, so tts.speak to its media_player updates HA state but produces no sound — the fix is assist_satellite.announce. Plus the two follow-on traps: announcing into a busy satellite, and a silent Piper add-on crash that looks like 'chime plays but no speech.' Here's the broke → tried → fixed."
tags:
  - homeassistant
  - selfhosted
  - voice-assistant
  - ai
  - assist
  - piper
date: 2026-06-01
canonical: "https://engineering.sailingnaturali.com/home-assistant-nabu-voice-no-audio-assist-satellite-announce/"
---

You wire up a local voice pipeline on a Home Assistant Voice (Nabu) puck, fire a `tts.speak` at it from an automation, and nothing comes out. The pipeline runs. Home Assistant reports the TTS call succeeded. There is no speech. Worse, when you poke at it in Developer Tools, the `media_player` entity flips to `playing` exactly like you'd expect — so it *looks* like it's working, and you spend an hour staring at a service call that does nothing audible.

The root cause: the puck isn't a plain media player. It's an `assist_satellite` entity, and that changes how you have to route TTS. Get past that and there are two follow-on traps — announcing into a busy satellite, and a silently-crashed Piper add-on that masquerades as the original "no speech" symptom. Here's the full broke → tried → fixed.

## Problem

You push text to the puck and it never speaks. Search terms for the person hitting this right now: *Home Assistant Nabu voice no audio*, *Voice PE tts.speak no sound*, *assist_satellite no speech media_player*.

The obvious service call — speak some text to the puck's media player:

```yaml
service: tts.speak
target:
  entity_id: tts.piper          # your TTS engine entity
data:
  media_player_entity_id: media_player.home_voice   # the puck
  message: "Depth is 4.2 metres under the keel, Captain."
```

In Developer Tools → States, `media_player.home_voice` dutifully flips to `playing` and shows the media metadata. The speaker stays silent. This is the trap: **the state change is real, the audio is not.**

## Diagnosis

The puck is not a plain media player. The Home Assistant Voice puck runs ESPHome, and the **ESPHome integration exposes it as an [`assist_satellite`](https://developers.home-assistant.io/docs/core/entity/assist-satellite/) entity** — an entity "which represents a voice satellite, with its state following the underlying Assist pipeline." Both the `esphome` and `voip` integrations were [transitioned to `AssistSatelliteEntity`](https://developers.home-assistant.io/blog/2024/10/01/assist-satellite-entity/). This is true the moment the device is adopted; it has nothing to do with installing the Whisper add-on. (Whisper is just one way to give the pipeline local STT — Speech-to-Phrase and Home Assistant Cloud are the other two. None of them is what creates the satellite entity.) If you only realized the puck was a satellite around the time you set up local STT, that's coincidence, not cause.

The satellite owns its own audio path, driven by its configured pipeline. `tts.speak` with `media_player_entity_id` targets the generic media-player surface instead. In our setup, that surface is effectively vestigial on the satellite — HA updates the `media_player` entity state to `playing`, but no audio comes out, because nothing routed the speech through the satellite's announcement path. No error, no log line, just silence. (We're not the only ones who've watched `tts.speak` to a satellite go quiet — the community "[still can't make tts.speak work](https://community.home-assistant.io/t/still-cant-make-tts-speak-work/703522)" threads are full of it — but the exact behavior depends on your device and TTS engine, so treat this as our-setup observation, not a documented contract.)

The action that *does* route through the satellite's audio path is [`assist_satellite.announce`](https://www.home-assistant.io/integrations/assist_satellite/), which converts the message to a media id "using the text-to-speech system of the satellite's configured pipeline."

## What we tried (and why it failed)

### Dead-end 1: `tts.speak` to the media_player entity

The call above. Result: `media_player.home_voice` shows `playing`, attributes populate, **zero audio**. No exception in the logs. This is the most expensive dead-end precisely because it half-works — the state machine lies to you.

### Dead-end 2: immediate ack + async response (two announces)

Once you switch to `assist_satellite.announce`, the next instinct is conversational polish: speak an instant "One moment" so the user knows they were heard, then speak the real answer when the slow work (a tide lookup, an LLM round-trip) finishes:

```yaml
# DON'T — two announces fired without waiting for the first to finish
- service: assist_satellite.announce
  target:
    entity_id: assist_satellite.home_voice
  data:
    message: "One moment, Captain."
- service: assist_satellite.announce      # fires while #1 is still going
  target:
    entity_id: assist_satellite.home_voice
  data:
    message: "{{ answer }}"
```

The trouble is timing. The docs say [`async_announce`](https://developers.home-assistant.io/docs/core/entity/assist-satellite/) "should only return when the announcement is finished playing on the device," and that the satellite stays in `responding` until something calls `tts_response_finished` to bring it back to `idle`. So the second `announce` lands while the satellite is still `responding` from the first — and in our testing that's where it goes wrong: the second announce gets dropped or the satellite wedges.

How much of this is "documented bug" vs. "our setup" is worth being precise about, because the upstream picture is messier than it first looks:

- There *is* a report of an [assist satellite stuck in the "responding" state](https://github.com/home-assistant/core/issues/142363) (core #142363) — but it's about the satellite failing to return to `idle` after a normal conversation, and it was **closed as not planned**, so don't read it as a confirmed fix or as proof that announcing-into-`responding` deadlocks. It just establishes that the `responding` state can hang.
- There's a community thread, "[executing two assist_satellite.announce in a script fails](https://community.home-assistant.io/t/issue-executing-two-assist-satellite-announce-in-a-script-fails/931121)," but read it carefully: the failure was specific to a script **called from a voice intent**, and the diagnosed cause was mixing `announce` with `set_conversation_response` on the same device — *not* two announces colliding in general. The same two-announce script ran fine from an automation or Developer Tools. So it's a real gotcha, but a narrower one than "two announces always conflict."

Bottom line: the reliable rule that fixed it for us is **one announce, fired only when the satellite is `idle`** — see the fix. We treat "announcing into `responding` wedges the satellite" as our-setup behavior, consistent with the docs' state machine but not something upstream has labeled a bug.

### Dead-end 3: everything's correct and it's *still* silent

You've got `assist_satellite.announce`, a single call, fired on idle — and after some unrelated restart it goes mute again. Same signature as the very first problem: pre-announce chime, then no speech. You re-check your service call. It's fine.

It's not your call. The **Piper add-on had crashed** and never came back. TTS has no engine, so the message never gets synthesized and nothing speaks. Piper crashing on TTS calls is not just us: [Piper: Crash after any TTS call](https://github.com/home-assistant/addons/issues/3379) (addons #3379) reports exactly this — `ConnectionResetError` then a `FileNotFoundError` on an empty audio path, i.e. the synthesis never produced a file. With no watchdog, a crashed Piper stays down and there's no obvious symptom pointing at it.

> Note on the chime: `assist_satellite.announce` plays a pre-announce chime that is itself a media id, and the Voice puck also has its own on-device wake/feedback sounds. We saw the device still making *a* sound while speech was dead, which is what made this so confusing — but whether a given chime survives a dead Piper depends on where that chime comes from. Don't over-read it; the reliable tell is below.

## The fix

Three things, all small:

**1. Use `assist_satellite.announce`, targeting the satellite entity:**

```yaml
service: assist_satellite.announce
target:
  entity_id: assist_satellite.home_voice   # your puck's assist_satellite entity
data:
  message: "Depth is 4.2 metres under the keel, Captain."
```

> Substitute your own entity ID — it's machine-local. Find it in Developer Tools → States by filtering on `assist_satellite.`.

**2. One announce, on idle only.** Drop the immediate-ack pattern. Fire a single `announce` with the *final* response, and only when the satellite is idle — never while it's `responding`. If you need a "thinking" cue, do it without a second announce (a UI/light cue, or let the pipeline's own response carry it).

**3. Turn on the Piper add-on watchdog.** Settings → Add-ons → Piper → enable **Watchdog**. (This is our mitigation, not something the upstream issue prescribes.) Without it, a crashed Piper stays down and takes all TTS with it until you notice.

And the one diagnostic that saves the most time: **when speech goes mute, check the Piper add-on status before you touch your automation.** Speech depends on Piper; if Piper is down, no `announce` and no `tts.speak` will ever produce audio, no matter how correct the call is. The Piper add-on log (`ConnectionResetError`, `FileNotFoundError` on an empty path) is the giveaway. Don't trust a chime as proof the audio path is healthy — see the gotcha below.

## Why it matters / gotchas

- **State changes are not proof of audio.** `tts.speak` to a satellite's media_player entity updating to `playing` tells you nothing about whether sound came out. On `assist_satellite` devices, trust your ears (or the satellite's own state), not the media_player entity.
- **The puck is a satellite from the start.** The ESPHome integration exposes the Voice puck as an `assist_satellite` the moment you adopt it — local STT (Whisper, Speech-to-Phrase, or Cloud) has nothing to do with it. So target `assist_satellite.announce` from day one; a `tts.speak`-to-media_player automation may never have made sound on this device, you just didn't notice until you needed it to talk.
- **Treat `responding` as busy.** Per the docs, a satellite stays in `responding` until `tts_response_finished` returns it to `idle`. Fire your `announce` only on `idle`. Better still, where you can, let the normal conversation pipeline return the speech response — it flows back through the satellite without you hand-rolling an announce at all. (And note `responding` can itself hang — core #142363 — independent of anything you do.)
- **Don't trust a chime.** Something on the device may keep chiming while speech is stone dead, which is exactly what sends you debugging your automation instead of the TTS engine. Whether a particular chime survives a dead Piper depends on where it's generated, so don't reason from it — check Piper.

## Close

This came out of building a local voice front-end for the boat-agent stack on *Sailing Naturali* — an all-electric charter catamaran where the helm talks to a local LLM through a Home Assistant Voice puck. The agent and MCP tooling are open source under [github.com/sailingnaturali](https://github.com/sailingnaturali); the voice front-end notes live alongside them.
