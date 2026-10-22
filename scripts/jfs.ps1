#Requires -Version 5.1
<#
.SYNOPSIS
    jupyter-for-share のユーザー環境 (ユーザーごとの JupyterLab) とリソースモニターを管理します。
.DESCRIPTION
    使い方は `jfs.cmd help` または README.md を参照してください。
    管理者権限が必要です (管理者でない場合は UAC で昇格して実行し直します)。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
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

$script:Commands = @('help', 'list', 'add', 'doctor', 'set', 'remove', 'start', 'stop', 'restart',
                     'url', 'token', 'logs', 'upgrade', 'reset-venv', 'firewall', 'protect', 'unprotect',
                     'monitor', 'monitor-stop')

# コマンドごとの詳しい説明 (jfs.cmd help <コマンド>)
$script:CommandHelp = @{
    'list'         = "jfs.cmd list`n  ユーザー環境 (ユーザー名・ポート・状態・フォルダ) とリソースモニターの状態を一覧表示します。"
    'add'          = "jfs.cmd add <ユーザー名>`n  ユーザー環境を作成して起動し、接続用 URL を表示します。`n  フォルダは user\<ユーザー名>、ポートは空いている番号から自動で決まります。`n  ユーザー名は半角英数字とハイフン (16 文字以内)。`n例: jfs.cmd add alice"
    'set'          = "jfs.cmd set <ユーザー名> [-Port 番号] [-AllowFrom 範囲]`n  ポートや、接続を許可する相手 (ファイアウォール) を変更して再起動します。`n例: jfs.cmd set alice -Port 23456`n    jfs.cmd set alice -AllowFrom 192.168.1.0/24,192.168.2.10"
    'remove'       = "jfs.cmd remove <ユーザー名> [-DeleteFiles] [-Force]`n  ユーザー環境 (実行用アカウント・自動起動・ファイアウォール規則) を削除します。`n  -DeleteFiles: フォルダ user\<ユーザー名> も中身ごと削除`n  -Force: 確認せずに削除"
    'start'        = "jfs.cmd start [ユーザー名]`n  ユーザー環境を起動します。省略または all で全員分。"
    'stop'         = "jfs.cmd stop [ユーザー名]`n  ユーザー環境を停止します。止めた環境は PC を再起動しても止まったままです。省略または all で全員分。"
    'restart'      = "jfs.cmd restart [ユーザー名]`n  ユーザー環境を再起動します。省略または all で全員分。"
    'url'          = "jfs.cmd url [ユーザー名]`n  接続用 URL (トークン付き) を表示します。省略すると全員分とリソースモニターの URL。"
    'token'        = "jfs.cmd token <ユーザー名> [-New]`n  接続用 URL を表示します。-New でトークンを再発行します (古い URL は使えなくなります)。"
    'logs'         = "jfs.cmd logs <ユーザー名|monitor> [-Follow]`n  ログの末尾を表示します。-Follow で追記を表示し続けます (Ctrl+C で終了)。"
    'upgrade'      = "jfs.cmd upgrade [ユーザー名]`n  JupyterLab 本体を最新版に更新します。省略で全員分。venv に入れたパッケージはそのまま。"
    'reset-venv'   = "jfs.cmd reset-venv <ユーザー名> [-Force]`n  venv を作り直します (pip で入れたパッケージは消えます。work フォルダのファイルは残ります)。"
    'monitor'      = "jfs.cmd monitor [-Port 番号] [-AllowFrom 範囲]`n  リソースモニター (CPU / メモリ / GPU) を設置・更新して起動します。既定のポートは 8000。"
    'monitor-stop' = "jfs.cmd monitor-stop`n  リソースモニターを停止します (再開は jfs.cmd monitor)。"
    'doctor'       = "jfs.cmd doctor [ユーザー名]`n  つながらないときの診断です。アカウント・自動起動タスク・待ち受けポート・HTTP 応答・`n  ファイアウォール・ネットワークの種類・ログを確認し、問題のある箇所に [NG] を表示します。"
    'firewall'     = "jfs.cmd firewall`n  Windows ファイアウォール規則を設定ファイル (servers.json) に合わせて作り直します。"
    'protect'      = "jfs.cmd protect [-Background] [-Force]`njfs.cmd protect -Status`n  サーバー実行用アカウントから他のフォルダへのアクセスを禁止します。設定済みの場所は飛ばします。`n  -Background: 裏で実行 / -Force: 設定済みの場所も付け直す / -Status: 進み具合を表示"
    'unprotect'    = "jfs.cmd unprotect`n  protect で設定したアクセス禁止を解除します。"
}

