#Requires -Version 5.1
<#
.SYNOPSIS
    jupyter-for-share のユーザー環境 (ユーザーごとの JupyterLab) とリソースモニターを管理します。
.DESCRIPTION
    使い方は `jfs help` または README.md を参照してください。
    管理者権限が必要です (管理者でない場合は UAC で昇格して実行し直します)。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'list', 'add', 'set', 'remove', 'start', 'stop', 'restart',
                 'url', 'token', 'logs', 'upgrade', 'reset-venv', 'firewall', 'protect', 'unprotect',
                 'monitor', 'monitor-stop')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name,

    [int]$Port,
    [string[]]$AllowFrom,

    [switch]$New,
    [switch]$DeleteFiles,
    [switch]$Follow,
    [switch]$Force,
    [switch]$Background,
    [switch]$Status,
    [string]$LogFile,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Show-Help {
    Write-Host @'
jupyter-for-share 管理コマンド (管理者権限で実行)

使い方: jfs <コマンド> [ユーザー名] [オプション]

  add <ユーザー名>               ユーザー環境を作成して起動 (フォルダ: user\<ユーザー名>、ポートは自動でランダムに決定)
  list                           ユーザー環境とリソースモニターの一覧・状態
  url [ユーザー名]               接続用 URL を表示 (省略で全員分)
  start|stop|restart [ユーザー名] 起動 / 停止 / 再起動 (省略または all で全員)
  remove <ユーザー名> [-DeleteFiles]
                                 ユーザー環境を削除 (-DeleteFiles でフォルダも削除)
  token <ユーザー名> -New        アクセストークンを再発行
  set <ユーザー名> [-Port 番号] [-AllowFrom 範囲]
                                 ポートや接続を許可する相手を変更
  logs <ユーザー名|monitor> [-Follow]
                                 ログを表示
  upgrade [ユーザー名]           JupyterLab 本体を最新版に更新
  reset-venv <ユーザー名>        venv (追加したパッケージ) を作り直す

  monitor [-Port 8000]           リソースモニター (CPU / メモリ / GPU) を設置・更新して起動
  monitor-stop                   リソースモニターを停止

  firewall                       Windows ファイアウォール規則を設定ファイルに合わせて更新
  protect [-Background] [-Force] サーバー実行用アカウントから他のフォルダへのアクセスを禁止
                                 (設定済みの場所は飛ばす。-Background で裏で実行、-Force で付け直し)
  protect -Status                アクセス禁止の設定状況
  unprotect                      アクセス禁止を解除
'@
}

# ---- ユーザー環境の情報 ----

function Find-UserEnv($Config, [string]$UserName) {
    foreach ($s in @($Config.users)) {
        if ($s.name -eq $UserName) { return $s }
    }
    return $null
}

function Get-TargetUsers($Config, [string]$UserName) {
    if (-not $UserName -or $UserName -eq 'all') { return @($Config.users) }
    $s = Find-UserEnv $Config $UserName
    if (-not $s) { throw "ユーザー '$UserName' は登録されていません。'jfs list' で確認してください。" }
    return @($s)
}

function Get-RequiredUser($Config, [string]$UserName) {
    if (-not $UserName -or $UserName -eq 'all') { throw 'ユーザー名を指定してください。' }
    return (Get-TargetUsers $Config $UserName)[0]
}

function Get-AccountName($UserEnv) { return "$($script:UserPrefix)$($UserEnv.name)" }
function Get-TaskName($UserEnv) { return "jfs-$($UserEnv.name)" }

function Get-InstancePaths($UserEnv) {
    $root = [string]$UserEnv.path
    $srv = Join-Path $root '.server'
    return [pscustomobject]@{
        Root    = $root
        Work    = Join-Path $root 'work'
        Venv    = Join-Path $root 'venv'
        Server  = $srv
        LabVenv = Join-Path $srv 'jupyterlab'
        Config  = Join-Path $srv 'config'
        Data    = Join-Path $srv 'data'
        Runtime = Join-Path $srv 'runtime'
        Home    = Join-Path $srv 'home'
        Tmp     = Join-Path $srv 'tmp'
        Logs    = Join-Path $srv 'logs'
        Log     = Join-Path $srv 'logs\server.log'
        RunCmd  = Join-Path $srv 'run.cmd'
    }
}

function Get-MonitorPaths {
    $rt = Join-Path $script:MonitorDir '.runtime'
    return [pscustomobject]@{
        Dir       = $script:MonitorDir
        Script    = Join-Path $script:MonitorDir 'monitor.py'
        Venv      = Join-Path $script:MonitorDir '.venv'
        Runtime   = $rt
        Tmp       = Join-Path $rt 'tmp'
        Log       = Join-Path $rt 'monitor.log'
        RunCmd    = Join-Path $rt 'run.cmd'
        UsersFile = Join-Path $rt 'users.json'
    }
}

function ConvertTo-UserName([string]$UserName) {
    $n = $UserName.Trim().ToLowerInvariant()
    # Windows のアカウント名は 20 文字まで ("jfs-" + 16 文字)
    if ($n -notmatch '^[a-z0-9][a-z0-9-]{0,15}$' -or $n -eq 'all' -or $n -eq 'monitor') {
        throw "ユーザー名 '$UserName' は使えません。半角英数字とハイフン (16 文字以内) で指定してください。"
    }
    return $n
}

# ---- ポート ----

function Test-PortListening([int]$P) {
    return [bool](Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue)
}

function Get-ReservedPorts($Config, [string]$Except) {
    $ports = @($Config.users | Where-Object { $_.name -ne $Except } | ForEach-Object { [int]$_.port })
    $ports += [int]$Config.monitor.port
    return $ports
}

