# Shared helpers for the host-side scripts (sourced, not executed). macOS or Linux.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR=$ROOT/vendor
KINDLE_VOL=${KINDLE_VOL:-/Volumes/Kindle}
KINDLE_KEY=${KINDLE_KEY:-$HOME/.ssh/id_ed25519_kindle}

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# The Kindle must be mounted as a USB drive.
require_volume() {
	[ -d "$KINDLE_VOL/system" ] && [ -d "$KINDLE_VOL/documents" ] ||
		die "Kindle drive not found at $KINDLE_VOL (plug it in, or set KINDLE_VOL)"
}

require_vendor() {
	[ -e "$VENDOR/$1" ] || die "missing vendor/$1; run scripts/fetch-deps.sh first"
}

# Firmware version string from the drive, e.g. 5.8.11
firmware_version() {
	sed -n 's/^Kindle \([0-9.]*\).*/\1/p' "$KINDLE_VOL/system/version.txt" 2>/dev/null
}

# 0 if version $1 <= $2 (dotted numeric compare)
version_le() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -n 1)" = "$1" ]
}

free_mb() {
	df -m "$KINDLE_VOL" | awk 'NR == 2 { print $4 }'
}

# Copy a directory tree onto the FAT drive without macOS metadata files.
copy_tree() {
	src=$1 dst=$2
	mkdir -p "$dst"
	(cd "$src" && COPYFILE_DISABLE=1 tar --format ustar -cf - .) | (cd "$dst" && tar -xf -)
}

# Delete firmware update files (OTA downloads, staged update .bins) from the drive root.
# Files only: on FW <= 5.10 an update.bin.tmp.partial *folder* is the OTA block and must stay.
remove_update_files() {
	find "$KINDLE_VOL" -maxdepth 1 -type f \( -iname 'update*.bin' -o -name '*.tmp.partial' \) -exec rm -f {} +
}

# Remove AppleDouble (._*) files macOS sprinkles on FAT volumes.
clean_appledouble() {
	find "$KINDLE_VOL" -name '._*' -not -path '*/.fseventsd/*' -exec rm -f {} + 2>/dev/null || true
}

require_host() {
	[ -n "${KINDLE_HOST:-}" ] || die "set KINDLE_HOST to the Kindle's IP (scripts/find-kindle.sh finds it)"
}

kssh() {
	ssh -i "$KINDLE_KEY" -o ConnectTimeout=10 -o LogLevel=ERROR "root@$KINDLE_HOST" "$@"
}
