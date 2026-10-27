#!/usr/bin/env bash
# jupyter-for-share: 管理コマンド (Linux)。使い方: ./jfs.sh help
# 管理者の権限が必要なコマンドは、自動で sudo して実行し直します。
# Everything runs inside main(), which bash reads completely before running it,
# so the server window's automatic "git pull" can update this file while it is running.
main() {
    local here py
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    py="$(command -v python3 || true)"
    if [ -z "$py" ]; then
        echo "[x] python3 が見つかりません。先に 'sudo ./setup.sh' を実行してください。" >&2
        return 1
    fi
    case "${1:-help}" in
        help|-h|-help|--help|-\?|version)
            exec "$py" "$here/scripts/jfs_linux.py" "$@" ;;
    esac
    if [ "$(id -u)" -ne 0 ]; then
        # プロキシの設定などは引き継ぐ (pip install などに必要なことがある)
        exec sudo --preserve-env=http_proxy,https_proxy,no_proxy,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,ALL_PROXY,PIP_INDEX_URL,PIP_EXTRA_INDEX_URL,PIP_TRUSTED_HOST,PIP_CERT,SSL_CERT_FILE,REQUESTS_CA_BUNDLE,LANG \
            "$py" "$here/scripts/jfs_linux.py" "$@"
    fi
    exec "$py" "$here/scripts/jfs_linux.py" "$@"
}
main "$@"; exit $?
