# Repository Guidelines

## Project Overview

Rekindle turns a jailbroken Kindle into an always-on clock and weather display. Two halves:

- **On-device dashboard**: one POSIX shell script, run by BusyBox 1.17 `ash` on the Kindle, that fetches Open-Meteo weather and draws with FBInk. KUAL launches it.
- **Host tooling** (macOS; Linux untested): `scripts/*.sh` that stage the jailbreak over USB, set up SSH, and deploy the dashboard.

The reference device is a Kindle 7th gen (KT2), FW 5.8.11, 600×800. Other models are untested.

## Architecture & Data Flow

```
Open-Meteo JSON ──fetch_weather──▶ /tmp/rekindle/weather.env ──read_status──▶ draw / draw_partial ──▶ FBInk
                  (sed + awk)        (shell KEY=value, sourced)                (600×800 canvas units)
```

- **State file**: `fetch_weather` writes `W_*` (current, hourly rain series) and `W_D_*` (next 5 days, space-separated lists) to `weather.env.tmp`, then `mv`s it into place, so a reader never sees a partial file. Drawing only ever sources this file and never calls the network.
- **Main loop** (`run`): wakes every minute.
  - Full redraw with flash at start and every `FULL_REFRESH_MINUTES`.
  - Otherwise `draw_partial` repaints only the clock band, plus the status band when its content changed.
  - Between ticks, powerd events (`charging`, `notCharging`, `battLevelChanged`…) from a `lipc-wait-event` watcher send `USR1`. The interrupted `wait` calls `refresh_status`, then waits again for the same `sleep`.
  - Fetches every `WEATHER_MINUTES`; NTP sync hourly.
- **Lifecycle**: `start [simplistic|forecast]` → `setsid "$0" run LAYOUT`.
  - `run` writes the pidfile and `/tmp/rekindle/layout`, stops the Kindle framework (`ui_off`), and starts two watchers: a `dd` on the power-button input device that sends TERM to the loop, and the powerd event watcher.
  - `shutdown` kills the process group and restarts the framework (`ui_on`).
- **Layouts**: `LAYOUT` selects a branch in `draw()`. `simplistic`: large current weather on dry days; compact row + rain banner + hourly chart when rain is due. `forecast`: compact row + 5 range rows (4 under the rain banner). KUAL `menu.json` passes the layout as `params`. KUAL is unreachable while the dashboard runs, so the layout is chosen only at start.

## Key Directories

- `kindle/extensions/rekindle/`: what gets deployed to `/mnt/us/extensions/rekindle/`. `bin/rekindle.sh` (all dashboard logic), `rekindle.conf` (per-device settings), `menu.json` + `config.xml` (KUAL), `icons/` (200×200 grayscale PNGs).
- `kindle/documents/KUAL.sh`: KUAL launcher copied to `/mnt/us/documents/`.
- `scripts/`: host scripts; `lib.sh` holds shared helpers.
- `tools/make_icons.py`: regenerates `icons/` (Pillow; drawn at 4× then LANCZOS-downsampled).
- `vendor/`: gitignored downloads from `scripts/fetch-deps.sh` (SHA-256 pinned). Never edit or commit.
- `docs/`: `guide.md` (canonical setup phases 0–7), `troubleshooting.md` (symptom/cause/fix table), `images/` (README screenshots).
- `skill/kindle-dashboard/SKILL.md`: agent skill that walks a user through setup.

## Development Commands

There is no build step, package manager, or test suite.

```sh
sh -n kindle/extensions/rekindle/bin/rekindle.sh        # syntax check (host)
sh kindle/extensions/rekindle/bin/rekindle.sh fetch      # runs on macOS too: prints the parsed weather.env
export KINDLE_HOST=$(scripts/find-kindle.sh)             # locate the Kindle (SSH key ~/.ssh/id_ed25519_kindle)
scripts/deploy.sh --restart                              # deploy, stop old process, restart (default layout)
scripts/screenshot.sh out.png                            # capture the e-ink framebuffer (needs python3 + Pillow)
. scripts/lib.sh && kssh '/mnt/us/extensions/rekindle/bin/rekindle.sh status'   # ad-hoc remote command
python3 tools/make_icons.py                              # regenerate icons
```

Device paths: log `/mnt/us/extensions/rekindle/rekindle.log`, state `/tmp/rekindle/` (`weather.env`, `pid`, `layout`).

## Code Conventions & Common Patterns

