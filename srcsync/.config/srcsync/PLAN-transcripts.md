# srcsync transcripts implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry each worktree's Claude conversation with its code, so `claude -c` on the other machine resumes where this one stopped, and restart an idle Claude that is holding the old conversation.

**Architecture:** A second ref per worktree, `refs/srcsync/<host>/<path>/claude`, holds `~/.claude/projects/<slug>/` (top-level `*.jsonl` and `memory/`) as a commit in the repo's own object store, so it follows the code to the same remote. Its tree joins `branch`, `head` and `tree` in what "touched" means. After an apply lays down new transcripts, an idle Claude in that worktree is respawned in its tmux pane through `claude-continue.sh`. All of it is behind the config line `transcripts on`, off by default, because DESIGN.md checks 1 and 2 have not been run.

**Tech Stack:** bash 3.2, git, jq 1.6, tmux.

**Spec:** `srcsync/.config/srcsync/DESIGN.md`, "Claude transcripts", "Applying a worktree" step 6, "The idle Claude holding an old conversation". Builds on `PLAN.md` and `PLAN-automation.md`. Facts about session files and panes: `.superpowers/sdd/research-automation.md`.

## Global constraints

- Everything from `PLAN.md` and `PLAN-automation.md` holds, including: no live-machine side effects from tests, fake `$HOME`s, a throwaway tmux socket.
- `transcripts off` (the default) leaves every existing behaviour and state file byte-for-byte as it is now. The `claude` field is absent, not null, when off.
- Never delete a transcript file. Applying writes and overwrites files; it removes none.
- Slug: the physical worktree path with every character outside `[A-Za-z0-9]` replaced by `-` (`/Users/scott/src/x` becomes `-Users-scott-src-x`), the rule `claude-continue.sh` uses. Projects dir: `${CC_PROJECTS_DIR:-$HOME/.claude/projects}`.
- Measured facts this plan rests on (Claude Code 2.1.280):
  - `~/.claude/sessions/<pid>.json` has `status` (`idle`, `busy`, `waiting`), `cwd`, `name`, and `tmux` as `<session>:@<window>.%<pane>`. The field is empty for a session outside tmux.
  - An idle Claude pane ends with its input box: a line of `─` characters, the input line starting `❯`, another line of `─`, then a status line. An empty input line is `❯` followed only by whitespace (possibly U+00A0). Text after `❯`, or more than one line between the two rules, means something is typed.

---

### Task 1: The claude tree in publish

**Files:**
- Create: `srcsync/.config/srcsync/lib/transcripts.sh`
- Modify: `lib/common.sh` (config keyword `transcripts on|off`, `CFG_TRANSCRIPTS`, `CC_PROJECTS_DIR`), `lib/publish.sh`, `lib/apply.sh` (`now_json` gains the field), `lib/decide.jq` (`st` gains `claude`), `srcsync.sh` (source the new lib), `config` (add `transcripts off` with a short comment naming checks 1 and 2)
- Test: `srcsync/.config/srcsync/tests/transcripts.test.sh` (new); `tests/decide.test.sh` gains rows

**Interfaces:**
- `slug_of dir` prints the slug. `claude_dir wt` prints `$CC_PROJECTS_DIR/<slug>`.
- `claude_tree repo_dir wt` prints the tree of `claude_dir wt`'s top-level `*.jsonl` files and its `memory/` directory, written into `repo_dir`'s object store, or prints nothing when the directory is missing or has none of those. It uses a persistent index at `$SRCSYNC_STATE/claude-index/<slug>` so unchanged files are not rehashed, with `git --git-dir=<repo's common git dir> --work-tree=<claude_dir> add -f -A -- '*.jsonl' memory` against that index, then `write-tree`. Top-level only: `':(glob)*.jsonl'`, so subdirectories other than `memory/` are left out.
- `now_json wt` and the state published per worktree gain `claude: <tree sha or null>` when `CFG_TRANSCRIPTS=on`, and no key when off.
- When the tree differs from the previous publish's, publish makes a commit of it (`commit-tree` with no parent, message `srcsync transcripts of <key>`), points `refs/srcsync/<host>/<key>/claude` at it and marks the repo pending. `push_size` adds the claude commit's objects to the size it reports.
- `decide.jq`'s `st` becomes `{branch, head, tree, claude}`. With transcripts off, `claude` is absent on every side and compares equal, so every existing row keeps its answer.

