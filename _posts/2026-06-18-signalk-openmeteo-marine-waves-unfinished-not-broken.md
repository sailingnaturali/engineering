---
layout: post
title: "The commented-out code was a to-do, not a bug: finishing waves in SignalK's Open-Meteo plugin"
description: "Our weather-mcp already had a SignalK provider that read wave height and swell from the boat's own forecast API — but the field came back empty, because the upstream Open-Meteo plugin had its marine query commented out. We'd built the consumer before the producer existed. Rather than fork, we finished the producer: why the marine code was unfinished (not broken), the throttling history behind the caution, the SI-units bug hiding in the commented draft, and how contributing one upstream PR lit up a code path we'd already shipped."
tags:
  - ai
  - mcp
  - signalk
  - open-source
  - weather
  - architecture
date: 2026-06-18
canonical: "https://engineering.sailingnaturali.com/signalk-openmeteo-marine-waves-unfinished-not-broken/"
---

Our boat's weather comes from a chain we didn't fully own. [Open-Meteo](https://open-meteo.com)
serves a free forecast; the [SignalK Open-Meteo provider plugin](https://github.com/SignalK/openmeteo-provider-plugin)
pulls it into the boat's own weather API at `/signalk/v2/api/weather/forecasts/point`;
and our [weather-mcp](https://github.com/sailingnaturali/weather-mcp) reads *that* — so the
voice agent gets sea state from the boat's canonical weather surface instead of every tool
hitting the internet on its own.

Except the sea state never arrived.

## A consumer with nothing to consume

weather-mcp has a `signalk` provider whose whole job is to map the SignalK weather response
into our forecast model. It was written to read the `water` block:

```python
water = wd.get("water") or {}
# ...
swell=_wave(water, "swellHeight", "swellDirection", "swellPeriod"),
combined_wave=_wave(water, "waveSignificantHeight", "waveDirection", "wavePeriod"),
```

That `or {}` is doing a lot of quiet work. Every forecast hour came back with no `water` key
at all, so the map produced `None` for every wave field, and the provider dutifully reported
a forecast with wind and pressure but no waves. No error, no warning — just a hole shaped
exactly like the data we wanted.

The hole wasn't in our code. It was upstream: the plugin's `getForecasts` returned wind and
atmospheric fields only. The `WeatherData.water` fields were never populated. We had built
the consumer before the producer existed.

## Chesterton's fence: why was the marine code commented out?

The obvious move when you find the gap is to fork the plugin and add the marine fetch. The
less obvious — and correct — move is to ask *why it isn't there already*.

It turned out the plumbing mostly **was** there: `getMarineUrl` existed, and a `water.*`
mapping sat in the source, commented out. Easy to read that as "broken, disabled in a
hurry." Git history said otherwise. The marine URL builder had been fleshed out in a later
commit, but the fetch, merge, and mapping around it were never wired — the marine path was
**unfinished from the initial scaffold, not broken and switched off**. That distinction
changes everything: there was no regression to be careful around, just a to-do someone left
in the open.

The history surfaced one real constraint, though. Open-Meteo is free and rate-limited, and
the plugin already carried [scars from request-throttling](https://github.com/SignalK/openmeteo-provider-plugin/issues/3) —
caching and request frequency were live concerns, not hypotheticals. Reintroducing a second
network call per forecast naively was exactly the kind of thing that fence was guarding
against. Knowing *that* shaped the fix.

## Finishing it

The [PR](https://github.com/SignalK/openmeteo-provider-plugin/pull/7) is one file and three
moves:

**Merge the marine series.** Open-Meteo serves marine data from a separate subdomain
(`marine-api.open-meteo.com`, distinct from `api.open-meteo.com`). We fetch it inside the
same cache-miss path as the atmospheric forecast, so it's cached alongside it — one more
request per *cache miss*, not per *call*, which is the number the throttling history actually
cares about. And the marine fetch is optional: if it fails, the catch degrades to a
wind-and-atmospheric forecast rather than failing the whole response. A boat with no wave
data is fine; a boat with no forecast is not.

**Fix the units the draft got wrong.** The commented-out mapping multiplied wave periods by
1000. SignalK is an SI data model — periods are seconds, not milliseconds. The disabled
draft would have reported every swell period off by three orders of magnitude. This is the
case *for* finishing commented code rather than just uncommenting it: the draft wasn't
correct-but-disabled, it was a sketch.

**Align the horizon.** The marine query defaulted to 8 hours; the hourly forecast defaults to
24. We bumped the marine default to match, so waves cover the same window as the wind.

Verified live against Boundary Pass — every forecast hour now carries `water`:

```json
{"waveSignificantHeight":0.28,"waveDirection":4.05,"wavePeriod":3.55,
 "swellHeight":0.24,"swellDirection":3.72,"swellPeriod":2.9}
```

One caveat we documented rather than fought: the SignalK `water` spec carries combined
significant-wave height and swell, but no separate **wind-wave** component. Open-Meteo's
marine API has it; the SignalK surface has nowhere to put it. So a forecast sourced through
SignalK reports combined-plus-swell, and our provider sets `wind_wave` to `None` on that
path. A consumer that needs the wind-wave split goes direct to Open-Meteo. That's a spec
limit, not a bug, and the right place for it is a comment in the mapper.

## The payoff: the loop closed without a fork

The moment the PR merged, nothing in our codebase changed — and the thing we wanted started
working. weather-mcp's SignalK provider had been reading `water.*` all along; the upstream
plugin simply started putting data there. The producer and the consumer live in different
GitHub orgs, maintained by different people, and they met at a documented API contract.

This is the [adopt-before-build rule](https://github.com/sailingnaturali) playing out at the
seam. We could have forked the plugin, or added a private marine fetch to weather-mcp and
duplicated what Open-Meteo's plugin almost did. Either would have worked and both would have
been ours to carry forever. Instead the gap got filled where it belonged — in the shared
plugin every SignalK boat installs — and our side stayed a thin reader of a standard API.

The cost was reading enough history to know the fence was a to-do and not a load-bearing
wall. That's most of the work in contributing upstream: not the diff, but earning the right
to make it.