**Device script (`rekindle.sh`), BusyBox 1.17 constraints:**
- Use `grep -e`, `cut -c`, `setsid`; avoid `grep -E`, `head -c`, `nohup`, and `date -d` on date strings.
- **awk**: `x = x sep (expr)` parses as a call to a function `sep`. Put the parenthesised value in a variable, then concatenate.
- **Globals everywhere**: functions assign unscoped variables, and helpers clobber callers. `describe` sets `code`, `day`, `ICON`, `DESC`, `WET_NOW`; `fb_rtext` sets `w`, `rx`, `RTEXT_LEFT`. In loops, pick names no helper uses (e.g. `wday`, not `day`).
- **Naming**: config in `UPPER_CASE` (from `rekindle.conf`); weather state `W_*` and `W_D_*`; status `ST_*`; layout bands `CLOCK_TOP`/`STATUS_TOP`.
- **JSON** is parsed with `sed` (`json_obj`/`json_num`/`json_arr`). This assumes Open-Meteo's single-line output and objects without nested braces; keep new fields flat.
- **Errors**: weather and NTP failures are written with `log` and the loop retries; it never exits on a network error. The weather is shown as stale after 2 h.

**Drawing:**
- Author everything on the **600×800 canvas**. Pass canvas units to `fb_text`/`fb_ltext`/`fb_rtext`/`fb_rect`/`fb_image`; `layout_init` scales and centers for other screens (preview with `REKINDLE_VIEW=WxH`).
- Helpers draw with `-b` (no refresh); one `fbink -s` refreshes at the end. Text over a gray rect needs `-O` (no background), otherwise FBInk paints a white box. `-C GRAY5` gives secondary text.
- Palette: `BLACK`, `GRAY5` (secondary text), `GRAYA` (tracks, dry bars), `GRAYD` (rain banner and rain chips), `WHITE`. Black marks rainy data (bars, ranges), never containers.
- **Do not move** the clock band (`CLOCK_TOP=62`, `CLOCK_H=220`) or the status band (`STATUS_TOP=770`, `STATUS_H=22`). `draw_partial` clears and refreshes only those rectangles.
- Fonts: Amazon Ember from `/usr/java/lib/fonts` on the device. FBInk `px` is the ascent+descent box height, not the em size.

**Host scripts (`scripts/*.sh`):** `#!/bin/sh`, `set -eu`, `. "$(dirname "$0")/lib.sh"`. Use `say`/`die` and `require_host`/`require_volume`/`require_vendor`. Header comment format: description, `# Usage:`, optional `# Env:`. Staging scripts end by printing the next action to take on the Kindle. Copies to the device use `COPYFILE_DISABLE=1 tar --format ustar`, because the Kindle's tar rejects pax headers.

## Important Files

- `kindle/extensions/rekindle/bin/rekindle.sh`: entry point (`start|stop|status|run|fetch`), `fetch_weather`, `describe` (WMO code → icon/description), `draw*`, `run`.
- `kindle/extensions/rekindle/rekindle.conf`: location, `TZ_POSIX` (sets `TZ`; the Kindle has no zoneinfo, so IANA names silently become UTC), `TZ_IANA` (for the Open-Meteo request), intervals, rain thresholds.
- `kindle/extensions/rekindle/menu.json`: KUAL items ("Start: simplistic", "Start: 5-day forecast", "Stop dashboard").
- `scripts/deploy.sh`: tars the extension over SSH. It **keeps the device's existing `rekindle.conf`**, so edit that over SSH for per-device settings.
- `scripts/lib.sh`: `ROOT`, `KINDLE_HOST`/`KINDLE_KEY`/`KINDLE_VOL` defaults, `kssh`.

## Runtime/Tooling Preferences

- **Host**: macOS `sh`, `curl`, `ssh`, `nc`, `tar`, `unzip`, `shasum`; Python 3 + Pillow only for `screenshot.sh` and `make_icons.py`.
- **Device**: BusyBox 1.17 `ash`/`awk`, FBInk, `lipc-get-prop`/`lipc-set-prop`, `ntpdate`. No bash, no Python.
- Weather is plain `http://api.open-meteo.com` (no API key). Keep everything on the device; there is no server component.

## Testing & QA

There is no automated test suite or CI. A change is verified when it has been seen on the device:

1. Run `sh -n` and a host `fetch` for parsing changes. BSD awk on macOS is more lenient than BusyBox, so also run `rekindle.sh fetch` on the device.
2. Run `scripts/deploy.sh --restart`. A running shell keeps executing the old file, so deploying without a restart leaves stale or broken code running.
3. Run `scripts/screenshot.sh` and check that the layout is right, then take a second screenshot a minute later and confirm the clock advanced. Check `rekindle.log` for errors.
4. For states the live weather doesn't show (e.g. rain due), draw from a copied `weather.env` with the rain fields overridden. Do this in a throwaway harness under `/tmp` on the device that sources the script's functions (everything above the final `case`); never edit the deployed files.

**When behavior changes, update** the README feature bullets and screenshots (`docs/images/`, captured from the device with `screenshot.sh`), `docs/guide.md` phase 7, `docs/troubleshooting.md` for new gotchas, and `skill/kindle-dashboard/SKILL.md`. Commit subjects are sentence-case imperatives, with an explanatory body for larger changes.
