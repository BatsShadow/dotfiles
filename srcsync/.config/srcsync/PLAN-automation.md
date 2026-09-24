# srcsync automation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the srcsync engine without anyone typing a command: after each Claude turn, on a 3-minute timer, around sleep, and when the sessionizer opens a worktree. Show conflicts in tmux and resolve them from a picker.

**Architecture:** Every trigger calls one entry point, `srcsync.sh auto <event> [path]`. While the config says `auto off` (the default), `auto` only appends what it would have done to `auto.log`. That keeps every hook a dummy until the user flips one line. Scoped `publish <path>` and `apply <path>` keep a per-turn hook to one worktree. `resolve` and `pick` settle conflicts.

**Tech Stack:** bash 3.2 (`/bin/bash`), git, jq 1.6, launchd (per-user LaunchAgent), fzf in a tmux popup, tmux-powerline, sleepwatcher (not installed; the switch-on checklist installs it).

**Spec:** `srcsync/.config/srcsync/DESIGN.md`, sections "Triggers", "When not to apply", "Failure". Builds on the engine from `PLAN.md`, whose code is in `srcsync/.config/srcsync/lib/` and whose test harness is `srcsync/.config/srcsync/tests/lib.sh`. Survey of the hook, launchd, sessionizer and status bar code this plugs into: `.superpowers/sdd/research-automation.md`.

## Global constraints

- Everything from `PLAN.md`'s global constraints holds: bash 3.2 rules, jq 1.6, real git in tests, company code never to the hub, unslop writing rules in comments and commit messages, comments as short as their neighbours.
- Nothing touches the live machine while this branch is unmerged. Tests use fake `$HOME`s, temp dirs, a throwaway tmux socket (`tmux -L name-$$`) and override variables. Never run `launchctl`, `stow`, `install.zsh` or `install-hooks.sh` against the real `$HOME`.
- Every hook and agent entry point exits 0 and never blocks its caller for more than a second, except `auto sleep`, which the machine waits on by design.
- `auto` is off unless the config has the line `auto on`. Off means: append one line to `$SRCSYNC_STATE/auto.log` and do nothing else. No lock, no hub clone, no `last.json`.
- Commit after each task. Commit messages: imperative, sentence case, no prefix, ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Run from the repo root: `/Users/scott/dotfiles-srcsync`. Test files are standalone executables printing `N passed, M failed` via `done_testing`.

## Files

| Path | What it does |
| --- | --- |
| `srcsync/.config/srcsync/srcsync.sh` | gains `publish [path]`, `apply [path]`, `auto`, `conflicts`, `resolve`, `pick` |
| `srcsync/.config/srcsync/lib/common.sh` | gains `auto` config keyword and `resolve_path` |
| `srcsync/.config/srcsync/lib/publish.sh`, `lib/apply.sh` | gain scoping |
| `srcsync/.config/srcsync/lib/auto.sh` | the `auto` entry point |
| `srcsync/.config/srcsync/lib/resolve.sh` | `conflicts`, `resolve`, `pick` |
| `srcsync/.config/srcsync/open.sh` | sessionizer's bounded apply |
| `srcsync/.config/srcsync/launchd/com.batsshadow.srcsync.plist.in`, `launchd/install.sh` | the 3-minute agent |
| `srcsync/.sleep`, `srcsync/.wakeup` | stow to `~/.sleep`, `~/.wakeup`, which sleepwatcher runs |
| `claude/.claude/hooks/srcsync-hook.sh` | Stop and SessionEnd hook |
| `claude/.claude/hooks/install-hooks.sh` | registers it |
| `tmux/.config/tmux-powerline/segments/srcsync.sh` | status bar segment |
| `tmux/.config/tmux/sessionizer.sh`, `tmux/.config/tmux/tmux.conf`, `install.zsh` | call sites |

---

### Task 1: Scoped publish and apply

A Stop hook fires after every Claude turn in one worktree. Snapshotting every repo under `~/src` each time is wasteful, and the sessionizer only needs the worktree it is opening.

