#!/bin/sh
# Phase 4 (USB): block OTA updates, free the filler space, and stage KUAL, MRPI and
# USBNetwork (SSH). Also removes the WinterBreak leftovers.
#
# Usage: scripts/stage-tools.sh
set -eu
. "$(dirname "$0")/lib.sh"

require_volume
require_vendor mrpi/extensions/MRInstaller
require_vendor peki/KUAL.jar
require_vendor usbnet/USBNetwork

[ -d "$KINDLE_VOL/libkh" ] || warn "no libkh/ on the drive; did 'Run Hotfix' complete?"

fw=$(firmware_version)
say "firmware $fw"
if version_le "$fw" 5.10.99; then
	# FW <= 5.10: a *folder* named like the OTA download file stops the download.
	remove_update_files
	mkdir -p "$KINDLE_VOL/update.bin.tmp.partial"
	say "OTA updates blocked (update.bin.tmp.partial folder)"
else
	die "firmware $fw >= 5.11 needs the renameotabin KUAL extension to block OTA (kindlemodding.org/jailbreaking/Legacy/post-jailbreak/disable-ota.html); not automated here"
fi

say "removing filler and jailbreak leftovers"
rm -rf "$KINDLE_VOL/fill_disk" "$KINDLE_VOL/jb.sh" "$KINDLE_VOL/patchedUks.sqsh" \
	"$KINDLE_VOL/apps/com.hackerdude.winterbreak" "$KINDLE_VOL/mesquito"
rmdir "$KINDLE_VOL/apps" 2>/dev/null || true
# WinterBreak's replacement Store pages; the Store regenerates its own.
rm -f "$KINDLE_VOL/.active_content_sandbox/store/resource/cachedResources/index.html" \
	"$KINDLE_VOL/.active_content_sandbox/store/resource/cachedResources/secondaryStore.html"

say "staging MRPI"
copy_tree "$VENDOR/mrpi/extensions" "$KINDLE_VOL/extensions"
mkdir -p "$KINDLE_VOL/mrpackages"

say "staging KUAL (booklet jar + fixed launcher)"
cp "$VENDOR/peki/KUAL.jar" "$KINDLE_VOL/documents/KUAL.jar"
cp "$ROOT/kindle/documents/KUAL.sh" "$KINDLE_VOL/documents/KUAL.sh"
rm -rf "$KINDLE_VOL/documents/KUAL.sh.sdr"

say "staging USBNetwork (pw2_and_up build: PW2, KT2 and newer K5-platform devices)"
cp "$VENDOR/usbnet/USBNetwork/Update_usbnet_0.22.N_install_pw2_and_up.bin" "$KINDLE_VOL/mrpackages/"

clean_appledouble
say "staged, $(free_mb) MB free. On the Kindle:"
cat <<'EOF'
  1. Eject. In the Home search bar type   ;log mrpi   and press Enter; wait for "Success".
  2. Connect Wi-Fi (2.4 GHz only on older models).
  3. Plug back in and run scripts/setup-ssh.sh
EOF
