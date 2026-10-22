# jupyter-for-share: JupyterLab のターミナル (PowerShell) で実行したコマンドを .logs\commands.log に記録する。
# jfs.cmd が各ユーザー環境の .server\config にコピーし、ターミナル起動時に読み込まれる。
if ($env:JFS_COMMAND_LOG) {
    $global:JfsCommandLog = $env:JFS_COMMAND_LOG
    try {
        Set-PSReadLineOption -AddToHistoryHandler {
            param([string]$Line)
            try {
                $text = '{0} [terminal] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($Line -replace "`r?`n", "`n    ")
                [System.IO.File]::AppendAllText($global:JfsCommandLog, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
            return $true
        }
    } catch {
        # PSReadLine が使えない場合は、ターミナルの入出力をすべて記録する
        $dir = Split-Path -Parent $global:JfsCommandLog
        Start-Transcript -Path (Join-Path $dir ('terminal-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) | Out-Null
    }
}
