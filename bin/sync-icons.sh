#!/usr/bin/env bash
# Copies the icon assets from docs/design/icon (the source) into the app's asset catalog.
set -euo pipefail
cd "$(dirname "$0")/.."
src=docs/design/icon
dst=App/Flotsam/Assets.xcassets
mkdir -p "$dst"
for set in AppIcon.appiconset MenuBarActive.imageset MenuBarPaused.imageset MenuBarCurated.imageset MenuBarWarning.imageset; do
  rm -rf "$dst/$set"
  cp -R "$src/$set" "$dst/$set"
done
