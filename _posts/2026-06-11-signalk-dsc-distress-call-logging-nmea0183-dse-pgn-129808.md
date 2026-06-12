---
layout: post
title: "Logging VHF DSC distress calls in SignalK: the $--DSC/$--DSE and PGN 129808 gaps stock parsers drop"
description: "When a nearby boat hits the red button, its radio broadcasts a DSC distress burst on channel 70 — MMSI, position, nature of distress — readable even when the voice call on 16 is not. Stock SignalK quietly drops most of it: the NMEA 0183 hook misses sparse distress sentences and persists nothing, ignores $--DSE position refinement, and n2k-signalk has no PGN 129808 mapping at all. Here's how signalk-dsc captures, stores, and alarms on every received call — and the century-old radio-log regulation (47 CFR 80.409) that makes logging intercepted distress traffic the right default."
tags:
  - signalk
  - marine
  - nmea0183
  - nmea2000
  - dsc
  - vhf
  - pgn-129808
  - gmdss
date: 2026-06-11
---

A DSC distress alert is the most important packet a marine VHF will ever hand you, and it's structured data. When a vessel hits the red button, its radio transmits a digital selective calling burst on **channel 70**: format specifier, the sender's MMSI, category, nature of distress, position, and UTC time — encoded per ITU-R M.493. A DSC-equipped radio that hears it re-emits it to your network, as `$--DSC`/`$--DSE` sentences on **NMEA 0183** or as **PGN 129808** on **NMEA 2000**.

That burst arrives — and stays readable — even when the follow-up voice MAYDAY on channel 16 is garbled, stepped on, or out of range. If you might be the nearest boat, you want every received alert stored with its position and surfaced as an alarm.