function Assert-PortAvailable($Config, [int]$P, [string]$Self) {
    if ($P -lt 1024 -or $P -gt 65535) { throw "ポート番号 $P は使えません (1024-65535)。" }
    if ((Get-ReservedPorts $Config $Self) -contains $P) { throw "ポート $P は既に使われています ('jfs list' で確認)。" }
    if (Test-PortListening $P) { throw "ポート $P は他のプログラムが使用中です。" }
}

function Get-RandomPort($Config) {
    $range = @(Get-Value $Config.defaults 'portRange' @(20000, 29999))
    $reserved = Get-ReservedPorts $Config ''
    for ($i = 0; $i -lt 500; $i++) {
        $p = Get-Random -Minimum ([int]$range[0]) -Maximum ([int]$range[1] + 1)
        if (($reserved -notcontains $p) -and -not (Test-PortListening $p)) { return $p }
    }
    throw "空いているポートが見つかりません (portRange: $($range -join '-'))。"
}

function Get-AllowFromList([string[]]$Values) {
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---- サーバー実行用の Windows アカウント ----

function New-ServiceAccount([string]$Account, [string]$Description) {
    if (-not (Get-LocalUser -Name $Account -ErrorAction SilentlyContinue)) {
        $pw = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
        New-LocalUser -Name $Account -Password $pw -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires `
            -Description $Description | Out-Null
        Write-Ok "サーバー実行用アカウント '$Account' を作成しました。"
    }
    foreach ($g in @($script:SidUsers, (Get-LocalGroupSid))) {
        try {
            Add-LocalGroupMember -SID $g -Member $Account -ErrorAction Stop
        } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
            # 既にメンバー
        }
    }
    # サインイン画面に表示しない
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name $Account -Value 0 -PropertyType DWord -Force | Out-Null
    return (Get-LocalUser -Name $Account).SID.Value
}

function Remove-ServiceAccount([string]$Account) {
    $user = Get-LocalUser -Name $Account -ErrorAction SilentlyContinue
    if (-not $user) { return }
    $sid = $user.SID.Value
    Remove-LocalUser -Name $Account
    Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $sid } | Remove-CimInstance -ErrorAction SilentlyContinue
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    Remove-ItemProperty -Path $key -Name $Account -ErrorAction SilentlyContinue
    Write-Ok "サーバー実行用アカウント '$Account' を削除しました。"
}

# ---- フォルダとアクセス権 ----
#   user\<名前>          … 管理者: フル / サーバー用アカウント: 読み取りのみ
#   user\<名前>\work     … ノートブック等の作業フォルダ (JupyterLab のルート) : 変更可
#   user\<名前>\venv     … パッケージを入れる Python 仮想環境 : 変更可
#   user\<名前>\.server  … JupyterLab 本体・設定 (読み取りのみ) と、ホーム・ログなど (変更可)
function Initialize-InstanceFolders($UserEnv, [string]$AccountSid) {
    $p = Get-InstancePaths $UserEnv
    foreach ($d in @($p.Root, $p.Work, $p.Venv, $p.Server, $p.Config, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs,
                     (Join-Path $p.Home 'AppData\Roaming'), (Join-Path $p.Home 'AppData\Local'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    (Get-Item -LiteralPath $p.Server).Attributes = 'Directory, Hidden'

    Invoke-Native 'icacls.exe' @($p.Root, '/inheritance:r', '/grant:r',
        "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidAdmins):(OI)(CI)F",
        "*$(Get-CurrentUserSid):(OI)(CI)F", "*$($AccountSid):(OI)(CI)RX", '/Q') -Quiet
    foreach ($d in @($p.Work, $p.Venv, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs)) {
        Invoke-Native 'icacls.exe' @($d, '/grant', "*$($AccountSid):(OI)(CI)M", '/Q') -Quiet
    }
}

# ---- Python 環境 ----

function Get-BasePythonOrThrow($Config) {
    $base = Find-BasePython $Config
    if (-not $base) { throw 'Python が見つかりません。先に setup.cmd を実行してください。' }
    return $base
}

function Install-JupyterLab($Config, $UserEnv, [switch]$Upgrade) {
    $p = Get-InstancePaths $UserEnv
    $py = Join-Path $p.LabVenv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) {
        Invoke-Native (Get-BasePythonOrThrow $Config) @('-m', 'venv', $p.LabVenv) -Quiet
    }
    $pkgs = @('jupyterlab')
    $locale = [string](Get-Value $Config.defaults 'labLocale' 'ja_JP')
    if ($locale -and $locale -notmatch '^en') { $pkgs += "jupyterlab-language-pack-$($locale.Replace('_', '-'))" }
    $pkgs += @(Get-Value $Config.defaults 'extraServerPackages' @())

    Write-Info "JupyterLab をインストールしています ($($UserEnv.name))。数分かかります..."
    Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip') -Quiet
    $a = @('-m', 'pip', 'install', '--disable-pip-version-check')
    if ($Upgrade) { $a += '--upgrade' }
    Invoke-Native $py ($a + $pkgs) -Quiet

    if ($locale) {
        $dir = Join-Path $p.LabVenv 'share\jupyter\lab\settings'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = '{ "@jupyterlab/translation-extension:plugin": { "locale": "' + $locale + '" } }'
        [System.IO.File]::WriteAllText((Join-Path $dir 'overrides.json'), $json)
    }
    Write-Ok 'JupyterLab のインストールが完了しました。'
}

# 利用者がパッケージを入れる venv を作り、JupyterLab の既定カーネル (python3) にする
function Install-UserVenv($Config, $UserEnv) {
    $p = Get-InstancePaths $UserEnv
    Write-Info "venv を作成しています: $($p.Venv)"
    Invoke-Native (Get-BasePythonOrThrow $Config) @('-m', 'venv', $p.Venv) -Quiet
    $py = Join-Path $p.Venv 'Scripts\python.exe'
    Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip') -Quiet
    $pkgs = @('ipykernel') + @(Get-Value $Config.defaults 'venvPackages' @())
    Invoke-Native $py (@('-m', 'pip', 'install', '--disable-pip-version-check') + $pkgs) -Quiet
    Invoke-Native $py @('-m', 'ipykernel', 'install', '--prefix', $p.LabVenv,
                        '--name', 'python3', '--display-name', 'Python 3 (venv)') -Quiet
    Write-Ok "venv の準備ができました (パッケージ: $($pkgs -join ', '))。"
}

# cmd.exe はバッチファイルを OEM コードページ (日本語環境では CP932) で読む
function Write-BatchFile([string]$Path, [string]$Content) {
    $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [System.IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n").Replace("`n", "`r`n"), $oem)
}

# ---- 起動スクリプトと Jupyter の設定 ----

function Write-ServerFiles($Config, $UserEnv) {
    $p = Get-InstancePaths $UserEnv
    $bind = [string](Get-Value $Config.defaults 'bindAddress' '0.0.0.0')

    $py = @'
# jupyter-for-share が生成したファイルです。jfs コマンドで上書きされるため直接編集しないでください。
c = get_config()  # noqa
c.ServerApp.ip = '@@BIND@@'
c.ServerApp.port = @@PORT@@
c.ServerApp.port_retries = 0
c.ServerApp.open_browser = False
c.ServerApp.allow_remote_access = True
c.ServerApp.root_dir = r'@@WORK@@'
c.IdentityProvider.token = '@@TOKEN@@'
c.ServerApp.terminado_settings = {'shell_command': ['powershell.exe', '-NoLogo']}
'@
    $py = $py.Replace('@@BIND@@', $bind).Replace('@@PORT@@', [string][int]$UserEnv.port).
              Replace('@@WORK@@', $p.Work).Replace('@@TOKEN@@', [string]$UserEnv.token)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $p.Config 'jupyter_server_config.py'), $py, $utf8)

    # HOME や AppData などを環境のフォルダ内に向け、venv を PATH の先頭に置いて JupyterLab を起動する
    $cmd = @'
@echo off
rem Generated by jupyter-for-share. Do not edit: the jfs command overwrites this file.
set "HOME=@@HOME@@"
set "USERPROFILE=@@HOME@@"
set "APPDATA=@@HOME@@\AppData\Roaming"
set "LOCALAPPDATA=@@HOME@@\AppData\Local"
set "TEMP=@@TMP@@"
set "TMP=@@TMP@@"
set "JUPYTER_CONFIG_DIR=@@CONFIG@@"
set "JUPYTER_DATA_DIR=@@DATA@@"
set "JUPYTER_RUNTIME_DIR=@@RUNTIME@@"
set "JUPYTERLAB_SETTINGS_DIR=@@HOME@@\.jupyter\lab\user-settings"
set "JUPYTERLAB_WORKSPACES_DIR=@@HOME@@\.jupyter\lab\workspaces"
set "IPYTHONDIR=@@HOME@@\.ipython"
set "PIP_CACHE_DIR=@@HOME@@\.cache\pip"
set "VIRTUAL_ENV=@@VENV@@"
set "PATH=@@VENV@@\Scripts;%PATH%"
set "PYTHONUTF8=1"
set "PYTHONUNBUFFERED=1"
set "PSExecutionPolicyPreference=RemoteSigned"
set "GCM_GUI_PROMPT=false"
cd /d "@@WORK@@"
for %%F in ("@@LOG@@") do if %%~zF GTR 10485760 move /y "@@LOG@@" "@@LOG@@.1" >nul
echo ===== %DATE% %TIME% start >> "@@LOG@@"
"@@LABVENV@@\Scripts\python.exe" -m jupyterlab >> "@@LOG@@" 2>&1
exit /b %ERRORLEVEL%
'@
    $cmd = $cmd.Replace('@@HOME@@', $p.Home).Replace('@@TMP@@', $p.Tmp).Replace('@@CONFIG@@', $p.Config).
                Replace('@@DATA@@', $p.Data).Replace('@@RUNTIME@@', $p.Runtime).Replace('@@VENV@@', $p.Venv).
                Replace('@@WORK@@', $p.Work).Replace('@@LOG@@', $p.Log).Replace('@@LABVENV@@', $p.LabVenv)
    Write-BatchFile $p.RunCmd $cmd
    Write-UserReadme $Config $UserEnv
}

