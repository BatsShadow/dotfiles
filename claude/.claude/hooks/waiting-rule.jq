# Does this message leave the user with something to answer?
#
# Shared by claude-waiting.sh and claude-waiting-backfill.sh, which have to
# agree exactly: the backfill exists to mark sessions the hook was installed too
# late to see, so any drift between them shows up as a window that is amber
# until the next turn and then silently is not.
#
# Input is the assistant's message as a raw string (`jq -Rs -f`). Output is one
# @tsv row: strict, para, tail2, ask, text.
#
#   strict  the message ends in ?
#   para    the last paragraph contains ?          <- live
#   tail2   either of the last two paragraphs does
#   ask     anywhere in the message, a request to reply
#
# The live rule is `para or ask`. The other two are computed and logged but not
# acted on, so waiting-report.sh can score what each would have done against the
# calls actually marked wrong.
#
# `ask` is scoped to the whole message, not the last paragraph, because the turn
# that motivated it put the request second from the end:
#
#   ...Here is the proposed commit message:
#   ```
#   GH #5126: Only update CSV columns present in the location import file
#   ...
#   ```
#   Reply "ok" to commit it, or tell me what to change.
#
#   One note on the footer: I put a real customer impact rather than `None`...
#   Say the word if you'd rather that read differently.
#
# Every punctuation rule misses that -- neither of the last two paragraphs holds
# a question mark -- and so would a last-paragraph `ask`. A request to reply is
# not a closing flourish that can be assumed to come last.
#
# The patterns are narrow on purpose. "Reply <quote>", "reply with" and "say the
# word" are all direct instructions to the user and read as nothing else. The
# tempting wider ones are not: "let me know" ends a great many turns that have
# simply finished, and would light up the bar permanently.
def ask_re: "reply\\s*[\"“”'‘’]|reply with\\b|say the word\\b";

sub("[[:space:]]+$"; "")
| . as $msg
| ($msg | split("\n\n")) as $paras
| ($paras | last // "") as $para
| ($paras[-2:] | join(" ")) as $tail2

# The paragraph to show on the status bar and in the jump list, which wants the
# request itself rather than whatever happened to be typed last.
#
# Questions and asks get opposite tie-breaks, because they sit in opposite
# places. A message with several question marks is building to the last one. A
# message that asks you to reply has made its request and then carried on
# explaining, so the first ask is the real one -- in the message above, last
# would show "One note on the footer..." and first shows `Reply "ok" to commit
# it`, which is the whole point of putting text on the row.
| (($paras | map(select(test("\\?")))        | last)
   // ($paras | map(select(test(ask_re; "i"))) | first)
   // $para // "") as $best

| [ ($msg   | endswith("?")),
    ($para  | test("\\?")),
    ($tail2 | test("\\?")),
    ($msg   | test(ask_re; "i")),
    ($best  | gsub("[[:space:]]+"; " ") | .[0:300]) ]
| @tsv
