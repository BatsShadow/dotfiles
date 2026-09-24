# srcsync: carry work between two machines

Status: built and tested on two fake machines, 2026-09-23. Next: install on
the main machine with `auto off`, read `auto.log`, then turn it on and hand off
to the second one.

## The goal

Two Macs, both used for the same coding work. Walk away from one, sit down at
the other, and find every repo, worktree, branch, uncommitted change and Claude
conversation where you left it. Both machines are equals. Nothing needs to be
typed at either end.

Conflicts are rare in this flow, because work moves one way at a time. The
design handles them with a warning and a choice, not with merge machinery.

## What rules out the obvious answers

- **SSH into one machine from the other.** Both machines run a managed firewall
  that blocks all incoming connections, so neither can be reached.
- **File sync over `~/src`.** Syncing `.git/` while both sides write to it
  corrupts index and lock files, and worktrees keep absolute paths in
  `.git/worktrees/`. Git is the only thing here that already knows how to move
  a repository safely.
- **Company code on a personal account.** A snapshot's parent is HEAD, so
  pushing one to a remote that lacks the repo sends the full history. Company
  repos therefore sync only through company GitHub. See "Where snapshots go".

Every connection is outbound to GitHub, which both firewalls allow.

## Paths must match

Claude files each conversation under the absolute path it ran in:
`~/src/foo` is `~/.claude/projects/-Users-scott-src-foo/`, and
`claude-continue.sh` decides whether to resume by looking there. Both machines
use `/Users/scott`, and every repo and worktree is recreated at the same path,
so transcripts land where `claude -c` looks.

## The state file

The private repo `BatsShadow/srcsync-state` holds one file per machine,
`machines/<host>.json`, rewritten by every publish:

```json
{
  "host": "bluey",
  "published_at": "2026-09-23T14:05:11Z",
  "repos": {
    "src/some-repo": {
      "origin": "git@github.com-batsshadow:BatsShadow/some-repo.git",
      "upstream": null,
      "sync": "hub",
      "worktrees": {
        "src/some-repo": {
          "branch": "feature-x",
          "head": "<sha>",
          "tracking": "origin/feature-x",
          "snapshot": "<sha>",
          "tree": "<sha>",
          "changed_at": "2026-09-23T13:58:40Z",
          "base": { "branch": "feature-x", "head": "<sha>", "tree": "<sha>" }
        }
      },
      "removed": { "src/some-repo-old-wt": "2026-09-22T09:12:00Z" }
    }
  }
}
```

- `branch` is `null` for a detached worktree.
- `snapshot` is the commit holding the uncommitted state. `tree` is its tree,
  kept separately so the touched check below needs no fetch.
- `changed_at` is when this machine last saw the worktree differ from its
  previous publish. It only settles removals, which have no state to compare.
- `base` is the other machine's state this entry was built from. An apply sets
  it, and every publish carries it forward until the next apply replaces it.
  It is `null` for work that started here.
- `snapshot` is `null` for a clean worktree whose HEAD is already on a remote.
  The other machine fetches HEAD from origin instead, and a clone of a large
  project does not get its history pushed to the hub.
- `removed` carries deletions as well as additions. Entries older than 30 days
  are dropped.

`<host>` is fixed on the first run: `SRCSYNC_HOST` if set, else the host in
an existing `last.json`, else `scutil --get LocalHostName`, else
`hostname -s`, written to
`~/.local/state/srcsync/host` and read from there after. `hostname -s` follows
DHCP and Bonjour, and a machine whose name changed took its own old file for
the other machine's and rolled its worktrees back on every run. Apply never
takes a file under this machine's own id. To retire a machine, or an old id,
delete its file from the hub by hand.

The file is pushed to the hub only when a repo entry changed, or when the last
push of it failed. A run with nothing new pushes nothing.

Repos and worktrees are found, not listed by hand: every git repo up to two
levels under `~/src`, and every worktree `git worktree list` reports for each.
A repo the other machine lists but this one lacks, such as a new project, is
cloned.