Stock SignalK quietly drops most of it. This is the broke → tried → fixed of getting **DSC distress calls into SignalK**, with receipts for every gap. The result is [`signalk-dsc`](https://github.com/sailingnaturali/signalk-dsc).

## The test sentence — try it without a radio

You don't need a transmitting vessel in distress to reproduce all of this. Feed two sentences through any NMEA 0183 input (TCP, UDP, file playback):

```
$CDDSC,12,3380400790,12,05,00,1423108312,2019,,,S,E*69
$CDDSE,1,1,A,3380400790,00,45894494*1B
```

That's a **format 12** (distress alert), from MMSI `338040079` (the sentence carries it `* 10`, with a trailing zero), **category 12** (distress), **nature 05** (sinking), a position field, UTC `2019`, and the `E` expansion flag saying *a `$--DSE` sentence follows*. The second sentence is that expansion, refining the position. Both together are one incident.

Now walk through what stock SignalK does with each, and where it falls short.

## Gap 1: the 0183 hook misses sparse distress alerts — and persists nothing

The DSC field layout (sentence id and checksum already stripped) is:

```
        0  1          2  3  4  5          6    7 8 9 10
        |  |          |  |  |  |          |    | | | |
 $--DSC,XX,XXXXXXXXXX,XX,XX,XX,XXXXXXXXXX,XXXX,,,A,C*hh

  0: format specifier (12 = distress alert)
  2: category (00 routine / 08 safety / 10 urgency / 12 distress)
  3: nature of distress
  5: position (quadrant + ddmm + dddmm)
  6: UTC time hhmm
 10: expansion flag — 'E' means a $--DSE sentence follows
```

The upstream issue here is [SignalK/nmea0183-signalk#217](https://github.com/SignalK/nmea0183-signalk/issues/217): some radios emit a distress alert with the **category field empty** — it's redundant, because format `112` *is* a distress alert by definition. The stock parser treats the empty category as "not a distress call" and the alert evaporates.

`signalk-dsc` registers its own `DSC` parser (a superset of the stock hook) that infers the category from the format when it's missing:

```js
let categoryCode = field(parts, 2);
// Some radios omit the category on distress alerts — it is implied by
// format 112 (see SignalK/nmea0183-signalk#217).
if (!categoryCode && formatCode === '12') categoryCode = '12';
```

The whole parser is tolerant by design: anything it can't interpret stays `undefined`, and the **raw sentence is always kept** alongside the parsed fields. That's the second half of the gap — even when the stock hook *does* fire, it raises a transient notification and stores nothing. There is no record afterward. A distress alert with no persistence is a distress alert you can't act on the moment you look away from the screen.

`signalk-dsc` appends every received call to an on-disk JSONL log and serves the history at `/signalk/v2/api/resources/dsc-calls` (anonymously readable under `allow_readonly`):

```js
app.registerResourceProvider({
  type: 'dsc-calls',
  methods: {
    async listResources() { /* every stored call, by id */ },
    async getResource(id) { /* one call */ },
    setResource() { throw new Error('dsc-calls is read-only'); },
    deleteResource() { throw new Error('dsc-calls is read-only'); },
  },
});
```

The store is deliberately boring — append-only JSONL, synchronous I/O, full-file compaction past a cap. DSC traffic is rare (a busy day within range of a coast station might see dozens of calls), so the simplest thing that survives a power cut mid-write wins: a torn last line is skipped on load, the rest is kept.

## Gap 2: $--DSE position refinement, which the stock parser ignores entirely

The position in the DSC sentence is truncated to whole minutes — about **±1 NM**. That's coarse for a search. The optional `$--DSE` expansion sentence carries the missing precision, down to ten-thousandths of a minute:

```
        0 1 2 3          4  5
        |_|_|_|__________|__|________
 $--DSE,t,n,A,XXXXXXXXXX,00,llllyyyy*hh

  3: address — MMSI * 10, same convention as DSC
  4+: (code, data) pairs; code 00 = enhanced position,
      data = 4 digits lat + 4 digits lon, in 1/10000 of a minute
```

The stock parser doesn't handle DSE at all. `signalk-dsc` pairs an incoming DSE with the matching DSC call it stored in the last two minutes (same MMSI, position still at minute resolution) and refines it. DSC truncates *toward zero*, so the fractional minutes always extend the magnitude — sign-preserving:

```js
function refinePosition(position, ext) {
  const extend = (value, minuteFraction) => {
    const sign = value < 0 ? -1 : 1;
    return sign * (Math.abs(value) + minuteFraction / 60);
  };
  return {
    latitude: extend(position.latitude, ext.latMinuteFraction),
    longitude: extend(position.longitude, ext.lonMinuteFraction),
  };
}
```

The stored call's `positionResolution` flips from `minute` to `enhanced`, and the refined position goes out as a delta. ±1 NM becomes a tight fix.

## Gap 3: n2k-signalk has no PGN 129808 mapping at all

On NMEA 2000, a DSC call is **PGN 129808**, "DSC Call Information." `n2k-signalk` — the converter that turns N2K into SignalK deltas — produces **no delta for it**. There's nothing to subscribe to.

So `signalk-dsc` goes one layer down and listens to the server's analyzer stream directly:

```js
const DSC_PGN = 129808;

function onPgn(pgnData) {
  if (!started || !pgnData || pgnData.pgn !== DSC_PGN) return;
  record(normalizePgn129808(pgnData), { source: 'n2k', raw: pgnData.fields });
}

app.on('N2KAnalyzerOut', onPgn);
```

Normalizing 129808 is fiddly because canboatjs may resolve the enumerations to their names *or* pass through the raw ITU symbol numbers when a lookup misses, and the distress vs. general variants use different field names. The mapping handles both — name and number — for format, category, and nature:

```js
const NATURES = new Map([
  ['sinking', 'sinking'],
  ['man overboard', 'mob'],
  ['flooding', 'flooding'],
  // ...resolved names above; raw ITU symbols below
  [5, 'sinking'],
  [10, 'mob'],
  [1, 'flooding'],
]);
```

Both transports — 0183 and N2K — land in the same canonical event shape, so everything downstream (storage, alarms, logbook) is transport-agnostic.

## Alarms under your own vessel — and surviving a restart

Every received distress/urgency/safety call raises a notification under *self* so the vessel's own alarm chain fires. The category maps straight onto SignalK's severity ladder:

```js
const NOTIFICATION_STATES = {
  distress: 'emergency',
  urgency:  'alarm',
  safety:   'alert',
};
// → notifications.dsc.distress / .urgency / .safety
```

Routine calls never alarm. DSC distress alerts **auto-repeat until acknowledged**, so a naive implementation would re-alarm every few minutes; instead, a repeat inside a 5-minute window bumps a `repeats` counter on the stored call rather than firing again.

The subtle one: SignalK notifications live **in memory**. If the server restarts mid-incident, an active distress alarm silently vanishes — and a received MAYDAY must not disappear because the server bounced. So on start, `signalk-dsc` re-raises the newest alert per category that's still fresh (within the last hour):

```js
reannounceTimer = setTimeout(() => {
  const now = Date.now();
  const reannounced = new Set();
  const events = store.list();
  for (let i = events.length - 1; i >= 0; i--) {
    const event = events[i];
    if (!NOTIFICATION_STATES[event.category] || reannounced.has(event.category)) continue;
    const at = Date.parse(event.lastReceivedAt || event.receivedAt);
    if (now - at <= REANNOUNCE_WINDOW_MS) {
      notify(event);
      reannounced.add(event.category);
    }
  }
}, 30000);
```

The 30-second delay is deliberate: it lets position providers come up first, so the spoken alert can say "2.3 nautical miles northwest" instead of reading out raw coordinates.

## Voice-sized message vs. full log detail

The notification message gets **spoken** by a voice pipeline, so it's deliberately minimal — type, vessel, situation, range and direction from own position, action, and nothing else:

```
DSC distress alert: vessel Wind Chaser, sinking, 2.3 nautical miles
northwest. Monitor channel 16.
```

Note what's *not* spoken: the MMSI. Text-to-speech reads `366123456` as "three hundred sixty-six million…", which is useless and slow on a safety alert. (The plugin never speaks an MMSI — a small but real design rule.) The full detail lands in the call log and a GMDSS-style logbook entry instead:

```
[DSC] DISTRESS alert from Wind Chaser (MMSI 338040079): sinking.
position 48°47.700′N 123°12.300′W at 20:19 UTC, 2.3 NM northwest of us. via nmea0183
```

The vessel name, when present, comes from AIS static data already in the data model — not from the DSC sentence, which only carries the MMSI.

## Why a *log*, specifically

Capturing the alert and alarming on it is the operational case. The reason to also **persist it as a log entry** is older than SignalK by about a century.

Recording distress traffic is the long-standing radio-station regulatory standard. The cleanest US statement is **[47 CFR § 80.409](https://www.law.cornell.edu/cfr/text/47/80.409)** (FCC station logs). The radiotelegraph-log subsection, **(d)(4)**:

> All distress calls, automatic-alarm signals, urgency and safety signals **made or intercepted**, the complete text, if possible, of distress messages and distress communications, and any incidents or occurrences which may appear to be of importance to safety of life or property at sea, must be entered, together with the time of such observation or occurrence and the position of the ship or other mobile unit in need of assistance.

The load-bearing phrase is **"made or intercepted."** The rule isn't only about the distress *you* declare — it explicitly covers the traffic you *receive*. That's exactly what a DSC receiver does: it intercepts. The required fields — text of the distress, the time, and the position of the station in need of assistance — are precisely what a DSC burst (plus its DSE refinement) carries, which is why the plugin stores all three. The radiotelephone-log equivalent is subsection **(e)**.

**The honest caveat, because a knowledgeable reader will poke at an overstated claim:** applicability is subsection **(f)**, and the log *mandate* binds **compulsorily-equipped / GMDSS / SOLAS-class / Great Lakes / Bridge-to-Bridge** stations — **not** voluntary recreational stations. A private sailor is generally *not* legally required to keep this log. Internationally the same duty flows from **SOLAS Chapter IV** and the **ITU Radio Regulations**; Canada's equivalent is **TP 1539** (Ship Station Radio Technical Regulations), which is the relevant one for a boat working BC waters.

So the accurate framing is narrow and worth getting right: the law doesn't force a recreational station to keep a distress log — but the standard it sets for stations that *are* required to is a good one, and the data to meet it is already arriving on your network. `signalk-dsc` gives you that same SOLAS-grade record automatically. (For the practical side of receiving DSC distress alerts, the USCG NavCen [DSC Distress](https://www.navcen.uscg.gov/dsc-distress) page is the reference.)

## The shape of it

```
$--DSC ─┐
$--DSE ─┼─→ canonical DSC event ─┬─→ JSONL log  (/resources/dsc-calls)
PGN 129808 ─┘                    ├─→ notifications.dsc.<category>  (alarm chain)
                                 ├─→ voice-sized spoken message
                                 ├─→ remote-vessel position delta  (chartplotter)
                                 └─→ GMDSS-style logbook entry  (signalk-logbook)
```

Two wire formats, three things stock SignalK drops, one canonical event, five sinks. A received distress alert no longer vanishes the moment you look away.

This is one piece of an all-electric charter-catamaran ops stack — the radio should keep the log the regulations describe whether or not anyone's watching the screen. Code's here: [`signalk-dsc`](https://github.com/sailingnaturali/signalk-dsc).
