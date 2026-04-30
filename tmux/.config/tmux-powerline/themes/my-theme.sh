# shellcheck shell=bash disable=SC2034
####################################################################################################
# This is a bubble theme created by @embe221ed (https://github.com/embe221ed)
# colors are inspired by catppuccin palettes (https://github.com/catppuccin/catppuccin)
####################################################################################################

# COLORS

# background for frappe catppuccin terminal theme
# thm_bg="#303446"

# background for macchiato catppuccin terminal theme
# thm_bg="#24273A"
#thm_bg="#303446"
thm_bg="#181818"
thm_bg="#151720"

thm_fg="#c6d0f5"
thm_cyan="#99d1db"
thm_black="#292c3c"
thm_black="#111111"
thm_gray="#414559"
thm_magenta="#ca9ee6"
thm_pink="#f4b8e4"
thm_blue="#8caaee"
thm_black4="#626880"
rosewater="#f2d5cf"
flamingo="#eebebe"
pink="#f4b8e4"
mauve="#ca9ee6"
red="#e78284"
maroon="#ea999c"
peach="#ef9f76"
yellow="#e5c890"
green="#a6d189"
teal="#81c8be"
sky="#99d1db"
sapphire="#85c1dc"
blue="#8caaee"
lavender="#babbf1"
text="#c6d0f5"
subtext1="#b5bfe2"
subtext0="#a5adce"
overlay2="#949cbb"
overlay1="#838ba7"
overlay0="#737994"
surface2="#626880"
surface1="#51576d"
surface0="#414559"
base="#303446"
base="#111111"
mantle="#292c3c"
crust="#232634"
eggplant="#e889d2"
sky_blue="#a7c7e7"
spotify_green="#1db954"
spotify_black="#191414"

# ayu updated colors
ayu_mirage() {
  # UI (canonical ayu Mirage)
  ayu_bg="#242936"
  ayu_bg_dim="#1f2430"
  ayu_fg="#cccac2"
  ayu_ui="#707a8c"
  ayu_accent="#ffcc66"
  ayu_selection="#34455a"
  ayu_line_hl="#1a1f29"
  ayu_guide="#2d3640"
  ayu_comment="#5c6773"

  # Syntax (ayutheme.com — Mirage column)
  ayu_tag="#5ccfe6"
  ayu_entity="#73d0ff"
  ayu_regexp="#95e6cb"
  ayu_string="#d5ff80"
  ayu_constant="#dfbfff"
  ayu_special="#d9be98"
  ayu_func="#ffcd66"
  ayu_keyword="#ffa659"
  ayu_operator="#f29e74"
  ayu_markup="#f28779"
  ayu_error="#ff3333"

  # ANSI aliases
  ayu_black="#1a1f29"
  ayu_red="$ayu_markup"
  ayu_green="$ayu_string"
  ayu_yellow="$ayu_func"
  ayu_blue="$ayu_entity"
  ayu_magenta="$ayu_constant"
  ayu_cyan="$ayu_regexp"
  ayu_white="#cccac2"
  ayu_orange="$ayu_keyword"
}

ayu_dark() {
  # UI (canonical ayu Dark)
  ayu_bg="#0b0e14"
  ayu_bg_dim="#0d1017"
  ayu_fg="#bfbdb6"
  ayu_ui="#565b66"
  ayu_accent="#e6b450"
  ayu_selection="#273747"
  ayu_line_hl="#131721"
  ayu_guide="#131721"
  ayu_comment="#acb6bf"

  # Syntax (ayutheme.com — Dark column)
  ayu_tag="#39bae6"
  ayu_entity="#59c2ff"
  ayu_regexp="#95e6cb"
  ayu_string="#aad94c"
  ayu_constant="#d2a6ff"
  ayu_special="#e6c08a"
  ayu_func="#ffb454"
  ayu_keyword="#ff8f40"
  ayu_operator="#f29668"
  ayu_markup="#f07178"
  ayu_error="#d95757"

  # ANSI aliases
  ayu_black="#000000"
  ayu_red="$ayu_markup"
  ayu_green="$ayu_string"
  ayu_yellow="$ayu_func"
  ayu_blue="$ayu_entity"
  ayu_magenta="$ayu_constant"
  ayu_cyan="$ayu_regexp"
  ayu_white="#bfbdb6"
  ayu_orange="$ayu_keyword"
}

# ayu_mirage
ayu_dark

# thm_bg="$ayu_bg"
thm_fg="$ayu_white"
sky="$ayu_entity"
flamingo="$ayu_markup"
blue="$ayu_entity"
sky_blue="$ayu_regexp"

TMUX_POWERLINE_SEPARATOR_LEFT_BOLD=""
TMUX_POWERLINE_SEPARATOR_LEFT_THIN=""
TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD=""
TMUX_POWERLINE_SEPARATOR_RIGHT_THIN=""
TMUX_POWERLINE_SEPARATOR_THIN="|"

