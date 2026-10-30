#!/usr/bin/env bash
# Count the columns a set of tiled windows makes on screen, for
# auto-config.aerospace.sh to pick gaps by. Usage: column-count.sh <window-id>...
#
# AeroSpace's tree is not readable from outside. list-windows gives only the
# layout of a window's parent container, with no id for that container, so two
# separate stacked groups look the same as one. AeroSpace's window ids are the
# window server's, though, and it knows every frame. Reading three of them
# took 100ms (2026-10-30), with nothing to install.
#
# Windows whose x ranges mostly overlap are one column. An accordion offsets
# each window by its 30px padding, so its windows overlap almost entirely and
# count once, at any nesting depth. Tiles side by side do not overlap. Half a
# width is the line, so an app whose minimum width spills into the next tile
# still counts as its own column. The caller drops floating windows first:
# a frame cannot say whether its window is floating, and AeroSpace can.

[ $# -gt 0 ] || { echo 0; exit 0; }

# id x y width height, one window per line
osascript -l JavaScript -e '
ObjC.import("CoreGraphics");
function run(argv) {
  const want = new Set(argv.map(Number));
  const list = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, $.kCGNullWindowID)));
  return list.filter(w => want.has(w.kCGWindowNumber))
    .map(w => { const b = w.kCGWindowBounds; return [w.kCGWindowNumber, b.X, b.Y, b.Width, b.Height].join(" "); })
    .join("\n");
}' "$@" |
  sort -n -k2 |
  awk '
    NF < 5 { next }
    { x = $2; right = $2 + $4 }
    n == 0 || end - x < $4 / 2 { n++; end = right; next }
    right > end { end = right }
    END { print n + 0 }'
