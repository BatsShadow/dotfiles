eval "$(/opt/homebrew/bin/brew shellenv)"

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
export PATH=$HOME/bin:$ANDROID_HOME/platform-tools:$HOME/.node/bin:$PATH

export PYTHONDONTWRITEBYTECODE=1

export PATH="/usr/local/sbin:$PATH"
export PATH="/usr/local/opt/gnu-tar/libexec/gnubin:$PATH"
export PATH="/Applications/WebStorm.app/Contents/MacOS:$PATH"
#export PATH="/usr/local/opt/openjdk@8/bin:$PATH"
#export PATH="/Applications/VMware Fusion.app/Contents/Library/VMware OVF Tool:$PATH"
#export PATH="/Users/scott/src/oss/flutter/bin:$PATH"

export LIBRARY_PATH="$LIBRARY_PATH:$(brew --prefix)/lib"

export CURL_PROXY=
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

FPATH="$(brew --prefix)/share/zsh/site-functions:${FPATH}"

# complete -C '/usr/local/bin/aws_completer' aws

. "$HOME/.cargo/env"

#export PATH="/opt/homebrew/opt/openjdk@11/bin:$PATH"

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

export EDITOR=/opt/homebrew/bin/nvim
export SVN_EDITOR=/opt/homebrew/bin/nvim
export LSCOLORS=ExGxFxdaCxDaDahbadacec

ZSH_TMUX_AUTOSTART=true
ZSH_TMUX_DEFAULT_SESSION_NAME=default
