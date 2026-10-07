#!/bin/bash
# Renders Assets/AppIcon.icns from Sources/IconGen.
set -euo pipefail
cd "$(dirname "$0")/.."
out="Assets/AppIcon.iconset"
rm -rf "$out"
mkdir -p "$out"
swift run -c release IconGen "$out"
iconutil -c icns "$out" -o Assets/AppIcon.icns
echo "wrote Assets/AppIcon.icns"
