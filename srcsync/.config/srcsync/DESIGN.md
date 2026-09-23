# srcsync: carry work between two machines

Status: design, 2026-09-23. Nothing is built yet. Build and first test on the
main machine, then hand off to the second one.

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
          "changed_at": "2026-09-23T13:58:40Z"
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
  previous publish. Newer `changed_at` wins.
- `removed` carries deletions as well as additions. Entries older than 30 days
  are dropped.

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
- `hub` for everything else. The snapshot goes to `srcsync-state` itself. This
  covers repos with no remote at all and upstream-only clones that cannot be
  pushed to, and backs up their history as a side effect.

A config file names the patterns that mark a repo as company, matched against
its remote URLs. Anything unmatched is `hub`. Get this wrong and company code
lands on a personal account, so a repo whose remote matches the company pattern
must never resolve to `hub`, even through a per-repo override. The tests pin
that.

A company repo whose `origin` is the team repo itself, not a fork, needs a fork
before it syncs. Otherwise the snapshot refs are visible to anyone listing the
team repo's refs.

### Claude transcripts

The `claude` ref holds the worktree's `~/.claude/projects/<slug>/` directory
as a commit: the `*.jsonl` transcripts and `memory/`. It goes to the same remote
as the code, so company conversations stay on company GitHub too.

## Apply: the one rule

For each worktree, compare the other machine's entry with this machine's.
If the other side's `changed_at` is newer and this machine has not touched the
worktree since its own last publish, apply the other side's state. There's no
prompt.

"Touched" means the current branch, HEAD or snapshot tree differs from what
`last.json` recorded. In the normal flow the machine you left published last
and nothing here changed since, so every worktree qualifies. Anything this
machine had before the apply is still its own published snapshot, so an apply
is recoverable.

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
7. Record the result as this machine's state, so it counts as untouched.

A removal the other side published after this machine's `changed_at` removes
the worktree here too, if it is untouched. The branch is left for
`worktree-remove.sh` to judge.

### When not to apply

- **Claude mid-turn.** `~/.claude/sessions/<pid>.json` records `status` and
  `cwd` for every live session. A worktree whose session is `busy` or `waiting`
  is skipped and retried next run. An idle session is normal and does not block
  an apply. Claude is almost always open, and nearly always idle.
- **Both sides touched it.** Nothing moves. The worktree gets a conflict mark
  in the tmux status bar, the way waiting windows are marked now, and a picker
  shows both states and applies the one chosen. Both stay on the remote as
  snapshots whichever way it goes.

### The idle Claude holding an old conversation

An idle Claude keeps the conversation it loaded at start and never rereads the
transcript. After an apply brings in a newer transcript, that pane is talking
to a stale conversation, and typing into it forks the transcript.

So after an apply that changed a worktree's transcripts, restart any idle
Claude in that worktree. Kill it, and relaunch with `claude-continue.sh`, whose
`claude -c` resumes the newest transcript, now the one from the other machine.

Optional refinement: a half-typed prompt in the idle Claude's input box would
be lost by the restart. `tmux capture-pane` can probably detect a non-empty
input line. Where it does, put off the restart until the window next gains
focus, instead of doing it in the background. Not required for a first version.

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

One run at a time, via a `mkdir` lock (macOS has no `flock`). A run that finds
the lock held exits and leaves the work to the next one.

## Failure

- Offline or a failed push: the local ref and `last.json` are kept, and the
  next run retries. The status bar shows the last successful sync's age once it
  passes 15 minutes.
- Untracked secrets: `add -A` skips ignored files, but a forgotten `.env`
  would still be pushed on every run. A configured exclude list is always
  applied, and a snapshot over a size cap (default 50M) is refused and reported,
  not trimmed silently.
- A file caught mid-save: the next snapshot fixes it. The Stop hook snapshots
  land between turns, when Claude is not writing.

## Out of scope

- Dotfiles. They are committed and pushed by hand, one change at a time, and the
  repo is public. A later addition could fetch on a timer and show "dotfiles:
  N behind" in the status bar.
- Merging diverged work. The picker chooses a side; merging is done by hand or
  by Claude.

## Check before building

Each of these is a short throwaway experiment. The design depends on the answers.

1. Does `claude -c` resume cleanly from a transcript written on the other
   machine, with the same absolute path?
2. What does `claude -c` do after two machines have both continued the same
   session? It decides how bad an unhandled conflict is.
3. Does GitHub accept pushes to `refs/srcsync/*` on a fork, and keep them?
4. Can `tmux capture-pane` tell an empty Claude input line from a non-empty one?
5. Does sleepwatcher run on a managed machine, and does it get enough time to
   push before sleep?

## Package layout

```
srcsync/.config/srcsync/
  DESIGN.md
  srcsync.sh          publish | apply | status | pick
  lib/                snapshot, state file, apply
  config              company patterns, excludes, size cap
  launchd/            agent plist + install step, as kanata does it
  tests/              standalone executables, like the tmux tests
```

The Stop and SessionEnd registrations go in `claude/.claude/hooks/`, merged by
`install-hooks.sh`. The status bar glyphs join the existing claude segment.

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
- A company-pattern repo never pushes to `hub`, even with an override.
- An unchanged tree pushes nothing.
- The exclude list and size cap hold.

## Bootstrap

1. On the main machine: create `BatsShadow/srcsync-state`, private. Fork any
   company repo whose origin is the team repo. Stow the package, run the first
   publish, and check the state file and refs.
2. On the second machine: stow, run apply, and compare the two machines.
3. Walk away from the main machine mid-task and pick it up here. That is the
   acceptance test.