# 利用者向けの短い README を作業フォルダに置く (利用者が書き換えた場合は上書きしない)
function Write-UserReadme($Config, $UserEnv) {
    $p = Get-InstancePaths $UserEnv
    $path = Join-Path $p.Work 'README.md'
    $stamp = Join-Path $p.Server 'README.generated.md'   # 前回生成した内容 (変更されたか判定する用)
    $marker = '<!-- generated by jupyter-for-share -->'
    if (Test-Path -LiteralPath $path) {
        $current = [System.IO.File]::ReadAllText($path)
        $previous = $null
        if (Test-Path -LiteralPath $stamp) { $previous = [System.IO.File]::ReadAllText($stamp) }
        if ($current -ne $previous) { return }
    }

    $hosts = @(Get-ServerHosts $Config)
    $mainHost = $hosts[0]
    $ip = @($hosts | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
    $labUrl = "http://$($mainHost):$($UserEnv.port)/lab"
    $monitorPort = [int]$Config.monitor.port
    $monitor = "- リソース確認 (CPU / メモリ / GPU の使用率): http://$($mainHost):$monitorPort/"
    if ($ip) { $monitor += "  (つながらない場合: http://$($ip[0]):$monitorPort/)" }
    if (-not [bool](Get-Value $Config.monitor 'enabled' $false)) { $monitor += '  ※ 現在は停止中' }
    $lab = "- この環境: $labUrl"
    if ($ip) { $lab += "  (つながらない場合: http://$($ip[0]):$($UserEnv.port)/lab)" }

    $text = @"
$marker
# $($UserEnv.name) さんの JupyterLab 環境

## アドレス

$lab
$monitor

初回はトークン付きの URL で開いてください (管理者から受け取ったもの)。2 回目以降は上のアドレスだけで開けます。

## 使い方

- このフォルダ (work) の中が作業場所です。ノートブックやファイルはここに保存してください。
  この環境から他のフォルダは見えません。
- パッケージ: ターミナルで ``pip install パッケージ名``、ノートブックでは ``%pip install パッケージ名``
  (この環境専用の venv に入ります。インストール後はカーネルを再起動してください)
- git: ターミナルで ``git clone https://...``
- ターミナルは PowerShell です (メニューの File → New → Terminal)。

このファイルは削除・編集してかまいません (編集すると自動更新されなくなります)。
"@
    $text = $text.Replace("`r`n", "`n")
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    [System.IO.File]::WriteAllText($stamp, $text, $utf8)
}

# ---- タスクスケジューラ (Windows 起動時に、サーバー実行用アカウントで自動起動) ----

function Register-JfsTask([string]$TaskName, [string]$Account, [string]$RunCmd, [string]$WorkDir, [string]$Description) {
    # パスワードは保存せず、登録のたびに新しいランダムなものを設定する
    $plain = New-RandomPassword
    Set-LocalUser -Name $Account -Password (ConvertTo-SecureString $plain -AsPlainText -Force)

    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -Argument "/d /c `"`"$RunCmd`"`"" -WorkingDirectory $WorkDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -Priority 5
    Register-ScheduledTask -TaskName $TaskName -TaskPath $script:TaskPath `
        -Action $action -Trigger $trigger -Settings $settings `
        -User "$env:COMPUTERNAME\$Account" -Password $plain -RunLevel Limited `
        -Description $Description -Force | Out-Null
}

function Get-JfsTask([string]$TaskName) {
    return Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Start-JfsTask([string]$TaskName, [int]$P, [string]$Label, [string]$LogHint) {
    $task = Get-JfsTask $TaskName
    if (-not $task) { throw "$Label のタスクがありません。作り直してください。" }
    Enable-ScheduledTask -InputObject $task | Out-Null
    if (Test-PortListening $P) {
        Write-Info "$Label は起動済みです。"
        return
    }
    Start-ScheduledTask -InputObject $task
    Write-Info "$Label を起動しています..."
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-PortListening $P) {
            Write-Ok "$Label が起動しました (ポート $P)。"
            return
        }
    }
    Write-Warn "$Label がポート $P で応答しません。'jfs logs $LogHint' でログを確認してください。"
}

# 停止したものは Windows を再起動しても起動しない (start で再開)
function Stop-JfsTask([string]$TaskName, [string]$Account, [string]$Label) {
    $task = Get-JfsTask $TaskName
    if ($task) {
        Disable-ScheduledTask -InputObject $task | Out-Null
        Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
    }
    $full = "$env:COMPUTERNAME\$Account"
    Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -eq $full } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "$Label を停止しました。"
}

function Get-TaskStatus([string]$TaskName, [int]$P) {
    $task = Get-JfsTask $TaskName
    if (-not $task) { return '未設置' }
    if ($task.State -eq 'Disabled') { return '停止' }
    if (Test-PortListening $P) { return '起動中' }
    if ($task.State -eq 'Running') { return '起動処理中' }
    return '停止 (自動起動待ち)'
}

function Register-UserTask($UserEnv) {
    Register-JfsTask (Get-TaskName $UserEnv) (Get-AccountName $UserEnv) (Get-InstancePaths $UserEnv).RunCmd `
        (Get-InstancePaths $UserEnv).Work "jupyter-for-share: $($UserEnv.name) (port $($UserEnv.port))"
}
function Start-UserEnv($UserEnv) {
    Start-JfsTask (Get-TaskName $UserEnv) ([int]$UserEnv.port) "ユーザー '$($UserEnv.name)' の環境" $UserEnv.name
}
function Stop-UserEnv($UserEnv) {
    Stop-JfsTask (Get-TaskName $UserEnv) (Get-AccountName $UserEnv) "ユーザー '$($UserEnv.name)' の環境"
}

# ---- リソースモニター ----

function Install-Monitor($Config) {
    $m = Get-MonitorPaths
    $sid = New-ServiceAccount $script:MonitorAccount 'jupyter-for-share: resource monitor'
    foreach ($d in @($m.Runtime, $m.Tmp)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    # モニターのプログラムは読み取りのみ、.runtime (ログ・一時ファイル) だけ書き込み可
    Invoke-Native 'icacls.exe' @($m.Dir, '/grant', "*$($sid):(OI)(CI)RX", '/Q') -Quiet
    Invoke-Native 'icacls.exe' @($m.Runtime, '/grant', "*$($sid):(OI)(CI)M", '/Q') -Quiet

    $py = Join-Path $m.Venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) {
        Write-Info 'リソースモニター用の venv を作成しています...'
        Invoke-Native (Get-BasePythonOrThrow $Config) @('-m', 'venv', $m.Venv) -Quiet
    }
    Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip', 'psutil') -Quiet

    $bind = [string](Get-Value $Config.defaults 'bindAddress' '0.0.0.0')
    $cmd = @'
@echo off
rem Generated by jupyter-for-share. Do not edit: the jfs command overwrites this file.
set "TEMP=@@TMP@@"
set "TMP=@@TMP@@"
set "PYTHONUTF8=1"
set "PYTHONUNBUFFERED=1"
for %%F in ("@@LOG@@") do if %%~zF GTR 10485760 move /y "@@LOG@@" "@@LOG@@.1" >nul
echo ===== %DATE% %TIME% start >> "@@LOG@@"
"@@PY@@" "@@SCRIPT@@" --bind @@BIND@@ --port @@PORT@@ --users "@@USERS@@" --disk "@@DISK@@" >> "@@LOG@@" 2>&1
exit /b %ERRORLEVEL%
'@
    $cmd = $cmd.Replace('@@TMP@@', $m.Tmp).Replace('@@LOG@@', $m.Log).Replace('@@PY@@', $py).
                Replace('@@SCRIPT@@', $m.Script).Replace('@@BIND@@', $bind).
                Replace('@@PORT@@', [string][int]$Config.monitor.port).Replace('@@USERS@@', $m.UsersFile).
                Replace('@@DISK@@', (Get-InstancesRoot $Config))
    Write-BatchFile $m.RunCmd $cmd

    Set-Value $Config.monitor 'enabled' $true
    Save-Config $Config   # users.json も書き出される
    Register-JfsTask 'jfs-monitor' $script:MonitorAccount $m.RunCmd $m.Dir `
        "jupyter-for-share: resource monitor (port $($Config.monitor.port))"
}

# ---- 接続先の表示 ----

function Get-ServerHosts($Config) {
    $hosts = @()
    $domain = [string](Get-Value $Config.defaults 'domain' '')
    if ($domain) { $hosts += $domain }
    $cn = $env:COMPUTERNAME.ToLowerInvariant()
    $hosts += $cn
    $hosts += "$cn.local"
    try {
        $hosts += @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and
                $_.InterfaceAlias -notmatch 'vEthernet|WSL|Loopback|Bluetooth'
            } |
            Select-Object -ExpandProperty IPAddress)
    } catch { }
    return $hosts
}

function Show-UserUrls($Config, $UserEnv) {
    Write-Host ''
    Write-Host "ユーザー '$($UserEnv.name)' (ポート $($UserEnv.port) / フォルダ: $($UserEnv.path))" -ForegroundColor White
    Write-Host '  接続 URL (どれか 1 つが使えれば OK。トークンはパスワードと同じ扱いで本人にだけ伝えてください):'
    foreach ($h in Get-ServerHosts $Config) {
        Write-Host "    http://$($h):$($UserEnv.port)/lab?token=$($UserEnv.token)"
    }
    Write-Host ''
}

function Show-MonitorUrls($Config) {
    Write-Host ''
    Write-Host "リソースモニター (ポート $($Config.monitor.port)):" -ForegroundColor White
    foreach ($h in Get-ServerHosts $Config) { Write-Host "    http://$($h):$($Config.monitor.port)/" }
    Write-Host ''
}

# ---- ファイアウォール ----

function Sync-FirewallRules($Config) {
    Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $profiles = [string](Get-Value $Config.defaults 'firewallProfiles' 'Domain,Private')
    $defaultAllow = @(Get-Value $Config.defaults 'allowFrom' @('LocalSubnet'))
    $rules = @()
    foreach ($s in @($Config.users)) {
        $rules += [pscustomobject]@{ Id = $s.name; Label = $s.name; Port = [int]$s.port
                                     Allow = @(Get-Value $s 'allowFrom' $defaultAllow) }
    }
    if ([bool](Get-Value $Config.monitor 'enabled' $false)) {
        $rules += [pscustomobject]@{ Id = '_monitor'; Label = 'resource monitor'; Port = [int]$Config.monitor.port
                                     Allow = @(Get-Value $Config.monitor 'allowFrom' $defaultAllow) }
    }
    foreach ($r in $rules) {
        New-NetFirewallRule -Name "jupyter-for-share-$($r.Id)" `
            -DisplayName "jupyter-for-share: $($r.Label) (TCP $($r.Port))" `
            -Group $script:FirewallGroup `
            -Direction Inbound -Protocol TCP -LocalPort $r.Port -Action Allow `
            -RemoteAddress $r.Allow -Profile $profiles | Out-Null
        Write-Ok "ファイアウォール: TCP $($r.Port) を許可 ($($r.Label) / 接続元: $($r.Allow -join ', '))"
    }
}

# ---- 他のフォルダへのアクセス禁止 ----
# サーバー実行用アカウントのグループに「拒否」のアクセス権を付ける。
# 対象 (protectedPaths の "auto"):
#   - システムドライブ以外の固定ドライブ全体 (D:\ など)
#   - システムドライブ直下の独自フォルダ (Windows / Program Files / Users など OS に必要なもの、
#     このリポジトリを含むフォルダは除く)
#   - C:\Users\Public
# 他のユーザーのプロファイル (C:\Users\<名前>) は Windows の既定で読めないので対象外。
# このリポジトリのフォルダは Protect-RepoFolder で管理者専用にしてある。

function Get-ProtectTargets($Config) {
    $repo = $script:RepoRoot.TrimEnd('\')
    $sysDrive = $env:SystemDrive
    $python = Find-BasePython $Config
    $targets = @()
    foreach ($entry in @(Get-Value $Config.defaults 'protectedPaths' @('auto'))) {
        if ($entry -ne 'auto') { $targets += [string]$entry; continue }

        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
            if ($_.DeviceID -ne $sysDrive) { $targets += "$($_.DeviceID)\" }
        }
        $keep = @('Windows', 'Program Files', 'Program Files (x86)', 'Users', 'PerfLogs')
        Get-ChildItem -LiteralPath "$sysDrive\" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_.FullName.TrimEnd('\')
            $isAncestor = ($repo -eq $dir) -or $repo.StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)
            $hasPython = $python -and $python.StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)
            if (($keep -notcontains $_.Name) -and -not $isAncestor -and -not $hasPython) { $targets += $dir }
        }
        if ($env:PUBLIC) { $targets += $env:PUBLIC }
    }
    return @($targets | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}

# 設定済みの対象は .runtime\protected.json に記録する (servers.json とは別にして、
# バックグラウンド実行中に jfs add などで設定ファイルを書き換えても競合しないようにする)
function Get-ProtectStatePaths {
    $dir = Join-Path $script:RepoRoot '.runtime'
    return [pscustomobject]@{
        Dir     = $dir
        Applied = Join-Path $dir 'protected.json'
        Job     = Join-Path $dir 'protect-job.json'
        Log     = Join-Path $dir 'protect.log'
    }
}

function Get-ProtectedApplied($Config) {
    $list = @(Get-Value $Config 'protectedApplied' @())   # 旧バージョンの記録
    $f = (Get-ProtectStatePaths).Applied
    if (Test-Path -LiteralPath $f) {
        # PowerShell 5.1 の ConvertFrom-Json は配列を 1 つのオブジェクトとして返すので foreach で展開する
        $data = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($x in $data) { $list += [string]$x }
    }
    return @($list | Where-Object { $_ } | Select-Object -Unique)
}

function Save-ProtectedApplied([string[]]$List) {
    $st = Get-ProtectStatePaths
    if (-not (Test-Path -LiteralPath $st.Dir)) { New-Item -ItemType Directory -Path $st.Dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($List | Where-Object { $_ }) -Depth 3
    [System.IO.File]::WriteAllText($st.Applied, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# フォルダ自体に、グループへの「拒否」が既に付いているか (付いていれば中のファイルにも継承済み)
function Test-HasDeny([string]$Path, [string]$Sid) {
    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($r in $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
            if ($r.AccessControlType -eq 'Deny' -and $r.IdentityReference.Value -eq $Sid) { return $true }
        }
    } catch { }
    return $false
}

# icacls をフォルダごとに並列で実行し、終わるまで経過を表示する
function Invoke-IcaclsParallel([string[]]$Targets, [string[]]$IcaclsArgs) {
    $jobs = @()
    foreach ($t in $Targets) {
        # "D:\" のように \ で終わるパスは、引用符の直前の \ がエスケープ扱いされるので \ を重ねる
        $quoted = $t
        if ($quoted.EndsWith('\')) { $quoted += '\' }
        $out = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList (@("`"$quoted`"") + $IcaclsArgs) `
            -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        $null = $proc.Handle   # 終了コードを後で取得するために必要
        $jobs += [pscustomobject]@{ Target = $t; Proc = $proc; Out = $out }
    }
    $started = Get-Date
    $lastReport = $started
    while (@($jobs | Where-Object { -not $_.Proc.HasExited }).Count -gt 0) {
        Start-Sleep -Seconds 2
        if (((Get-Date) - $lastReport).TotalSeconds -ge 30) {
            $lastReport = Get-Date
            $running = @($jobs | Where-Object { -not $_.Proc.HasExited } | ForEach-Object { $_.Target })
            Write-Info ("処理中 ({0} 分経過): {1}" -f [int]((Get-Date) - $started).TotalMinutes, ($running -join ', '))
        }
    }
    foreach ($j in $jobs) {
        $j.Proc.WaitForExit()
        if ($j.Proc.ExitCode -ne 0) {
            # /C 指定なので、一部のファイルで失敗しても残りは処理されている
            $msg = (Get-Content -LiteralPath $j.Out, "$($j.Out).err" -ErrorAction SilentlyContinue | Select-Object -Last 3) -join ' / '
            Write-Warn "$($j.Target): 一部のファイルを処理できませんでした ($msg)"
        }
        Remove-Item -LiteralPath $j.Out, "$($j.Out).err" -ErrorAction SilentlyContinue
    }
}