Each machine also keeps its own last publish in
`~/.local/state/srcsync/last.json`. That copy is what the touched check reads,
so it works offline.

## Snapshots

A snapshot records a worktree's full state as one commit, without touching the
working tree, the index, HEAD or the stash:

```sh
GIT_INDEX_FILE=$tmp_index git add -A        # tracked + untracked, minus ignored
tree=$(GIT_INDEX_FILE=$tmp_index git write-tree)
commit=$(git commit-tree "$tree" -p HEAD -m "$message")
```

Its parent is HEAD, so pushing it also carries any local commits on a branch
that was never pushed. The other machine rebuilds the branch from
`<snapshot>^1`. The message ends in git trailers repeating the worktree path,
branch, tracking ref and host, so a snapshot can be read without the state file.

Staged and unstaged changes flatten into one tree. Carrying the index as a
second parent, as `git stash` does, is possible later if the distinction is
missed.

If the tree matches the last published tree, nothing is pushed. That makes a
run every few minutes nearly free.

Refs are namespaced by host and path, with a fixed leaf so that a worktree
nested inside another's path cannot collide with it as a ref:

```
refs/srcsync/<host>/<path from $HOME>/tree
refs/srcsync/<host>/<path from $HOME>/claude
```

Each machine force-pushes only under its own host, so neither can overwrite the
other.

### Where snapshots go

Each repo's `sync` field names the remote:

- `origin` for company repos. The snapshot goes to that repo's own remote, a
  personal fork on company GitHub, so company code never leaves company GitHub
  and the team never sees the refs.
- `hub` for every other repo worth carrying. The snapshot goes to
  `srcsync-state` itself, which covers upstream-only clones that cannot be
  pushed to and backs up their history as a side effect.
- `skip`, from a `sync <path> skip` config line, for a repo that should not
  sync at all.

A repo not worth carrying is ignored: left out of the state file and never
mentioned in the log, since the timer walks about 90 repos every 3 minutes.
`sync_target` decides, in this order:

1. A repo with any remote URL matching a `company` pattern is company code,
   matched ignoring case, as GitHub owner names do. It goes to `origin`. It is
   skipped and reported when it has no origin or its origin is the team repo,
   and ignored when its origin is not on GitHub (`ordering-html` is on
   Bitbucket).
2. A `sync <path> skip|origin|hub` line wins next. `hub` carries a repo the
   rules below would ignore, such as one with no remote, and `skip` ignores
   one they would carry.
3. A repo already in this machine's `last.json` goes to `hub`, whatever its
   remotes or the rules below now say. That is on purpose: dropped once its
   changes were gone or its origin was removed, the other machine's
   still-dirty entry would read as new work here, and apply would bring back
   what this machine threw away. Only a `skip` line, above, lets it go.
4. A repo whose origin is not on GitHub, or that has no origin, is ignored.
   "On GitHub" means the host is a `forge` line, `github.com` by default,
   ignoring case, or that host followed by `-`, as in the ssh alias
   `github.com-batsshadow`. `github.company.com` and `mygithub.com` are not.
5. A repo with any remote on GitHub whose owner, the path part after the
   host, is an `owner` line goes to `hub`. That remote need not be origin, so
   a clone of upstream with a personal fork added as `mine` counts.
6. So does one with local changes: `git status` output in any worktree,
   untracked files included and ignored ones not, or a local branch with
   commits no remote-tracking ref reaches. A clone of someone else's project
   with work in it is carried like any other.
7. Anything else, a clean clone of someone else's project, is ignored.

Routing reads each URL as configured and as `url.<base>.insteadOf` rewrites
it. A company match or a team match on either counts, and the forge and owner
come from the configured one, which is also what the state file records.

Get the company test wrong and company code lands on a personal account, so a
repo whose remote matches the company pattern must never resolve to `hub`,
even through a per-repo override. The tests pin that.

A company repo whose `origin` is the team repo itself, not a fork, is skipped
and reported until it has a fork. Otherwise the snapshot refs are visible to
anyone listing the team repo's refs. A `team` config pattern names the team
repo. `upngo/slack-hugo` is one today.

