#!/bin/bash
# Captures ONLY Paperole Dev's own windows (agents' test instances), by window id; never the whole screen. A window
# behind other windows, or in another Space (the user in a full-screen app), is captured whole: the window server keeps
# its content, so a --background test instance needs no focus.
#   shot.sh --pid <pid> out.png        the main window of that process (its largest window at layer 0)
#   shot.sh --pid <pid> out.png --all  also each other window of it (sheet, popover) as out-<id>.png
#   shot.sh out.png [--all]            the same for any process named Paperole Dev (only when no other instance
#                                      runs: the user's own Dev window may be the one captured); never the official
#                                      Paperole's, which holds real reviews
set -euo pipefail
pid=""
if [ "${1:-}" = "--pid" ]; then pid="${2:?usage: shot.sh --pid <pid> out.png [--all]}"; shift 2; fi
out="${1:?usage: shot.sh [--pid <pid>] out.png [--all]}"
ids=$(osascript -l JavaScript -e '
function run(argv) {
  ObjC.import("CoreGraphics");
  var pid = argv[0];
  // with a pid, every window of it (also one in another Space), but not tiny helpers or transparent ones
  var list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(
      pid ? $.kCGWindowListOptionAll : $.kCGWindowListOptionOnScreenOnly, 0));
  var rows = [];
  for (var i = 0; i < list.count; i++) {
    var w = list.objectAtIndex(i);
    if (pid ? String(ObjC.unwrap(w.objectForKey("kCGWindowOwnerPID"))) !== pid
            : ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")) !== "Paperole Dev") continue;
    var b = w.objectForKey("kCGWindowBounds");
    var width = ObjC.unwrap(b.objectForKey("Width")), height = ObjC.unwrap(b.objectForKey("Height"));
    if (pid && (width < 40 || height < 40 || ObjC.unwrap(w.objectForKey("kCGWindowAlpha")) === 0)) continue;
    var area = width * height;
    var layer = ObjC.unwrap(w.objectForKey("kCGWindowLayer"));
    rows.push([layer === 0 ? 1 : 0, area, ObjC.unwrap(w.objectForKey("kCGWindowNumber"))]);
  }
  rows.sort(function (a, b) { return b[0] - a[0] || b[1] - a[1]; });
  return rows.map(function (r) { return r[2]; }).join("\n");
}' "$pid")
[ -n "$ids" ] || { echo "no window of ${pid:-Paperole Dev}" >&2; exit 1; }
main=$(echo "$ids" | head -1)
screencapture -l "$main" -o -x "$out"
echo "$out"
if [ "${2:-}" = "--all" ]; then
  for id in $(echo "$ids" | tail -n +2); do
    screencapture -l "$id" -o -x "${out%.png}-$id.png" && echo "${out%.png}-$id.png"
  done
fi
