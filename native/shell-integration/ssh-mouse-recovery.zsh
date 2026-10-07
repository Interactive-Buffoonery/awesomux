# awesoMux local zsh prompts use terminal selection after direct SSH exits.
_awesomux_ssh_mouse_recovery_init() {
    builtin emulate -L zsh -o no_aliases
    [[ -o interactive ]] || return 0
    (( $+functions[_awesomux_ssh_mouse_recovery_preexec] )) && return 0
    builtin zmodload zsh/parameter || return 0
    builtin typeset -gi _awesomux_ssh_mouse_recovery_pending=0
    builtin typeset -ga _awesomux_ssh_mouse_recovery_prior_pids
    _awesomux_ssh_mouse_recovery_prior_pids=()
    builtin typeset -gA _awesomux_ssh_mouse_recovery_jobs
    _awesomux_ssh_mouse_recovery_jobs=()

    _awesomux_ssh_mouse_recovery_preexec() {
        builtin emulate -L zsh -o no_aliases
        _awesomux_ssh_mouse_recovery_pending=0
        (( ZSH_SUBSHELL == 0 )) || return 0
        builtin local -a words
        words=(${(z)2})
        [[ $words[1] == ssh || $words[1] == /usr/bin/ssh ]] || return 0
        [[ $words[1] == ssh ]] && (( $+functions[ssh] )) && return 0
        builtin local word
        for word in "${words[@]}"; do
            case "$word" in
                ';'|'&'|'&|'|'&&'|'||'|'|'|'|&'|'('|')'|'{'|'}'|$'\n') return 0 ;;
            esac
        done
        _awesomux_ssh_mouse_recovery_prior_pids=()
        builtin local state process
        for state in "${(@v)jobstates}"; do
            process=${state##*:}
            _awesomux_ssh_mouse_recovery_prior_pids+=(${process%%=*})
        done
        _awesomux_ssh_mouse_recovery_pending=1
        return 0
    }

    _awesomux_ssh_mouse_recovery_precmd() {
        builtin emulate -L zsh -o no_aliases
        (( _awesomux_ssh_mouse_recovery_pending || ${#_awesomux_ssh_mouse_recovery_jobs} )) || return 0
        [[ -t 1 ]] || return 0
        builtin local -i cleanup=$_awesomux_ssh_mouse_recovery_pending live=0
        builtin local job state process
        builtin local -a words
        for job in "${(@k)_awesomux_ssh_mouse_recovery_jobs}"; do
            state=${jobstates[$job]-}
            process=${state##*:}
            if [[ $state == (running|suspended):* && ${process%%=*} == ${_awesomux_ssh_mouse_recovery_jobs[$job]} ]]; then
                live=1
            else
                builtin unset "_awesomux_ssh_mouse_recovery_jobs[$job]"
                cleanup=1
            fi
        done
        if (( _awesomux_ssh_mouse_recovery_pending )); then
            for job in "${(@k)jobstates}"; do
                state=${jobstates[$job]}
                [[ $state == suspended:* ]] || continue
                process=${state##*:}
                process=${process%%=*}
                (( ${_awesomux_ssh_mouse_recovery_prior_pids[(Ie)$process]} )) && continue
                words=(${(z)jobtexts[$job]})
                [[ $words[1] == ssh || $words[1] == /usr/bin/ssh ]] || continue
                # The newly stopped direct SSH job retains its modes through fg.
                _awesomux_ssh_mouse_recovery_jobs[$job]=$process
                live=1
            done
            _awesomux_ssh_mouse_recovery_pending=0
        fi
        if (( cleanup && !live )); then
            # PTY output restores both parsers before the next command starts.
            builtin printf '\033[?9l\033[?1000l\033[?1002l\033[?1003l\033[?1005l\033[?1006l\033[?1015l\033[?1016l'
        fi
        return 0
    }

    builtin typeset -ga preexec_functions precmd_functions
    preexec_functions+=(_awesomux_ssh_mouse_recovery_preexec)
    precmd_functions+=(_awesomux_ssh_mouse_recovery_precmd)
}
_awesomux_ssh_mouse_recovery_init
builtin unfunction _awesomux_ssh_mouse_recovery_init
