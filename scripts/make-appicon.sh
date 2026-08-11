#!/usr/bin/env bash
#
# make-appicon.sh — turn one square image into the application icon set.
#
#   scripts/make-appicon.sh path/to/source-1024.png
#
# The source should be full-bleed with SQUARE corners: the rounded shape,
# the inset, and the shadow are applied here. Image generators approximate
# the corner curve badly and the error is visible against every other icon
# in the Dock, so it is worth owning that step rather than asking for it.
#
# What "the rounded shape" means precisely: macOS icons are not rounded
# rectangles. Their corners follow a superellipse — the curvature eases in
# continuously rather than meeting the straight edge at a tangent — which is
# why a plain rounded rect reads as subtly wrong beside a system icon. The
# mask below is generated from the superellipse itself.
#
# Geometry follows Apple's macOS icon grid: the artwork occupies 824 points
# of a 1024 canvas, leaving the surrounding margin for the shadow.

set -euo pipefail

SOURCE="${1:-}"
if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
  echo "usage: scripts/make-appicon.sh <source-image>" >&2
  echo "       a square image, 1024x1024 or larger, square corners" >&2
  exit 2
fi

command -v magick >/dev/null 2>&1 || {
  echo "make-appicon: ImageMagick (magick) is required" >&2
  exit 1
}

cd "$(git rev-parse --show-toplevel)"

ICONSET="ConduitApp/ConduitApp/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CANVAS=1024
ART=824
# n=5 lands very close to the system curve; 2 would be an ellipse and 100 a
# square, so the value is doing real work and is not a rounding of "rounded".
EXPONENT=5

echo "make-appicon: $SOURCE"

# 1. The superellipse mask, |x|^n + |y|^n <= 1 over the art square.
magick -size "${ART}x${ART}" xc:black \
  -fx "(pow(abs((i-($ART/2))/($ART/2)),$EXPONENT) + pow(abs((j-($ART/2))/($ART/2)),$EXPONENT)) <= 1 ? 1 : 0" \
  -alpha off "$WORK/mask.png"

# 2. Square the source by cropping to centre, then fit the art square.
magick "$SOURCE" \
  -gravity center -resize "${ART}x${ART}^" -extent "${ART}x${ART}" \
  "$WORK/art.png"

# 3. Punch the shape out of the artwork.
magick "$WORK/art.png" "$WORK/mask.png" \
  -alpha off -compose CopyOpacity -composite "$WORK/shaped.png"

# 4. Centre on the full canvas, with the soft shadow the surrounding margin
#    exists for. Without it the icon sits flat against the Dock while every
#    neighbour is lifted off it.
magick "$WORK/shaped.png" \
  \( +clone -background black -shadow 30x18+0+16 \) \
  +swap -background none -layers merge +repage \
  -gravity center -background none -extent "${CANVAS}x${CANVAS}" \
  "$WORK/icon-1024.png"

# 5. Every size the set declares, resampled from the full-resolution shape
#    rather than from each other, so small sizes do not accumulate softness.
mkdir -p "$ICONSET"
emit() {
  magick "$WORK/icon-1024.png" -resize "${1}x${1}" "$ICONSET/icon_${1}.png"
  printf '  %4sx%-4s %s\n' "$1" "$1" "icon_${1}.png"
}
for size in 16 32 64 128 256 512 1024; do emit "$size"; done

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",   "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16",   "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

echo "make-appicon: wrote $ICONSET"
echo "make-appicon: rebuild with  make app-build && make app-install"