function Protect-Folders($Config, [switch]$Reapply) {
    $sid = Get-LocalGroupSid
    $targets = @(Get-ProtectTargets $Config)
    $applied = @(Get-ProtectedApplied $Config)
    # 最後まで処理が終わった記録があり、拒否も付いているフォルダは飛ばす
    # (付け直すと中の全ファイルを書き換えるため時間がかかる)。
    # 途中で中断した場所は記録がないので、次回もう一度最初から処理する。
    $todo = @($targets | Where-Object { $Reapply -or ($applied -notcontains $_) -or -not (Test-HasDeny $_ $sid) })

    if ($todo.Count -eq 0) {
        Save-ProtectedApplied $applied
        Write-Ok "アクセス禁止は設定済みです (対象 $($targets.Count) か所)。"
        return
    }
    Write-Info 'サーバー実行用アカウントから次のフォルダへのアクセスを禁止します。'
    Write-Info '中のファイル数が多いと時間がかかります (初回のみ。2 回目以降は設定済みの場所を飛ばします):'
    $todo | ForEach-Object { Write-Host "    $_" }
    Invoke-IcaclsParallel $todo @('/deny', "*$($sid):(OI)(CI)F", '/Q', '/C')

    foreach ($t in $todo) {
        if (Test-HasDeny $t $sid) {
            if ($applied -notcontains $t) { $applied += $t }
        } else {
            Write-Warn "$t : アクセス禁止を設定できませんでした。"
        }
    }
    Save-ProtectedApplied $applied
    Write-Ok 'アクセス禁止を設定しました。'
}

