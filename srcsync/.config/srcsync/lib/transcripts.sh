# A worktree's Claude conversation as a tree in its repo, so it travels to the
# same remote as the code. See DESIGN.md "Claude transcripts".

# Claude's name for the project dir of $1: the physical path, with every
# character outside [A-Za-z0-9] a dash, the rule claude-continue.sh uses.
slug_of() { # dir
	local p
	p=$(cd "$1" 2>/dev/null && pwd -P) || p=$1
	printf '%s' "$p" | tr -c 'A-Za-z0-9' '-'
	echo
}

claude_dir() { # wt
	printf '%s/%s\n' "$CC_PROJECTS_DIR" "$(slug_of "$1")"
}

claude_ref() { # host key
	printf 'refs/srcsync/%s/%s/claude\n' "$1" "$2"
}

# git on claude_tree's index and directory, read from its locals. The repo's
# own fsmonitor, sparse and split-index settings describe its worktree, not
# this directory.
claude_git() {
	GIT_INDEX_FILE=$idx git -c core.fsmonitor=false -c core.sparseCheckout=false \
		-c core.splitIndex=false \
		--git-dir="$gcd" --work-tree="$cdir" "$@"
}

# One file under dir $1 matching the find tests after it, within the cap when
# the scan is capped.
small() { # dir find-tests...
	local d=$1 lim=()
	shift
	[ "$mode" = capped ] && lim=(! -size +"$CFG_MAX_SIZE"c)
	find "$d" "$@" -type f ${lim[@]+"${lim[@]}"} 2>/dev/null | head -1
}

# Says $1 once per srcsync run. Every $(...) shares the run's $$.
say_once() { # message
	local f=$SRCSYNC_STATE/said
	[ "$(head -1 "$f" 2>/dev/null)" = "$$" ] || echo "$$" >"$f"
	grep -qxF "$1" "$f" && return
	echo "$1" >>"$f"
	say "$1"
}

