#!/bin/bash
# Builds release and wraps the binary into an app bundle, one of two (AppVariant.swift; the advisor's decision,
# 2026-10-21):
#   VARIANT=dev (the default)  build/Paperole Dev.app: agents' tests and the advisor's experiments, its own data,
#                              the checkout's live engine (EngineClient.checkoutEngine)
#   VARIANT=release            the official Paperole.app, with a snapshot of the engine; only into APP_OUT, as
#                              release.sh does before it installs it in /Applications
# The app was PaperCollab until 2026-10-27 (bundle ids com.papercollab.app[.dev]). Its first real launch under the new
# ids moves its data to the new names (Migration.swift; UX.md §34). An old "build/PaperCollab Dev.app" is left as it is:
# the advisor moves it to the Trash.
set -euo pipefail
cd "$(dirname "$0")"
VARIANT="${VARIANT:-dev}"
case "$VARIANT" in
  dev) NAME="Paperole Dev"; EXE=PaperoleDev; ID=com.paperole.app.dev; ICON=paperole-dev ;;
  release) NAME="Paperole"; EXE=Paperole; ID=com.paperole.app; ICON=paperole ;;
  *) echo "VARIANT is dev or release, not $VARIANT" >&2; exit 2 ;;
esac
if [ "$VARIANT" = release ] && [ -z "${APP_OUT:-}" ]; then
  echo "VARIANT=release builds only into APP_OUT; release.sh builds and installs the official app" >&2
  exit 2
fi
# build/Paperole Dev.app is never replaced under a running Paperole Dev, nor the old PaperCollab Dev (CLAUDE.md): build
# a test bundle with APP_OUT instead
if [ -z "${APP_OUT:-}" ] && { pgrep -x PaperoleDev >/dev/null 2>&1 || pgrep -x PaperCollabDev >/dev/null 2>&1; }; then
  echo "Paperole Dev (or the old PaperCollab Dev) is running: quit it, or build elsewhere with APP_OUT" >&2
  exit 1
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Paperole"
APP="${APP_OUT:-build/$NAME.app}"  # APP_OUT: build elsewhere, e.g. while the user's copy is running
# The bundle is made beside its place and moved there whole (UX.md §26): a bundle seen while it is made, before its
# Info.plist (Finder showing the folder, Spotlight, the Dock), gets the generic app icon, and Finder and Launch Services
# keep it until the bundle's date changes, which writing inside Contents never does.
mkdir -p "$(dirname "$APP")"
STAGE="$(mktemp -d "$(dirname "$APP")/.Paperole-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/$NAME.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp "$BIN" "$NEW/Contents/MacOS/$EXE"
# The app icon (UX.md §26, §34; design/logo/LOGO.md §9-§10), light and dark: Paperole, made by
# design/brand/paperole/round6/src/build_icns.py. The bundle's own is the light one (CFBundleIconFile); the app shows
# the style chosen in Settings › General while it runs. Paperole Dev's own is paperole-dev, Paperole with the DEV mark
# (tools/dev_icon.sh); it marks the one shown while it runs.
cp Resources/AppIcons/paperole.icns Resources/AppIcons/paperole-dark.icns "$NEW/Contents/Resources/"
if [ "$VARIANT" = dev ]; then cp Resources/AppIcons/paperole-dev.icns "$NEW/Contents/Resources/"; fi
# The official app's engine: the package's .py files as they are now (no __pycache__ from the repo), compiled here by
# the venv's Python the app runs it with (EngineClient.defaultPython), so that nothing writes inside the installed
# bundle; the app puts this folder first on PYTHONPATH.
if [ "$VARIANT" = release ]; then
  PY=../engine/.venv/bin/python
  [ -x "$PY" ] || { echo "no engine venv at engine/.venv" >&2; exit 1; }
  ENGINE="$NEW/Contents/Resources/engine"
  (cd ../engine && find paperole -name '*.py' ! -path '*/__pycache__/*') | while IFS= read -r f; do
    mkdir -p "$ENGINE/$(dirname "$f")"
    cp "../engine/$f" "$ENGINE/$f"
  done
  [ -f "$ENGINE/paperole/__init__.py" ] || { echo "no engine package copied" >&2; exit 1; }
  "$PY" -m compileall -q --invalidation-mode checked-hash "$ENGINE/paperole" >/dev/null
fi
# The app's accent colour (POLISH §2.2): Resources/Assets.xcassets compiled to Assets.car, named by NSAccentColorName.
xcrun actool Resources/Assets.xcassets --compile "$NEW/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist "$(mktemp -d)/assets.plist" >/dev/null
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundleIconFile</key><string>$ICON</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$NEW" >/dev/null 2>&1 || true
# The old bundle out of the way and the new one in its place: two renames, so the path is never a half-made bundle.
if [ -e "$APP" ]; then mv "$APP" "$STAGE/old.app"; fi
mv "$NEW" "$APP"
# A new date (a rename keeps the one it was made with), so an icon cached for this bundle, or for the path's last one,
# is looked up again.
touch "$APP"
# The installed copy only: Launch Services takes this bundle (its icon) at once, not when Finder or a launch next
# registers it. A test bundle (APP_OUT, temporary) is left out of its database; nothing else in it is changed.
if [ -z "${APP_OUT:-}" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
fi
echo "$APP"