# See Color formatting section below for details on what colors can be used here.
#TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR=${TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR:-$thm_bg}
TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR=default
TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR=${TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR:-$thm_fg}
TMUX_POWERLINE_SEG_AIR_COLOR=$(air_color)

TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR=${TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR:-$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}
TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR=${TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR:-$TMUX_POWERLINE_SEPARATOR_LEFT_BOLD}

# See `man tmux` for additional formatting options for the status line.
# The `format regular` and `format inverse` functions are provided as conveinences

# shellcheck disable=SC2128
current_window=$sky
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_CURRENT" ]; then
  TMUX_POWERLINE_WINDOW_STATUS_CURRENT=(
    "#[fg=$current_window,bg=$thm_bg]"
    "$TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR"
    # "#[$(format inverse)]"
    "#[fg=$thm_bg,bg=$current_window]"
    "#I#F"
    # "$TMUX_POWERLINE_SEPARATOR_RIGHT_THIN"
    " #W"
    "#[fg=$current_window,bg=$thm_bg]"
    "$TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR"
    "#[$(format regular)]"
  )
fi

# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_STYLE" ]; then
  TMUX_POWERLINE_WINDOW_STATUS_STYLE=(
    "$(format regular)"
  )
fi

# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_FORMAT" ]; then
  TMUX_POWERLINE_WINDOW_STATUS_FORMAT=(
    "#[$(format regular)]"
    " #I#{?window_flags,#F, }"
    #"$TMUX_POWERLINE_SEPARATOR_THIN"
    " #W "
  )
fi

# Format: segment_name background_color foreground_color [non_default_separator] [separator_background_color] [separator_foreground_color] [spacing_disable] [separator_disable]
#
# * background_color and foreground_color. Color formatting (see `man tmux` for complete list):
#   * Named colors, e.g. black, red, green, yellow, blue, magenta, cyan, white
#   * Hexadecimal RGB string e.g. #ffffff
#   * 'default' for the default tmux color.
#   * 'terminal' for the terminal's default background/foreground color
#   * The numbers 0-255 for the 256-color palette. Run `tmux-powerline/color-palette.sh` to see the colors.
# * non_default_separator - specify an alternative character for this segment's separator
# * separator_background_color - specify a unique background color for the separator
# * separator_foreground_color - specify a unique foreground color for the separator
# * spacing_disable - remove space on left, right or both sides of the segment:
#   * "left_disable" - disable space on the left
#   * "right_disable" - disable space on the right
#   * "both_disable" - disable spaces on both sides
#   * - any other character/string produces no change to default behavior (eg "none", "X", etc.)
#
# * separator_disable - disables drawing a separator on this segment, very useful for segments
#   with dynamic background colours (eg tmux_mem_cpu_load):
#   * "separator_disable" - disables the separator
#   * - any other character/string produces no change to default behavior
#
# Example segment with separator disabled and right space character disabled:
# "hostname 33 0 {TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD} 33 0 right_disable separator_disable"
#
# Note that although redundant the non_default_separator, separator_background_color and
# separator_foreground_color options must still be specified so that appropriate index
# of options to support the spacing_disable and separator_disable features can be used

# shellcheck disable=SC1143,SC2128
if [ -z "$TMUX_POWERLINE_LEFT_STATUS_SEGMENTS" ]; then
  TMUX_POWERLINE_LEFT_STATUS_SEGMENTS=(
    #"tmux_session_info $sky_blue $thm_bg"
    #"hostname $eggplant $thm_bg"
    #"ifstat 30 255"
    #"ifstat_sys 30 255"
    #"lan_ip $sky_blue $thm_bg ${TMUX_POWERLINE_SEPARATOR_RIGHT_THIN}"
    #"wan_ip $blue $thm_bg"
    #"vcs_branch $thm_gray"
    #"air ${TMUX_POWERLINE_SEG_AIR_COLOR} $thm_bg"
    #"vcs_compare 60 255"
    #"vcs_staged 64 255"
    #"vcs_modified 9 255"
    #"vcs_others 245 0"
  )
fi

# shellcheck disable=SC1143,SC2128
if [ -z "$TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS" ]; then
  TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=(
    # "earthquake 3 0"
    # "pwd $mauve $surface0"
    #"macos_notification_count 29 255"
    #"mailcount 9 255"
    "tmux_session_info $flamingo $thm_bg"
    "now_playing $spotify_green $spotify_black"
    #"cpu 240 136"
    #"load 237 167"
    #"tmux_mem_cpu_load 234 136"
    #"battery $blue $thm_bg"
    #"weather 37 255"
    #"rainbarf 0 ${TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR}"
    #"xkb_layout 125 117"
    #"date_day $teal $thm_bg"
    #"date $teal $thm_bg ${TMUX_POWERLINE_SEPARATOR_LEFT_THIN}"
    #"time $teal $thm_bg ${TMUX_POWERLINE_SEPARATOR_LEFT_THIN}"
    #"utc_time 235 136 ${TMUX_POWERLINE_SEPARATOR_LEFT_THIN}"
    "utc_time $blue $thm_bg"
    "wan_ip $sky_blue $thm_bg"
  )
fi