- [ ] **Step 1: Write the tests.**
  - `decide.test.sh` gains two rows: same code but theirs has a newer claude tree built on mine is `apply`; now's claude tree differs from mine's and theirs moved is `conflict`. Build them with the existing `st` and `entry` helpers extended to take an optional claude value.
  - `transcripts.test.sh`, two machines with `transcripts on`, one GitHub repo `src/app` cloned on both, each machine's projects dir under its fake `$HOME`:
    1. Write `<projects>/<slug of a's app>/s1.jsonl` and `memory/MEMORY.md` on a, plus `other/sub.jsonl` (must be left out). `on a publish`. a's `last.json` worktree entry has a non-null `claude`. The hub holds `refs/srcsync/a/src/app/claude` whose tree lists `s1.jsonl` and `memory/MEMORY.md` and not `other`.
    2. A second `on a publish` with nothing changed leaves the hub's `main` sha and the refs unchanged.
    3. Appending a line to `s1.jsonl` on a is a change: the next publish moves the claude ref and `changed_at`.
    4. With `transcripts off` on a fresh machine c, the worktree entry has no `claude` key (`jq 'has("claude")'` is `false`).
- [ ] **Step 2: Run them and see the new cases fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole srcsync suite.** All `0 failed`. The existing files prove "off changes nothing".
- [ ] **Step 5: Commit** "Publish each worktree's Claude transcripts beside its code".

---

### Task 2: Transcripts in apply

**Files:**
- Modify: `lib/transcripts.sh`, `lib/apply.sh` (`fetch_theirs`, `apply_worktree` or `apply_one`, `record_theirs`)
- Test: `tests/transcripts.test.sh` gains cases

**Interfaces:**
- `fetch_theirs` also fetches `refs/srcsync/<host>/<key>/claude` when theirs has a non-null `claude`, and verifies its tree equals `theirs.claude`. A mismatch fails the fetch the way a snapshot mismatch does: retry next run.
- `lay_claude repo_dir wt tree` writes every file in `tree` into `claude_dir wt`, creating it, through a temp index (`read-tree` then `checkout-index -a -f --prefix=<claude_dir>/`). It deletes nothing. It is called after `lay_tree` in the apply path when theirs has a claude tree.
- `record_theirs` copies `claude` into this machine's entry, and re-points this machine's own claude ref, as it already does for the snapshot.
- A worktree whose code is identical but whose claude tree moved on is applied like any other change. Only the claude part has anything to lay.

