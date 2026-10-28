# jupyter-for-share: JupyterLab のターミナル (PowerShell) で実行したコマンドを .logs\commands.log に記録する。
# jfs.cmd が各ユーザー環境の .server\config にコピーし、ターミナル起動時に読み込まれる。
#
# プロンプトを表示するたびに、このターミナルで直前に実行したコマンド (Get-History) を記録する。
# (PSReadLine の AddToHistoryHandler は、起動時に過去の履歴を読み込むときにも呼ばれ、
#  過去のコマンドがすべて記録し直されてしまうため使わない)
if ($env:JFS_COMMAND_LOG) {
    $global:JfsCommandLog = $env:JFS_COMMAND_LOG
    $global:JfsLastHistoryId = 0
    $global:JfsOriginalPrompt = $function:prompt
    function global:prompt {
        try {
            $h = Get-History -Count 1
            if ($h -and $h.Id -ne $global:JfsLastHistoryId) {
                $global:JfsLastHistoryId = $h.Id
                $text = '{0} [terminal] {1}' -f $h.StartExecutionTime.ToString('yyyy-MM-dd HH:mm:ss'),
                    ($h.CommandLine -replace "`r?`n", "`n    ")
                [System.IO.File]::AppendAllText($global:JfsCommandLog, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
            }
        } catch { }
        if ($global:JfsOriginalPrompt) { & $global:JfsOriginalPrompt } else { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
    }
}