**Files:**
- Modify: `srcsync/.config/srcsync/lib/common.sh`, `lib/publish.sh`, `lib/apply.sh`, `srcsync.sh`
- Test: `srcsync/.config/srcsync/tests/scoped.test.sh` (new)

**Interfaces:**
- Consumes: `cmd_publish`, `publish_repo`, `cmd_apply`, `apply_one`, `key_of`, `$LAST`, `$CONFLICTS` from the engine.
- Produces, in `lib/common.sh`: `resolve_path path` prints two tab-separated fields, `repo_dir` (the main worktree of the repo holding `path`, physical) and `wt_dir` (the worktree top holding `path`). It fails (status 1, nothing printed) when `path` is not inside a git worktree, or the repo is not one `find_repos` would list (not exactly 1 or 2 levels under `$SRCSYNC_SRC`). Derive `repo_dir` as the parent of `git rev-parse --path-format=absolute --git-common-dir`, and `wt_dir` from `git rev-parse --show-toplevel`, both through `pwd -P`.
- Produces: `cmd_publish [repo_dir]` and `cmd_apply [wt_dir]`. With no argument, behaviour is unchanged. `srcsync.sh publish [path]` and `srcsync.sh apply [path]` call `resolve_path`; on failure they `say "<path>: not a synced repo"` and exit 0.

Behaviour:
- Scoped publish starts from `last.json`'s `.repos`, replaces that one repo's entry with `publish_repo`'s output (or deletes the entry if the output is empty), and otherwise runs the same push, hub-pending and hub-publish steps.
- Scoped apply runs only `apply_one` for the worktree key of `wt_dir`, for each other host that lists it under the repo key of `repo_dir`. No removals. It rewrites `$CONFLICTS` keeping every existing entry whose `.worktree` is a different key, plus the new ones from this run.

- [ ] **Step 1: Write `tests/scoped.test.sh`** with these cases, using `tests/lib.sh` helpers (`machine`, `github_repo`, `on`, `g`, `refs_in`, `home`, `assert_eq`, `done_testing`):
  1. Machine a has `src/app` and `src/lib` (both `github_repo`), b has clones. `on a publish`. Then change a file in each on a, and `on a publish "$(home a)/src/app/sub"` where `sub` is a directory inside app. Assert the hub has a ref under `refs/srcsync/a/src/app/` and none under `refs/srcsync/a/src/lib/`. Assert `jq -c '.repos["src/lib"]'` of a's `last.json` equals what it was before the scoped run.
  2. `on a publish /tmp` prints `/tmp: not a synced repo` into `$WORK/a.log` and exits 0.
  3. `on a publish` (full) so both changes are in the hub. `on b apply "$(home b)/src/app"`. Assert b's app has the change and b's lib does not. `on b apply`. Assert b's lib now has it.
  4. Make a conflict on `src/app` (change it on both, publish both, `on b apply`), check `conflicts.json` has one entry. Then change lib on a, publish, and `on b apply "$(home b)/src/lib"`. Assert `conflicts.json` still has the `src/app` entry.
  5. On a, `git worktree add` a linked worktree at `src/app-wt` on a new branch, change a file there, `on a publish "$(home a)/src/app-wt"`. Assert a's `last.json` has `.repos["src/app"].worktrees["src/app-wt"]`.
- [ ] **Step 2: Run it and see it fail.** `srcsync/.config/srcsync/tests/scoped.test.sh`. Expect failures on every case that passes a path.
- [ ] **Step 3: Implement** `resolve_path`, the optional arguments, and the argument handling in `srcsync.sh`'s dispatch. Update the usage comment at the top of `srcsync.sh`.
- [ ] **Step 4: Run `scoped.test.sh` and the whole suite** (`for t in srcsync/.config/srcsync/tests/*.test.sh; do $t | tail -1; done`). All `0 failed`.
- [ ] **Step 5: Commit** "Scope srcsync publish and apply to one worktree".

---

### Task 2: The `auto` entry point and its off switch

