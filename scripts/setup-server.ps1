#Requires -Version 5.1
<#
.SYNOPSIS
    jupyter-for-share サーバー (Windows) の初期セットアップ。
.DESCRIPTION
    1. Python (全ユーザー向け) と Git for Windows のインストール (winget)
    2. 設定ファイル (servers.json) の作成
    3. サーバー実行用ユーザーのグループとログオン権限の設定
    4. このリポジトリ・user フォルダ・C:\ProgramData\jupyter のアクセス権設定
    5. サーバー実行用アカウントから他のフォルダへのアクセス禁止 (-SkipProtect で省略)
    6. リソースモニター (CPU / メモリ / GPU) の設置 (-SkipMonitor で省略)
    何度実行しても問題ありません。
#>
[CmdletBinding()]
param(
    [string]$Domain,          # 接続 URL に使うドメイン名 (例: jupyter.home.arpa)。DNS / hosts の設定は別途必要
    [switch]$SkipProtect,     # 他フォルダへのアクセス禁止を設定しない
    [switch]$SkipMonitor,     # リソースモニターを設置しない
    [int]$MonitorPort,        # リソースモニターのポート (既定: 8000)
    [switch]$DisableSleep,    # AC 電源時のスリープ・休止を無効にする (常時起動のサーバー向け)
    [switch]$PauseAtEnd       # 自動昇格したウィンドウが閉じないようにする (内部用)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-Admin)) {
    Start-Elevated $PSCommandPath $PSBoundParameters
    exit 0
}

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Install-WithWinget([string]$Id, [string[]]$ExtraArgs = @()) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw ("winget が見つかりません。Microsoft Store の「アプリ インストーラー」を入れるか、" +
               "$Id を手動で (全ユーザー向けに) インストールしてから再実行してください。")
    }
    Write-Info "$Id をインストールしています..."
    & winget install -e --id $Id --scope machine --accept-package-agreements --accept-source-agreements @ExtraArgs
    Update-PathFromRegistry
}

function Invoke-Setup {
    Write-Host ''
    Write-Host '=== jupyter-for-share サーバーセットアップ ===' -ForegroundColor White

    # ---- 設定ファイル ----
    $cfg = Read-Config
    if ($Domain) { Set-Value $cfg.defaults 'domain' $Domain }
    Save-Config $cfg
    Write-Ok "設定ファイル: $script:ConfigPath"
    Write-Ok "インストール先: $script:RepoRoot (ユーザー環境はこの中の user フォルダに作られます)"
    Assert-AclFileSystem $script:RepoRoot

    # ---- Python ----
    $py = Find-BasePython $cfg
    if (-not $py) {
        # サーバー用ユーザーからも使えるよう、全ユーザー向け (C:\Program Files) にインストールする
        Install-WithWinget 'Python.Python.3.12' @('--override', '/quiet InstallAllUsers=1 PrependPath=1 Include_launcher=1 Include_test=0')
        $py = Find-BasePython $cfg
        if (-not $py) { throw 'Python のインストールを確認できませんでした。' }
    }
    if (-not (Get-Value $cfg.defaults 'python')) {
        Set-Value $cfg.defaults 'python' $py
        Save-Config $cfg
    }
    Write-Ok "Python: $py"

    # ---- Git ----
    $git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    if (-not (Test-Path -LiteralPath $git)) {
        Install-WithWinget 'Git.Git' @('--silent')
    }
    if (Test-Path -LiteralPath $git) { Write-Ok "Git: $git" }
    else { Write-Warn 'Git for Windows を確認できませんでした。git clone を使う場合は手動でインストールしてください。' }

    # ---- アカウント・フォルダ ----
    Initialize-LocalGroup
    Write-Ok "ローカルグループ '$script:LocalGroup' とログオン権限を設定しました。"
    Protect-ProgramDataJupyter
    $root = Initialize-InstancesRoot $cfg
    Write-Ok "ユーザー環境を作る場所: $root"

    if (-not $SkipProtect) {
        & (Join-Path $PSScriptRoot 'jfs.ps1') protect -Background
        if ($LASTEXITCODE -ne 0) { Write-Warn "アクセス禁止の設定に失敗しました。後で 'jfs.cmd protect' を実行してください。" }
    }

    # ---- リソースモニター ----
    if (-not $SkipMonitor) {
        $jfsArgs = @('monitor')
        if ($MonitorPort) { $jfsArgs += @('-Port', $MonitorPort) }
        & (Join-Path $PSScriptRoot 'jfs.ps1') @jfsArgs
        if ($LASTEXITCODE -ne 0) { Write-Warn "リソースモニターの設置に失敗しました。後で 'jfs.cmd monitor' を実行してください。" }
    }

    # ---- 既存のユーザー環境を新しいバージョンに合わせる ----
    & (Join-Path $PSScriptRoot 'jfs.ps1') refresh
    if ($LASTEXITCODE -ne 0) { Write-Warn "ユーザー環境の更新に失敗しました。後で 'jfs.cmd refresh' を実行してください。" }

    # ---- ネットワーク・電源 ----
    $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' })
    foreach ($n in $public) {
        Write-Warn ("ネットワーク '$($n.Name)' が「パブリック」になっています。他の PC からつながらない場合は " +
                    "'jfs.cmd network' (または 'jfs.cmd network -SetPrivate') を実行してください。")
    }
    if ($DisableSleep) {
        & powercfg.exe /change standby-timeout-ac 0
        & powercfg.exe /change hibernate-timeout-ac 0
        Write-Ok 'AC 電源時のスリープ・休止を無効にしました。'
    }

    Write-Host ''
    Write-Ok 'セットアップが完了しました。'
    Write-Host @'

次の手順:
  1. ユーザー環境を作成する (例: alice さん用。ポートは自動で決まります)
       jfs.cmd add alice
  2. 表示された URL を本人に伝え、別の PC のブラウザで開いてもらう
     (全ユーザー共通のサーバー管理ウィンドウが 1 つ開きます。閉じると全員のサーバーが停止します)
     PC の再起動後は 'jfs.cmd start' で開き直すか、'jfs.cmd autostart on' でサインイン時に自動で開けます
  3. 一覧・停止などは 'jfs.cmd help' を参照
  4. 別の PC からつながらない場合は 'jfs.cmd network' (ネットワーク・ファイアウォール設定の確認と変更)
'@
}

try {
    Invoke-Setup
} catch {
    Write-Host "[x] $($_.Exception.Message)" -ForegroundColor Red
    if ($PauseAtEnd) { Read-Host 'Enter キーで終了します' | Out-Null }
    exit 1
}
if ($PauseAtEnd) { Read-Host 'Enter キーで終了します' | Out-Null }