function Unprotect-Folders($Config) {
    $sid = Get-LocalGroupSid
    $targets = @(Get-ProtectedApplied $Config | Where-Object { Test-Path -LiteralPath $_ })
    if ($targets.Count -gt 0) {
        Write-Info "アクセス禁止を解除しています: $($targets -join ', ')"
        Invoke-IcaclsParallel $targets @('/remove:d', "*$sid", '/Q', '/C')
    }
    Save-ProtectedApplied @()
    if ($Config.PSObject.Properties['protectedApplied']) { Remove-Value $Config 'protectedApplied'; Save-Config $Config }
    Write-Ok 'アクセス禁止を解除しました。'
}

# バックグラウンドで protect を実行する (setup の待ち時間をなくすため)
function Start-ProtectBackground {
    $st = Get-ProtectStatePaths
    if (-not (Test-Path -LiteralPath $st.Dir)) { New-Item -ItemType Directory -Path $st.Dir -Force | Out-Null }
    if ((Get-ProtectJobState) -eq 'running') { Write-Info 'アクセス禁止の設定は既にバックグラウンドで実行中です。'; return }
    $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'protect', '-LogFile', "`"$($st.Log)`"")
    $job = @{ pid = $proc.Id; started = (Get-Date).ToString('o') }
    [System.IO.File]::WriteAllText($st.Job, (ConvertTo-Json $job), (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "アクセス禁止の設定をバックグラウンドで開始しました。進み具合は 'jfs protect -Status' で確認できます。"
}

function Get-ProtectJobState {
    $st = Get-ProtectStatePaths
    if (-not (Test-Path -LiteralPath $st.Job)) { return 'none' }
    $job = Get-Content -LiteralPath $st.Job -Raw -Encoding UTF8 | ConvertFrom-Json
    $p = Get-Process -Id ([int]$job.pid) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'powershell' -and $p.StartTime -ge ([datetime]$job.started).AddSeconds(-5)) { return 'running' }
    return 'finished'
}

function Show-ProtectStatus($Config) {
    $st = Get-ProtectStatePaths
    switch (Get-ProtectJobState) {
        'running'  { Write-Info 'アクセス禁止の設定: バックグラウンドで実行中' }
        'finished' { Write-Info 'アクセス禁止の設定: バックグラウンド処理は終了しています' }
    }
    $applied = @(Get-ProtectedApplied $Config)
    if ($applied.Count -gt 0) { Write-Host "  設定済み: $($applied -join ', ')" } else { Write-Host '  設定済みの場所はありません。' }
    if (Test-Path -LiteralPath $st.Log) {
        Write-Host "  ログ ($($st.Log)) の末尾:"
        Get-Content -LiteralPath $st.Log -Tail 8 -Encoding UTF8 | ForEach-Object { Write-Host "    $_" }
    }
}

# ---- メイン ----

if ($Command -ne 'help' -and -not (Test-Admin)) {
    Start-Elevated $PSCommandPath $PSBoundParameters
    exit 0
}

$bound = $PSBoundParameters

try {
    switch ($Command) {
        'help' {
            Show-Help
        }

        'list' {
            $cfg = Read-Config
            $rows = @(foreach ($s in @($cfg.users)) {
                [pscustomobject]@{
                    User   = $s.name
                    Port   = $s.port
                    Status = Get-TaskStatus (Get-TaskName $s) ([int]$s.port)
                    Folder = $s.path
                }
            })
            if ($rows.Count -gt 0) { $rows | Format-Table -AutoSize | Out-Host }
            else { Write-Info "ユーザー環境はまだありません。'jfs add <ユーザー名>' で作成してください。" }
            Write-Host "リソースモニター: ポート $($cfg.monitor.port) / $(Get-TaskStatus 'jfs-monitor' ([int]$cfg.monitor.port))"
            if ((Get-ProtectJobState) -eq 'running') { Write-Host "アクセス禁止の設定: バックグラウンドで実行中 ('jfs protect -Status' で確認)" }
        }

        'add' {
            if (-not $Name) { throw 'ユーザー名を指定してください。例: jfs add alice' }
            $userName = ConvertTo-UserName $Name
            $cfg = Read-Config
            if (Find-UserEnv $cfg $userName) { throw "ユーザー '$userName' は既に存在します。" }
            Get-BasePythonOrThrow $cfg | Out-Null

            Initialize-LocalGroup
            $root = Initialize-InstancesRoot $cfg
            $folder = Join-Path $root $userName
            if (Test-Path -LiteralPath $folder) { throw "フォルダ $folder が既に存在します。別の名前にするか、フォルダを移動してください。" }
            if ($folder -match "[%`"',]") { throw "フォルダのパスに使えない文字 (% `" ' ,) が含まれています: $folder" }

            $u = [pscustomobject]@{ name = $userName; port = (Get-RandomPort $cfg); path = $folder; token = (New-Token) }
            $sid = New-ServiceAccount (Get-AccountName $u) "jupyter-for-share: $userName"
            Initialize-InstanceFolders $u $sid
            Install-JupyterLab $cfg $u
            Install-UserVenv $cfg $u
            Write-ServerFiles $cfg $u

            $cfg.users = @($cfg.users) + $u
            Save-Config $cfg
            Sync-FirewallRules $cfg
            Register-UserTask $u
            Start-UserEnv $u
            Show-UserUrls $cfg $u
        }

        'set' {
            $cfg = Read-Config
            $u = Get-RequiredUser $cfg $Name
            if ($bound.ContainsKey('Port') -and $Port -ne [int]$u.port) {
                Assert-PortAvailable $cfg $Port $u.name
                Set-Value $u 'port' $Port
            }
            if ($bound.ContainsKey('AllowFrom')) {
                $list = Get-AllowFromList $AllowFrom
                if ($list.Count -gt 0) { Set-Value $u 'allowFrom' $list } else { Remove-Value $u 'allowFrom' }
            }
            Save-Config $cfg
            Write-ServerFiles $cfg $u
            Sync-FirewallRules $cfg
            Register-UserTask $u
            Stop-UserEnv $u
            Start-UserEnv $u
            Show-UserUrls $cfg $u
        }

        'remove' {
            $cfg = Read-Config
            $u = Get-RequiredUser $cfg $Name
            if (-not $Force) {
                $msg = "ユーザー '$($u.name)' の環境を削除します。"
                if ($DeleteFiles) { $msg += "フォルダ $($u.path) も中身ごと削除されます。" }
                else { $msg += "フォルダ $($u.path) は残ります。" }
                $ans = Read-Host "$msg よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            Stop-UserEnv $u
            $task = Get-JfsTask (Get-TaskName $u)
            if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
            $cfg.users = @($cfg.users | Where-Object { $_.name -ne $u.name })
            Save-Config $cfg
            Sync-FirewallRules $cfg
            Remove-ServiceAccount (Get-AccountName $u)
            if ($DeleteFiles -and (Test-Path -LiteralPath $u.path)) {
                Remove-Item -LiteralPath $u.path -Recurse -Force
                Write-Ok "フォルダを削除しました: $($u.path)"
            }
            Write-Ok "ユーザー '$($u.name)' の環境を削除しました。"
        }

        'start' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Start-UserEnv $u }
        }

        'stop' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Stop-UserEnv $u }
        }

        'restart' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Stop-UserEnv $u; Start-UserEnv $u }
        }

        'url' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Show-UserUrls $cfg $u }
            if (-not $Name -and [bool](Get-Value $cfg.monitor 'enabled' $false)) { Show-MonitorUrls $cfg }
        }

        'token' {
            $cfg = Read-Config
            $u = Get-RequiredUser $cfg $Name
            if ($New) {
                Set-Value $u 'token' (New-Token)
                Save-Config $cfg
                Write-ServerFiles $cfg $u
                Stop-UserEnv $u
                Start-UserEnv $u
                Write-Ok '新しいトークンを発行しました。古い URL は使えなくなります。'
            }
            Show-UserUrls $cfg $u
        }

        'logs' {
            $cfg = Read-Config
            if ($Name -eq 'monitor') { $log = (Get-MonitorPaths).Log }
            else { $log = (Get-InstancePaths (Get-RequiredUser $cfg $Name)).Log }
            if (-not (Test-Path -LiteralPath $log)) { throw "ログファイルがまだありません: $log" }
            if ($Follow) { Get-Content -LiteralPath $log -Tail 100 -Wait -Encoding UTF8 }
            else { Get-Content -LiteralPath $log -Tail 100 -Encoding UTF8 }
        }

        'upgrade' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) {
                $wasRunning = (Get-TaskStatus (Get-TaskName $u) ([int]$u.port)) -eq '起動中'
                Stop-UserEnv $u
                Install-JupyterLab $cfg $u -Upgrade
                if ($wasRunning) { Start-UserEnv $u }
            }
        }

        'reset-venv' {
            $cfg = Read-Config
            $u = Get-RequiredUser $cfg $Name
            if (-not $Force) {
                $ans = Read-Host "ユーザー '$($u.name)' の venv を作り直します (追加したパッケージは消えます)。よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            Stop-UserEnv $u
            $venv = (Get-InstancePaths $u).Venv
            if (Test-Path -LiteralPath $venv) { Remove-Item -LiteralPath $venv -Recurse -Force }
            $sid = New-ServiceAccount (Get-AccountName $u) "jupyter-for-share: $($u.name)"
            Initialize-InstanceFolders $u $sid
            Install-UserVenv $cfg $u
            Start-UserEnv $u
        }

        'monitor' {
            $cfg = Read-Config
            if ($bound.ContainsKey('Port') -and $Port -ne [int]$cfg.monitor.port) {
                Assert-PortAvailable $cfg $Port ''
                Set-Value $cfg.monitor 'port' $Port
            }
            if ($bound.ContainsKey('AllowFrom')) {
                $list = Get-AllowFromList $AllowFrom
                if ($list.Count -gt 0) { Set-Value $cfg.monitor 'allowFrom' $list } else { Remove-Value $cfg.monitor 'allowFrom' }
            }
            Initialize-LocalGroup
            Protect-RepoFolder
            Stop-JfsTask 'jfs-monitor' $script:MonitorAccount 'リソースモニター'
            Install-Monitor $cfg
            Sync-FirewallRules $cfg
            Start-JfsTask 'jfs-monitor' ([int]$cfg.monitor.port) 'リソースモニター' 'monitor'
            foreach ($u in @($cfg.users)) { Write-UserReadme $cfg $u }
            Show-MonitorUrls $cfg
        }

        'monitor-stop' {
            $cfg = Read-Config
            Stop-JfsTask 'jfs-monitor' $script:MonitorAccount 'リソースモニター'
            Set-Value $cfg.monitor 'enabled' $false
            Save-Config $cfg
            Sync-FirewallRules $cfg
            foreach ($u in @($cfg.users)) { Write-UserReadme $cfg $u }
        }

        'firewall' {
            Sync-FirewallRules (Read-Config)
        }

        'protect' {
            $cfg = Read-Config
            if ($Status) { Show-ProtectStatus $cfg; break }
            Initialize-LocalGroup
            if ($Background) { Start-ProtectBackground; break }
            if ($LogFile) { Start-Transcript -LiteralPath $LogFile -Force | Out-Null }
            try { Protect-Folders $cfg -Reapply:$Force }
            finally { if ($LogFile) { Stop-Transcript | Out-Null } }
        }

        'unprotect' {
            Unprotect-Folders (Read-Config)
        }
    }
} catch {
    Write-Host "[x] $($_.Exception.Message)" -ForegroundColor Red
    if ($PauseAtEnd) { Read-Host 'Enter キーで終了します' | Out-Null }
    exit 1
}
if ($PauseAtEnd) { Read-Host 'Enter キーで終了します' | Out-Null }
