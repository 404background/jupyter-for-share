# jupyter-for-share: JupyterLab のターミナル (bash) で実行したコマンドを .logs/commands.log に記録する。
# jfs.sh が各ユーザー環境の .server にコピーし、ターミナル起動時に読み込まれる (Linux 用)。
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f /etc/bashrc ] && . /etc/bashrc
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
export HISTFILE="$HOME/.bash_history"
PS1='(venv) \[\e[32m\]\u\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '

if [ -n "$JFS_COMMAND_LOG" ]; then
    __jfs_last="$(HISTTIMEFORMAT= builtin history 1)"
    __jfs_log() {
        local h c
        h="$(HISTTIMEFORMAT= builtin history 1)"
        { [ -z "$h" ] || [ "$h" = "$__jfs_last" ]; } && return
        __jfs_last="$h"
        c="$(printf '%s' "$h" | sed -E '1s/^ *[0-9]+\*? *//')"
        printf '%s [terminal] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${c//$'\n'/$'\n    '}" >> "$JFS_COMMAND_LOG" 2>/dev/null
    }
    PROMPT_COMMAND="__jfs_log${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
