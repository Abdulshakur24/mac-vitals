#!/bin/bash
#
# Renders the app icon at every size macOS asks for and packs it into
# Resources/Vitals.icns. Also writes Resources/icon-512.png for the README.
#
#   ./Scripts/make-icon.sh
#
# Only needs running when the artwork in make-icon.swift changes; the .icns is
# committed, so a normal build does not pay for this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Compiling the generator"
swiftc -O "$ROOT/Scripts/make-icon.swift" -o "$WORK/make-icon"

echo "==> Rendering"
mkdir -p "$WORK/Vitals.iconset" "$OUT"

# iconutil expects exactly these names. Each @2x is the same artwork rendered
# at twice the pixel count, not an upscale of the 1x.
render() { "$WORK/make-icon" "$1" "$WORK/Vitals.iconset/$2"; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

echo "==> Packing Vitals.icns"
iconutil --convert icns "$WORK/Vitals.iconset" --output "$OUT/Vitals.icns"

# The bundle art is square because macOS masks it. A square PNG dropped into
# the README would just look unfinished, so that one gets the corners drawn in.
echo "==> Writing icon-512.png for the README"
"$WORK/make-icon" --rounded 512 "$OUT/icon-512.png"

echo "    $(du -h "$OUT/Vitals.icns" | cut -f1) $OUT/Vitals.icns"
echo "==> Done"
