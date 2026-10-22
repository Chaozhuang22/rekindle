#!/bin/sh
# Phase 2 (USB): stage WinterBreak v1.7.0 on the Kindle and fill its storage so it
# cannot download a firmware update mid-jailbreak.
#
# Usage: scripts/prepare-jailbreak.sh
# Env:   KINDLE_VOL (default /Volumes/Kindle), FREE_TARGET_MB (default 70; guide says 50-90)
set -eu
. "$(dirname "$0")/lib.sh"

require_volume
require_vendor winterbreak/jb.sh

fw=$(firmware_version)
[ -n "$fw" ] || die "cannot read firmware from $KINDLE_VOL/system/version.txt"
say "firmware $fw"
if ! version_le 5.6.1.1 "$fw" || ! version_le "$fw" 5.18.0.2; then
	die "WinterBreak covers 5.6.1.1-5.18.0.2; firmware $fw needs a different jailbreak (kindlemodding.org/jailbreaking)"
fi

say "removing stray firmware downloads"
remove_update_files

say "copying WinterBreak v1.7.0 (local jb.sh; v2.x fetches it over HTTPS, which old firmware cannot do)"
for item in jb.sh patchedUks.sqsh apps mesquito .active_content_sandbox; do
	if [ -d "$VENDOR/winterbreak/$item" ]; then
		copy_tree "$VENDOR/winterbreak/$item" "$KINDLE_VOL/$item"
	else
		cp "$VENDOR/winterbreak/$item" "$KINDLE_VOL/$item"
	fi
done
# Stale Kindle Store cache can keep Mesquito from loading (WinterBreak troubleshooting).
rm -rf "$KINDLE_VOL/.active_content_sandbox/store/resource/LocalStorage"
touch "$KINDLE_VOL/.metadata_never_index"
clean_appledouble

target=${FREE_TARGET_MB:-70}
free=$(free_mb)
need=$((free - target))
if [ "$need" -gt 0 ]; then
	say "filling storage: writing ${need} MB of zeros (leaves ~${target} MB free; USB 2.0 is slow, expect ~10 min/GB)"
	mkdir -p "$KINDLE_VOL/fill_disk"
	i=0
	while [ "$need" -gt 0 ]; do
		i=$((i + 1))
		chunk=$need
		[ "$chunk" -gt 1000 ] && chunk=1000
		dd if=/dev/zero of="$KINDLE_VOL/fill_disk/f$i" bs=1048576 count="$chunk" 2>/dev/null
		need=$((need - chunk))
		say "  wrote f$i (${chunk} MB), $(free_mb) MB free"
	done
else
	say "already ${free} MB free (<= ${target}), no filler needed"
fi
clean_appledouble

say "ready. On the Kindle:"
cat <<'EOF'
  1. Eject. Turn Airplane mode ON, then restart (hold power ~40 s).
  2. Tap the Store (cart). Answer "Yes" to turning off Airplane mode; wait for Wi-Fi.
  3. Tap the WinterBreak icon. Text scrolls, ending in "Please Install HOTFIX now".
  4. Plug back in and run scripts/stage-hotfix.sh
EOF