**Files:**
- Create: `srcsync/.config/srcsync/lib/auto.sh`
- Modify: `srcsync/.config/srcsync/lib/common.sh` (config keyword), `srcsync.sh` (dispatch), `srcsync/.config/srcsync/config` (add `auto off` with a one-line comment)
- Test: `srcsync/.config/srcsync/tests/auto.test.sh` (new)

**Interfaces:**
- Produces: `CFG_AUTO` (`on` or `off`, default `off`) from config line `auto on|off`. `AUTO_LOG=$SRCSYNC_STATE/auto.log`.
- Produces: `srcsync.sh auto <event> [path]`, with this mapping:

| event | command it runs |
| --- | --- |
| `timer` | `sync` |
| `stop`, `end` | `publish <path>` |
| `sleep` | `publish` |
| `wake` | `apply` |
| `open` | `apply <path>` |

An unknown or missing event prints usage to stderr and exits 2. Everything else exits 0 whatever happens.

Behaviour:
- Off: append `<UTC timestamp> dry <event> <path or -> would run <command>` to `$AUTO_LOG`, creating `$SRCSYNC_STATE` if needed, and exit. Take no lock, don't clone the hub, don't create `last.json`.
- On: append `<timestamp> <event> <path or ->`, then run the command in-process (the same functions the plain commands use, under the same lock) with its stderr appended to `$AUTO_LOG`. `sleep` waits for a held lock for up to 20 seconds, one-second retries, because it is the last chance before the lid closes. Other events give up at once, as the plain commands do.
- After each run, trim `$AUTO_LOG` to its last 2000 lines.

