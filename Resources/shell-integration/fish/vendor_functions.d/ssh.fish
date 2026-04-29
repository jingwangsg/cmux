function ssh --wraps ssh
    if test "$CMUX_SSH_UPGRADE_INTERACTIVE" = 1
        and test -n "$CMUX_WORKSPACE_ID"
        and test -n "$CMUX_PANEL_ID"
        set -l cmux_cli "$CMUX_BUNDLED_CLI_PATH"
        if test -z "$cmux_cli"; or not test -x "$cmux_cli"
            set cmux_cli (command -v cmux 2>/dev/null)
        end
        if test -n "$cmux_cli"
            command "$cmux_cli" ssh-exec $argv
            return $status
        end
    end

    command ssh $argv
end
