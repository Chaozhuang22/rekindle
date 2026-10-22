#!/bin/sh
# Capture the Kindle's e-ink framebuffer over SSH and save it as a PNG (needs python3 + Pillow).
#
# Usage: KINDLE_HOST=192.168.x.y scripts/screenshot.sh out.png
set -eu
. "$(dirname "$0")/lib.sh"

require_host
out=${1:-kindle.png}
info=$(kssh 'fbink -e')
eval "$(echo "$info" | tr ';' '\n' | grep -e '^viewWidth=' -e '^viewHeight=' -e '^lineLength=' -e '^BPP=')"
[ "${BPP:-}" = 8 ] || die "only 8-bpp framebuffers are handled (got BPP=${BPP:-?})"

raw=$(mktemp)
kssh "dd if=/dev/fb0 bs=$lineLength count=$viewHeight 2>/dev/null" >"$raw"
python3 - "$raw" "$out" "$lineLength" "$viewWidth" "$viewHeight" <<'EOF'
import sys
from PIL import Image
raw, out, stride, w, h = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:])
Image.frombytes("L", (stride, h), open(raw, "rb").read()).crop((0, 0, w, h)).save(out)
EOF
rm -f "$raw"
say "saved $out"
