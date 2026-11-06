# awesoMux SSH terminal identity helper. Run as: /bin/sh awesomux-ssh [ssh args]
#
#   awesomux-ssh [--portable] <ssh args>      ssh with the right remote TERM
#   awesomux-ssh --setup-terminfo [--force] <ssh options> <destination>
#   awesomux-ssh --forget <ssh options> <destination>
#
# Hosts listed in the cache keep xterm-ghostty; every other host, and any
# failure, gets xterm-256color. Other TERMs pass through unless --portable
# (SSH workspaces) asks for xterm-256color. Nothing is written remotely
# without a "y".

cache=${AWESOMUX_SSH_TERMINFO_HOSTS:-"$HOME/Library/Application Support/awesoMux/ssh-terminfo-hosts"}
marker=AWESOMUX-TERMINFO

destination_key() {
    ssh -G "$@" 2>/dev/null | awk '
        $1 == "user" { user = $2 }
        $1 == "hostname" { host = $2 }
        $1 == "port" { port = $2 }
        END { if (user == "" || host == "" || port == "") exit 1; print user "@" host ":" port }'
}

run() {
    portable=$1
    shift
    if [ "${TERM-}" = xterm-ghostty ]; then
        # Never resolve the destination before a host has been set up: ssh -G
        # reruns Match exec and may look up DNS.
        if ! { grep -q . "$cache" 2>/dev/null && key=$(destination_key "$@") && grep -Fqx -- "$key" "$cache"; }; then
            TERM=xterm-256color
            export TERM
        fi
    elif [ "$portable" = 1 ]; then
        TERM=xterm-256color
        export TERM
    fi
    exec ssh "$@"
}

local_definition() {
    resources=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)
    if [ -n "$resources" ] && [ -f "$resources/terminfo/78/xterm-ghostty" ]; then
        TERMINFO="$resources/terminfo" infocmp -x xterm-ghostty
    else
        infocmp -x xterm-ghostty
    fi
}

# Read by the remote `sh` on stdin, so the remote login shell never parses it.
remote_script() {
    printf 'force=%s\n' "$1"
    cat <<'SCRIPT'
found() {
    if command -v infocmp >/dev/null 2>&1; then
        infocmp xterm-ghostty >/dev/null 2>&1
    else
        [ -e "$HOME/.terminfo/x/xterm-ghostty" ] || [ -e "$HOME/.terminfo/78/xterm-ghostty" ]
    fi
}
if [ "$force" = 0 ] && found; then echo AWESOMUX-TERMINFO:present; exit 0; fi
command -v tic >/dev/null 2>&1 || { echo AWESOMUX-TERMINFO:no-tic; exit 0; }
tmp=$(mktemp "${TMPDIR:-/tmp}/awesomux-terminfo.XXXXXX") || { echo AWESOMUX-TERMINFO:no-temp-file; exit 0; }
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'AWESOMUX_TERMINFO_END'
SCRIPT
    printf '%s\n' "$2"
    cat <<'SCRIPT'
AWESOMUX_TERMINFO_END
mkdir -p "$HOME/.terminfo" && tic -x -o "$HOME/.terminfo" "$tmp" >/dev/null 2>&1 \
    || { echo AWESOMUX-TERMINFO:not-writable; exit 0; }
if found; then echo AWESOMUX-TERMINFO:installed; else echo AWESOMUX-TERMINFO:not-visible; fi
SCRIPT
}

remember() {
    grep -Fqx -- "$1" "$cache" 2>/dev/null && return 0
    mkdir -p "$(dirname "$cache")" || return 1
    # A hand-edited file may lack its final newline; don't merge two keys.
    if [ -s "$cache" ] && [ -n "$(tail -c 1 "$cache")" ]; then echo >> "$cache" || return 1; fi
    printf '%s\n' "$1" >> "$cache"
}

forget() {
    key=$(destination_key "$@") || { echo "awesomux-ssh: could not resolve the destination with ssh -G" >&2; return 2; }
    if ! grep -Fqx -- "$key" "$cache" 2>/dev/null; then
        echo "$key was not set up; it already uses xterm-256color."
        return 0
    fi
    tmp=$(mktemp "$cache.XXXXXX") || { echo "awesomux-ssh: could not update $cache" >&2; return 1; }
    grep -Fvx -- "$key" "$cache" > "$tmp"
    # grep exits 1 when no lines remain, which is still a valid result.
    if [ $? -le 1 ] && mv "$tmp" "$cache"; then
        echo "Forgot $key; new connections use xterm-256color."
    else
        rm -f "$tmp"
        echo "awesomux-ssh: could not update $cache" >&2
        return 1
    fi
}

setup() {
    force=0
    if [ "${1-}" = --force ]; then force=1; shift; fi
    key=$(destination_key "$@") || { echo "awesomux-ssh: could not resolve the destination with ssh -G" >&2; return 2; }
    definition=$(local_definition) || { echo "awesomux-ssh: the bundled xterm-ghostty definition is unavailable" >&2; return 1; }
    echo "Set up the xterm-ghostty terminal definition on $key?"
    echo "This connects once and, if the definition is missing, writes it to ~/.terminfo"
    echo "for your user on that host. No admin rights are needed."
    [ "$force" = 1 ] && echo "--force replaces an existing copy in ~/.terminfo."
    printf 'Continue? [y/N] '
    answer=
    read -r answer < /dev/tty 2>/dev/null || answer=
    case "$answer" in
        y | Y | yes | YES | Yes) ;;
        *) echo "Skipped. $key keeps using xterm-256color."; return 1 ;;
    esac
    output=$(remote_script "$force" "$definition" | TERM=xterm-256color ssh -T "$@" sh)
    status=$?
    result=$(printf '%s\n' "$output" | tr -d '\r' | sed -n "s/^$marker:\([a-z-]*\)\$/\1/p" | tail -n 1)
    case "$result" in
        present | installed)
            remember "$key" || { echo "awesomux-ssh: could not update $cache" >&2; return 1; }
            echo "xterm-ghostty is $result on $key. New connections will use it." ;;
        no-tic) echo "$key has no tic command, so it keeps using xterm-256color."; return 1 ;;
        not-writable) echo "Could not write ~/.terminfo on $key, so it keeps using xterm-256color."; return 1 ;;
        not-visible) echo "The definition was written but $key cannot find it, so it keeps using xterm-256color."; return 1 ;;
        no-temp-file) echo "Could not create a temporary file on $key, so it keeps using xterm-256color."; return 1 ;;
        *) echo "Setup did not finish (ssh exit $status). $key keeps using xterm-256color."; return 1 ;;
    esac
}

case "${1-}" in
    --setup-terminfo) shift; setup "$@" ;;
    --forget) shift; forget "$@" ;;
    --portable) shift; run 1 "$@" ;;
    *) run 0 "$@" ;;
esac
