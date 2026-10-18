# Keep the local terminal identity; only ordinary SSH gets the compatibility TERM.
_awesomux_ssh_compat() {
    'builtin' 'emulate' -L zsh -o no_aliases
    if [[ $TERM == xterm-ghostty ]]; then
        TERM=xterm-256color 'command' ssh "$@"
    else
        'command' ssh "$@"
    fi
}

_awesomux_ssh_compat_install() {
    'builtin' 'emulate' -L zsh -o no_aliases
    precmd_functions=(${precmd_functions:#_awesomux_ssh_compat_install})
    # Wait until user startup files have defined their aliases and functions.
    if (( ! $+functions[ssh] && ! $+aliases[ssh] )); then
        'builtin' functions -c _awesomux_ssh_compat ssh
    fi
    'builtin' unfunction _awesomux_ssh_compat_install
    return 0
}

if [[ -o interactive ]]; then
    'builtin' typeset -ga precmd_functions
    (( ${precmd_functions[(Ie)_awesomux_ssh_compat_install]} )) || precmd_functions+=(_awesomux_ssh_compat_install)
fi
