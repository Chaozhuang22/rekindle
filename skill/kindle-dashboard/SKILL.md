---
name: kindle-dashboard
description: Turn an old Kindle into an always-on clock and weather e-ink display with the rekindle repo (jailbreak, hotfix, KUAL, SSH, dashboard deploy). Use when the user wants to repurpose, jailbreak, or set up a Kindle as a dashboard, or to change, redeploy or debug that dashboard.
---

# Kindle clock and weather dashboard

You drive the **rekindle** repo (https://github.com/Chaozhuang22/rekindle; clone it if the workspace
lacks `scripts/fetch-deps.sh`). The flow alternates between **host steps** you run and
**device steps** only the human can do on the Kindle (taps, restarts, typing in its search bar).
At every device step: give the exact on-Kindle instructions the script printed, then stop and wait
for the user to report back. Verify the result yourself from the drive or over SSH before moving on.

Reference, read as needed:
- `docs/guide.md`: the phase-by-phase procedure, with each phase's completion check.
- `docs/troubleshooting.md`: symptom → cause → fix for every failure seen so far.

## Steps

1. **Identify the device.** Firmware from `system/version.txt` on the mounted drive (or the user's
   Device Info), model from the serial prefix. Check the firmware against
   https://kindlemodding.org/jailbreaks.json. Done when model and firmware are known and inside
   WinterBreak's 5.6.1.1–5.18.0.2. Outside that range, stop: this repo's flow does not apply.
   Also confirm the Wi-Fi band: pre-2018 models are 2.4 GHz only.
2. **Fetch packages:** `scripts/fetch-deps.sh`. Done when it prints `done` (checksums verified).
3. **Prepare:** user backs up books, Airplane mode on, plugs in. Run `scripts/prepare-jailbreak.sh`.
   Done when it reports the free space; the filler can take many minutes, so run it in the background.
4. **Jailbreak (device):** Store → Yes to Wi-Fi → WinterBreak icon. Done when `winterbreak.log`
   on the drive contains "Finished installing jailbreak".
5. **Hotfix:** `scripts/stage-hotfix.sh`; device: Update Your Kindle, then Run Hotfix. Done when
   `libkh/bin/fbink` exists on the drive.
6. **Tools:** `scripts/stage-tools.sh`; device: `;log mrpi` in the search bar, then join 2.4 GHz Wi-Fi.
   Done when `usbnet/usbnetwork_install.log` ends in "Success" and tapping KUAL opens its menu.
7. **SSH:** `scripts/setup-ssh.sh`; device: eject and restart. Then
   `export KINDLE_HOST=$(scripts/find-kindle.sh)`. Done when `ssh -i ~/.ssh/id_ed25519_kindle root@$KINDLE_HOST true` succeeds.
8. **Dashboard:** set `LATITUDE`, `LONGITUDE`, `PLACE`, `TZ_POSIX`, `TZ_IANA` in
   `kindle/extensions/rekindle/rekindle.conf` for the user's location, `scripts/deploy.sh`;
   device: KUAL → Rekindle dashboard → Start dashboard. Done when `scripts/screenshot.sh` shows the
   clock and weather, a second screenshot a minute later shows the clock advanced, and the user
   confirms the power button returns to the Kindle UI.

## Changing the dashboard later

Edit `kindle/extensions/rekindle/bin/rekindle.sh` (BusyBox 1.17 ash: no `grep -E`, `head -c`,
`nohup`), then `scripts/deploy.sh --restart` and check with `scripts/screenshot.sh`. The on-device
`rekindle.conf` is preserved; edit it over SSH for per-device settings.