# The tree of the top-level *.jsonl and memory/ in claude_dir $2, written into
# the objects of the repo holding $1. Prints nothing when there are none. With
# mode all, every file goes in. With capped, a file over max_size is left out,
# so it never holds back the rest. Each mode has its own index in the state
# dir, never in a worktree, so its stat cache spares rehashing transcripts
# that have not grown. An index naming objects the repo lacks, as after a
# fresh clone, is thrown away and rebuilt once.
claude_scan() { # repo_dir wt capped|all
	local cdir gcd idx specs f tree try big=() key mode=$3
	cdir=$(claude_dir "$2")
	gcd=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
	idx=$SRCSYNC_STATE/claude-index/$(slug_of "$2")
	[ "$3" = capped ] || idx=$idx.all
	[ -d "$cdir" ] || return 0
	mkdir -p "$SRCSYNC_STATE/claude-index"
	if [ "$3" = capped ]; then
		key=$(key_of "$2" 2>/dev/null) || key=$2
		while IFS= read -r f; do
			f=${f#"$cdir"/}
			big+=("$f")
			say_once "$key: transcript $f is over the size cap; left out"
		done < <(find "$cdir" -maxdepth 1 -type f -name '*.jsonl' -size +"$CFG_MAX_SIZE"c 2>/dev/null
			find "$cdir/memory" -type f -size +"$CFG_MAX_SIZE"c 2>/dev/null)
	fi
	for try in 1 2; do
		# Out of the index first, so the pathspecs below see only what
		# stays. One that matches nothing on disk or in the index is an
		# error, so each goes in only when it has something to match.
		if [ ${#big[@]} -gt 0 ] && ! claude_git rm -q --cached --ignore-unmatch -- "${big[@]}" >/dev/null; then
			rm -f "$idx"
			continue
		fi
		specs=()
		{ [ -n "$(small "$cdir" -maxdepth 1 -name '*.jsonl')" ] ||
			[ -n "$(claude_git ls-files -- ':(glob)*.jsonl')" ]; } && specs+=(':(glob)*.jsonl')
		{ [ -n "$(small "$cdir/memory")" ] || [ -n "$(claude_git ls-files -- memory)" ]; } && specs+=(memory)
		if [ ${#specs[@]} -gt 0 ]; then
			for f in ${big[@]+"${big[@]}"}; do specs+=(":(exclude,literal)$f"); done
			claude_git add -f -A -- "${specs[@]}" || {
				rm -f "$idx"
				continue
			}
		fi
		[ -n "$(claude_git ls-files)" ] || return 0
		tree=$(claude_git write-tree 2>/dev/null) && break
		tree=
		rm -f "$idx"
	done
	[ -n "$tree" ] || return 1
	echo "$tree"
}

# The claude tree of worktree $2 as publish sends it and apply compares it.
# Files over the cap are left out, and when what remains would still push more
# than max_size, there is no tree. A tree some claude ref already holds costs
# nothing to push, so this host's ref keeps mine's tree readable as itself.
claude_tree() { # repo_dir wt
	local tree key
	tree=$(claude_scan "$1" "$2" capped) || return 1
	[ -n "$tree" ] || return 0
	if ! git -C "$1" for-each-ref --format='%(tree) %(refname)' refs/srcsync |
		grep -q "^$tree .*/claude\$" &&
		[ "$(git -C "$1" rev-list --objects --disk-usage "$tree" --not --glob='refs/srcsync/*')" -gt "$CFG_MAX_SIZE" ]; then
		key=$(key_of "$2" 2>/dev/null) || key=$2
		say_once "transcripts of $key over the size cap; code published without them"
		return 0
	fi
	echo "$tree"
}

# A parentless commit of claude tree $3 for the worktree keyed $2.
make_claude_commit() { # repo_dir key tree
	git -C "$1" commit-tree "$3" -m "srcsync transcripts of $2"
}

# The first path at which laying tree $2 over claude_dir $1 would replace a
# directory or symlink, or a file where the tree wants a directory. checkout-index
# -f would delete what is there, and a transcript file is never deleted.
claude_clash() { # repo_dir wt tree
	local cdir p d
	cdir=$(claude_dir "$2")
	while IFS= read -r p; do
		{ [ -d "$cdir/$p" ] || [ -L "$cdir/$p" ]; } && echo "$p" && return
		d=$(dirname "$p")
		while [ "$d" != . ]; do
			if [ -L "$cdir/$d" ] || { [ -e "$cdir/$d" ] && [ ! -d "$cdir/$d" ]; }; then
				echo "$d"
				return
			fi
			d=$(dirname "$d")
		done
	done < <(git -C "$1" ls-tree -r --name-only "$3")
}

# True when file $2 is a strict byte prefix of blob $3 in repo $1. Transcripts
# only grow, so theirs then holds every line here and more.
extends() { # repo_dir file blob
	local n
	n=$(wc -c <"$2" | tr -d ' ') || return 1
	[ "$n" -lt "$(git -C "$1" cat-file -s "$3")" ] || return 1
	# macOS cmp -n 0 exits 1, and an empty file is a prefix of anything
	[ "$n" -eq 0 ] && return 0
	git -C "$1" cat-file blob "$3" | cmp -s -n "$n" "$2" -
}

# Writes the files of claude tree $3 into claude_dir $2, creating it. Files
# the tree lacks stay, and so does everything if any path clashes. Theirs
# replaces a file here only when it extends it, judged by content alone: the
# recorded base and claude fields have been wrong about which side is newer
# in every way they can be, and each time a line was lost. Any other file
# that differs is kept and logged. Files already equal to theirs are not
# rewritten, so their mtimes, which claude -c picks the newest session by,
# stay. The index is a temp file, never a worktree's. CLAUDE_LAID is the
# number of files written, so a lay that kept everything restarts no Claude.
lay_claude() { # repo_dir wt tree
	local cdir gcd idx rc p key n
	CLAUDE_LAID=0
	cdir=$(claude_dir "$2")
	gcd=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
	[ -z "$(claude_clash "$1" "$2" "$3")" ] || return 1
	key=$(key_of "$2" 2>/dev/null) || key=$2
	idx=$(mktemp "${TMPDIR:-/tmp}/srcsync-claude-index.XXXXXX") || return 1
	rm -f "$idx"
	n=$(
		mkdir -p "$cdir" && claude_git read-tree "$3" || exit 1
		claude_git update-index -q --refresh >/dev/null
		claude_git diff-files -z --name-only | while IFS= read -r -d '' p; do
			[ -f "$cdir/$p" ] || continue
			# memory is edited in place, where a prefix can be a deletion
			case $p in
			(*.jsonl) extends "$1" "$cdir/$p" "$3:$p" && continue
				say_once "$key: kept $p: both machines added to it" ;;
			(*) say_once "$key: kept $p: it differs here" ;;
			esac
			claude_git update-index --force-remove -- "$p" || exit 1
		done || exit 1
		# what is left differs or is missing; checkout-index skips the rest
		claude_git diff-files --name-only | wc -l | tr -d ' '
		claude_git checkout-index -a -f >/dev/null
	)
	rc=$?
	rm -f "$idx"
	[ $rc = 0 ] && CLAUDE_LAID=$n
	return $rc
}

# The first file in claude_dir $2 whose content differs from claude tree $3's
# copy of it. Files only one side has do not count.
claude_disagree() { # repo_dir wt tree
	local cdir gcd idx p
	cdir=$(claude_dir "$2")
	[ -d "$cdir" ] || return 0
	gcd=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
	idx=$(mktemp "${TMPDIR:-/tmp}/srcsync-claude-index.XXXXXX") || return 1
	rm -f "$idx"
	claude_git read-tree "$3" && claude_git update-index -q --refresh >/dev/null
	claude_git diff-files -z --name-only | while IFS= read -r -d '' p; do
		[ -f "$cdir/$p" ] && echo "$p" && break
	done
	rm -f "$idx"
}

# The claude tree now in claude_dir $3 as a JSON string or null, with this
# machine's claude ref at a commit of it, as publish would leave it. After an
# apply it can hold files theirs lacks, since nothing is deleted.
own_claude() { # repo_dir wt_key theirs_json
	local tree ref commit
	tree=$(claude_tree "$1" "$HOME_P/$2") || tree=$(jq -r '.claude // empty' <<<"$3")
	if [ -z "$tree" ]; then
		echo null
		return
	fi
	ref=$(claude_ref "$SRCSYNC_HOST" "$2")
	if [ "$(git -C "$1" rev-parse -q --verify "$ref^{tree}")" != "$tree" ]; then
		commit=$(make_claude_commit "$1" "$2" "$tree") &&
			git -C "$1" update-ref "$ref" "$commit" || return 1
	fi
	echo "\"$tree\""
}

# The fields of a state that base records: the code, and the transcripts when
# they are on here.
base_keys() {
	if [ "$CFG_TRANSCRIPTS" = on ]; then echo '{branch, head, tree, claude}'; else echo '{branch, head, tree}'; fi
}