function Show-Help([string]$Topic) {
    if ($Topic -and $script:CommandHelp.ContainsKey($Topic.ToLowerInvariant())) {
        Write-Host $script:CommandHelp[$Topic.ToLowerInvariant()]
        return
    }
    Write-Host @'
jupyter-for-share 管理コマンド

使い方: jfs.cmd <コマンド> [ユーザー名] [オプション]
        (PowerShell から実行するときは .\jfs.cmd)
        管理者権限が必要なコマンドは、実行すると UAC の確認が表示されます。

ユーザー環境
  jfs.cmd add <ユーザー名>              作成して起動 (ポートは自動で決定)
  jfs.cmd list                          一覧と状態
  jfs.cmd url [ユーザー名]              接続用 URL を表示
  jfs.cmd start|stop|restart [ユーザー名] 起動 / 停止 / 再起動 (省略で全員)
  jfs.cmd remove <ユーザー名> [-DeleteFiles]
                                        削除 (-DeleteFiles でフォルダも削除)
  jfs.cmd token <ユーザー名> -New       トークンを再発行
  jfs.cmd set <ユーザー名> -Port 番号   ポートなどを変更
  jfs.cmd logs <ユーザー名> [-Follow]   ログを表示
  jfs.cmd upgrade [ユーザー名]          JupyterLab を更新
  jfs.cmd reset-venv <ユーザー名>       venv を作り直す

リソースモニター (CPU / メモリ / GPU)
  jfs.cmd monitor [-Port 8000]          設置・更新して起動
  jfs.cmd monitor-stop                  停止

サーバー全体
  jfs.cmd doctor [ユーザー名]           つながらないときの診断
  jfs.cmd firewall                      ファイアウォール規則を更新
  jfs.cmd protect [-Background]         他のフォルダへのアクセスを禁止 (-Status で進み具合)
  jfs.cmd unprotect                     アクセス禁止を解除

ヘルプ
  jfs.cmd help <コマンド>               コマンドごとの詳しい説明 (例: jfs.cmd help add)
  jfs.cmd -h / --help / /?              この一覧を表示
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
    if (-not $s) { throw "ユーザー '$UserName' は登録されていません。'jfs.cmd list' で確認してください。" }
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
    if ((Get-ReservedPorts $Config $Self) -contains $P) { throw "ポート $P は既に使われています ('jfs.cmd list' で確認)。" }
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
    (Get-Item -LiteralPath $p.Server -Force).Attributes = 'Directory, Hidden'

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

# テンプレート内の @@名前@@ を置き換える
function Expand-Template([string]$Text, [hashtable]$Values) {
    foreach ($k in $Values.Keys) { $Text = $Text.Replace("@@$k@@", [string]$Values[$k]) }
    return $Text
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
    # '*' は IPv4 と IPv6 の両方で待ち受ける (コンピューター名が IPv6 アドレスに解決されても接続できるように)
    if ($bind -eq '0.0.0.0') { $bind = '*' }

    $py = @'
# jupyter-for-share が生成したファイルです。jfs.cmd で上書きされるため直接編集しないでください。
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
    $py = Expand-Template $py @{ BIND = $bind; PORT = [string][int]$UserEnv.port; WORK = $p.Work; TOKEN = [string]$UserEnv.token }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $p.Config 'jupyter_server_config.py'), $py, $utf8)

    # HOME や AppData などを環境のフォルダ内に向け、venv を PATH の先頭に置いて JupyterLab を起動する
    $cmd = @'
@echo off
rem Generated by jupyter-for-share. Do not edit: the jfs.cmd command overwrites this file.
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
    $cmd = Expand-Template $cmd @{
        HOME = $p.Home; TMP = $p.Tmp; CONFIG = $p.Config; DATA = $p.Data; RUNTIME = $p.Runtime
        VENV = $p.Venv; WORK = $p.Work; LOG = $p.Log; LABVENV = $p.LabVenv
    }
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
    $repoUrl = [string](Get-Value $Config.defaults 'repositoryUrl' $script:RepositoryUrl)
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

## このサーバーについて

この環境は jupyter-for-share で作られています: $repoUrl

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

# タスクスケジューラの結果コードを説明に変える
# 結果コードを 0～0xFFFFFFFF の数値にそろえる (負の Int32 で返ることがあるため)
function ConvertTo-ResultCode($Code) {
    $v = [long]$Code
    if ($v -lt 0) { $v += 4294967296 }
    return $v
}