- [ ] **Step 1: Add cases to `transcripts.test.sh`:**
  1. After a publishes (from Task 1's setup), `on b apply`. b's projects dir for its app (same path, since the fake homes differ only by machine name, so compute b's slug from b's physical path) has `s1.jsonl` and `memory/MEMORY.md` with a's content, and not `other/sub.jsonl`.
  2. b has its own `s0.jsonl` there before the apply: it survives.
  3. a appends to `s1.jsonl` with no code change and publishes, then `on b apply`: b's `s1.jsonl` has the new line, and `took a's state` appears in b's log.
  4. Both append different lines to `s1.jsonl` and both publish, then `on b apply`: a conflict on `src/app`, and b's `s1.jsonl` keeps b's line.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole srcsync suite.** All `0 failed`.
- [ ] **Step 5: Commit** "Bring the other machine's Claude transcripts with its work".

---

### Task 3: Restart the idle Claude

**Files:**
- Create: `srcsync/.config/srcsync/lib/restart.sh`
- Modify: `lib/apply.sh` (call it after an apply that changed `claude`), `srcsync.sh` (source it; `auto` runs pending restarts on every event while `auto on`)
- Test: `srcsync/.config/srcsync/tests/restart.test.sh` (new)

**Interfaces:**
- `SRCSYNC_TMUX` (default `tmux`) is the tmux command, split on spaces, so tests pass `tmux -L <socket>`. `CLAUDE_CONTINUE` (default `$HOME/.config/tmux/claude-continue.sh`).
- `idle_panes wt` prints `pane_id<TAB>name` for each session file in `$CC_SESSIONS_DIR` whose `status` is `idle`, whose `cwd` is `wt` or under it, whose `pid` is alive (`kill -0`), and whose `tmux` field is non-empty (pane id is the text after the last `.`).
- `input_empty pane` captures the pane (`capture-pane -p -t pane`), takes the lines between the last two lines made of `─`, and succeeds only when that is exactly one line matching `❯` plus optional whitespace (treat U+00A0 as whitespace). Anything else, including no box found, fails.
- `restart_idle wt`: for each idle pane, if `input_empty` succeeds, `respawn-pane -k -t <pane> -c <wt> "<CLAUDE_CONTINUE> -n '<name>'; exec zsh -l"` (omit `-n` when the name is empty) and `say "<key>: restarted the idle Claude in <pane>"`. Otherwise append `<wt>` to `$SRCSYNC_STATE/restart-pending` (once) and `say "<key>: Claude has typed input; restart when it is empty"`.
- `restart_pending`: retries each line of `restart-pending`, dropping the ones that restart or whose worktree has no idle pane left.
- Called from the apply path only when the applied entry's `claude` differs from this machine's previous `claude` for that worktree, and only with `CFG_TRANSCRIPTS=on`.

- [ ] **Step 1: Write `restart.test.sh`** with a throwaway server `tmux -L srcsync-restart-$$` (kill it in the EXIT trap), a fake `CLAUDE_CONTINUE` script that writes its arguments to a marker file then sleeps, and panes whose content is controlled with `printf` from a script (e.g. a pane running `sh -c 'printf "%s\n" "────" "❯ " "────" "status"; sleep 1000'`):
  1. `input_empty` on a pane showing an empty box succeeds; on `❯ hello` fails; on a two-line input fails; on a pane with no box fails; with a trailing U+00A0 after `❯` succeeds.
  2. A session file (use the `session` helper then add `tmux` and `name` with jq) for an idle Claude in b's app whose `pid` is the pane's process (`#{pane_pid}`) and whose pane shows an empty box. Make a change to a's transcript, publish, `on b apply` with `SRCSYNC_TMUX` and `CLAUDE_CONTINUE` exported. The marker file appears (poll up to 3 seconds) holding `-n <name>`, and b's log says `restarted the idle Claude`.
  3. Same with `❯ half typed`: no marker, `restart-pending` lists the worktree. Then change the pane to an empty box (respawn it with the empty-box script) and run `on b auto timer` with `auto on`: the marker appears and `restart-pending` is empty.
  4. A busy session in that worktree blocks the apply itself (already covered by the engine; assert no marker).
  5. An apply that changes only code, not `claude`, restarts nothing.
- [ ] **Step 2: Run and see it fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `restart.test.sh` and the whole suite.** All `0 failed`.
- [ ] **Step 5: Commit** "Restart an idle Claude after its transcript changes underneath it".

---

### Task 4: DESIGN.md and the two unrun checks

**Files:**
- Modify: `srcsync/.config/srcsync/DESIGN.md`

- [ ] **Step 1: Update DESIGN.md.**
  - "Claude transcripts": add that the tree covers the top-level `*.jsonl` and `memory/`, is built through a persistent index per slug, and that the state file carries it as `claude`, which counts toward "touched". Add that applying never deletes a transcript.
  - "The idle Claude holding an old conversation": replace "Optional refinement" with what was built: the input-line check (the measured box shape), the pending list, and the retry on every `auto` run.
  - "Check before building": mark check 4 answered, with the box shape and the version it was measured on. Mark checks 1 and 2 as still open and say `transcripts on` waits on them.
- [ ] **Step 2: Run the whole srcsync suite once more.** All `0 failed`.
- [ ] **Step 3: Commit** "Record how srcsync carries transcripts and restarts Claude".
