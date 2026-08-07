# shellcheck shell=bash

# Resolve each session's pid up its process tree until it reaches a pane, so a
# session is attributed to the window that actually owns it. Matching on the
# session `name` instead would be wrong: two sessions can share a name (there
# are currently two called fp-wallet-avs) and background agents have no window.
#
# Two inputs describe Claude, and they describe different things:
#
#   <dir>   ~/.claude/sessions/<pid>.json -- one file per live INTERACTIVE
#           session. Every one of these has a pid, and that pid is what walks up
#           to a pane.
#
#   <jobs>  ~/.claude/jobs/<id>/state.json -- one directory per background
#           agent. These have no pid and no session file; the daemon owns them,
#           and `claude agents --json` is derived from them, which is why they
#           can be read directly instead of paying ~290ms of node startup to ask
#           the binary the same question.
#
#   <marks> ~/.claude/waiting/<sessionId> -- one file per session a hook has
#           judged to be waiting on the user. Also keyed by sessionId, and read
#           the same way. See claude/.claude/hooks/claude-waiting.sh for why
#           this exists: a session that asked an open-ended question is
#           indistinguishable, in both directories above, from one that merely
#           finished, and only the hook can see the text that separates them.
#
# The link between all three is sessionId: a blocked agent names the interactive
# session that owns it, that session has a pid, and the pid resolves to a
# window. This is the only link that exists. An earlier design expected agents
# to write session files of their own with `kind: "bg"` and to be paired up
# through jobId/parkedJobId; Claude Code writes none of those three fields, so
# that path could never fire and blocked agents never showed as waiting.
#
# Matching on sessionId also disposes of stale agents for free. Blocked jobs
# accumulate -- three of the four on the machine this was written against were
# 24 to 38 days old, parked against sessions that had long since exited. With no
# live session file carrying their sessionId they resolve to no pid, and so to
# no window, without needing an age heuristic.
__cc_collect() {
	local dir="$1" jobs="$2" marks="$3"

	{
		echo "P"
		ps -eo pid=,ppid=
		echo "W"
		tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}'
		echo "B"
		# Blocked background agents, as the sessionId of the session that owns
		# each one. A directory holding no state.json is a leftover temp dir and
		# simply contributes nothing.
		if [ -n "$jobs" ]; then
			cat "$jobs"/*/state.json 2>/dev/null | jq -r -n '
				[inputs]
				| .[]
				| select(.state == "blocked" and .sessionId != null)
				| .sessionId' 2>/dev/null
			echo "Q ${PIPESTATUS[1]}"
		else
			echo "Q 0"
		fi
		echo "M"
		# Hook-written markers, named for the sessionId they belong to. The
		# .pending ones are excluded deliberately: those record only that Claude
		# asked something, not that the user has yet failed to answer, and
		# promoting one early would light up every window the instant a turn
		# ended. See claude-waiting.sh.
		if [ -n "$marks" ] && [ -d "$marks" ]; then
			ls -1 "$marks" 2>/dev/null | grep -v '\.pending$'
			echo "R ${PIPESTATUS[0]}"
		else
			echo "R 0"
		fi
		echo "S"
		cat "$dir"/*.json 2>/dev/null | jq -r -n '
			[inputs]
			| .[]
			| select(.pid != null and .status != null)
			| [(.pid | tostring), .status, (.sessionId // "-")]
			| @tsv' 2>/dev/null
		# Whether the read can be trusted is jq's answer to give, not
		# something to infer from how many records came back. Immediately
		# after the pipeline above, PIPESTATUS[1] is jq's exit code.
		echo "J ${PIPESTATUS[1]}"
	} | awk '
		$0 == "P" { mode = "P"; next }
		$0 == "W" { mode = "W"; next }
		$0 == "B" { mode = "B"; next }
		$0 == "M" { mode = "M"; next }
		$0 == "S" { mode = "S"; next }
		# The sentinels sit with the mode markers so the mode rules below
		# cannot swallow them. None can collide with real data: a session
		# record starts with a pid, and a blocked entry and a waiting marker
		# are both a bare sessionId, which is a UUID.
		$1 == "J" { jqrc = $2; next }
		$1 == "Q" { jobsrc = $2; next }
		$1 == "R" { marksrc = $2; next }
		# Both of these are counted, not just recorded. An input that comes
		# back empty leaves its map empty, the pid walk then resolves nothing,
		# and awk would print COUNTS with no WIN lines at all -- which the
		# caller reads as "no window hosts a session" and responds to by
		# stripping every window option, arming a notification burst on the
		# next healthy tick. Counting the input is the only way to tell that
		# apart from the legitimate no-WIN case, which is every live session
		# being a background agent with no window of its own.
		mode == "P" { parent[$1] = $2; nproc++; next }
		mode == "W" { pane[$1] = $2; npane++; next }
		mode == "B" { blocked[$1] = 1; next }
		mode == "M" { marked[$1] = 1; next }
		mode == "S" {
			# A session owning a blocked agent is waiting on the user, whatever
			# its own file says -- the file describes the terminal, not the work
			# parked under it. A hook marker says the same thing for a different
			# reason: the session asked a question and has not been answered,
			# which no file in either directory records.
			st = $2
			if ($3 != "-") {
				if ($3 in blocked) st = "waiting"
				# Busy overrides a marker, and only a marker. A marker is a
				# claim about the past -- Claude asked, and as of 60s ago
				# nobody had answered -- so a session now working is evidence
				# the claim has expired, however it got cleared. A blocked
				# agent is the opposite: it is parked right now, and its owner
				# being busy on something else does not unpark it, which is
				# why that case still outranks busy.
				else if (($3 in marked) && st != "busy") st = "waiting"
			}

			n++
			spid[n] = $1; sstatus[n] = st

			if (st == "waiting")   waiting++
			else if (st == "busy") busy++
			else                   idle++
		}
		END {
			# A jobs read that failed leaves the blocked set unknowable. Saying
			# "nothing blocked" would drop every affected window out of waiting
			# for a tick and put it back on the next one, and that recovery tick
			# reads as a fresh transition on every one of them -- a notification
			# burst. Checked first: it holds whether or not there are sessions.
			if (jobsrc != 0 || marksrc != 0) {
				print "TORN"
				exit
			}

			# TORN means the read cannot be trusted; EMPTY means a clean read
			# of a directory with no sessions. The caller responds to EMPTY by
			# stripping every window option, so calling a bad read empty would
			# manufacture a fresh transition on the following tick.
			#
			# jq failing is the whole of the first test. Asking instead whether
			# any file was present froze the segment permanently: a process
			# SIGKILLed mid-write leaves a 0-byte file that nothing ever cleans
			# up -- cleanup is the job of the exiting process -- so once every
			# real session had exited, the directory held one unparseable file,
			# no records came back, and every tick from then on returned TORN.
			# jq reads no input from a 0-byte file and exits 0, which is the
			# truth: there really are no sessions.
			if (!n) {
				if (jqrc != 0) print "TORN"; else print "EMPTY"
				exit
			}

			# The sessions input has a sentinel; these two never did. Gate on
			# them being empty rather than on the WIN lines they would have
			# produced -- see the counting rules above.
			if (!nproc || !npane) {
				print "TORN"
				exit
			}

			printf "COUNTS %d %d %d\n", waiting + 0, busy + 0, idle + 0

			for (s = 1; s <= n; s++) {
				p = spid[s]

				rank = (sstatus[s] == "waiting" ? 3 : (sstatus[s] == "busy" ? 2 : 1))

				# Walk up to the owning pane. Bounded so a cycle or a
				# reparented process can never spin.
				for (i = 0; i < 24; i++) {
					if (p == "" || p == "0" || p == "1") break
					if (p in pane) {
						w = pane[p]
						# A window can hold more than one session. Most
						# demanding state wins.
						if (rank > best[w]) {
							best[w] = rank
							state[w] = sstatus[s]
							bestpid[w] = spid[s]
						}
						break
					}
					p = parent[p]
				}
			}

			for (w in state) printf "WIN %s %s %s\n", w, state[w], bestpid[w]
		}
	'
}