function Get-TaskResultText($Code) {
    $hex = '0x{0:X8}' -f (ConvertTo-ResultCode $Code)
    $known = @{
        '0x00000000' = '正常終了'
        '0x00041300' = '実行準備完了'
        '0x00041301' = '実行中'
        '0x00041303' = 'まだ一度も実行されていない'
        '0x00041306' = '停止された'
        '0x8007052E' = 'ログオン失敗: パスワードが正しくない (jfs.cmd set <ユーザー名> で再登録してください)'
        '0x80070569' = 'ログオン失敗: 「バッチ ジョブとしてログオン」が許可されていない (グループ ポリシーで制限されている可能性)'
        '0x80070533' = 'ログオン失敗: アカウントが無効になっている'
        '0x800710E0' = 'タスクの起動が拒否された'
        '0x00000001' = 'JupyterLab (Python) がエラーで終了した (ログを確認してください)'
    }
    if ($known.ContainsKey($hex)) { return "$hex ($($known[$hex]))" }
    return $hex
}

function Show-LogTail([string]$LogPath, [int]$Lines = 15) {
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        Write-Host "  ログ ($LogPath) の末尾:"
        Get-Content -LiteralPath $LogPath -Tail $Lines -Encoding UTF8 | ForEach-Object { Write-Host "    $_" }
    } elseif ($LogPath) {
        Write-Host "  ログファイルがありません ($LogPath)。起動用のバッチファイルが実行されていません (アカウントのログオンに失敗している可能性)。"
    }
}

function Start-JfsTask([string]$TaskName, [int]$P, [string]$Label, [string]$LogPath) {
    $task = Get-JfsTask $TaskName
    if (-not $task) { throw "$Label のタスクがありません。作り直してください。" }
    Enable-ScheduledTask -InputObject $task | Out-Null
    if (Test-PortListening $P) {
        Write-Info "$Label は起動済みです。"
        return $true
    }
    $startedAt = Get-Date
    Start-ScheduledTask -InputObject $task
    Write-Info "$Label を起動しています (初回は 1 分ほどかかることがあります)..."
    $deadline = $startedAt.AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-PortListening $P) {
            Write-Ok "$Label が起動しました (ポート $P)。"
            return $true
        }
        # タスク自体が終わってしまった (ログオン失敗や Python のエラー) なら待たずに原因を表示する
        $info = Get-ScheduledTaskInfo -InputObject (Get-JfsTask $TaskName) -ErrorAction SilentlyContinue
        $state = (Get-JfsTask $TaskName).State
        if ($info -and $state -ne 'Running' -and $info.LastRunTime -ge $startedAt.AddSeconds(-5) -and
            (ConvertTo-ResultCode $info.LastTaskResult) -ne 0x41301) {
            break
        }
    }
    $info = Get-ScheduledTaskInfo -InputObject (Get-JfsTask $TaskName) -ErrorAction SilentlyContinue
    Write-Warn "$Label がポート $P で起動しませんでした。"
    if ($info) { Write-Host "  タスクの結果: $(Get-TaskResultText $info.LastTaskResult)" }
    Show-LogTail $LogPath
    Write-Host "  詳しい診断: jfs.cmd doctor"
    return $false
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
    if (-not $task) { return "未登録 ('jfs.cmd set <ユーザー名>' で再登録)" }
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
    return (Start-JfsTask (Get-TaskName $UserEnv) ([int]$UserEnv.port) "ユーザー '$($UserEnv.name)' の環境" (Get-InstancePaths $UserEnv).Log)
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
rem Generated by jupyter-for-share. Do not edit: the jfs.cmd command overwrites this file.
set "TEMP=@@TMP@@"
set "TMP=@@TMP@@"
set "PYTHONUTF8=1"
set "PYTHONUNBUFFERED=1"
for %%F in ("@@LOG@@") do if %%~zF GTR 10485760 move /y "@@LOG@@" "@@LOG@@.1" >nul
echo ===== %DATE% %TIME% start >> "@@LOG@@"
"@@PY@@" "@@SCRIPT@@" --bind @@BIND@@ --port @@PORT@@ --users "@@USERS@@" --disk "@@DISK@@" >> "@@LOG@@" 2>&1
exit /b %ERRORLEVEL%
'@
    $cmd = Expand-Template $cmd @{
        TMP = $m.Tmp; LOG = $m.Log; PY = $py; SCRIPT = $m.Script; BIND = $bind
        PORT = [string][int]$Config.monitor.port; USERS = $m.UsersFile; DISK = (Get-InstancesRoot $Config)
    }
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
# バックグラウンド実行中に jfs.cmd add などで設定ファイルを書き換えても競合しないようにする)
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
    Write-Ok "アクセス禁止の設定をバックグラウンドで開始しました。進み具合は 'jfs.cmd protect -Status' で確認できます。"
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

