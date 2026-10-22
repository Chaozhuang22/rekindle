#!/bin/sh
# Phase 3 (USB): confirm the jailbreak ran, then stage the Universal Hotfix.
#
# Usage: scripts/stage-hotfix.sh
set -eu
. "$(dirname "$0")/lib.sh"

require_volume
require_vendor Update_hotfix_universal.bin

if [ -f "$KINDLE_VOL/winterbreak.log" ]; then
	grep -q "Finished installing jailbreak" "$KINDLE_VOL/winterbreak.log" ||
		die "winterbreak.log exists but has no success line; see docs/troubleshooting.md"
	say "jailbreak log: success"
else
	die "no winterbreak.log on the drive: WinterBreak did not run (docs/troubleshooting.md)"
fi

say "removing stray firmware downloads (they block 'Update Your Kindle')"
remove_update_files

cp "$VENDOR/Update_hotfix_universal.bin" "$KINDLE_VOL/"
clean_appledouble
say "hotfix staged. On the Kindle:"
cat <<'EOF'
  1. Airplane mode ON, eject.
  2. Settings -> (menu) -> Update Your Kindle -> Update. It installs and restarts.
  3. Open "Run Hotfix" in the Library and let it finish.
  4. Plug back in and run scripts/stage-tools.sh
EOF
