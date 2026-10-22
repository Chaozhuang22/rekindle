#!/bin/sh
# Find the Kindle on the local network: populate the ARP table, then try an SSH
# login (with the Kindle key) against every neighbour and print the one that answers.
#
# Usage: scripts/find-kindle.sh        (prints the IP; use it as KINDLE_HOST)
set -eu
. "$(dirname "$0")/lib.sh"

[ -f "$KINDLE_KEY" ] || die "no key at $KINDLE_KEY (run scripts/setup-ssh.sh first)"

# Broadcast ping of every /24 we are on, so ARP learns the neighbours.
for net in $(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" { print $2 }' | cut -d. -f1-3); do
	ping -c 2 -t 2 "$net.255" >/dev/null 2>&1 || ping -c 2 -b -W 2 "$net.255" >/dev/null 2>&1 || true
done

candidates=$(arp -an | awk '!/incomplete/ { gsub(/[()]/, "", $2); print $2 }' | grep -v '\.255$' || true)
[ -n "$candidates" ] || die "no neighbours in the ARP table; is the Kindle on the same Wi-Fi?"

out=$(mktemp)
for ip in $candidates; do
	(
		if ssh -i "$KINDLE_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
			-o StrictHostKeyChecking=accept-new "root@$ip" 'cat /etc/prettyversion.txt' >/dev/null 2>&1; then
			echo "$ip" >>"$out"
		fi
	) &
done
wait
if [ -s "$out" ]; then
	cat "$out"
	rm -f "$out"
else
	rm -f "$out"
	die "no Kindle answered over SSH. Check Wi-Fi, that USBNetwork autostart is on, and restart the Kindle"
fi
