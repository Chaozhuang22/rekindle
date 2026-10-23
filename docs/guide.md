# Setup guide: from stock Kindle to clock and weather display

Every phase lists what runs on the computer, what you do on the Kindle, and how to know it
worked. Something off? [troubleshooting.md](troubleshooting.md) is organised by symptom.

## Before you start: is your Kindle covered?

| Situation | Status |
|---|---|
| Kindle 7th gen (KT2), firmware 5.8.11, macOS host | **Tested end to end** (the reference device) |
| Other K5-platform Kindles (Touch, PW1–PW3, Voyage, Oasis 1, Basic 7th–8th gen) still on firmware **5.6.1.1–5.10.x** | Should work: same jailbreak, update block and tools. The dashboard scales to the screen size; the power-button device is found by name. Not tested on hardware. |
| Firmware **5.11–5.16.2** | The jailbreak applies, but blocking updates needs the `renameotabin` KUAL extension ([KindleModding](https://kindlemodding.org/jailbreaking/Legacy/post-jailbreak/disable-ota.html)), which `stage-tools.sh` does not automate; it stops and points there. |
| Firmware **5.16.3 and newer** | **Not covered.** These are hard-float ("kindlehf") systems: the soft-float USBNetwork used here does not apply, and above 5.18.0.2 WinterBreak does not either. |
| Kindle Touch (KT) or Paperwhite 1 | Use the older USBNetwork build: `USBNET_BUILD=touch_pw scripts/stage-tools.sh`. |
| Linux host | Should work: set `KINDLE_VOL` to the drive's mount point. Not tested. |
| Windows host | Not supported by the scripts; follow the [KindleModding guides](https://kindlemodding.org/jailbreaking/) by hand. |

Get the code:

```sh
git clone https://github.com/Chaozhuang22/rekindle.git
cd rekindle
```

```mermaid
flowchart LR
  A[0 Check model & firmware] --> B[1 Fetch packages]
  B --> C[2 Prepare & fill storage]
  C --> D[3 WinterBreak v1.7.0]
  D --> E[4 Hotfix]
  E --> F[5 Block OTA, KUAL, MRPI, USBNetwork]
  F --> G[6 SSH over Wi-Fi]
  G --> H[7 Deploy dashboard]
```

## 0. Check model and firmware

- **Firmware:** Kindle → Settings → Device Options → Device Info. Also printed in `system/version.txt` on the USB drive.
- **Model:** the serial number is on the same Device Info screen (on macOS also
  `ioreg -p IOUSB -l -w0 | grep -A2 '"Amazon Kindle"'` → `USB Serial Number`). Look up its first
  characters in MobileRead's [Kindle Serial Numbers](https://wiki.mobileread.com/wiki/Kindle_Serial_Numbers)
  table (for example, this project's `90C6…` is a Kindle 7th gen, KT2). After the jailbreak, `fbink -e` prints it as `deviceName`.
- **Jailbreak coverage:** look the firmware up in [kindlemodding.org's live list](https://kindlemodding.org/jailbreaks.json).
  WinterBreak (used here) covers 5.6.1.1–5.18.0.2 on most models from the PW1 onwards.
- **Wi-Fi:** pre-2018 Kindles are **2.4 GHz only**. A 5 GHz-only network is invisible to them.

✅ Done when you know the model, the firmware, and that it falls within WinterBreak's range.

## 1. Fetch the packages (computer)

```sh
scripts/fetch-deps.sh
```

This downloads pinned versions into `vendor/` and verifies their SHA-256:

| Package | Why |
|---|---|
| WinterBreak **v1.7.0** | The jailbreak. Use v1.7.0: it ships `jb.sh` locally. v2.x and WinterBreak2 download `jb.sh` over HTTPS at run time, and FW 5.8's curl (OpenSSL 1.0.1) cannot connect, so they hang on "Jailbreaking – please wait". |
| Universal Hotfix 2.5.0 | Keeps the jailbreak working and installs FBInk plus the `.sh` shell integration. |
| PEKI v1.0 (`KUAL.jar` only) | The KUAL launcher booklet. This repo ships its own `KUAL.sh` (see phase 5). |
| MRPI (KHF build) | Package installer. The zip contains builds for K5/PW2-era devices too. |
| USBNetwork 0.22.N | SSH server. `pw2_and_up` build by default (PW2, KT2 and later); Kindle Touch and PW1 use `USBNET_BUILD=touch_pw`. |

✅ Done when the script ends with `done` and no checksum errors.

## 2. Prepare the Kindle for jailbreaking (USB)

Back up any books you want to keep. Turn **Airplane mode on**, plug the Kindle into the computer, then run:

```sh
scripts/prepare-jailbreak.sh
```

It checks the firmware is in range, removes stray firmware downloads, copies WinterBreak v1.7.0,
clears the Kindle Store cache, and **fills the storage** until about 70 MB is free. With less than
the update's size free, the Kindle cannot download a firmware update during the jailbreak.
Writing several GB of filler over USB 2.0 takes a while (about 10 min/GB).

✅ Done when the script prints the on-Kindle steps and Device Info shows about 50–90 MB free.

## 3. Jailbreak (on the Kindle)

1. Eject. Airplane mode **on**, then restart (hold power ~40 s).
2. Tap the **Store** (cart icon). When asked to turn off Airplane mode, tap **Yes**. Wait for the Wi-Fi icon.
3. A launcher screen (Mesquito) appears with a **WinterBreak** icon. Tap it.
4. Text scrolls up the screen, ending in **"Finished installing jailbreak! … Please Install HOTFIX now"**.

The Store needs a registered Amazon account. Logging in is harmless because the filled storage
blocks updates.

✅ Done when that message appears. On the drive, `winterbreak.log` ends with the same lines.

## 4. Hotfix (USB, then on the Kindle)

```sh
scripts/stage-hotfix.sh
```

It verifies `winterbreak.log`, deletes any `update*.bin` / `*.tmp.partial` (they block manual
updates), and copies `Update_hotfix_universal.bin`. Then, on the Kindle:

1. Airplane mode on, eject.
2. Settings → ⋮ → **Update Your Kindle** → Update. It installs and restarts.
3. Open **Run Hotfix** in the Library.

✅ Done when the drive has a `libkh/` folder and FBInk exists (`libkh/bin/fbink`).

## 5. Block updates, install KUAL, MRPI and USBNetwork (USB, then on the Kindle)

```sh
scripts/stage-tools.sh
```

- **OTA block:** on FW ≤ 5.10 an `update.bin.tmp.partial` **folder** in the drive root stops all
  firmware downloads. After that the filler files are deleted. (FW ≥ 5.11 needs the
  `renameotabin` KUAL extension instead; the script stops and points to it.)
- **KUAL:** copies `KUAL.jar` plus this repo's [`kindle/documents/KUAL.sh`](../kindle/documents/KUAL.sh).
  PEKI's own `KUAL.sh` ends with `nohup`, which FW 5.8 lacks, so tapping it did nothing. The
  replacement installs the booklet on first tap and opens KUAL.
- **MRPI** into `extensions/`, **USBNetwork** `.bin` into `mrpackages/`.
- Removes WinterBreak leftovers.

On the Kindle: eject, type `;log mrpi` in the Home search bar and press Enter. When it finishes,
connect to a 2.4 GHz Wi-Fi network.

✅ Done when `usbnet/usbnetwork_install.log` on the drive ends in `Success! :)`, and tapping
**KUAL** in the Library opens a menu.

## 6. SSH over Wi-Fi (USB, then network)

```sh
scripts/setup-ssh.sh          # key ~/.ssh/id_ed25519_kindle, USE_WIFI, authorized_keys, autostart
# eject, restart the Kindle, make sure Wi-Fi is connected
scripts/find-kindle.sh        # prints the Kindle's IP
export KINDLE_HOST=192.168.x.y
ssh -i ~/.ssh/id_ed25519_kindle root@$KINDLE_HOST
```

Password logins are disabled over Wi-Fi, so the key is required. `USE_WIFI_SSHD_ONLY` keeps USB
working as a normal drive.

✅ Done when `ssh` lands at a `[root@kindle …]` prompt.

## 7. Deploy and run the dashboard

Set your location and timezone in `kindle/extensions/rekindle/rekindle.conf` first:

- `LATITUDE`, `LONGITUDE`: decimal degrees (right-click a spot in Google Maps to copy them); `PLACE`: the label shown on screen.
- `TZ_IANA`: your zone's name, e.g. `Europe/Berlin` (used by the weather service).
- `TZ_POSIX`: the same zone for the clock, as a POSIX string, because the Kindle has no timezone
  database. A name like `Europe/Berlin` would silently show UTC.

| Zone | `TZ_POSIX` | `TZ_IANA` |
|---|---|---|
| Japan | `JST-9` | `Asia/Tokyo` |
| China | `CST-8` | `Asia/Shanghai` |
| India | `IST-5:30` | `Asia/Kolkata` |
| Sydney | `AEST-10AEDT,M10.1.0,M4.1.0/3` | `Australia/Sydney` |
| Central Europe | `CET-1CEST,M3.5.0,M10.5.0/3` | `Europe/Berlin` (or Paris, Madrid, …) |
| UK | `GMT0BST,M3.5.0/1,M10.5.0` | `Europe/London` |
| US Eastern | `EST5EDT,M3.2.0,M11.1.0` | `America/New_York` |
| US Pacific | `PST8PDT,M3.2.0,M11.1.0` | `America/Los_Angeles` |

These were checked on the Kindle against summer and winter dates. For other zones,
[posix_tz_db's zones.csv](https://github.com/nayarsystems/posix_tz_db/blob/master/zones.csv) maps each IANA name to its POSIX string.

```sh
scripts/deploy.sh
```

The dashboard scales its 600×800 layout to the screen it finds, so Paperwhites (758×1024,
1072×1448) get the same design, larger.

On the Kindle: **KUAL → Rekindle dashboard**, then pick a layout:

- **Start: simplistic**: the current weather, plus a rain banner and an hourly rain chart when rain is due
  within `RAIN_LOOKAHEAD_HOURS`.
- **Start: 5-day forecast**: the current weather and the next five days (four when the rain banner is
  showing), each with a low-to-high temperature bar and its chance of rain when that reaches
  `RAIN_PROBABILITY`.

The Kindle UI stops and the dashboard takes over within about 5 seconds. The **power button** exits
back to the Kindle UI; to switch layouts, exit and start the other one. Over SSH the same choice is
`rekindle.sh start simplistic` or `rekindle.sh start forecast` (plain `start` is the simplistic layout).

Check it from the computer:

```sh
scripts/screenshot.sh now.png
ssh -i ~/.ssh/id_ed25519_kindle root@$KINDLE_HOST /mnt/us/extensions/rekindle/bin/rekindle.sh status
```

✅ Done when the screenshot shows the clock and weather, and the clock advances a minute later.

Keep the Kindle on a **wall charger**. Wi-Fi stays on and the device never sleeps while the
dashboard runs. Plugging into a computer normally switches the Kindle into USB-drive mode, which
takes `/mnt/us` (where the dashboard lives) away from it.

## Updating later

Edit files under `kindle/`, then `scripts/deploy.sh --restart`. On-device settings in
`/mnt/us/extensions/rekindle/rekindle.conf` are kept across deploys.

To preview the layout at another screen size on your own Kindle, start it with a smaller target,
e.g. a Paperwhite 3's proportions:
`ssh … 'REKINDLE_VIEW=444x600 /mnt/us/extensions/rekindle/bin/rekindle.sh start'`.