The size cap measures what the push would send, not the tree:
`git rev-list --objects --disk-usage <snapshot> --not` every srcsync ref, plus
the remote-tracking refs when the target is origin. A few edits in a big clone
cost kilobytes.

### Claude transcripts

The `claude` ref holds the worktree's `~/.claude/projects/<slug>/` directory
as a commit: the top-level `*.jsonl` transcripts and `memory/`, nothing else.
Subdirectories there are Claude's per-session state, not conversations. It goes
to the same remote as the code, so company conversations stay on company GitHub
too.

`transcripts on` in the config turns this on. The tree is built through an
index kept per slug in the state dir, so a run rehashes only the transcripts
that grew. The worktree's entry carries it as `claude`, beside `tree`, and a
change to it counts toward "touched" like a code change does. With transcripts
off the field is absent, and the state file is byte for byte what it was
before transcripts existed. Applying never deletes a transcript: it writes
files and replaces some, and removes none.

### What srcsync does to a repo's objects

Snapshots and claude trees are written into each repo's own object store.
Every publish writes a whole new blob for each transcript that grew and each
untracked file that changed, and moving a srcsync ref leaves the old one
unreachable, since those refs keep no reflog. `gc --auto` counts loose
objects, not bytes, so it never fires for a few dozen large ones. Measured: an
8.4 MB transcript published, then appended to and published 100 times, took
`.git/objects` from 6 MB to 605 MB in 306 loose objects.

So the launchd timer, and nothing else, repacks a repo at most once a day,
when it holds 10 MB of loose objects or a cruft pack srcsync wrote before:
`git repack -a -d -l --cruft --cruft-expiration=1.day.ago`, then
`git prune --expire=1.day.ago`, logged to `auto.log`. Everything a ref, a
reflog or an index reaches is kept, before-apply refs included. The rest goes
into a cruft pack, where one transcript's versions delta against each other,
and drops out once it is a day old. That covers every unreachable object in
a repo srcsync repacks, not only its own: a dropped stash there can be
recovered for a day, not git's two weeks. On the case above it took 605 MB to 29 MB,
and to 6 MB once the day passed. The Stop hook never repacks.

## Apply: the one rule

For each worktree, compare three states: the other machine's entry (theirs),
this machine's last publish (mine), and the worktree as it is now.
`lib/decide.jq` holds the rule, and `tests/decide.test.sh` is its table.

- Now matches theirs: nothing to do.
- Theirs matches mine's `base`: they have not moved since this machine took
  their state. Keep this one.
- Now differs from mine, and theirs moved: both sides changed it. Conflict.
- Theirs was built on mine, or mine is only what this machine took from them:
  apply. There's no prompt.
- Anything else: conflict.

Comparing `changed_at` cannot tell "they moved on from what I have" from "we
both moved", and in the second case the newer timestamp would overwrite the
other side's work. `base` is what tells them apart.

When neither entry has a `base`, as on first contact or before this machine has
ever published, git decides. If this worktree is clean at a commit that theirs
descends from, apply. If theirs is clean at a commit this one descends from,
keep this one. Otherwise, conflict.

"Touched" means the current branch, HEAD, tracking ref or snapshot tree
differs from what `last.json` recorded, or with transcripts on, the `claude`
tree. In the normal flow the machine you left published last and nothing here
changed since, so every worktree qualifies. Anything this machine had before
the apply is still its own published snapshot, so an apply is recoverable.

Applying a worktree:

1. Clone the repo if it is missing, with `origin` and `upstream` as recorded.
   `merged-branches.sh` needs `upstream` to see squash merges.
2. Fetch the snapshot ref.
3. If the worktree is missing, `git worktree add` it at the same path: on
   `branch` created at `<snapshot>^1`, or detached. Set the tracking ref.
4. If it exists, switch to `branch`, creating it if needed, and move it to
   `<snapshot>^1`.
5. Lay the snapshot's tree into the working tree as uncommitted changes. That
   includes adding untracked files, deleting files the snapshot deleted, and
   leaving the index matching HEAD.
