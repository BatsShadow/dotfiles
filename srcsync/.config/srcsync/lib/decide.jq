# Which way one worktree should move. See DESIGN.md "Apply: the one rule".
#
# Input:
#   mine        this machine's last published entry, or null
#   now         {branch, head, tree} as the worktree is right now, or null if
#               absent, plus claude with transcripts on. Off, claude is absent
#               everywhere and compares equal.
#   theirs      the other machine's entry
#   removed_at  when this machine published the worktree's removal, or null
#   ff_forward  now is clean and its head is an ancestor of theirs, or null if unchecked
#   ff_back     theirs is clean and its head is an ancestor of now's, or null if unchecked
#
# Output, one of:
#   same      the two already match
#   ahead     this side holds everything theirs does; they will take ours
#   apply     take theirs
#   conflict  both moved; the picker decides
#   check-ff  first contact, and the answer needs the two ff flags
#
# base is the other machine's state an entry was built from. It is what tells
# "they moved on from what I have" apart from "we both moved".

def st: {branch, head, tree, claude};
def eq($a; $b): $a != null and $b != null and ($a | st) == ($b | st);

if .now == null then
  # a removal here only wins over a worktree the other side has not moved since
  if .mine != null then (if eq(.theirs; .mine) or eq(.theirs; .mine.base) then "ahead" else "apply" end)
  elif .removed_at != null and .removed_at >= .theirs.changed_at then "ahead"
  else "apply" end
elif eq(.now; .theirs) then "same"
elif eq(.theirs; .mine.base) then "ahead"
elif .mine == null or (.mine.base == null and .theirs.base == null) then
  if .ff_forward == null then "check-ff"
  elif .ff_forward then "apply"
  elif .ff_back then "ahead"
  else "conflict" end
elif eq(.now; .mine) | not then "conflict"
elif eq(.theirs.base; .mine) or eq(.mine; .mine.base) then "apply"
else "conflict" end