# ユーザー環境の実行用アカウント・自動起動タスク・フォルダ (指定時) を削除する。
# 設定ファイルに載っていない、作成途中で残ったものも片付けられるようにしている。
function Remove-UserLeftovers([string]$UserName, [string]$Folder) {
    $taskName = "jfs-$UserName"
    $account = "$($script:UserPrefix)$UserName"
    if ((Get-JfsTask $taskName) -or (Get-LocalUser -Name $account -ErrorAction SilentlyContinue)) {
        Stop-JfsTask $taskName $account "ユーザー '$UserName' の環境"
    }
    $task = Get-JfsTask $taskName
    if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
    Remove-ServiceAccount $account
    if ($Folder -and (Test-Path -LiteralPath $Folder)) {
        Remove-Item -LiteralPath $Folder -Recurse -Force
        Write-Ok "フォルダを削除しました: $Folder"
    }
}

# ---- 診断 (jfs.cmd doctor) ----

function Write-Check([bool]$Ok, [string]$Message) {
    if ($Ok) { Write-Host "  [OK] $Message" -ForegroundColor Green } else { Write-Host "  [NG] $Message" -ForegroundColor Red }
}

function Test-HttpOk([string]$Url) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Test-ServiceTarget([string]$Label, [string]$TaskName, [string]$Account, [int]$P, [string]$RuleName,
                            [string]$HttpPath, [string]$LogPath) {
    Write-Host ''
    Write-Host "== $Label (ポート $P) ==" -ForegroundColor White
    $user = Get-LocalUser -Name $Account -ErrorAction SilentlyContinue
    Write-Check ([bool]$user -and $user.Enabled) "実行用アカウント $Account"
    $task = Get-JfsTask $TaskName
    if ($task) {
        $info = Get-ScheduledTaskInfo -InputObject $task
        Write-Check ($task.State -ne 'Disabled') "自動起動タスク $($script:TaskPath)$TaskName (状態: $($task.State))"
        Write-Host "       前回の実行: $($info.LastRunTime) / 結果: $(Get-TaskResultText $info.LastTaskResult)"
    } else {
        Write-Check $false "自動起動タスク $($script:TaskPath)$TaskName がありません"
    }
    $conn = @(Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue)
    if ($conn.Count -gt 0) {
        $procs = @($conn | ForEach-Object { (Get-Process -Id $_.OwningProcess -IncludeUserName -ErrorAction SilentlyContinue) } |
                   Where-Object { $_ } | ForEach-Object { "$($_.ProcessName) ($($_.UserName))" } | Select-Object -Unique)
        Write-Check $true "ポート $P で待ち受け中: $($procs -join ', ') / アドレス: $(@($conn | ForEach-Object { $_.LocalAddress }) -join ', ')"
        Write-Check (Test-HttpOk "http://127.0.0.1:$P$HttpPath") "このPCからの HTTP 接続 (http://127.0.0.1:$P$HttpPath)"
    } else {
        Write-Check $false "ポート $P で待ち受けていません (サーバーが起動していない)"
    }
    $rule = Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
    if ($rule) {
        $addr = (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule).RemoteAddress -join ', '
        Write-Check ($rule.Enabled -eq 'True') "ファイアウォール規則 (プロファイル: $($rule.Profile) / 接続元: $addr)"
    } else {
        Write-Check $false "ファイアウォール規則 $RuleName がありません ('jfs.cmd firewall' で作り直せます)"
    }
    Show-LogTail $LogPath 10
}

