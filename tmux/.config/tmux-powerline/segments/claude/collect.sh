# shellcheck shell=bash

# Seconds since a file was last modified, or nothing if it does not exist.
__cc_file_age() {
	local m
	m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || return 1
	[ -n "$m" ] || return 1
	echo $(( $(date +%s) - m ))
}

# Resolve each session's pid up its process tree until it reaches a pane, so a
# session is attributed to the window that actually owns it. Matching on the
# session `name` instead would be wrong: two sessions can share a name (there
# are currently two called fp-wallet-avs) and background agents have no window.
__cc_collect() {
	local dir="$1" blocked_cache="$2"

	{
		echo "P"
		ps -eo pid=,ppid=
		echo "W"
		tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}'
		echo "B"
		[ -n "$blocked_cache" ] && cat "$blocked_cache" 2>/dev/null
		echo "S"
		cat "$dir"/*.json 2>/dev/null | jq -r -n '
			[inputs]
			| .[]
			| select(.pid != null and .status != null)
			| [(.pid | tostring), .status, (.kind // "-"),
			   (.jobId // "-"), (.parkedJobId // "-")]
			| @tsv' 2>/dev/null
		# Whether the read can be trusted is jq's answer to give, not
		# something to infer from how many records came back. Immediately
		# after the pipeline above, PIPESTATUS[1] is jq's exit code.
		echo "J ${PIPESTATUS[1]}"
	} | awk '
		$0 == "P" { mode = "P"; next }
		$0 == "W" { mode = "W"; next }
		$0 == "B" { mode = "B"; next }
		$0 == "S" { mode = "S"; next }
		# Sits with the mode markers so the mode == "S" rule below cannot
		# swallow it. No session record can collide: every one of them starts
		# with a pid.
		$1 == "J" { jqrc = $2; next }
		mode == "P" { parent[$1] = $2; next }
		mode == "W" { pane[$1] = $2; next }
		mode == "B" { blocked[$1] = 1; next }
		# Buffer the sessions rather than resolving inline: a background agent
		# can be read before the interactive session that parked it.
		mode == "S" {
			# A background agent blocked on input records itself as idle, so
			# the blocked list is the only thing that can promote it. Trust it
			# over the file.
			st = $2
			if ($1 in blocked) st = "waiting"

			n++
			spid[n] = $1; sstatus[n] = st; skind[n] = $3; sjob[n] = $4
			if ($5 != "-") parked[$5] = $1

			# Ambiguity is a property of the RAW file status, not the promoted
			# one. A blocked background agent records itself as idle, so idle
			# is the only bg state the file cannot resolve on its own. Using
			# the promoted value here would drop the session out of the set the
			# moment the promotion landed, and the binary would be asked again
			# on the very next tick, forever.
			if ($3 == "bg" && $2 == "idle") amb[$1] = 1

			if (st == "waiting")   waiting++
			else if (st == "busy") busy++
			else                   idle++
		}
		END {
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
			printf "COUNTS %d %d %d\n", waiting + 0, busy + 0, idle + 0

			for (s = 1; s <= n; s++) {
				p = spid[s]

				# A background agent has no pane of its own — it is spawned
				# under the daemon, not under a shell. Its work still belongs
				# to the window whose session parked it, which is the window
				# the user is actually looking at, so borrow that pid and
				# resolve from there. Without this the window shows the idle
				# state of the parked session while the real work happens
				# invisibly. Note the awk body is single-quoted, so no
				# apostrophes in these comments.
				if (skind[s] == "bg" && sjob[s] != "-" && (sjob[s] in parked))
					p = parked[sjob[s]]

				rank = (sstatus[s] == "waiting" ? 3 : (sstatus[s] == "busy" ? 2 : 1))

				# Walk up to the owning pane. Bounded so a cycle or a
				# reparented process can never spin.
				for (i = 0; i < 24; i++) {
					if (p == "" || p == "0" || p == "1") break
					if (p in pane) {
						w = pane[p]
						# A window can hold more than one session — including a
						# parked one plus its background agent. Most demanding
						# state wins.
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
			for (a in amb) printf "AMB %s\n", a
		}
	'
}