6. Restore the transcripts from the `claude` ref.
7. Record the result as this machine's state, with theirs as its `base`, so it
   counts as untouched. A snapshot is re-pointed under this machine's own ref
   and pushed, so the hub holds it under both hosts.

A removal the other side published at or after this machine's `changed_at`
removes the worktree here too, if it is untouched. A tie goes to the removal;
the touched check is what protects work here. Only linked worktrees are ever
removed, never a main worktree or a repo. Excluded files in it, which exist
nowhere else, are first copied to `~/.local/state/srcsync/removed/<path>/<time>/`,
and the worktree stays if they cannot be. The branch is left for
`worktree-remove.sh` to judge. The reverse holds too: a worktree removed here
but moved on by the other side since is recreated, not removed there.

### What apply will not destroy

The worktree's state is read again after the fetch and the busy check, just
before anything is written. If it moved in between, the apply waits for the
next run.

Before overwriting an existing worktree, apply saves it as a commit under
`refs/srcsync-local/<path>/before-apply`, with a reflog, never pushed.
`git log -g refs/srcsync-local/<path>/before-apply` lists what each apply
replaced.

With `transcripts on`, the transcripts go beside it in
`refs/srcsync-local/<path>/claude-before-apply` whenever the projects dir holds
any, worktree or not, files over the cap included. Laying theirs deletes
nothing and judges each file by content alone. It writes theirs only where the
file here is absent or a byte prefix of theirs, since transcripts only grow.
Any other file that differs is kept, and the log says both machines added to
it. The recorded base and `claude` never decide it: three times they misjudged
which side was newer, and each time lines were lost. A `memory/` file is
edited in place, where a shorter copy can mean a deleted line, so theirs is
laid there only when the file is absent here. New memory files cross; edits
stay on the machine that made them. `resolve theirs` keeps a transcript both
machines added to. An apply that would replace a directory or symlink there,
or a file where theirs has a directory, is refused. With no base, on first
contact with or without a worktree, a file both sides hold with different
content is a conflict.

A file over `max_size` is left out of the claude tree, and the log names the
file once per run. When the rest would still push more than the cap, there is
no tree and `claude` is null. Whether it is null can depend on what the repo
already holds: the size counts only objects no srcsync ref has, and loose
objects weigh more than packed ones. That is harmless, because this host's own
claude ref always holds mine's tree, so mine keeps reading as itself. Publish,
apply's reading of now, and the tree an apply records all use this one
function, so the entry always names what was pushed and raising the cap takes
effect on the next run.

A worktree that exists but cannot be read, because it has no commits yet or an
unreadable file, is skipped, not treated as missing.

Moving a branch that exists here to theirs is refused as a conflict when the
branch holds commits this machine never published, meaning its tip is neither
theirs' head, an ancestor of it, nor this machine's last published head. An
amend or rebase on the other machine still applies.

Publish keeps a worktree's previous entry when its state or snapshot fails,
and the run does not count as a success, so a failure never reads as a
removal.

### When not to apply

- **Claude mid-turn.** `~/.claude/sessions/<pid>.json` records `status` and
  `cwd` for every live session. A worktree whose session is `busy` or `waiting`
  is skipped and retried next run. An idle session is normal and does not block
  an apply. Claude is almost always open, and nearly always idle.
- **Both sides touched it.** Nothing moves. The worktree gets a conflict mark
  in the tmux status bar, the way waiting windows are marked now, and a picker
  shows both states and applies the one chosen. While the conflict is open,
  both stay on the remote as snapshots. Keeping mine leaves theirs there until
  the other machine next publishes. Taking theirs re-points this machine's
  snapshot ref at theirs, so after that the lasting copy of mine is the local
  `refs/srcsync-local/<path>/before-apply`.

`srcsync.sh pick`, on prefix `g`, is that picker: enter takes theirs, ctrl-k
keeps mine. Each side reads as its host, branch@head and tree, since the two
sides usually share a head and differ only in uncommitted work. `srcsync.sh resolve <path> mine|theirs` settles one conflict
without it. Keeping mine publishes this side with theirs recorded as its
`base`, so to the other machine mine now reads as built on theirs, and its
next apply takes it.

