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

- **State files**: `fetch_weather` writes `W_*` (current, hourly rain series) to `weather.env.tmp`, then `mv`s it into place, so a reader never sees a partial file. In the `train` layout `fetch_train` does the same for `train.env` (`T_STATUS` normal/delay/part/stop, `T_NAME`, `T_FETCHED`), parsed with `awk` from JR East's English Kanto status page (HTTPS; the line is found by its `ico_rosen_<line>.svg` icon). Drawing only ever sources these files and never calls the network.
- **Main loop** (`run`): wakes every minute.
  - Full redraw with flash at start and every `FULL_REFRESH_MINUTES`.
  - Otherwise `draw_partial` repaints only the clock band, plus the status band when its content changed.
  - Between ticks the loop either suspends or waits awake, per `low_power` (`LOW_POWER` in `rekindle.conf`: `auto` = on battery only, `always`, `never`).
    - Suspend: `suspend_until_next_tick` sets an RTC alarm (`/sys/class/rtc/rtc1/wakealarm`) for the next tick boundary and writes `mem` to `/sys/power/state`. The tick is 1 minute, or `QUIET_MINUTES` inside `QUIET_HOURS` (`tick_minutes`; battery only, the awake path always ticks every minute). If it did not really sleep (<2 s, e.g. woken by the charger), it returns non-zero and `wait_next_minute` waits awake.
    - Awake: powerd events (`charging`, `notCharging`, `battLevelChanged`…) from a `lipc-wait-event` watcher send `USR1`. The interrupted `wait` calls `refresh_status`, then waits again for the same `sleep`.
  - `sync_network` runs the weather fetch (every `WEATHER_MINUTES`) and NTP sync (hourly) inside one wifi window; in the `train` layout a successful weather fetch is followed by `fetch_train` from an hour before `TRAIN_HOURS` until its end. When low power is active, wifi is off (`com.lab126.cmd wirelessEnable 0`, the Airplane-mode switch; the lower-level `wifid enable` wedged the radio) outside it. Failed fetches back off 1, 2, 5, 10, then 30 minutes (failed NTP retries every 30 minutes). On a wifi timeout `wifi_up` logs `cmState` and the last `wifid` lines, and power-cycles the radio once while `fetch_fails` < 2.
  - `train_state` decides the band (`T_SHOW`: empty, delay, part, stop, or unknown when `train.env` is older than `WEATHER_MINUTES` + 15 min). The loop redraws fully when it differs from what `draw` last showed (`DRAWN_TRAIN`), which covers the start and end of `TRAIN_HOURS`.
  - `wifi_down` waits until `ath6kl_sdio` and `cfg80211` have left `/proc/modules` (about 2 s) before the loop may suspend. The driver powers the chip off on unload; a suspend before that leaves the kernel's `wifi_card_enable` flag set, every later load fails with `device power already on!`, and only a reboot recovers.
- **Lifecycle**: `start [simplistic|train]` → `setsid "$0" run LAYOUT`.
  - `run` writes the pidfile and `/tmp/rekindle/layout`, stops the Kindle framework (`ui_off`), and starts two watchers: a loop on the power-button input device (acts only on a key-press event; a read can return early after a suspend) that sends TERM to the loop, and the powerd event watcher.
  - `shutdown` kills the process group and restarts the framework (`ui_on`), which also re-enables wifi and clears the RTC alarm.
