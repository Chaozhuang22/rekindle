#!/bin/sh
# Phase 5 (USB): enable SSH over Wi-Fi with key auth and autostart.
# Run after USBNetwork was installed with ";log mrpi".
#
# Usage: scripts/setup-ssh.sh
# Env:   KINDLE_KEY (default ~/.ssh/id_ed25519_kindle; created if missing)
set -eu
. "$(dirname "$0")/lib.sh"

require_volume
conf=$KINDLE_VOL/usbnet/etc/config
[ -f "$conf" ] || die "no usbnet/etc/config: USBNetwork is not installed yet (run ;log mrpi on the Kindle)"
if [ -f "$KINDLE_VOL/usbnet/usbnetwork_install.log" ]; then
	tail -n 3 "$KINDLE_VOL/usbnet/usbnetwork_install.log"
fi

if [ ! -f "$KINDLE_KEY" ]; then
	say "creating SSH key $KINDLE_KEY"
	ssh-keygen -q -t ed25519 -N '' -C kindle -f "$KINDLE_KEY"
fi

say "enabling SSH over Wi-Fi (USB stays a normal drive)"
tmp=$(mktemp)
sed -e 's/^USE_WIFI=.*/USE_WIFI="true"/' -e 's/^USE_WIFI_SSHD_ONLY=.*/USE_WIFI_SSHD_ONLY="true"/' "$conf" >"$tmp"
cat "$tmp" >"$conf" # keep the FAT file, UNIX line endings preserved
rm -f "$tmp"
grep -e '^USE_WIFI' "$conf"

cp "$KINDLE_KEY.pub" "$KINDLE_VOL/usbnet/etc/authorized_keys"
[ -f "$KINDLE_VOL/usbnet/DISABLED_auto" ] && mv "$KINDLE_VOL/usbnet/DISABLED_auto" "$KINDLE_VOL/usbnet/auto"
[ -f "$KINDLE_VOL/usbnet/auto" ] && say "SSH autostart enabled"

clean_appledouble
say "done. On the Kindle: eject, restart (hold power ~40 s), make sure Wi-Fi is connected."
say "then: scripts/find-kindle.sh"
