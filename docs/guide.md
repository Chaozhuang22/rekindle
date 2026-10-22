# Setup guide: from stock Kindle to clock and weather display

The full path this project took on a Kindle 7th gen (KT2) running firmware 5.8.11. Each phase lists
what runs on the computer, what you do on the Kindle, and how to know it worked. Something
off? [troubleshooting.md](troubleshooting.md) is organised by symptom.

The host scripts were written for macOS (`/Volumes/Kindle`). On Linux, set `KINDLE_VOL` to the
mount point.

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
- **Model:** first characters of the serial number. On macOS, `ioreg -p IOUSB -l -w0 | grep -A2 '"Amazon Kindle"'` shows it as `USB Serial Number`.
  This project's `90C6…` is a KT2. NiLuJe's FBInk also prints the model after jailbreak (`fbink -e` → `deviceName`).
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
| USBNetwork 0.22.N | SSH server. KT2 uses the `pw2_and_up` build. |

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

```sh
$EDITOR kindle/extensions/rekindle/rekindle.conf   # latitude/longitude, place, timezone
scripts/deploy.sh
```

On the Kindle: **KUAL → Rekindle dashboard → Start dashboard**. The Kindle UI stops and the
dashboard takes over within about 5 seconds. The **power button** exits back to the Kindle UI.

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
