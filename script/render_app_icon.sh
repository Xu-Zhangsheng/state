#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"
SOURCE="$ROOT_DIR/Design/state-blender-preview.png"
DEST="$ROOT_DIR/Stasis/Assets.xcassets/AppIcon.appiconset"
[[ -x "$BLENDER" ]] || { echo 'Blender is required at /Applications/Blender.app.' >&2; exit 1; }
(
  cd "$ROOT_DIR"
  STATE_RES=1024 STATE_SAMPLES=128 "$BLENDER" \
    --background --factory-startup --threads 6 --python Design/state_blender.py
)
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$DEST/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$DEST/icon_${size}x${size}@2x.png" >/dev/null
done
