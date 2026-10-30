#!/bin/bash
# Builds the official app (build_app.sh VARIANT=release, into a temporary folder) and installs it as
# /Applications/Paperole.app, with a snapshot of the engine as it is now (AppVariant.swift; the advisor's decision,
# 2026-10-21). Never while Paperole runs, never with sudo; no data folder and no defaults are touched.
# The app was PaperCollab until 2026-10-27, installed as /Applications/PaperCollab.app (bundle id com.papercollab.app).
# The new app moves that app's data and settings to its own names at its first launch (Migration.swift; UX.md §34);
# this script never removes the old app, and says what to do with it while it is there.
set -euo pipefail
cd "$(dirname "$0")"
DEST=/Applications/Paperole.app
OLD=/Applications/PaperCollab.app
ID=com.paperole.app
OLD_ID=com.papercollab.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The official app running: a process named exactly Paperole, or PaperCollab (the old one, whose data the new one
# moves; the dev app's are PaperoleDev and PaperCollabDev; `swift run`'s binary is named Paperole too, so it counts;
# this script's own command line is never matched, pgrep -x looks at process names only), or an app of either bundle id.
running() {
  pgrep -x Paperole >/dev/null 2>&1 || pgrep -x PaperCollab >/dev/null 2>&1 \
    || [ -n "$(lsappinfo find bundleid="$ID" 2>/dev/null)" ] || [ -n "$(lsappinfo find bundleid="$OLD_ID" 2>/dev/null)" ]
}
refuse_if_running() {
  if running; then
    echo "Quit Paperole (or the old PaperCollab) first: it is running, and release.sh never replaces it while it runs." >&2
    exit 1
  fi
}

if [ "$(id -u)" -eq 0 ]; then echo "Run release.sh as yourself, not with sudo." >&2; exit 1; fi
refuse_if_running
if [ ! -w /Applications ]; then echo "/Applications is not writable for $(id -un); nothing was installed." >&2; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/paperole-release.XXXXXX")"
INSTALL=""
cleanup() {
  rm -rf "$TMP"
  if [ -n "$INSTALL" ]; then rm -rf "$INSTALL"; fi
}
trap cleanup EXIT

# The build's output (swift build's errors among it) is shown only when it fails, so a failed build never ends silently.
if ! APP_OUT="$TMP/Paperole.app" VARIANT=release ./build_app.sh >"$TMP/build.log" 2>&1; then
  tail -n 40 "$TMP/build.log" >&2
  echo "The build failed; nothing was installed." >&2
  exit 1
fi
codesign --verify "$TMP/Paperole.app"

# Staged beside its place (a hidden folder in /Applications), then two renames: the old bundle aside, the new one in.
# The old one is removed only once the new one is in place; if that fails, the old one goes back.
INSTALL="$(mktemp -d /Applications/.Paperole-install.XXXXXX)"
ditto "$TMP/Paperole.app" "$INSTALL/Paperole.app"
codesign --verify "$INSTALL/Paperole.app"
refuse_if_running  # it may have been opened while this built
if [ -e "$DEST" ]; then mv "$DEST" "$INSTALL/old.app"; fi
if ! mv "$INSTALL/Paperole.app" "$DEST"; then
  if [ ! -e "$INSTALL/old.app" ]; then
    echo "Could not put the new Paperole.app in place." >&2
  elif mv "$INSTALL/old.app" "$DEST"; then
    echo "Could not put the new Paperole.app in place; the old one is back as it was." >&2
  else
    echo "Could not put the new Paperole.app in place; the old one is kept at $INSTALL/old.app." >&2
    INSTALL=""  # kept: the cleanup removes only what is safe to lose
  fi
  exit 1
fi
touch "$DEST"
"$LSREGISTER" -f "$DEST" || true
rm -rf "$INSTALL"
INSTALL=""

SNAP="$DEST/Contents/Resources/engine/paperole"
COUNT="$(find "$SNAP" -name '*.py' | wc -l | tr -d ' ')"
SUM="$(cd "$SNAP" && find . -name '*.py' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-12)"
echo "Installed $DEST"
echo "Engine snapshot from $(cd ../engine/paperole && pwd -P) ($COUNT files, sha256 $SUM)"
echo
echo "Open $DEST from the Finder or the Dock. At its first launch it moves its data from"
echo "~/Library/Application Support/PaperCollab to ~/Library/Application Support/Paperole (and its thumbnails), and copies"
echo "its settings from $OLD_ID; ~/Library/Application Support/Paperole/migration.log says what it did."
if [ -e "$OLD" ]; then
  echo "After that the old $OLD shows an empty list: check that $DEST shows your reviews, then move"
  echo "$OLD to the Trash yourself (and replace it in the Dock). Never import a paper into it."
fi
