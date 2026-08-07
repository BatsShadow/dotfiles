eval "$(/opt/homebrew/bin/brew shellenv)"

export BREW_PREFIX="$(brew --prefix)"

export GREP_OPTIONS=--color=auto
export UPNGO_ROOT=/Users/scott/src/upngo
export WEBBERROBOTS_ROOT=/Users/scott/src/webberrobots
export HOMEBREW_CASK_OPTS="--appdir=/Applications"
#export HOMEBREW_GITHUB_API_TOKEN=4795866357eb661ee569456ac20de89bcac2e832
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

# export JAVA6_HOME=$(/usr/libexec/java_home -v 1.6)
# export JAVA7_HOME=$(/usr/libexec/java_home -v 1.7)
# export JAVA8_HOME=$(/usr/libexec/java_home -v 1.8)
# export JAVA_HOME=$JAVA8_HOME
export ANDROID_HOME=/Users/scott/src/android-sdk-macosx

export PYTHONDONTWRITEBYTECODE=1
# bun
export BUN_INSTALL="$HOME/.bun"

export LIBRARY_PATH="$LIBRARY_PATH:$BREW_PREFIX/lib"

export CURL_PROXY=
export CLAUDE_CODE_TMPDIR=/tmp/claude-swebber
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
export DEFAULT_PYTEST_OPTS=-n3
export MAX_OLD_SPACE_SIZE=6144

if [[ $TERM_PROGRAM != "WarpTerminal" ]]; then
  ##### WHAT YOU WANT TO DISABLE FOR WARP - BELOW
  ##### WHAT YOU WANT TO DISABLE FOR WARP - ABOVE
fi

# if command -v pyenv 1>/dev/null 2>&1; then
#   eval "$(pyenv init --path)"
#   eval "$(pyenv init -)"
# fi
# if which pyenv-virtualenv-init > /dev/null; then
#   eval "$(pyenv virtualenv-init -)"
# fi

# export NVM_DIR="$HOME/.nvm"
# [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"  # This loads nvm

# source <(kubectl completion bash)

FPATH="$BREW_PREFIX/share/zsh/site-functions:${FPATH}"

# complete -C '/usr/local/bin/aws_completer' aws

. "$HOME/.cargo/env"

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"
export BROWSER="$HOME/bin/safari-open"

export EDITOR="NVIM_APPNAME=lazyvim /opt/homebrew/bin/nvim"
export SVN_EDITOR="NVIM_APPNAME=lazyvim /opt/homebrew/bin/nvim"
export LSCOLORS=ExGxFxdaCxDaDahbadacec

# fzf: ayu palette — entity-blue pointer, blue-tinted full-width highlight, and
# no bold on the current row.
#
# The gutter is blanked rather than coloured. fzf draws it as a solid '▌' rail
# down the left of every row, and the only lever on its appearance is a
# foreground colour -- so any setting that hides it has to paint it, which would
# punch an opaque stripe through this window's transparency and blur. A space
# has nothing to paint, so the desktop shows through as it should.
#
# Nothing is lost by dropping it: the gutter column exists to host the pointer
# on the current line, and --highlight-line with bg+ already marks that row
# across its full width. The pointer itself is unaffected -- it is a separate
# glyph and still renders on the current row.
#
# This became necessary at fzf 0.74. Earlier versions drew the gutter as a
# background-only column, where the previous gutter:-1 ("terminal default")
# correctly meant invisible; 0.74 draws a foreground glyph, so -1 started
# rendering the rail in normal text colour on every row.
export FZF_DEFAULT_OPTS="--highlight-line --gutter=' ' --color=fg+:regular,hl:#ffb454,hl+:regular:#ffb454,current-fg:regular,pointer:#59C2FF,prompt:#59C2FF,bg+:#112034"

ZSH_TMUX_AUTOSTART=true
ZSH_TMUX_DEFAULT_SESSION_NAME=default

. "$HOME/dotfiles/zsh/private.env"

# Do not share history between tmux panes / sessions
setopt nosharehistory

alias assume=". assume"
