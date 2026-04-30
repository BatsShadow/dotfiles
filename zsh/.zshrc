
# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

bindkey -v

# Set personal aliases, overriding those provided by oh-my-zsh libs,
# plugins, and themes. Aliases can be placed here, though oh-my-zsh
# users are encouraged to define aliases within the ZSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.

alias ll="ls -laG"
alias ls="ls -G"

# if [ -x "$(command -v colorls)" ]; then
#     alias ls="colorls"
#     alias ll="colorls -laG"
#     alias ls="colorls -G"
# fi
if [ -x "$(command -v eza)" ]; then
    # Disable eza's built-in bold styling so output uses normal terminal weight
    # Filenames in ayu-dark func orange (#FFB454) to mirror vim oil styling; icons keep their per-type colors
    export EZA_COLORS="reset:di=38;2;255;180;84:ex=38;2;255;180;84:fi=38;2;255;180;84:ln=38;2;255;180;84:pi=33:so=35:bd=33:cd=33:or=31:mi=31:ur=33:uw=31:ux=32:ue=32:gr=33:gw=31:gx=32:tr=33:tw=31:tx=32:su=32:sf=32:df=33:ds=33:uu=33:un=37:gu=33:gn=37:ga=32:gm=33:gd=31:gv=35:gt=33:da=34:lc=37:lm=37:xx=37:in=37"
    alias ls="eza --icons --classify"
    alias ll="eza -1l --icons --classify --git"
    alias la="eza -1la --icons --classify --git"
    alias lt="eza -1la --icons --classify --git --tree --level=3"
fi

alias vi="NVIM_APPNAME=lazyvim nvim"

alias envwebberrobots="source ~/src/env/webberrobots_start;cd ~/src/webberrobots"
alias cdu="cd ~/src/upngo/upngo-web/"
alias cdw="cd ~/src/upngo/worktrees"

alias cl=claude --enable-auto-mode

alias kc='kubectl'
alias kl='kubectl config get-contexts'
alias ku='kubectl config use-context'
alias kcu='export KUBECONFIG="$(for c in ~/.kube/config ~/.kube/*.kubeconfig; do echo -n ${sep-}$c; sep=:; done)"'

alias prune="docker system prune --volumes -f"
alias dc="docker compose"
alias build='./build.sh'
alias build-fresh='tools/build-local-base-images.sh && build'
alias start='./start.sh'
alias stop='./stop.sh'
alias test-api='./run_api_tests.sh'
alias test-admin='./run_admin_tests.sh'
alias test-control-panel='./run_admin_tests.sh'
alias test-web='./run_web_tests.sh'
alias test-menu='./run_menu_tests.sh'
alias test-ng-shared='./run_ng-shared_tests.sh'
alias test-frontend='./run_ng-shared_tests.sh && ./run_admin_tests.sh && ./run_web_tests.sh && ./run_menu_tests.sh'
alias tests='./stop.sh && ./run_ng-shared_tests.sh && ./run_admin_tests.sh && ./run_web_tests.sh && ./run_menu_tests.sh && ./run_api_tests.sh'

alias b=build
alias ta=test-api
alias tf=test-frontend
alias t=tests

alias ktm-report="cdupngo && cd tools/ktm-error-auto && DB_USER=${SWEBBER_DBUSER} DB_PASS=${SWEBBER_DBPASS} ALOHA_AUTH=${REAL_ALOHA_AUTH} npx ts-node index.ts"
alias order-snapshot="cdupngo && cd tools/pull-json-api-order && DB_USER=${SWEBBER_DBUSER} DB_PASS=${SWEBBER_DBPASS} npx ts-node index.ts"
alias dev-order-snapshot="cdupngo && cd tools/pull-json-api-order && DB_ENV=dev DB_USER=${DEV_DBUSER} DB_PASS=${DEV_DBPASS} npx ts-node index.ts"
alias export-creds='~/src/upngo/upngo-web/tools/export-creds.sh'
alias clean-release-branches="git br | rg '(beta|prod)-release' | xargs git br -d"

# Auto-start tmux with last session
if [[ -z "$TMUX" ]] && command -v tmux &>/dev/null; then
    last=$(cat ~/.config/tmux/.last-session 2>/dev/null)
    if [[ -n "$last" ]]; then
        exec ~/.config/tmux/sessionizer.sh "$last"
    else
        exec tmux new-session
    fi
fi

eval "$(zoxide init zsh)"
eval "$(but completions zsh)"
