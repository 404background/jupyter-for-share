#!/usr/bin/env bash
# jupyter-for-share: この PC に加えた変更をすべて元に戻す (Linux)。
# サーバーを止め、実行用アカウント・グループ・ファイアウォール規則を削除します。
# ユーザーのフォルダ (user/) は残します。-DeleteFiles を付けると user フォルダも削除します。
main() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec "$here/jfs.sh" uninstall "$@"
}
main "$@"; exit $?