function Invoke-Doctor($Config, [string]$UserName) {
    Write-Host '== サーバー全体 ==' -ForegroundColor White
    $py = Find-BasePython $Config
    Write-Check ([bool]$py) "Python: $py"
    Write-Check ([bool](Get-LocalGroup -Name $script:LocalGroup -ErrorAction SilentlyContinue)) "グループ $script:LocalGroup"

    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    foreach ($n in $profiles) {
        Write-Check ($n.NetworkCategory -ne 'Public') ("ネットワーク '$($n.Name)' ($($n.InterfaceAlias)): $($n.NetworkCategory)" +
            $(if ($n.NetworkCategory -eq 'Public') { " → パブリックでは他の PC から接続できません。Set-NetConnectionProfile -InterfaceIndex $($n.InterfaceIndex) -NetworkCategory Private" } else { '' }))
    }
    $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $_.AllowInboundRules -eq 'False' })
    foreach ($f in $fw) { Write-Check $false "ファイアウォールのプロファイル $($f.Name) で受信規則が無効化されています (グループ ポリシーなど)" }

    # 過去に「アクセスを許可しない」を選ぶと、python.exe をブロックする規則ができ、ポートの許可より優先される
    $blocks = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -match 'python' } |
        ForEach-Object { Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' })
    if ($blocks.Count -gt 0) {
        foreach ($b in $blocks) { Write-Check $false "python をブロックする受信規則があります: '$($b.DisplayName)' (wf.msc で無効化または削除してください)" }
    } else {
        Write-Check $true 'python をブロックするファイアウォール規則はありません'
    }

    foreach ($u in (Get-TargetUsers $Config $UserName)) {
        Test-ServiceTarget "ユーザー '$($u.name)'" (Get-TaskName $u) (Get-AccountName $u) ([int]$u.port) `
            "jupyter-for-share-$($u.name)" '/api' (Get-InstancePaths $u).Log
    }
    if (-not $UserName -and [bool](Get-Value $Config.monitor 'enabled' $false)) {
        Test-ServiceTarget 'リソースモニター' 'jfs-monitor' $script:MonitorAccount ([int]$Config.monitor.port) `
            'jupyter-for-share-_monitor' '/api/stats' (Get-MonitorPaths).Log
    }
    Write-Host ''
    Write-Host '[OK] がすべて付いているのに別の PC からつながらない場合は、接続元の PC が同じサブネットにあるか、'
    Write-Host 'IP アドレスの URL (jfs.cmd url) で試してください。'
}

# ---- メイン ----

if ($script:Commands -notcontains $Command.ToLowerInvariant()) {
    Write-Host "[x] '$Command' というコマンドはありません。" -ForegroundColor Red
    Write-Host ''
    Show-Help
    exit 1
}
$Command = $Command.ToLowerInvariant()

if ($Command -ne 'help' -and -not (Test-Admin)) {
    Start-Elevated $PSCommandPath $PSBoundParameters
    exit 0
}

$bound = $PSBoundParameters

