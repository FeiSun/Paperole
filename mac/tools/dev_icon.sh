#!/bin/bash
# Makes Resources/AppIcons/paperole-dev.icns from paperole.icns, light, with the DEV mark drawn by the code the running
# dev app uses for its Dock icon (Sources/Paperole/DevMark.swift): Paperole Dev's own icon (its CFBundleIconFile in
# build_app.sh). Run it again after either changes; the .icns is committed. (The Round's, round-dev.icns, its icon
# before 2026-10-26, is kept in design/logo/red/icns.)
#   usage: tools/dev_icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ICON=paperole
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
swiftc -O -o "$T/dev_icon" Sources/Paperole/DevMark.swift tools/DevIcon/main.swift
"$T/dev_icon" "Resources/AppIcons/$ICON.icns" "$T/$ICON-dev.iconset"
iconutil -c icns "$T/$ICON-dev.iconset" -o "Resources/AppIcons/$ICON-dev.icns"
echo "Resources/AppIcons/$ICON-dev.icns"
