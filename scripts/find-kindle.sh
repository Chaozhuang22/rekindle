#!/bin/sh
# Find the Kindle on the local network and print its IP (use it as KINDLE_HOST).
#
# The Kindle ignores ping, so this sweeps TCP port 22 across each local /24 (which also
# fills the neighbour table), then tries an SSH login with the Kindle key against every
# candidate. Works with macOS (ifconfig/arp) and Linux (ip; or ifconfig/arp).
#
# Usage: scripts/find-kindle.sh
set -eu
. "$(dirname "$0")/lib.sh"

[ -f "$KINDLE_KEY" ] || die "no key at $KINDLE_KEY (run scripts/setup-ssh.sh first)"

local_ips() {
	if command -v ip >/dev/null 2>&1; then
		ip -4 -o addr show 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }'
	else
		ifconfig 2>/dev/null | awk '/inet / { sub("addr:", "", $2); print $2 }'
	fi | grep -v -e '^127\.' -e '^169\.254\.'
}

neighbours() {
	if command -v ip >/dev/null 2>&1; then
		ip -4 neigh show 2>/dev/null | awk '!/FAILED|INCOMPLETE/ { print $1 }'
	else
		arp -an 2>/dev/null | awk '!/incomplete/ { gsub(/[()]/, "", $2); print $2 }'
	fi
}

# nc flag for a connect timeout differs: macOS -G, Linux (OpenBSD netcat) -w.
if nc -h 2>&1 | grep -q -e '-G'; then NC_TIMEOUT="-G 3"; else NC_TIMEOUT="-w 3"; fi

nets=$(local_ips | cut -d. -f1-3 | sort -u)
[ -n "$nets" ] || die "no IPv4 address on this machine"
say "scanning port 22 on $(echo "$nets" | tr '\n' ' ')(about a minute)…" >&2

swept=$(mktemp)
for net in $nets; do
	i=1
	while [ "$i" -le 254 ]; do
		# shellcheck disable=SC2086
		(nc -z $NC_TIMEOUT "$net.$i" 22 >/dev/null 2>&1 && echo "$net.$i" >>"$swept") &
		# Batches of 32 stay under per-user process limits.
		[ $((i % 32)) -eq 0 ] && wait
		i=$((i + 1))
	done
	wait
done

candidates=$( (cat "$swept"; neighbours) | grep -v -e '\.255$' -e '\.0$' | sort -u)
rm -f "$swept"
[ -n "$candidates" ] || die "no hosts found; is the Kindle awake and on the same Wi-Fi?"

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
	die "no Kindle answered over SSH. Wake it, check Wi-Fi and that usbnet/auto exists, then restart it"
fi