try {
    switch ($Command) {
        'help' {
            Show-Help $Name
        }

        'list' {
            $cfg = Read-Config
            $users = @($cfg.users)
            if ($users.Count -gt 0) {
                Write-Host ('{0,-18}{1,-8}{2}' -f 'ユーザー', 'ポート', '状態')
                foreach ($s in $users) {
                    Write-Host ('{0,-18}{1,-8}{2}' -f $s.name, $s.port, (Get-TaskStatus (Get-TaskName $s) ([int]$s.port)))
                }
                Write-Host "(フォルダ: $(Get-InstancesRoot $cfg)\<ユーザー名>)"
                Write-Host ''
            } else { Write-Info "ユーザー環境はまだありません。'jfs.cmd add <ユーザー名>' で作成してください。" }
            if (Get-JfsTask 'jfs-monitor') {
                Write-Host "リソースモニター: ポート $($cfg.monitor.port) / $(Get-TaskStatus 'jfs-monitor' ([int]$cfg.monitor.port))"
            } else {
                Write-Host "リソースモニター: 未設置 ('jfs.cmd monitor' で設置)"
            }
            if ((Get-ProtectJobState) -eq 'running') { Write-Host "アクセス禁止の設定: バックグラウンドで実行中 ('jfs.cmd protect -Status' で確認)" }
        }

        'add' {
            if (-not $Name) { throw 'ユーザー名を指定してください。例: jfs.cmd add alice' }
            $userName = ConvertTo-UserName $Name
            $cfg = Read-Config
            if (Find-UserEnv $cfg $userName) { throw "ユーザー '$userName' は既に存在します ('jfs.cmd list' で確認)。" }
            Get-BasePythonOrThrow $cfg | Out-Null

            Initialize-LocalGroup
            $root = Initialize-InstancesRoot $cfg
            $folder = Join-Path $root $userName
            if ($folder -match "[%`"',]") { throw "フォルダのパスに使えない文字 (% `" ' ,) が含まれています: $folder" }
            if ((Test-Path -LiteralPath $folder) -or (Get-LocalUser -Name "$($script:UserPrefix)$userName" -ErrorAction SilentlyContinue)) {
                throw ("以前の作成途中のデータ (フォルダ $folder またはアカウント $($script:UserPrefix)$userName) が残っています。" +
                       "'jfs.cmd remove $userName -DeleteFiles' で片付けてから、もう一度作成してください。")
            }

            $u = [pscustomobject]@{ name = $userName; port = (Get-RandomPort $cfg); path = $folder; token = (New-Token) }
            try {
                Write-Info "[1/6] 実行用アカウント $(Get-AccountName $u) を作成"
                $sid = New-ServiceAccount (Get-AccountName $u) "jupyter-for-share: $userName"
                Write-Info "[2/6] フォルダとアクセス権を設定: $folder"
                Initialize-InstanceFolders $u $sid
                Write-Info '[3/6] JupyterLab をインストール'
                Install-JupyterLab $cfg $u
                Write-Info '[4/6] venv を作成'
                Install-UserVenv $cfg $u
                Write-ServerFiles $cfg $u

                Write-Info "[5/6] 設定ファイル・ファイアウォール・自動起動を登録 (ポート $($u.port))"
                $cfg.users = @($cfg.users) + $u
                Save-Config $cfg
                Sync-FirewallRules $cfg
                Register-UserTask $u
            } catch {
                $err = $_.Exception.Message
                Write-Warn "作成に失敗したため、途中まで作ったものを片付けます: $err"
                try {
                    Remove-UserLeftovers $userName $folder
                    $cfg = Read-Config
                    $cfg.users = @($cfg.users | Where-Object { $_.name -ne $userName })
                    Save-Config $cfg
                    Sync-FirewallRules $cfg
                } catch {
                    Write-Warn "片付けの一部に失敗しました ($($_.Exception.Message))。'jfs.cmd remove $userName -DeleteFiles' で片付けてください。"
                }
                throw "ユーザー '$userName' の作成に失敗しました: $err"
            }

            Write-Info '[6/6] 起動'
            $ok = Start-UserEnv $u
            Show-UserUrls $cfg $u
            if (-not $ok) { Write-Warn '環境は作成されましたが、まだ起動していません。上の内容を確認してください。' }
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
            Start-UserEnv $u | Out-Null
            Show-UserUrls $cfg $u
        }

        'remove' {
            if (-not $Name) { throw 'ユーザー名を指定してください。' }
            $userName = ConvertTo-UserName $Name
            $cfg = Read-Config
            $u = Find-UserEnv $cfg $userName
            $folder = if ($u) { [string]$u.path } else { Join-Path (Get-InstancesRoot $cfg) $userName }
            $leftover = (Test-Path -LiteralPath $folder) -or (Get-LocalUser -Name "$($script:UserPrefix)$userName" -ErrorAction SilentlyContinue) -or
                        (Get-JfsTask "jfs-$userName")
            if (-not $u -and -not $leftover) { throw "ユーザー '$userName' は登録されていません。'jfs.cmd list' で確認してください。" }
            if (-not $Force) {
                $msg = "ユーザー '$userName' の環境を削除します。"
                if ($DeleteFiles) { $msg += "フォルダ $folder も中身ごと削除されます。" }
                else { $msg += "フォルダ $folder は残ります。" }
                $ans = Read-Host "$msg よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            if ($u) {
                $cfg.users = @($cfg.users | Where-Object { $_.name -ne $userName })
                Save-Config $cfg
            }
            Sync-FirewallRules $cfg
            if ($DeleteFiles) { Remove-UserLeftovers $userName $folder }
            else { Remove-UserLeftovers $userName '' }
            Write-Ok "ユーザー '$userName' の環境を削除しました。"
        }

        'start' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Start-UserEnv $u | Out-Null }
        }

        'stop' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Stop-UserEnv $u }
        }

        'restart' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Stop-UserEnv $u; Start-UserEnv $u | Out-Null }
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
                Start-UserEnv $u | Out-Null
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
                if ($wasRunning) { Start-UserEnv $u | Out-Null }
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
            Start-UserEnv $u | Out-Null
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
            Start-JfsTask 'jfs-monitor' ([int]$cfg.monitor.port) 'リソースモニター' (Get-MonitorPaths).Log | Out-Null
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

        'doctor' {
            Invoke-Doctor (Read-Config) $Name
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