- [ ] **Step 1: Write `tests/auto.test.sh`**:
  1. Off by default: a has `src/app`, change a file, `on a auto stop "$(home a)/src/app"`. Assert exit 0, `auto.log` has one line matching `dry stop .*/src/app would run publish`, `last.json` does not exist, `refs_in hub` is empty and `$GH/hub.git` has no `main` branch.
  2. On: write `auto on` into a's config. `on a auto stop "$(home a)/src/app"`. Assert a's hub file exists (`git -C "$GH/hub.git" show main:machines/a.json`) and a snapshot ref for `src/app` exists.
  3. b has a clone and `auto on`. `on b auto timer`. Assert b's app has a's change.
  4. `on a auto bogus` exits 2.
  5. With `auto on` and `SRCSYNC_HUB` pointing at a nonexistent path, `on a auto wake` exits 0 and `auto.log` contains `cannot reach the hub`. The `on` helper hardcodes `SRCSYNC_HUB`, so call srcsync directly here with the same env it sets, overriding the hub.
  6. Trim: write 2500 lines into `auto.log`, run `on a auto stop <path>`, assert `wc -l` is 2000.
  7. Lock and sleep: create the lock dir with a live pid (`sleep 30 &`), run `auto sleep` in the background, kill the holder after 2 seconds, wait, and assert `auto.log` shows a publish happened (a's hub file exists). Then with a live holder that never dies, assert `auto sleep` returns within 25 seconds and exits 0.
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement.** Keep the event table in one `case` in `lib/auto.sh`.
- [ ] **Step 4: Run `auto.test.sh` and the whole suite.** All `0 failed`.
- [ ] **Step 5: Commit** "Add srcsync auto, which only logs until switched on".

---

### Task 3: Conflicts, resolve and the picker

DESIGN.md: "a picker shows both states and applies the one chosen. Both stay on the remote as snapshots whichever way it goes."

**Files:**
- Create: `srcsync/.config/srcsync/lib/resolve.sh`
- Modify: `srcsync/.config/srcsync/lib/apply.sh` (fetch theirs on conflict), `srcsync.sh`
- Test: `srcsync/.config/srcsync/tests/resolve.test.sh` (new)

**Interfaces:**
- Consumes: `fetch_theirs`, `apply_worktree`, `record_theirs`, `set_mine`, `claude_busy`, `now_json`, `cmd_publish repo_dir`, `hub_publish`, `resolve_path`, `$CONFLICTS` entries `{repo, worktree, host, mine, theirs}`.
- Produces: `srcsync.sh conflicts` prints one line per conflict: `worktree<TAB>host<TAB>mine_branch@mine_head7<TAB>theirs_branch@theirs_head7`, with `(detached)` for a null branch. Nothing when there are none.
- Produces: `srcsync.sh resolve <path> theirs|mine`, under the lock. Exit 1 with a message when there is no conflict for that worktree, or when `theirs` finds Claude busy there.
  - `theirs`: `fetch_theirs`, `apply_worktree`, verify the tree as `apply_one` does, `record_theirs`, drop the entry from `$CONFLICTS`, then `cmd_publish repo_dir` so the hub hears this machine took it.
  - `mine`: `cmd_publish repo_dir` first so `last.json` holds the worktree as it is now. Then set that entry's `base` to theirs' `{branch, head, tree}` with `set_mine`, drop the conflict, and `hub_publish "$LAST"` (clear `$HUB_PENDING` on success). The other machine's next apply then sees `theirs.base == mine` and takes this state.
- Produces: `srcsync.sh pick`. With no conflicts, print `no conflicts` and wait for one keypress (the popup would otherwise flash). Otherwise run fzf over `conflicts` output with `--delimiter='\t' --with-nth=1,2,3,4 --expect=ctrl-k`, header `enter: take theirs   ctrl-k: keep mine`, and a preview of `git -C <wt> diff --stat <mine.tree> <theirs.tree>` (fall back to `their snapshot is not here yet`). Run `resolve` on the choice, show its output, and wait for a keypress.
- Change in `apply_one`: when the decision is `conflict`, call `fetch_theirs` best-effort (ignore failure) so the picker's preview has their tree.

- [ ] **Step 1: Write `tests/resolve.test.sh`**:
  1. Make a conflict on `src/app` (a and b each change a different file, both publish, `on b apply`). `on b conflicts` prints one line starting `src/app<TAB>a<TAB>main@`.
  2. `on b resolve "$(home b)/src/app" theirs`: b's working tree now matches a's (`changes` equal), `conflicts` prints nothing, and a following `on b apply` reports no new conflict (`conflicts.json` is `[]`).
  3. Fresh pair, fresh conflict. `on b resolve "$(home b)/src/app" mine`. Then `on a apply`. Assert a now has b's change and lost its own uncommitted edit only in the working tree. a's own snapshot ref `refs/srcsync/a/src/app/tree` still holds the edit in the hub (`git -C "$GH/hub.git" show refs/srcsync/a/src/app/tree:<file>`). a's `conflicts.json` is `[]`.
  4. `resolve` on a worktree with no conflict exits 1 and says `no conflict`.
  5. Busy: conflict, then `session b busy src/app $$`, `resolve ... theirs` exits 1 and says `Claude is working there`.
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement** `lib/resolve.sh` and the `apply_one` change. `pick` is interactive and untested beyond `bash -n`. Keep its logic to glue around `conflicts` and `resolve`.
- [ ] **Step 4: Run `resolve.test.sh` and the whole suite.** All `0 failed`.
- [ ] **Step 5: Commit** "Resolve srcsync conflicts from a picker".

---

### Task 4: Claude Code hooks

**Files:**
- Create: `claude/.claude/hooks/srcsync-hook.sh` (executable)
- Modify: `claude/.claude/hooks/install-hooks.sh`, `claude/.claude/hooks/tests/install-hooks.test.sh`
- Test: `claude/.claude/hooks/tests/srcsync-hook.test.sh` (new, same harness shape as `install-hooks.test.sh`)

**Interfaces:**
- `srcsync-hook.sh` reads the hook payload JSON on stdin. `hook_event_name` `Stop` maps to event `stop`, `SessionEnd` to `end`, anything else exits 0 doing nothing. `cwd` from the payload is the path. `SRCSYNC_BIN` (default `$HOME/.config/srcsync/srcsync.sh`) is run as `/bin/bash "$SRCSYNC_BIN" auto <event> "<cwd>"`, detached (stdin from /dev/null, output discarded, backgrounded in a subshell so the hook returns at once). A missing `SRCSYNC_BIN`, missing `jq`, or bad JSON exits 0 silently.
- `install-hooks.sh`: `SRCSYNC="${CC_SRCSYNC_HOOK_CMD:-~/.claude/hooks/srcsync-hook.sh}"`, added with `ensure("Stop"; $srcsync; "") | ensure("SessionEnd"; $srcsync; "")`, beside the existing `claude-waiting.sh` registrations. Extend the header comment by one sentence at most.

- [ ] **Step 1: Write `srcsync-hook.test.sh`**, with `SRCSYNC_BIN` pointing at a fake script that appends `$*` to a file, then `sleep 5`:
  1. A Stop payload `{"hook_event_name":"Stop","cwd":"/x/y","session_id":"s"}` makes the fake record `<fake path> auto stop /x/y`. Poll for the file for up to 2 seconds rather than sleeping a fixed time.
  2. The hook returns in under 1 second despite the fake's `sleep 5` (time it with `date +%s` before and after, assert the difference is 0 or 1).
  3. SessionEnd records `auto end`. UserPromptSubmit records nothing.
  4. Exit 0 with `SRCSYNC_BIN` pointing at nothing, and with the payload `not json`.
- [ ] **Step 2: Extend `install-hooks.test.sh`:** a fresh install registers the srcsync command once under Stop and once under SessionEnd, a second run adds nothing, and the existing `claude-waiting.sh` counts are unchanged.
- [ ] **Step 3: Run both and see the new cases fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run `claude/.claude/hooks/tests/*.test.sh` and `claude/.claude/hooks/tests/run.sh`.** All `0 failed`.
- [ ] **Step 6: Commit** "Publish a worktree through srcsync after each Claude turn".

---

### Task 5: The launchd agent

**Files:**
- Create: `srcsync/.config/srcsync/launchd/com.batsshadow.srcsync.plist.in`, `srcsync/.config/srcsync/launchd/install.sh` (executable)
- Modify: `install.zsh` (one line after the `claude-waiting-backfill.sh` step: `~/.config/srcsync/launchd/install.sh`)
- Test: `srcsync/.config/srcsync/tests/launchd.test.sh` (new)

**Interfaces:**
- The template: Label `com.batsshadow.srcsync`; ProgramArguments `/bin/bash`, `@HOME@/.config/srcsync/srcsync.sh`, `auto`, `timer`; StartInterval `180`; RunAtLoad `true`; ProcessType `Background`; LowPriorityIO `true`; StandardOutPath and StandardErrorPath `@HOME@/Library/Logs/srcsync.log`; EnvironmentVariables PATH `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`. A per-user LaunchAgent, not a daemon like kanata's, because it needs the user's ssh keys and no root.
- `install.sh`: renders the template with `@HOME@` replaced by `$HOME` into `${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/com.batsshadow.srcsync.plist`, checks it with `plutil -lint`, and when the rendered file differs from what is there (or nothing is there) runs `$LAUNCHCTL bootout gui/$(id -u)/com.batsshadow.srcsync` (ignoring failure) then `$LAUNCHCTL bootstrap gui/$(id -u) <plist>`. `LAUNCHCTL` defaults to `launchctl`. Unchanged means no launchctl calls. Header comment: why a LaunchAgent, why `/bin/bash`, why re-bootstrap only on change.

- [ ] **Step 1: Write `launchd.test.sh`** with `LAUNCH_AGENTS_DIR` a temp dir and `LAUNCHCTL` a fake script appending its arguments to a file:
  1. After one run the plist exists, `plutil -lint` passes, it contains no `@HOME@`, and `plutil -extract StartInterval raw` gives `180`, `ProgramArguments.0` gives `/bin/bash`, `ProgramArguments.3` gives `timer`.
  2. The fake saw `bootout gui/<uid>/com.batsshadow.srcsync` then `bootstrap gui/<uid> <path>`.
  3. A second run makes no new launchctl calls.
  4. Changing the template (copy it to a temp package dir first; let `install.sh` find the template relative to itself) makes the next run bootstrap again.
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement** the template, `install.sh` and the `install.zsh` line.
- [ ] **Step 4: Run `launchd.test.sh`.** `0 failed`.
- [ ] **Step 5: Commit** "Run srcsync every three minutes from a LaunchAgent".

---

### Task 6: Sleep, wake and the sessionizer

**Files:**
- Create: `srcsync/.sleep`, `srcsync/.wakeup` (executable; stow puts them at `~/.sleep` and `~/.wakeup`, which sleepwatcher's brew service runs)
- Create: `srcsync/.config/srcsync/open.sh` (executable)
- Modify: `tmux/.config/tmux/sessionizer.sh`
- Test: `srcsync/.config/srcsync/tests/triggers.test.sh` (new)

**Interfaces:**
- `.sleep` runs `/bin/bash "$HOME/.config/srcsync/srcsync.sh" auto sleep` in the foreground, since sleepwatcher waits for it. `.wakeup` runs `auto wake`. Both exit 0 if the script is missing. Both honour `SRCSYNC_BIN` for tests.
- `open.sh <dir>`: runs `auto open <dir>` with a cap of `${SRCSYNC_OPEN_TIMEOUT:-10}` seconds. It starts the command in the background, starts a watchdog that kills it after the cap, waits for the command, then kills the watchdog. Always exits 0. Honours `SRCSYNC_BIN`.
- `sessionizer.sh`: just before each of the two blocks that create the `vi`/`cli`/`claude` windows (the `[new]` path and the `needs_windows` path), run `[[ -x ~/.config/srcsync/open.sh ]] && ~/.config/srcsync/open.sh "<that block's dir>"`. That puts the other machine's work, and later its transcripts, in place before `claude-continue.sh` starts. Add one short comment.

- [ ] **Step 1: Write `triggers.test.sh`** with a fake `SRCSYNC_BIN` that appends its arguments to a file:
  1. `HOME=<tmp> SRCSYNC_BIN=<fake> srcsync/.sleep` records `auto sleep`. `.wakeup` records `auto wake`.
  2. `.sleep` exits 0 when `SRCSYNC_BIN` points at nothing.
  3. `open.sh /some/dir` records `auto open /some/dir`.
  4. With a fake that sleeps 30 and `SRCSYNC_OPEN_TIMEOUT=1`, `open.sh` returns within 3 seconds and exits 0, and no fake process is left running (`pgrep -f <fake path>` finds nothing after a short poll).
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement,** then `bash -n tmux/.config/tmux/sessionizer.sh`.
- [ ] **Step 4: Run `triggers.test.sh` and `tmux/.config/tmux/tests/*.test.sh`.** All `0 failed`.
- [ ] **Step 5: Commit** "Sync around sleep and when the sessionizer opens a worktree".

---

### Task 7: Status bar and picker key

DESIGN.md: "The status bar shows the last successful sync's age once it passes 15 minutes", and conflicts get a mark.

**Files:**
- Create: `tmux/.config/tmux-powerline/segments/srcsync.sh`
- Modify: the tmux-powerline theme that lists `claude_sessions` (find it under `tmux/.config/tmux-powerline/`), `tmux/.config/tmux/tmux.conf`
- Test: `tmux/.config/tmux-powerline/segments/srcsync.test.sh` (new) or a case file beside the claude segment tests, following that harness

**Interfaces:**
- The segment defines `run_segment` as the other tmux-powerline segments do. It reads `${SRCSYNC_STATE:-$HOME/.local/state/srcsync}` and `${SRCSYNC_CONFIG:-$HOME/.config/srcsync/config}` directly (no sourcing srcsync's libs, since this runs every second) and prints:
  - nothing, when the config lacks `auto on`;
  - `⇄ !N` when `conflicts.json` holds N > 0 entries;
  - otherwise `⇄ <age>` when `last-success` is older than 15 minutes or missing, with age as `Nm` under an hour, else `Nh`, and `never` when missing;
  - otherwise nothing.
  It exits 0 in every case and never prints an error.
- The theme gains the segment immediately after `claude_sessions`, in the same side list.
- `tmux.conf` gains, beside the other popup bindings: `bind-key g display-popup -E -w 70% -h 60% "~/.config/srcsync/srcsync.sh pick"` with a one-line comment.

- [ ] **Step 1: Write the segment test,** pointing `SRCSYNC_STATE` and `SRCSYNC_CONFIG` at temp files: `auto off` prints nothing even with conflicts; `auto on` with 2 conflicts prints `⇄ !2`; no conflicts and a `last-success` 20 minutes old prints `⇄ 20m`; 3 hours old prints `⇄ 3h`; 5 minutes old prints nothing; missing prints `⇄ never`. Write `last-success` timestamps as `date -u -v-20M +%Y-%m-%dT%H:%M:%SZ`.
- [ ] **Step 2: Run it and see it fail.**
- [ ] **Step 3: Implement** the segment, the theme entry and the binding. Check the config with `tmux -L srcsync-check-$$ -f tmux/.config/tmux/tmux.conf start-server \; kill-server` exiting 0 (a throwaway server; plugin paths may warn).
- [ ] **Step 4: Run the segment test and the claude segment tests.** All `0 failed`.
- [ ] **Step 5: Commit** "Show srcsync conflicts and a stale sync in the status bar".

---

### Task 8: Two machines end to end, and DESIGN.md

**Files:**
- Test: `srcsync/.config/srcsync/tests/flow.test.sh` (new)
- Modify: `srcsync/.config/srcsync/DESIGN.md`

- [ ] **Step 1: Write `flow.test.sh`,** driving only the trigger entry points, the way the real machines will. Two machines with `auto on`, a GitHub repo cloned on both, and a no-remote repo on a only:
  1. On a: edit, then feed `srcsync-hook.sh` a Stop payload for a's worktree with `SRCSYNC_BIN` set to the real `srcsync.sh` and `HOME`, `SRCSYNC_HOST`, `SRCSYNC_HUB` exported as `tests/lib.sh`'s `on` does. Poll until a's hub file shows the change (up to 10 seconds).
  2. On b: run `.wakeup` (with `SRCSYNC_BIN` set). b has a's edit, and the no-remote repo now exists on b.
  3. On b: edit, run `open.sh` on the worktree (nothing to take), then Stop-hook it. On a: run the launchd command line by hand (`/bin/bash <srcsync.sh> auto timer`). a has b's edit.
  4. Both edit the same worktree, both Stop-hook, a runs `auto timer`: a gets a conflict, `conflicts` lists it, and the status segment with a's state prints `⇄ !1`. `resolve ... mine` on a, then `auto timer` on b: b takes a's state, and both `conflicts.json` files are `[]`.
  5. With `auto off` on b, `.wakeup` changes nothing on b and `auto.log` gains a `dry wake` line.
- [ ] **Step 2: Run it.** Fix what it finds in the code it exercises; add a focused test in the matching test file for anything that fails here and was not already covered.
- [ ] **Step 3: Update DESIGN.md.** In "Triggers", add a short paragraph: every trigger calls `srcsync.sh auto <event>`, which logs and does nothing until the config says `auto on`; the Stop hook publishes only its own worktree, in the background; `open.sh` caps the sessionizer's wait at 10 seconds; sleepwatcher runs `~/.sleep` and `~/.wakeup`, stowed from this package. In "When not to apply", add that `srcsync.sh pick` (prefix `g`) and `srcsync.sh resolve <path> mine|theirs` settle a conflict, and that keeping mine works by recording theirs as the base of mine, so the other machine's next apply takes it. In "Package layout", list the new files.
- [ ] **Step 4: Run every test file in the repo that this branch touched.** All `0 failed`.
- [ ] **Step 5: Commit** "Test srcsync across two machines through its triggers".