- **Layouts**: `LAYOUT` selects what `draw()` adds. `simplistic`: large current weather on dry days; compact row + rain banner + hourly chart when rain is due. `train`: the same, plus the train band during `TRAIN_HOURS` when the line is not running normally: a gray band at y 352 above the dry-day weather, or sharing the rain banner (status left, rain window right). KUAL `menu.json` passes the layout as `params`. KUAL is unreachable while the dashboard runs, so the layout is chosen only at start.

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
- **Naming**: config in `UPPER_CASE` (from `rekindle.conf`); weather state `W_*`; train state `T_*`; status `ST_*`; layout bands `CLOCK_TOP`/`STATUS_TOP`.
- **JSON** is parsed with `sed` (`json_obj`/`json_num`/`json_arr`). This assumes Open-Meteo's single-line output and objects without nested braces; keep new fields flat.
- **Errors**: weather and NTP failures are written with `log` and retried (fetch with backoff); the loop never exits on a network error. The weather is shown as stale after 2 h.
- **Low power and SSH**: with `LOW_POWER` active the device is unreachable over SSH except during a wifi window. `auto` stays awake while charging, so develop on the charger or set `LOW_POWER=never` in the device's `rekindle.conf` (deploy keeps that file). New `rekindle.conf` keys need an in-script default (`: "${KEY:=value}"`) because existing devices keep their old file.

**Drawing:**
- Author everything on the **600×800 canvas**. Pass canvas units to `fb_text`/`fb_ltext`/`fb_rtext`/`fb_rect`/`fb_image`; `layout_init` scales and centers for other screens (preview with `REKINDLE_VIEW=WxH`).
- Helpers draw with `-b` (no refresh); one `fbink -s` refreshes at the end. Text over a gray rect needs `-O` (no background), otherwise FBInk paints a white box. `-C GRAY5` gives secondary text.
- Palette: `BLACK`, `GRAY5` (secondary text), `GRAYA` (tracks, dry bars), `GRAYD` (rain banner and rain chips), `WHITE`. Black marks rainy data (bars, ranges), never containers.
- **Do not move** the clock band (`CLOCK_TOP=62`, `CLOCK_H=220`) or the status band (`STATUS_TOP=770`, `STATUS_H=22`). `draw_partial` clears and refreshes only those rectangles.
- Fonts: Amazon Ember from `/usr/java/lib/fonts` on the device. FBInk `px` is the ascent+descent box height, not the em size.

**Host scripts (`scripts/*.sh`):** `#!/bin/sh`, `set -eu`, `. "$(dirname "$0")/lib.sh"`. Use `say`/`die` and `require_host`/`require_volume`/`require_vendor`. Header comment format: description, `# Usage:`, optional `# Env:`. Staging scripts end by printing the next action to take on the Kindle. Copies to the device use `COPYFILE_DISABLE=1 tar --format ustar`, because the Kindle's tar rejects pax headers.

## Important Files

- `kindle/extensions/rekindle/bin/rekindle.sh`: entry point (`start|stop|status|run|fetch`), `fetch_weather`, `describe` (WMO code → icon/description), `draw*`, `run`.
- `kindle/extensions/rekindle/rekindle.conf`: location, `TZ_POSIX` (sets `TZ`; the Kindle has no zoneinfo, so IANA names silently become UTC), `TZ_IANA` (for the Open-Meteo request), intervals, rain thresholds, `TRAIN_LINE`/`TRAIN_HOURS`.
- `kindle/extensions/rekindle/menu.json`: KUAL items ("Start: simplistic", "Start: with train status", "Stop dashboard").
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
5. For suspend/wifi changes, never test on a device you cannot reach: with `LOW_POWER=always` the device is only reachable during a wifi window (use a short `WEATHER_MINUTES` and poll `ssh` in a tight loop), and a wedged radio needs a 40 s power-button restart. `dmesg` timestamps exclude suspended time, so gaps between `PM: Entering mem sleep` lines are the awake time per tick (about 1–2 s; a wifi window tick adds about 12–15 s). Restore `LOW_POWER=auto` and `WEATHER_MINUTES=30` in the device's `rekindle.conf` afterwards.

**When behavior changes, update** the README feature bullets and screenshots (`docs/images/`, captured from the device with `screenshot.sh`), `docs/guide.md` phase 7, `docs/troubleshooting.md` for new gotchas, and `skill/kindle-dashboard/SKILL.md`. Commit subjects are sentence-case imperatives, with an explanatory body for larger changes.
