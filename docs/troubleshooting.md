# Troubleshooting

Each entry was hit while building this project on a KT2 / FW 5.8.11, unless marked otherwise.

## Jailbreak

| Symptom | Cause | Fix |
|---|---|---|
| WinterBreak2: tapping **Jailbreak** asks to download a `.mobi`, then nothing happens | WinterBreak2's payload runs `curl https://kindlemodding.org/jb.sh`. FW 5.8's curl 7.33 / OpenSSL 1.0.1 cannot complete the TLS handshake. `documents/JAILBROKEN.txt` never appears. | Use WinterBreak **v1.7.0** (`scripts/fetch-deps.sh` pins it), which runs a local `jb.sh`. |
| WinterBreak v2.x: stuck on "Jailbreaking – please wait" for 20+ minutes, no text | Same HTTPS download, same failure. | Restart (hold power 40 s; nothing has been changed yet) and use v1.7.0. |
| `update.bin.tmp.partial` keeps reappearing on the drive | The Kindle starts a firmware download every time it goes online; the filled storage stops it partway. | Expected until OTA is blocked. Delete it before any manual update; `stage-hotfix.sh` and `stage-tools.sh` do this. |
| Opening the Store logs into an account | Normal; WinterBreak needs a registered device. | Harmless while storage is full. |

## Hotfix and tools

| Symptom | Cause | Fix |
|---|---|---|
| "Update Your Kindle" greyed out | No `Update_*.bin` in the drive root, or another `.bin`/`.partial` file is in the way. | Re-run `scripts/stage-hotfix.sh`. |
| Tapping **KUAL** in the Library does nothing (a `KUAL.sh.sdr` folder may appear) | PEKI's `KUAL.sh` ends with `nohup …`. FW 5.8 has no `nohup` (`sh: nohup: not found`), so the launch line never runs. | Use this repo's `kindle/documents/KUAL.sh` (staged by `stage-tools.sh`, also pushed by `deploy.sh`). |
| `;log mrpi` shows nothing | MRPI not in `extensions/`, or the `.bin` not in `mrpackages/`. | Re-run `scripts/stage-tools.sh`, restart, retry. |

## Network

| Symptom | Cause | Fix |
|---|---|---|
| Home network not listed / manual setup fails | Pre-2018 Kindles are 2.4 GHz only. | Enable the router's 2.4 GHz band (WPA2 or WPA2/WPA3 mixed). Switching a single-band travel router to 2.4 GHz costs little when the uplink is a mobile line: we measured 10.6 Mbps down on the line vs an 866 Mbps 5 GHz link. |
| `find-kindle.sh` finds nothing | Kindle not on the same subnet, Wi-Fi asleep, or USBNetwork autostart off. | Wake the Kindle, check Wi-Fi, confirm `usbnet/auto` exists (not `DISABLED_auto`), restart. |
| A port scan misses the Kindle | The Kindle ignores pings and answers slowly while dozing. | `find-kindle.sh` logs in over SSH to each ARP neighbour instead of scanning. |

## Dashboard

| Symptom | Cause | Fix |
|---|---|---|
| Power button does nothing while the dashboard runs | The dashboard sets powerd's `preventScreenSaver`, and with that set powerd ignores the button: no `goingToScreenSaver` event. | Fixed: the script reads the power key directly from `/dev/input/event0` (the `max77696-onkey` device on KT2). Other models may use a different event node. |
| Text drawn with `-C WHITE -B BLACK` comes out black on white | FBInk 1.25's TrueType path did not honour these colours in our tests. | Use `-h` (invert) on a black rectangle, as the rain banner does. |
| Dashboard keeps running old code after `deploy.sh` | A running shell keeps executing the old script file. | `scripts/deploy.sh --restart`. |
| `grep -E`, `head -c`, `nohup` "not found"/"invalid option" | BusyBox 1.17 on FW 5.8. | Use `grep -e`, `cut -c`, `setsid`. |
| Clock in the Kindle's own status bar is an hour off | The Kindle's timezone setting (e.g. a China-region device in Japan). | The dashboard ignores it (`TZ_POSIX` in `rekindle.conf`). To fix the status bar, change the time zone in Settings → Device Options. |
| "weather offline since HH:MM" in the footer | No successful fetch for 2 hours. | Check Wi-Fi; `rekindle.sh fetch` over SSH shows the parsed result or the error is in `rekindle.log`. |

## Recovering the Kindle UI

- Press the power button, or `ssh … rekindle.sh stop`.
- If all else fails: hold power ~40 s to restart. The dashboard does not autostart, so the normal UI returns.