### The idle Claude holding an old conversation

An idle Claude keeps the conversation it loaded at start and never rereads the
transcript. After an apply brings in a newer transcript, that pane is talking
to a stale conversation, and typing into it forks the transcript.

So after an apply whose lay wrote at least one file, transcript or memory,
`lib/restart.sh` restarts each idle Claude in that worktree: `respawn-pane -k`
with `claude-continue.sh`, whose `claude -c` resumes the newest transcript, now
the one from the other machine. A lay that kept every file, and an apply of
code alone, restart nothing.

`-k` kills whatever runs in the pane, including anything the idle Claude
started in the background, such as a dev server or a watcher. So a pane
qualifies only through a session file in `~/.claude/sessions/` that is `idle`,
has a live `pid`, a `cwd` that is physically the worktree itself, and a `tmux`
field naming the pane. The pid must also be the pane's `#{pane_pid}` or a descendant of it, on the pane's
own tty (`#{pane_tty}`), in that tty's foreground process group. A session file
outlives a crash, and after a tmux restart its pane id can name another pane. A
Claude on a nested pty, such as nvim's `:terminal`, descends from the pane too,
and respawning would kill its host. Such a pane is neither restarted nor put on
the pending list. A Claude in a subdirectory is left alone: its transcripts sit
under that directory's slug, which srcsync does not carry, and a restart in the
worktree would switch its conversation.

A half-typed prompt would be lost by the restart, so `tmux capture-pane` reads
the input box first, right before the respawn. On Claude Code 2.1.280 an idle
pane ends with a line of `─`, the input line, another line of `─`, then a
status line. The box is empty when exactly one line sits between the last two
rules and it is `❯` followed only by whitespace, which can include a no-break
space. Anything else, a missing box included, reads as typed input. The
worktree then goes on `~/.local/state/srcsync/restart-pending`, and every
`auto` run while `auto on` and `transcripts on` retries each line first,
dropping the ones that restart or whose worktree has no idle Claude left.

## Triggers

Publish:

- Claude's Stop hook, after every turn, for that worktree only. Registered by
  `install-hooks.sh` next to the existing Stop hook.
- SessionEnd.
- sleepwatcher, when the lid closes or the machine sleeps. This covers hand
  edits made in the minutes before walking away.
- A launchd agent every 3 minutes, for all worktrees. launchd because it runs
  whether or not tmux is up, and catches up after wake.

Apply:

- The same launchd agent, after its publish.
- sleepwatcher on wake, so the machine has caught up before you reach a pane.
- The sessionizer, when a worktree is opened.

Every trigger calls `srcsync.sh auto <event> [path]`. Until the config has the
line `auto on`, that appends one line to `~/.local/state/srcsync/auto.log` and
does nothing else, so the triggers can be installed before the sync is
trusted. The Stop hook publishes only the repo it ran in, and in the
background, so the next turn does not wait on the push. `open.sh` stops the
sessionizer waiting after 10 seconds but never kills the run, which finishes
in the background. A run killed between a checkout and the lay after it once
left a worktree at the other machine's head without its uncommitted work. sleepwatcher runs `~/.sleep` and `~/.wakeup`,
which this package stows.

One run at a time, via a `mkdir` lock (macOS has no `flock`). A run that finds
the lock held exits and leaves the work to the next one.

## Failure

- Offline or a failed push: the local ref and `last.json` are kept, and the
  next run retries. A hub push that loses a race with the other machine pulls
  and pushes again at once. The hub clone holds nothing `last.json` cannot
  rebuild, so one left mid-rebase or with stray edits, or whose pull stops on
  a conflict, is reset to the hub's `main` and this machine's file written
  again. The status bar shows the last successful sync's
  age once it passes 15 minutes.
