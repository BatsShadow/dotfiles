#!/usr/bin/env bash
# The short version of the always-on skills, for UserPromptSubmit to inject.
#
# session-start-skills.sh puts the whole of unslop in at session start, which is
# the right place for 80 lines of rules: once, before the first word. This is
# the other half. By turn ten the full skill is a long way behind the text it
# governs, and repeating all of it every turn costs ~1700 tokens a time.
#
# What goes in it was measured rather than guessed. Scanning 189 transcripts and
# splitting on the date unslop landed: injection cut the em dash rate 45%, from
# 199.8 per 10k words to 110.7, so the mechanism works and does not finish. Of
# the violations left that a regex can see, em dashes are 89%, bold inline
# headers 7%, and "not just X" 2%. Three rules are 98.5% of it. The remaining
# 28 rules together produced 21 hits in 110k words.
#
# So this names three rules, not thirty-one. The full set is already in context
# from session start; what this adds is proximity, and a list long enough to
# bury the one rule that matters would spend the proximity on the other thirty.
#
# Only the rules a scanner can count are ranked here. Puffery, plain speech and
# active voice may well be broken just as often, invisibly. Do not read the
# three as the whole job.
#
#   turn-skill-reminder.sh

cat <<'EOF'
unslop is in force. Full rules came in at session start; these three are the
ones actually broken, measured across every transcript on this machine:

1. No em dashes. 89% of all violations, on its own. A period or a comma
   instead, never a parenthesis or an en dash standing in for one.
2. No bold inline-header bullets. "**Label:** restated line" becomes prose.
3. No "not just X, but Y". State the point directly.
EOF
