#!/bin/bash
# Renders Assets/AppIcon.svg into Resources/AppIcon.icns and Assets/icon.png, the README's copy.
# Needs Google Chrome, which draws the SVG's gradients and shadows; macOS has nothing that does.
set -euo pipefail
cd "$(dirname "$0")"

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$chrome" ]] || { echo "Error: icon.sh needs Google Chrome in /Applications." >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --force-device-scale-factor=1 --window-size=1024,1024 --user-data-dir="$work/profile" \
  --screenshot="$work/icon.png" "file://$PWD/Assets/AppIcon.svg" >/dev/null 2>&1
[[ "$(sips -g pixelWidth "$work/icon.png" | awk '/pixelWidth/ { print $2 }')" == 1024 ]] \
  || { echo "Error: Chrome didn't render a 1024 px icon." >&2; exit 1; }

mkdir "$work/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/icon.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$work/icon.png" \
    --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
sips -z 512 512 "$work/icon.png" --out Assets/icon.png >/dev/null
echo "Resources/AppIcon.icns, Assets/icon.png"
