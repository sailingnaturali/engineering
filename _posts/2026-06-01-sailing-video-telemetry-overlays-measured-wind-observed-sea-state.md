---
layout: post
title: "The wind is measured. The sea state is a judgment call. — honest telemetry overlays for sailing video"
description: "You want to put the real conditions on screen when you say them on camera: wind from the west at fifteen, building sea. The instinct is to record a data stream and sync it to the footage. Two things turn out to be true and non-obvious — the stream is already recording itself for free, and the one value you most want to narrate isn't a sensor reading at all. Getting overlays right is less a video problem than a question of which data is measured, which is observed, and refusing to fake the difference."
date: 2026-06-01
tags:
  - signalk
  - sailing
  - video
  - telemetry
  - dataviz
  - nodejs
---

You're editing footage from a good sailing day. On camera you say it plainly: *"Wind's come in from the west, about fifteen knots, and the sea's building."* You want a clean overlay to surface right then — wind speed and direction, sea state — showing the **actual** numbers from that moment, not a decorative gauge.

The instinct is to treat this as a video problem: record a telemetry stream, sync it to the timeline, draw some dials. But the interesting part isn't the drawing. It's the data — and two things about it are non-obvious until you go to build the overlay.

## There are two data layers, and conflating them is the trap

A boat running [SignalK](https://signalk.org) has two completely different kinds of "data," and they are *not* the same thing:

1. **Continuous telemetry** — wind, depth, boat speed, position, battery, at instrument cadence. This is the stream you'd put on screen.
2. **The log** — sparse, human, semantic entries: "anchored, Montague", a marked moment, an observation.

When the overlay data feels missing, it's usually because someone is looking at layer 2 and worrying they need to *manually* capture layer 1. You don't. On SignalK, continuous telemetry records itself: every real instrument connection with logging enabled writes the full delta stream to disk, hourly, automatically. It's a checkbox, not a chore. The moment you find yourself about to hand-log wind speed every few minutes "so I'll have it for the video," stop — you'd be a human data logger for data the connection already records perfectly.

So the log layer is freed up for what it's actually good at: marking *which* moments are worth an overlay, and recording the things instruments can't.

## The value you most want to narrate isn't a sensor

Look again at the line: *"wind from the west at fifteen, sea building."*

Wind speed and direction are **measured** — they come off the masthead, land in SignalK as `environment.wind.speedTrue` and `environment.wind.directionTrue`, and can be read back at any timestamp. But "the sea's building" — sea state — is **not a sensor reading.** There is no transducer for it. It's an observation, a judgment on the [Douglas scale](https://en.wikipedia.org/wiki/Douglas_sea_scale) the skipper makes by looking at the water.

That reframes the whole system. An honest overlay pipeline has to carry *human observations* on the same clock as machine telemetry — because the most evocative thing you'll say on camera is often the thing no instrument can measure. In practice that means logging sea state as a timestamped observation (it rides into the data as `environment.water.swell.state`), so that at edit time a single timestamp resolves *both* the measured wind and the observed sea.

This is the same discipline as publishing your genset runtime hours instead of claiming "zero emissions": the credible version distinguishes what you measured from what you judged, and never blurs the two.

## The bridge: SI in, human units out, `null` where there's nothing

Between the recorded deltas and a lower-third sits a small, boring, important tool. SignalK speaks SI — metres per second, radians, ratios. Overlays speak knots, degrees, percent, Beaufort. So the bridge:

- parses a trip's delta archive,
- at any timestamp does a **sample-and-hold** lookup (the most recent value at-or-before that instant, per field),
- converts to display units, and
- returns `null` — never a fabricated zero — for anything that wasn't measured at that moment.

That last rule is the one that matters. Our boat's solar and regeneration figures aren't on the data bus yet (the energy backbone isn't bridged into SignalK). The honest behavior is for those fields to come back empty until they're real — not to show a confident `0 W` that's actually "no idea." A telemetry overlay that fakes a reading is worse than no overlay; it puts a false number on a true moment.

We built this as a tiny CLI in our open [`journey-data`](https://github.com/sailingnaturali/journey-data) repo (MIT). It does three things: resolve one moment (`at`), dump a whole trip to an overlay-ready CSV (`export`) that feeds tools like Telemetry Overlay or a DaVinci Resolve data-merge, and resolve a list of marked moments (`moments`) into rows. A `--video-start … --at mm:ss` flag maps a clip offset to UTC so the camera clock and the boat clock line up.

## The point

The cinematic part — the branded graphic, the animation — is the easy half, and the tools for it already exist. The half that decides whether the overlay is *true* is upstream of all of it: record the continuous stream automatically, log the observations instruments can't measure, key both to one clock, and refuse to fake the gaps. Get that right and the number on screen earns the sentence you said out loud.
