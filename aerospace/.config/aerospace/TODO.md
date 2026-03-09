# AeroSpace Mode Switching Overhaul

Goal: Make tile mode the default, enable seamless switching between tile and workspace modes without losing window placement context.

## Phase 1: Mode Switching

- [x] **Build a window-to-workspace resolver script**
  - Parse the `on-window-detected` rules from workspace-mode's `modes.toml` to map app-id (and optionally window title) to the correct workspace
  - Windows that don't match any rule default to the Browser workspace
  - Output: given a window-id, return the workspace it belongs in

- [x] **Write a "restore to workspaces" script for exiting tile mode**
  - List all windows, run each through the resolver, and `move-node-to-workspace` accordingly
  - Switch to whichever workspace ends up with the most windows (or Browser as fallback)

- [x] **Wire up alt-shift-q as a bidirectional toggle**
  - Detect which mode is active (e.g. a `.current-mode` flag file)
  - Tile → Workspace: run restore script, then swap in workspace-mode config
  - Workspace → Tile: swap in tile-mode config, run `split-focus.aerospace.sh` to arrange windows

## Phase 2: Make Tile Mode the Default

- [x] **Set tile mode config as the default `aerospace.toml`**
  - Update `after-startup-command` or the install process so tile mode loads on launch
  - Ensure `split-focus.aerospace.sh` runs on startup to arrange existing windows

- [x] **Auto-tile newly opened windows**
  - In tile mode, `on-window-detected` should move new windows to the Tiles workspace and stack in the accordion side
  - In workspace mode, keep existing named-workspace routing

## Phase 3: Tile Mode Gaps for Built-in Monitor

- [x] **Add per-monitor gap config for tile mode**
  - Currently `split.gaps.toml` gives built-in monitor 0 gaps everywhere
  - On built-in: give the unfocused (right/accordion) side ~40px total so apps are just barely peeking out
  - On XDR: keep current behavior (710px left margin, 40px right)

- [x] **Set sensible left margin on built-in**
  - XDR uses 710px left to center the focused window — that would eat the entire laptop screen
  - Use 0 or minimal left margin on built-in so the focused app gets nearly full width

## Phase 4: Smart App Shortcuts

- [x] **Launch apps if not running when shortcut is pressed**
  - For both modes: if `alt-<key>` targets an app that has no windows, launch it instead of just switching
  - Use `aerospace list-windows --all --json` to check if the app has any windows; if not, `open -a <app-name>`
  - Wrap this in a shared helper script that both modes' keybindings can call

- [x] **Context-sensitive "already focused" behavior for Arc workspaces**
  - If pressing the shortcut and already on the target workspace/window, perform a secondary action instead
  - YouTube (`alt-y`): if already on YouTube workspace, use AppleScript to select the first tab in Arc space 3 (the YouTube space)
  - This lets repeated presses cycle through relevant tabs
  - Generalize: each shortcut can optionally define an "already here" action (e.g. `alt-g` on Email could cycle between Gmail and Messages tabs)

- [x] **Build a shortcut dispatcher script**
  - Single script that handles the logic: check if focused → run "already here" action, check if running → switch to it, else → launch it
  - Takes args like: `dispatch.sh --app-id "company.thebrowser.Browser" --workspace YouTube --launch "Arc" --on-focus "osascript select-tab.scpt 3 1"`
  - Both tile-mode and workspace-mode keybindings call this same script

## Phase 5: Fix Workspace Mode Gap Calculation

- [x] **Exclude floating windows from window count in `auto-config.aerospace.sh`**
  - Currently `aerospace list-windows --monitor $XDR_ID --workspace visible --count` counts all windows including floating
  - Switch to `list-windows --json` and filter out windows where layout == "floating" before counting
  - This ensures floating windows don't bump the gap mode (e.g. 1 tiled + 1 floating should use 1-window gaps, not 2-window gaps)

## Phase 6: Polish

- [x] **Persist active mode across aerospace restarts**
  - Save current mode (tile/workspace) to a dotfile so it survives config reloads and app restarts

- [~] **Handle floating windows in tile mode**
  - [x] Detect floating windows via `list-windows --json` (layout == "floating")
  - [ ] On XDR: arrange floating windows in the left margin area (the 710px gap) — blocked on aerospace lacking move-to-position CLI support; `arrange-floating.sh` is a placeholder
  - [x] On built-in: floating windows left as-is (centered by default)
  - [x] When switching back to workspace mode, move floating windows to their resolved workspace and keep them floating

- [x] **Handle edge cases**
  - Windows on secondary monitor: restore-workspaces.sh moves all windows to their correct workspace regardless of monitor (aerospace handles monitor assignment via workspace-to-monitor rules)

- [x] **Remove left-hand duplicate keybindings**
  - Currently many workspace shortcuts have two bindings (left-hand and right-hand)
  - Keep only the right-hand (Colemak-DH) keys:
    - Terminal: keep `alt-u`, remove `alt-w`
    - Browser: keep `alt-o`, remove `alt-a`
    - Email: keep `alt-l`, remove `alt-g`
    - Slack: keep `alt-h`, remove `alt-s`
    - Discord: keep `alt-semicolon`, remove `alt-d`
  - Also remove the corresponding `alt-shift-` duplicates for move-to-workspace
  - Remap freed left-hand keys to duplicate the gap/layout modes (replacing number row):
    - `alt-a` → same as `alt-1` (accordion/1-window gaps)
    - `alt-s` → same as `alt-2` (tiles/2-window gaps)
    - `alt-d` → same as `alt-3` (tiles/3-window gaps)
    - `alt-g` → same as `alt-0`/`alt-4` (auto-detect)
  - `alt-w` left free for future use (or could duplicate another function)
  - Comment out `alt-t` monkeytype shortcut (keep for reference, no longer bound)
  - Apply to both workspace-mode and tile-mode keybindings

- [x] **Unify alt-shift-q semantics**
  - Both modes define `alt-shift-q` — make it a clean "toggle mode" in both configs
  - macOS notification on mode switch via `toggle-mode.sh`
