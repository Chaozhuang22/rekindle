#!/bin/sh
# Download the third-party Kindle packages this project relies on into vendor/,
# verify their SHA-256 and unpack them. These are not redistributed in this repo;
# each belongs to its authors (see README "Credits").
#
# Usage: scripts/fetch-deps.sh
set -eu
. "$(dirname "$0")/lib.sh"

mkdir -p "$VENDOR/downloads"

# name|url|sha256
DEPS='
WinterBreak-v1.7.0.tar.gz|https://github.com/KindleModding/WinterBreak/releases/download/v1.7.0/WinterBreak.tar.gz|e947c57ec47e3d468ad786f2d28418dc33fc9f7c79d352762724eeab5e2ff391
Update_hotfix_universal-2.5.0.bin|https://github.com/KindleModding/Hotfix/releases/download/2.5.0/Update_hotfix_universal.bin|94d5c05254b70c4905392515411f620168ac238db62c7dcbc48a1e31d5de6c59
PEKI-v1.0.zip|https://github.com/KindleTweaks/PEKI/releases/download/v1.0/PEKI.zip|f653045909ed230496c3d8176c9901d3a6a1f693c52b488569be6a60e0852499
kual-mrinstaller-khf.zip|https://kindlemodding.org/jailbreaking/Legacy/post-jailbreak/installing-kual-mrpi/kual-mrinstaller-khf.zip|9974dfc2d1e7687b3fc74d68f6b5aeab2428f22d83ab82e6d600a0384c607d09
kindle-usbnet-0.22.N-r19297.tar.xz|https://storage.gra.cloud.ovh.net/v1/AUTH_2ac4bfee353948ec8ea7fd1710574097/mr-public/Touch/kindle-usbnet-0.22.N-r19297.tar.xz|cf971557d42cc0a6d7699f1c743108c681fa41e3d67ee5802a91932d130d4032
'

sha256() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

echo "$DEPS" | while IFS='|' read -r name url sum; do
	[ -n "$name" ] || continue
	file=$VENDOR/downloads/$name
	if [ ! -f "$file" ] || [ "$(sha256 "$file")" != "$sum" ]; then
		say "downloading $name"
		# -C - resumes; the USBNetwork mirror can be slow.
		curl -fsSL --retry 3 -C - -o "$file" "$url" || curl -fsSL --retry 3 -o "$file" "$url"
	fi
	[ "$(sha256 "$file")" = "$sum" ] || die "checksum mismatch for $name (upstream changed? update the pin)"
done

say "unpacking into vendor/"
rm -rf "$VENDOR/winterbreak" "$VENDOR/peki" "$VENDOR/mrpi" "$VENDOR/usbnet"
mkdir -p "$VENDOR/winterbreak" "$VENDOR/peki" "$VENDOR/mrpi" "$VENDOR/usbnet"
tar -xzf "$VENDOR/downloads/WinterBreak-v1.7.0.tar.gz" -C "$VENDOR/winterbreak"
unzip -q -o "$VENDOR/downloads/PEKI-v1.0.zip" -d "$VENDOR/peki"
unzip -q -o "$VENDOR/downloads/kual-mrinstaller-khf.zip" -d "$VENDOR/mrpi"
tar -xJf "$VENDOR/downloads/kindle-usbnet-0.22.N-r19297.tar.xz" -C "$VENDOR/usbnet"
cp "$VENDOR/downloads/Update_hotfix_universal-2.5.0.bin" "$VENDOR/Update_hotfix_universal.bin"
say "done"
