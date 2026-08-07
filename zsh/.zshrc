
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
    # Ayu-dark palette: distinct color per filetype + per-extension category.
    # Base types: di=blue ex=green fi=fg ln=cyan pi=warm-yellow so=purple bd=gold cd=orange or/mi=red
    # Extensions: source=white docs=fg config=yellow images=func-orange jpg=pink media=purple archives=orange web=cyan logs=gray
    export EZA_COLORS="di=38;2;89;194;255:ex=38;2;170;217;76:fi=38;2;191;189;182:ln=38;2;149;230;203:pi=38;2;230;182;115:so=38;2;210;166;255:bd=38;2;230;180;80:cd=38;2;255;180;84:or=38;2;240;113;120:mi=38;2;217;87;87:ur=38;2;230;180;80:uw=38;2;255;143;64:ux=38;2;170;217;76:ue=38;2;170;217;76:gr=38;2;230;180;80:gw=38;2;255;143;64:gx=38;2;170;217;76:tr=38;2;230;180;80:tw=38;2;255;143;64:tx=38;2;170;217;76:su=38;2;217;87;87:sf=38;2;217;87;87:sn=38;2;191;189;182:sb=38;2;230;180;80:df=38;2;230;180;80:ds=38;2;230;180;80:uu=38;2;230;180;80:un=38;2;172;182;191:gu=38;2;230;180;80:gn=38;2;172;182;191:ga=38;2;170;217;76:gm=38;2;230;180;80:gd=38;2;240;113;120:gv=38;2;210;166;255:gt=38;2;255;180;84:da=38;2;89;194;255:lc=38;2;172;182;191:lm=38;2;172;182;191:xx=38;2;172;182;191:in=38;2;172;182;191:*.ts=38;2;255;255;255:*.tsx=38;2;255;255;255:*.js=38;2;255;255;255:*.jsx=38;2;255;255;255:*.mjs=38;2;255;255;255:*.cjs=38;2;255;255;255:*.py=38;2;255;255;255:*.rs=38;2;255;255;255:*.go=38;2;255;255;255:*.c=38;2;255;255;255:*.cpp=38;2;255;255;255:*.cc=38;2;255;255;255:*.cxx=38;2;255;255;255:*.h=38;2;255;255;255:*.hpp=38;2;255;255;255:*.java=38;2;255;255;255:*.kt=38;2;255;255;255:*.rb=38;2;255;255;255:*.php=38;2;255;255;255:*.lua=38;2;255;255;255:*.sh=38;2;255;255;255:*.zsh=38;2;255;255;255:*.bash=38;2;255;255;255:*.fish=38;2;255;255;255:*.vim=38;2;255;255;255:*.swift=38;2;255;255;255:*.scala=38;2;255;255;255:*.clj=38;2;255;255;255:*.ex=38;2;255;255;255:*.exs=38;2;255;255;255:*.erl=38;2;255;255;255:*.hs=38;2;255;255;255:*.ml=38;2;255;255;255:*.dart=38;2;255;255;255:*.zig=38;2;255;255;255:*.vue=38;2;255;255;255:*.svelte=38;2;255;255;255:*.md=38;2;191;189;182:*.markdown=38;2;191;189;182:*.txt=38;2;191;189;182:*.rst=38;2;191;189;182:*.org=38;2;191;189;182:*.tex=38;2;191;189;182:*.pdf=38;2;191;189;182:*.json=38;2;230;182;115:*.yaml=38;2;230;182;115:*.yml=38;2;230;182;115:*.toml=38;2;230;182;115:*.ini=38;2;230;182;115:*.conf=38;2;230;182;115:*.config=38;2;230;182;115:*.cfg=38;2;230;182;115:*.env=38;2;230;182;115:*.png=38;2;255;180;84:*.jpg=38;2;240;113;120:*.jpeg=38;2;240;113;120:*.gif=38;2;255;180;84:*.bmp=38;2;255;180;84:*.tiff=38;2;255;180;84:*.webp=38;2;255;180;84:*.ico=38;2;255;180;84:*.heic=38;2;255;180;84:*.mp3=38;2;210;166;255:*.wav=38;2;210;166;255:*.flac=38;2;210;166;255:*.ogg=38;2;210;166;255:*.m4a=38;2;210;166;255:*.aac=38;2;210;166;255:*.mp4=38;2;210;166;255:*.mkv=38;2;210;166;255:*.mov=38;2;210;166;255:*.avi=38;2;210;166;255:*.webm=38;2;210;166;255:*.zip=38;2;255;143;64:*.tar=38;2;255;143;64:*.gz=38;2;255;143;64:*.tgz=38;2;255;143;64:*.bz2=38;2;255;143;64:*.xz=38;2;255;143;64:*.7z=38;2;255;143;64:*.rar=38;2;255;143;64:*.zst=38;2;255;143;64:*.html=38;2;149;230;203:*.htm=38;2;149;230;203:*.css=38;2;149;230;203:*.scss=38;2;149;230;203:*.sass=38;2;149;230;203:*.less=38;2;149;230;203:*.svg=38;2;255;180;84:*.xml=38;2;149;230;203:*.log=38;2;86;91;102:*.lock=38;2;86;91;102:*.tmp=38;2;86;91;102:*.bak=38;2;86;91;102:*.swp=38;2;86;91;102"
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

# Report a window the status bar called wrong -- amber when nothing was waiting,
# or grey when Claude had asked something. See claude/.claude/hooks/.
alias ccwrong="~/.config/tmux/waiting-report.sh"
alias ccwrongs="~/.config/tmux/waiting-report.sh --tally"

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
alias taf='test-api -f'

alias ktm-report="cdupngo && cd tools/ktm-error-auto && DB_USER=${SWEBBER_DBUSER} DB_PASS=${SWEBBER_DBPASS} ALOHA_AUTH=${REAL_ALOHA_AUTH} npx ts-node index.ts"
alias order-snapshot="cdupngo && cd tools/pull-json-api-order && DB_USER=${SWEBBER_DBUSER} DB_PASS=${SWEBBER_DBPASS} npx ts-node index.ts"
alias dev-order-snapshot="cdupngo && cd tools/pull-json-api-order && DB_ENV=dev DB_USER=${DEV_DBUSER} DB_PASS=${DEV_DBPASS} npx ts-node index.ts"
alias export-creds='~/src/upngo/upngo-web/tools/export-creds.sh'
alias clean-release-branches="git br | rg '(beta|prod)-release' | xargs git br -d"

alias voyager-flash='zapp flash https://configure.zsa.io/voyager/layouts/MRxjr/pjBzjW/0'

# Recover when Finder shows "application is not open anymore" and apps won't launch.
# Escalates: restart Finder/Dock → rebuild LaunchServices DB → nuke launchservicesd.
fix-launchservices() {
    local lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
    case "$1" in
        ""|finder)
            echo "Restarting Finder and Dock..."
            killall Finder Dock
            ;;
        rebuild)
            echo "Rebuilding LaunchServices database (30-60s)..."
            "$lsregister" -kill -r -domain local -domain system -domain user
            killall Finder Dock
            ;;
        nuke)
            echo "Killing launchservicesd (requires sudo)..."
            sudo killall -9 launchservicesd && killall Finder Dock
            ;;
        *)
            echo "Usage: fix-launchservices [finder|rebuild|nuke]"
            echo "  finder  (default) restart Finder + Dock"
            echo "  rebuild rebuild LaunchServices DB, then restart Finder + Dock"
            echo "  nuke    kill launchservicesd, then restart Finder + Dock"
            return 1
            ;;
    esac
}

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
