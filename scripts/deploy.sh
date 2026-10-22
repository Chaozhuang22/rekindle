#!/bin/sh
# Phase 6 (SSH): install or update the dashboard on the Kindle.
# Copies kindle/extensions/rekindle to /mnt/us/extensions/rekindle and the KUAL launcher
# to /mnt/us/documents/KUAL.sh. An existing on-device rekindle.conf is kept.
#
# Usage: KINDLE_HOST=192.168.x.y scripts/deploy.sh [--restart]
set -eu
. "$(dirname "$0")/lib.sh"

require_host
ext=/mnt/us/extensions/rekindle

restart=0
[ "${1:-}" = "--restart" ] && restart=1
if [ "$restart" = 1 ]; then
	# A running shell keeps executing the old script file; stop it before replacing.
	kssh "[ -x $ext/bin/rekindle.sh ] && $ext/bin/rekindle.sh stop; sleep 1" || true
fi

# ustar: BusyBox 1.17 tar on the Kindle does not understand pax headers.
COPYFILE_DISABLE=1 tar --format ustar -C "$ROOT/kindle/extensions" -cf - --exclude rekindle/rekindle.conf rekindle |
	kssh "mkdir -p /mnt/us/extensions && tar -C /mnt/us/extensions -xf -"
if kssh "[ -f $ext/rekindle.conf ]"; then
	say "keeping the Kindle's existing rekindle.conf"
else
	kssh "cat > $ext/rekindle.conf" <"$ROOT/kindle/extensions/rekindle/rekindle.conf"
fi
kssh "cat > /mnt/us/documents/KUAL.sh" <"$ROOT/kindle/documents/KUAL.sh"

if [ "$restart" = 1 ]; then
	# Starting right after stop races the framework restart; give it time.
	kssh "sleep 20; $ext/bin/rekindle.sh start"
fi
say "deployed to $KINDLE_HOST"
