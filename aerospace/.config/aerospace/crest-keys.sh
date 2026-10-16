#!/usr/bin/env bash
# Send key chords to Crest, the front app after this activates it.
# Usage: crest-keys.sh <chord>...    chord: [cmd-|ctrl-|opt-|shift-...]<key>
#        key: a digit or a lowercase letter. e.g. crest-keys.sh ctrl-3 cmd-1
#
# The keys are posted as CGEvents with their flags set outright. System Events'
# `keystroke` adds whatever modifiers are physically held, and the AeroSpace
# binding fires with alt still down, so Cmd-N arrived as Cmd-Opt-N and opened
# a blank window. Waiting for alt to come up fixed that but made the Email
# toggle lag until the key was released. Explicit flags need no wait.
#
# Posting keys needs Accessibility. From an AeroSpace binding macOS charges
# AeroSpace for it; from a terminal the events are silently dropped.

[ $# -gt 0 ] || { echo "Usage: crest-keys.sh <chord>..." >&2; exit 1; }

osascript -l JavaScript - "$@" <<'JXA'
ObjC.import("AppKit");
ObjC.import("CoreGraphics");

// ANSI virtual key codes (HIToolbox Events.h).
const CODES = {
  "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
  a: 0, b: 11, c: 8, d: 2, e: 14, f: 3, g: 5, h: 4, i: 34, j: 38, k: 40, l: 37, m: 46,
  n: 45, o: 31, p: 35, q: 12, r: 15, s: 1, t: 17, u: 32, v: 9, w: 13, x: 7, y: 16, z: 6,
};
const FLAGS = { shift: 0x20000, ctrl: 0x40000, opt: 0x80000, cmd: 0x100000 };

function post(chord) {
  const parts = chord.split("-");
  const code = CODES[parts.pop()];
  if (code === undefined) throw new Error("unknown key in " + chord);
  const flags = parts.reduce((f, m) => f | FLAGS[m], 0);
  for (const down of [true, false]) {
    const e = $.CGEventCreateKeyboardEvent($(), code, down);
    $.CGEventSetFlags(e, flags);
    $.CGEventPost($.kCGHIDEventTap, e);
  }
}

function run(argv) {
  Application("Crest").activate();
  argv.forEach((chord, i) => {
    // A Space switch animates; the next key, sent mid-swipe, can land in
    // the Space being left.
    if (i > 0 && argv[i - 1].startsWith("ctrl-")) delay(0.15);
    post(chord);
  });
}
JXA
