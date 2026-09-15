# shellcheck shell=bash
# The glyphs shared by the status bar and the fzf pickers.
#
# A session has to read identically in both, and the two live in separate stow
# packages that cannot share environment: a tmux popup shell inherits nothing
# from tmux-powerline. Restating the literals in each file is what let them
# drift. Sourcing this one does not.
#
# The segment sits beside this directory and reaches it by name. The picker is
# in the other package and climbs one level to tmux/.config first, which works
# because ~/.config/tmux and ~/.config/tmux-powerline are sibling symlinks into
# that directory, so both paths resolve the same in the checkout and under stow.
#
# Neutral names on purpose. Each consumer keeps its own override convention:
# the segment's long TMUX_POWERLINE_SEG_* variables, the picker's CC_G_*.

CC_GLYPH_WAIT='󰫢'
CC_GLYPH_BUSY='•'
CC_GLYPH_IDLE='·'
