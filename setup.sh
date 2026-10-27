#!/usr/bin/env bash
# jupyter-for-share: サーバーのセットアップ (Linux)。
#   ./setup.sh [-Domain 名前] [-SkipMonitor] [-Port リソースモニターのポート]
# 最初に git pull で最新版にしてから、管理者の権限 (sudo) でセットアップします。何度実行しても問題ありません。
# Everything runs inside main(), which bash reads completely before running it,
# so "git pull" can safely update this file while it is running.
main() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 1. 最新版にする (リポジトリを clone した人のアカウントで実行する)
    if [ -d "$here/.git" ] && command -v git >/dev/null 2>&1; then
        echo "[*] Updating jupyter-for-share: git pull"
        local pull=(git -c safe.directory='*' -C "$here" pull --ff-only)
        if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            pull=(sudo -u "$SUDO_USER" "${pull[@]}")
        fi
        if ! "${pull[@]}"; then
            echo
            echo "[!] git pull FAILED. The scripts were NOT updated - setup will run the OLD version."
            echo "[!] Check the message above, fix it, and run setup.sh again."
            read -r -p "[!] Press Enter to continue with the old version anyway, or Ctrl+C to stop. " _
        fi
    fi

    # 2. python3 がなければ入れる (セットアップの本体は Python で書かれているため)
    local sudo=()
    [ "$(id -u)" -ne 0 ] && sudo=(sudo)
    if ! command -v python3 >/dev/null 2>&1; then
        echo "[*] python3 が見つかりません。インストールします。"
        if command -v apt-get >/dev/null 2>&1; then
            "${sudo[@]}" apt-get update && "${sudo[@]}" apt-get install -y python3 python3-venv python3-pip || return 1
        elif command -v dnf >/dev/null 2>&1; then
            "${sudo[@]}" dnf install -y python3 python3-pip || return 1
        else
            echo "[x] python3 (3.9 以上) を手動でインストールしてから、もう一度実行してください。" >&2
            return 1
        fi
    fi

    # 3. セットアップ本体
    exec "$here/jfs.sh" setup "$@"
}
main "$@"; exit $?
