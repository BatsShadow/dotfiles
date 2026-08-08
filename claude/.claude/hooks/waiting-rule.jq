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
#   para    the last paragraph contains ?                  <- live
#   tail2   either of the last two paragraphs does
#   ask     either of the last two paragraphs asks you to reply   <- live
#
# The live rule is `para or ask`. The other two are computed and logged but not
# acted on, so waiting-report.sh can score what each would have done against the
# calls actually marked wrong.
#
# `ask` exists because a request for input need not be a question. The turn that
# motivated it put the request second from the end, with a footnote after it:
#
#   ...Here is the proposed commit message:
#   ```
#   GH #5126: Only update CSV columns present in the location import file
#   ```
#   Reply "ok" to commit it, or tell me what to change.
#
#   One note on the footer: I put a real customer impact rather than `None`...
#
# Neither of the last two paragraphs holds a question mark, so every punctuation
# rule scores that idle.
#
# Scoped to the last two paragraphs rather than the whole message, because
# unscoped it fired on this, four paragraphs from the end of an eight-paragraph
# completion report:
#
#   If you want certainty I can loop the full suite ... Say the word.
#
# A real invitation, but an aside: the message went on to results and a handover
# list. A request that is genuinely the close of a turn sits at the close. The
# two live cases separate cleanly on position -- 1 from the end against 4 -- so
# the window is what distinguishes them, not the wording.
#
# The patterns are narrow on purpose. "Reply <quote>", "reply with" and "say the
# word" are direct instructions to the user and read as nothing else. The
# tempting wider ones are not: "let me know" ends a great many turns that have
# simply finished, and would light up the bar permanently.
def ask_re: "reply\\s*[\"“”'‘’]|reply with\\b|say the word\\b";

# Good enough for display. Abbreviations and decimals split wrongly, which costs
# a slightly short row and nothing else -- no verdict depends on this.
def sentences: [splits("(?<=[.!?])\\s+")] | map(select(length > 0));

sub("[[:space:]]+$"; "")
| . as $msg
| ($msg | split("\n\n")) as $paras
| ($paras | last // "") as $para
| ($paras[-2:]) as $window
| ($window | join(" ")) as $tail2
| ($window | map(select(test(ask_re; "i"))) | first) as $askpara

# What to put on the status bar and in the jump list: the sentence that did the
# asking, not the paragraph around it. The paragraph is often a long piece of
# analysis with the request at the end of it, which reads as noise on a row.
#
# Questions and asks take opposite ends, because they sit at opposite ends. A
# paragraph with several question marks is building to the last one; a paragraph
# that asks you to reply has made its request and then keeps explaining.
| (($paras | map(select(test("\\?"))) | last) as $qpara
   | if $qpara then ($qpara | sentences | map(select(test("\\?"))) | last) // $qpara
     elif $askpara then ($askpara | sentences | map(select(test(ask_re; "i"))) | first) // $askpara
     else $para end) as $best

| [ ($msg   | endswith("?")),
    ($para  | test("\\?")),
    ($tail2 | test("\\?")),
    ($askpara != null),
    ($best  | gsub("[[:space:]]+"; " ") | .[0:300]) ]
| @tsv
