if status is-interactive
    function _awesomux_ssh_compat_install --on-event fish_prompt
        functions --erase _awesomux_ssh_compat_install
        # `type` also discovers user functions that have not been autoloaded yet.
        if test (type --type ssh) = function
            return
        end
        function ssh --wraps ssh --description 'SSH with a compatible remote terminal identity'
            if test "$TERM" = xterm-ghostty
                set --local --export TERM xterm-256color
                command ssh $argv
            else
                command ssh $argv
            end
        end
    end
end