- Untracked secrets: `add -A` skips ignored files, but a forgotten `.env`
  would still be pushed on every run. A configured exclude list is always
  applied, and a snapshot over a size cap (default 50M) is refused and reported,
  not trimmed silently. A pattern excludes a directory of that name and
  everything under it. Excludes filter untracked files only. A tracked file
  such as a committed `.env.example` is already in history, so it is
  snapshotted, compared and saved before an apply like any other file. Hidden
  from the snapshot, an edit to it read as untouched and apply overwrote it.
- A file caught mid-save: the next snapshot fixes it. The Stop hook snapshots
  land between turns, when Claude is not writing.

## Out of scope

- Dotfiles. They are committed and pushed by hand, one change at a time, and the
  repo is public. A later addition could fetch on a timer and show "dotfiles:
  N behind" in the status bar.
- Merging diverged work. The picker chooses a side; merging is done by hand or
  by Claude.

## Checks before switching on

Each of these is a short throwaway experiment. Check 4 is answered; the open
ones gate `auto on`. Checks 1 and 2 are still open, and `transcripts on` waits
on them too.

1. Open. Does `claude -c` resume cleanly from a transcript written on the
   other machine, with the same absolute path?
2. Open. What does `claude -c` do after two machines have both continued the
   same session? It decides how bad an unhandled conflict is.
3. Do GitHub and Bitbucket accept pushes to `refs/srcsync/*` on a fork, and
   keep them? `upngo/ordering-html` is on Bitbucket.
4. Can `tmux capture-pane` tell an empty Claude input line from a non-empty one?
   Answered: yes, measured on Claude Code 2.1.280. The box is two lines of `─`
   around the input line, and an empty one is `❯` and whitespace. See "The idle
   Claude holding an old conversation".
5. Does sleepwatcher run on a managed machine, and does it get enough time to
   push before sleep?

## Package layout

```
srcsync/.config/srcsync/
  DESIGN.md
  srcsync.sh          publish | apply | sync | status | auto | conflicts |
                      resolve | pick
  open.sh             what the sessionizer calls, capped at 10 seconds
  lib/                snapshot, state file, apply, auto, resolve,
                      transcripts, restart, maintain
  config              company patterns, excludes, size cap, auto on|off
  launchd/            agent plist + install step, as kanata does it
  tests/              standalone executables, like the tmux tests
srcsync/.sleep        sleepwatcher's hooks, stowed to ~/.sleep and ~/.wakeup
srcsync/.wakeup
claude/.claude/hooks/srcsync-hook.sh
                      Stop and SessionEnd, merged by install-hooks.sh
tmux/.config/tmux-powerline/segments/srcsync.sh
                      the status bar mark: conflicts, or the sync's age
```

## Tests

Tests drive real git, not stubs: two fake `$HOME`s standing in for the two
machines, and bare repos standing in for GitHub. The facts this rests on are
facts about git, and a stub would assert them into existence.

Cases the tests must cover:

- The walk-away handoff: A edits and commits locally on an unpushed branch, and
  B ends up with the same branch, HEAD, uncommitted changes, untracked files
  and deletions.
- A new worktree on A appears on B. A removed worktree disappears from B.
- A new repo on A is cloned on B.
- B touched the worktree too: nothing moves and a conflict is reported.
- A worktree with a busy session is skipped. The same worktree with an idle
  session is applied.
- After an apply that writes a transcript, an idle Claude with an empty box
  restarts, one with typed input waits on the pending list, and a session file
  naming a pane its process is not in restarts nothing.
- A company-pattern repo never pushes to `hub`, even with an override.
- An unchanged tree pushes nothing.
- The exclude list and size cap hold.
- A worktree removed on A but changed on B is kept on B.
- A repo deleted on A is not deleted on B.
- One run at a time: a held lock stops a second run, and a dead holder's lock
  is taken over.

## Bootstrap

1. On the main machine: create `BatsShadow/srcsync-state`, private. Fork any
   company repo whose origin is the team repo. Stow the package, run the first
   publish, and check the state file and refs.
2. On the second machine: stow, run apply, and compare the two machines.
3. Walk away from the main machine mid-task and pick it up here. That is the
   acceptance test.
