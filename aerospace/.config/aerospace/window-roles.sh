#!/usr/bin/env bash
# Remembered browser windows: one window per role, keyed by AeroSpace window id.
# Sourced by dispatch.sh, tile-mode/app.sh, restore-workspaces.sh, role-claim.sh.
#
# Arc's keys used to work out which window was which on every press, from the
# window title and the active tab's URL. Both follow whatever page is showing,
# so a Work window playing a video looked like the YouTube window, and tile mode
# and restore-workspaces.sh sent it to the wrong place. A window id does not
# change when the page does.
#
# A role is named after the workspace its window lives on in workspace mode
# (Browser, Email, YouTube), so the role also says where restore puts it back.
#
# Finding a role's window, in order:
#   1. The remembered id, if that window still exists and is still this app's.
#   2. Adopt: a window of this app already on the role's workspace that no role
#      has claimed. Arc restores its windows with new ids when it relaunches,
#      and on-window-detected sorts them onto workspaces by title, so adoption
#      is what stops every relaunch from opening a second window per role. It
#      finds nothing in tile mode, where every window sits in Tiles.
#   3. Create: the caller opens a new window with role_create.
#
# File format, one line per role: role<TAB>window-id<TAB>bundle-id. Roles are
# per app, so Arc and Crest can each have an Email window during a trial.
# Bash 3.2 safe and `set -u` safe, since tile-mode/app.sh sources this.

ROLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_FILE="${ROLES_FILE:-$ROLES_DIR/.window-roles}"
ROLE_WAIT_TRIES="${ROLE_WAIT_TRIES:-30}"   # x 0.1s for a created window to appear

# The script that opens a new window for a role, by bundle id. An app with no
# opener has no roles. The opener takes the role name as its only argument.
role_opener() {
  case "$1" in
    company.thebrowser.Browser) echo "$ROLES_DIR/arc-new-window.sh" ;;
  esac
}

_role_windows() {
  aerospace list-windows --all --format '%{window-id}%{tab}%{app-bundle-id}%{tab}%{workspace}' 2>/dev/null
}

_role_has_window() { # bundle
  _role_windows | awk -F'\t' -v b="$1" '$2==b{f=1} END{exit !f}'
}

# role_set <role> <window-id> <bundle>: remember a window for a role. Replaces
# the role's old window, and takes the id away from any role that had it.
role_set() {
  local tmp="$ROLES_FILE.$$"
  {
    [ -f "$ROLES_FILE" ] && awk -F'\t' -v r="$1" -v id="$2" -v b="$3" \
      '!($1==r && $3==b) && $2!=id' "$ROLES_FILE"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  } > "$tmp" && mv "$tmp" "$ROLES_FILE"
}

role_forget() { # role bundle
  [ -f "$ROLES_FILE" ] || return 0
  local tmp="$ROLES_FILE.$$"
  awk -F'\t' -v r="$1" -v b="$2" '!($1==r && $3==b)' "$ROLES_FILE" > "$tmp" && mv "$tmp" "$ROLES_FILE"
}

# role_of <window-id> <bundle>: the role remembered for a window, if any.
role_of() {
  awk -F'\t' -v id="$1" -v b="$2" '$2==id && $3==b {print $1; exit}' "$ROLES_FILE" 2>/dev/null
}

# role_window <role> <bundle>: the remembered window, if it still exists and is
# still this app's. A dead entry is dropped so adoption can take over.
role_window() {
  local id
  id="$(awk -F'\t' -v r="$1" -v b="$2" '$1==r && $3==b {print $2; exit}' "$ROLES_FILE" 2>/dev/null)"
  [ -n "$id" ] || return 1
  if _role_windows | awk -F'\t' -v id="$id" -v b="$2" '$1==id && $2==b {f=1} END{exit !f}'; then
    echo "$id"
    return 0
  fi
  role_forget "$1" "$2"
  return 1
}

# role_adopt <role> <bundle>: claim an unclaimed window of this app that is
# already on the role's workspace.
role_adopt() {
  local id
  id="$(_role_windows | awk -F'\t' -v b="$2" -v ws="$1" -v f="$ROLES_FILE" '
    BEGIN { while ((getline l < f) > 0) { split(l, a, "\t"); claimed[a[2]] = 1 } }
    $2==b && $3==ws && !claimed[$1] { print $1; exit }')"
  [ -n "$id" ] || return 1
  role_set "$1" "$id" "$2"
  echo "$id"
}

role_find() { role_window "$1" "$2" || role_adopt "$1" "$2"; }

# role_launch <bundle>: start the app if it has no windows, and wait for the
# windows it restores to land. Returns 1 when the app was already running, so
# the caller knows a second role_find would see nothing new.
role_launch() {
  _role_has_window "$1" && return 1
  open -b "$1" || return 1
  local n=0
  until _role_has_window "$1"; do
    [ "$n" -ge 50 ] && return 1
    sleep 0.2
    n=$((n + 1))
  done
  # Restored windows arrive one at a time and on-window-detected routes each
  # as it comes. Give the rest time to reach their workspaces before adopting.
  sleep 1
  return 0
}

# role_create <role> <bundle>: open a new window with the app's opener, wait
# for it, and remember it. Prints the new id; fails if none appeared.
role_create() {
  local role="$1" bundle="$2" opener before id n=0
  opener="$(role_opener "$bundle")"
  [ -n "$opener" ] || return 1
  before="$(_role_windows | awk -F'\t' -v b="$bundle" '$2==b{print $1}' | paste -sd, -)"
  "$opener" "$role" >/dev/null || return 1
  while [ "$n" -lt "$ROLE_WAIT_TRIES" ]; do
    id="$(_role_windows | awk -F'\t' -v b="$bundle" -v before="$before" '
      BEGIN { n = split(before, a, ","); for (i = 1; i <= n; i++) old[a[i]] = 1 }
      $2==b && !old[$1] { print $1; exit }')"
    if [ -n "$id" ]; then
      role_set "$role" "$id" "$bundle"
      echo "$id"
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}
