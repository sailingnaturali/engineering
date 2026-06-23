---
layout: post
title: "Why generic weather MCPs fail for marine navigation (use NDBC buoys)"
description: "An adopt-vs-keep audit of three existing weather MCP servers (Open-Meteo, NOAA CO-OPS, a 12-tool generic) against a purpose-built marine one. None does NDBC nearest-buoy observations, quota-aware premium tools, or a TTS-safe display contract. Then the capability that fell out of the audit: parsing NDBC realtime2 .spec files to split swell from wind waves — ~60 lines that surfaced wave data the standard .txt file had marked missing. With receipts from station 46088."
tags:
  - mcp
  - marine
  - weather
  - ndbc
  - llm
  - tool-use
  - ai
date: 2026-06-06
---

We run a prime directive on this stack: if a usable tool already exists, improve it; build our own only as a last resort, and when you keep your own, record *why* each alternative failed. This post is that audit for [`weather-mcp`](https://github.com/sailingnaturali/weather-mcp) — a marine-weather MCP server — against the weather-MCP ecosystem, and the one capability change that fell out of it.

The short version: three perfectly good weather MCP servers exist, and none of them does the thing a navigator actually needs. The reasons generalize to *any* "adopt an MCP server or keep your own" call, so the audit is the post. Then the fix — parsing a second NDBC file format to split swell from wind waves — is small enough to paste in full, and it surfaced data the standard file had thrown away.

## The problem, as you'd search it

You want an agent to answer "what are the seas doing where we are?" and you go looking for a marine weather MCP. You find a few. Each one returns a *forecast*. None of them returns what a buoy 12 nautical miles away is *measuring right now*. That gap — forecast vs. observed — is the entire job, and it's the one thing the ecosystem skips.

Here's what's on the shelf, and what each one is missing for marine use.

## The candidates

Three real servers, all worth your time for what they're built for:

```text
cmer81/open-meteo-mcp           ~13 tools, raw Open-Meteo JSON straight through
weather-mcp/weather-mcp         ~12 tools, own format, global; marine = Open-Meteo
RyanCardin15/NOAA-Tides...      CO-OPS stations: water levels + currents, not buoys
```

And ours:

```text
sailingnaturali/weather-mcp     4 tools, Python, 2 runtime deps (httpx + mcp)
  get_marine_forecast            Open-Meteo wind/swell/wind-wave/seas/pressure
  get_marine_forecast_premium    Stormglass blend — 10 tokens/UTC-day, cache hits free
  get_nearest_buoy_observations  NDBC observed wind + waves by lat/lon, with bearing + age
  get_stormglass_quota_status    token-ledger read, no network
```

Mapped against what a navigator needs:

| Capability | ours | open-meteo-mcp | weather-mcp/weather-mcp | NOAA-Tides |
|---|---|---|---|---|
| Open-Meteo marine (swell / wind-wave split) | yes | yes (raw JSON) | yes (own format) | no |
| NDBC nearest-buoy *observations* by lat/lon | **yes** | no | no | no (CO-OPS stations, not buoys) |
| Quota-aware premium tool design | **yes** | no | no | no |
| TTS-safe `{value, display}` contract | **yes** | no | no | no |
| Tools exposed to the agent | **4** | ~13 | ~12 | 25+ |

The `weather-mcp/weather-mcp` README is admirably honest about the gap — for marine it routes to the Open-Meteo Marine API, which is a forecast model, not an observation. None of these is a bad server. They're built for a chat-window agent asking general weather questions. We're building for a voice-first agent on a small local model doing navigation. Different target, different binding constraints.

## Three failure axes that generalize

Strip out the marine specifics and the audit comes down to three things a generic server can't give an agent, plus one that hurts small models specifically.

### 1. Buoy ground-truthing — observations, not just forecasts

The core doctrine is "forecast vs. observed, lead with the observation." A forecast says the seas *should* be 1.5 m; a buoy 12 nm upwind says they *are* 2.4 m and building. The agent should say the second thing. No generic weather MCP does observations at all — they're all forecast APIs. The NDBC realtime network is the data source, and wrapping it is the whole reason our server exists.

### 2. Quota-aware tool design

The premium provider (Stormglass) has a hard free-tier wall: 10 requests per UTC day. An agent that can't *see* that budget will burn it in one chatty session. So the budget has to be expressible in the tool surface itself — a paid tool and a free "how many tokens are left?" tool, paired:

```python
# get_stormglass_quota_status — no network, just reads the ledger
def get_stormglass_quota_status(quota: StormglassQuota) -> dict:
    ...   # used / remaining for the current UTC day
```

"This call costs 1 of 10 daily tokens; cache hits are free" is a *design property of the tool surface*, not a footnote in a README. No generic server models cost, because for a free forecast API there's no cost to model.

### 3. The display contract

Every value our tools return carries a pre-formatted, TTS-safe `display` string the agent speaks verbatim — because small local models mangle re-formatting, and a text-to-speech engine mispronounces raw units and codes. (We've written before about why [formatting belongs in the tool layer, not the prompt](https://engineering.sailingnaturali.com/fix-llm-formatting-in-the-tool-layer-not-the-prompt/).) A server that returns raw API JSON pushes that formatting onto the model — the exact layer that fails. Generic servers return raw or near-raw payloads. That's correct for a frontier model in a chat window and disqualifying for ours.

### And: tool-count bloat

4 tools vs. ~13, ~12, 25+. The MCP field has converged on a real number here: tool-selection accuracy on smaller models degrades as the surface grows, and the common advice is to keep a server in the 5–8 range and split domains past ~15. A curated 4-tool surface isn't minimalism for its own sake — it's the thing that keeps an 8B picking the right tool.

## The decision: keep, with receipts

Per the directive, every alternative gets a recorded reason:

- **open-meteo-mcp** — covers only the Open-Meteo forecast leg, returns raw JSON (breaks the display contract), ~13 tools. No buoys, no premium, no observations.
- **weather-mcp/weather-mcp** — same gaps, more tools, marine is forecast-only by its own README.
- **NOAA-Tides** — CO-OPS water levels and currents; overlaps a tide server's domain, not a wave-observation server's. No buoy waves, no forecasts.
- **Splitting** (someone's forecast + our buoys) — doubles config surface and the most-called tool loses the display contract.

Keep ours. Now close its biggest documented gap.

## The honest twist: a library-level adopt we *also* rejected

"Prefer adopting" doesn't stop at servers — there's a library that does exactly the NDBC parsing we hand-roll: [`CDJellen/ndbc-api`](https://github.com/CDJellen/ndbc-api), a well-maintained Python package for NDBC data. The directive says use it. We didn't, and the reason is a clause worth naming out loud: **install weight is an adoption barrier for a `uvx`-installable server.**

`ndbc-api` pulls a scientific-computing stack — pandas, numpy, scipy, xarray, h5netcdf, beautifulsoup4, html5lib. Adopting it to replace ~220 lines of whitespace-table parsing would take the server from **2 runtime dependencies to ~9**:

```text
weather-mcp today:   httpx, mcp
with ndbc-api:       httpx, mcp, ndbc-api
                       └─ pandas, numpy, scipy, xarray, h5netcdf, beautifulsoup4, ...
```

For a server people install with `uvx weather-mcp`, every transitive dependency is cold-start latency and a bigger surface to break. We're optimizing the public artifact, not just our own runtime. Adopt-first has a dependency-weight escape clause, and this is what it looks like in practice. So: keep the hand parser, and extend it.

## The fix: parsing NDBC `.spec` to split swell from wind waves

Our biggest documented limitation was sitting in the buoy tool itself. The standard NDBC realtime file (`realtime2/{station}.txt`) reports **combined** significant wave height only — one number that smears swell and local wind chop together. For navigation that distinction matters: 0.4 m of short-period wind chop is a different sea state than 0.4 m of long-period swell from a distant storm.

NDBC publishes the separation in a *second* file alongside the `.txt` — `realtime2/{station}.spec` — same whitespace-table format, with swell and wind waves broken out. The header:

```text
#YY  MM DD hh mm WVHT  SwH  SwP  WWH  WWP SwD WWD  STEEPNESS  APD MWD
2026 06 06 04 10  0.4  0.1  6.2  0.4  2.9 WSW   W        N/A  2.9 273
```

- `SwH` / `SwP` / `SwD` — swell height (m), period (s), direction (compass string)
- `WWH` / `WWP` / `WWD` — wind-wave height, period, direction
- `STEEPNESS` — qualitative, may be `N/A`; `MM` marks missing values, same as `.txt`

The parser mirrors the existing `.txt` parser — first data row, `MM`-as-`None`, directions kept as compass strings (no degree round-trip, because the display layer wants "WSW" not 247°):

```python
def parse_spec(text: str) -> SpecWaves | None:
    """Parse the first data row of a realtime2 .spec response.

    Directions arrive as compass strings (e.g. 'WSW') and are kept as-is.
    Returns None if there are no data rows or every wave field is missing.
    """
    rows = [ln for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]
    if not rows:
        return None
    cols = rows[0].split()
    if len(cols) < 13:
        return None
    yyyy, mm, dd, hh, mn = cols[0:5]
    try:
        observed = datetime(int(yyyy), int(mm), int(dd), int(hh), int(mn), tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None
    spec = SpecWaves(
        observed_utc=observed,
        swell_height_m=_maybe_float(cols[6]),
        swell_period_s=_maybe_float(cols[7]),
        swell_dir_compass=_maybe_str(cols[10]),
        wind_wave_height_m=_maybe_float(cols[8]),
        wind_wave_period_s=_maybe_float(cols[9]),
        wind_wave_dir_compass=_maybe_str(cols[11]),
        steepness=_maybe_str(cols[12]),
    )
    if spec.swell_height_m is None and spec.wind_wave_height_m is None:
        return None
    return spec
```

Two files, two failure modes, so the merge degrades gracefully. The `.spec` is fetched **concurrently** with the `.txt`, and a missing or *stale* `.spec` (404, or an observation time skewed more than an hour from the `.txt` row) just drops the swell fields — the tool output is byte-identical to the old combined-only behavior:

```python
MAX_SPEC_SKEW_S = 3600  # .spec off the .txt row by >1h → treat as stale

def merge_spec(obs: BuoyObservation, spec: SpecWaves | None) -> BuoyObservation:
    if spec is None:
        return obs
    if abs((obs.observed_utc - spec.observed_utc).total_seconds()) > MAX_SPEC_SKEW_S:
        return obs
    return replace(obs, swell_height_m=spec.swell_height_m, ...)
```

```python
# both files, one round trip; .txt is the source of truth, .spec only enriches
txt_text, spec_text = await asyncio.gather(
    _get_text_or_none(client, txt_url),
    _get_text_or_none(client, spec_url),
)
if txt_text is None:
    return None
obs = parse_realtime2(txt_text, station, ref_lat, ref_lon)
spec = parse_spec(spec_text) if spec_text is not None else None
return merge_spec(obs, spec)
```

The merged observation rides the existing cache key; the `.spec` is never fetched on its own, so it needs no cache key of its own. And the absence case stays honest in the output — the note only appears when separation is actually missing:

```python
if not has_spec:
    wave_block["note"] = (
        "combined waves only — this station's .spec swell separation is unavailable or stale"
    )
```

## The receipt

This isn't theoretical. Pulled live from station **46088 (New Dungeness)**, the standard `.txt` file reported **no combined wave height at all** — `WVHT` came back `MM`, missing. The `.spec` file, same station, same minute, had the separation:

```text
.txt   →  WVHT MM            (no combined wave height — missing)
.spec  →  swell 0.1 m WSW at 5.6 s, wind wave 0.4 m W
```

The separation didn't just refine an existing number — it **surfaced wave data that was invisible** in the file everyone parses. The combined field was missing; the component fields were there the whole time, in a file most NDBC wrappers ignore. ~60 lines plus tests, two new runtime dependencies (zero), one closed gap.

## Why it matters

The reusable lesson isn't about waves. It's that **an MCP server's value to an agent is the tool *design* — how it handles absence, whether it models cost, what contract its output guarantees — not API-coverage breadth.** Three servers with more tools and broader coverage each failed the same navigator on the same three axes: no observations, no quota awareness, no speakable output. Coverage is easy to add and easy to find; design for a specific agent is the part you can't adopt off the shelf.

And the dependency-weight clause cuts the other way against "always adopt the library": for a tool people install with one command, ~220 lines of stdlib parsing can be the *right* call over a maintained package, when the package drags a scientific-computing stack behind it. Adopt-first, with an escape clause you can defend.

## Close

This came out of building an AI ops layer for an all-electric charter catamaran, where the weather agent has to ground its forecasts against real buoys and say the answer out loud, on a small local model, reliably. The server and the audit baked into its README are open: [github.com/sailingnaturali/weather-mcp](https://github.com/sailingnaturali/weather-mcp). Go read the three servers above too — all good work, just built for a different boat.
