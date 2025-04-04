
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
    alias ls="eza --icons --classify"
    alias ll="eza -1l --icons --classify --git"
    alias la="eza -1la --icons --classify --git"
    alias lt="eza -1la --icons --classify --git --tree --level=3"
fi

alias vi="NVIM_APPNAME=lazyvim nvim"

alias envwebberrobots="source ~/src/env/webberrobots_start;cd ~/src/webberrobots"
alias cdupngo="cd ~/src/upngo/upngo-web"

alias kc='kubectl'
alias kl='kubectl config get-contexts'
alias ku='kubectl config use-context'
alias kcu='export KUBECONFIG="$(for c in ~/.kube/config ~/.kube/*.kubeconfig; do echo -n ${sep-}$c; sep=:; done)"'

alias prune="docker system prune --volumes -f"
alias dc="docker compose"
alias build='./build.sh'
alias start='./start.sh'
alias stop='./stop.sh'
alias test-api='./run_api_tests.sh'
alias test-admin='./run_admin_tests.sh'
alias test-control-panel='./run_admin_tests.sh'
alias test-web='./run_web_tests.sh'
alias test-menu='./run_menu_tests.sh'
alias test-ng-shared='./run_ng-shared_tests.sh'
alias test-frontend='./run_ng-shared_tests.sh && ./run_admin_tests.sh && ./run_web_tests.sh && ./run_menu_tests.sh'
alias tests='./stop.sh && ./run_api_tests.sh && ./run_ng-shared_tests.sh && ./run_admin_tests.sh && ./run_web_tests.sh && ./run_menu_tests.sh'
alias ktm-report="cdupngo && cd tools/ktm-error-auto && DB_USER=${SWEBBER_DBUSER} DB_PASS=${SWEBBER_DBPASS} ALOHA_AUTH=${REAL_ALOHA_AUTH} npx ts-node index.ts"
alias order-snapshot="cdupngo && cd tools/pull-json-api-order && DB_USER=${SWEBBER_DBUSER} DB_PASS=${SWEBBER_DBPASS} npx ts-node index.ts"
alias dev-order-snapshot="cdupngo && cd tools/pull-json-api-order && DB_ENV=dev DB_USER=${DEV_DBUSER} DB_PASS=${DEV_DBPASS} npx ts-node index.ts"
alias export-creds='~/src/upngo/upngo-web/tools/export-creds.sh'
alias clean-release-branches="git br | rg '(beta|prod)-release' | xargs git br -d"

eval "$(zoxide init zsh)"

# fnm
FNM_PATH="/home/scott/.local/share/fnm"
if [ -d "$FNM_PATH" ]; then
  export PATH="/home/scott/.local/share/fnm:$PATH"
  eval "`fnm env`"
fi
