if status is-interactive
    set --global _awesomux_ssh_helper "$GHOSTTY_RESOURCES_DIR/shell-integration/awesomux-ssh"

    function awesomux-ssh --description 'awesoMux SSH helper; see --setup-terminfo'
        /bin/sh $_awesomux_ssh_helper $argv
    end

    function _awesomux_ssh_compat_install --on-event fish_prompt
        functions --erase _awesomux_ssh_compat_install
        # `type` also discovers user functions that have not been autoloaded yet.
        if test (type --type ssh) = function
            return
        end
        function ssh --wraps ssh --description 'SSH with a compatible remote terminal identity'
            if test "$TERM" = xterm-ghostty; and test -r $_awesomux_ssh_helper
                /bin/sh $_awesomux_ssh_helper $argv
            else if test "$TERM" = xterm-ghostty
                set --local --export TERM xterm-256color
                command ssh $argv
            else
                command ssh $argv
            end
        end
    end
end
