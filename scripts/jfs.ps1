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
    [switch]$DeleteFiles,   # 互換のため残している (現在は remove で常にフォルダも削除する)
    [switch]$KeepFiles,
    [switch]$Follow,
    [switch]$Force,
    [switch]$Background,
    [switch]$Status,
    [string]$LogFile,
    [switch]$Yes,
    [switch]$SetPrivate,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$script:Commands = @('help', 'list', 'add', 'doctor', 'network', 'set', 'remove', 'start', 'stop', 'restart',
                     'hub', 'refresh', 'autostart', 'uninstall', 'version',
                     'url', 'token', 'logs', 'upgrade', 'reset-venv', 'firewall', 'protect', 'unprotect',
                     'monitor', 'monitor-stop')

# コマンドごとの詳しい説明 (jfs.cmd help <コマンド>)
$script:CommandHelp = @{
    'list'         = "jfs.cmd list`n  ユーザー環境 (ユーザー名・ポート・状態・フォルダ) とリソースモニターの状態を一覧表示します。"
    'add'          = "jfs.cmd add <ユーザー名>`n  ユーザー環境を作成し、接続用 URL を表示します (サーバー管理ウィンドウが動いていればそこで起動。なければ jfs.cmd start で起動)。`n  フォルダは user\<ユーザー名>、ポートは空いている番号から自動で決まります。`n  ユーザー名は半角英数字とハイフン (16 文字以内)。`n例: jfs.cmd add alice"
    'set'          = "jfs.cmd set <ユーザー名> [-Port 番号] [-AllowFrom 範囲]`n  ポートや、接続を許可する相手 (ファイアウォール) を変更して再起動します。`n例: jfs.cmd set alice -Port 23456`n    jfs.cmd set alice -AllowFrom 192.168.1.0/24,192.168.2.10"
    'remove'       = "jfs.cmd remove <ユーザー名> [-KeepFiles] [-Force]`n  ユーザー環境 (実行用アカウント・自動起動・ファイアウォール規則) を、フォルダ user\<ユーザー名> ごと削除します。`n  -KeepFiles: フォルダは残す`n  -Force: 確認せずに削除"
    'start'        = "jfs.cmd start [ユーザー名]`n  サーバーを起動します。省略または all で全員分。`n  サーバー管理ウィンドウがまだなければ、実行したこのウィンドウがサーバー管理ウィンドウになり (新しいウィンドウは開きません)、`n  全員のサーバーのログと実行したコマンドを [ユーザー名] 付きで表示し続けます。`n  ウィンドウを閉じる (または Ctrl+C) と全員のサーバーが停止します。`n  既にサーバー管理ウィンドウがあるときは、そちらで起動されるのを待って終わります。"
    'stop'         = "jfs.cmd stop [ユーザー名]`n  そのユーザーのサーバーを停止します。省略または all で全員を停止し、サーバー管理ウィンドウも閉じます。"
    'restart'      = "jfs.cmd restart [ユーザー名]`n  ユーザー環境を再起動します。省略または all で全員分。"
    'url'          = "jfs.cmd url [ユーザー名]`n  接続用 URL (トークン付き) を表示します。省略すると全員分とリソースモニターの URL。"
    'token'        = "jfs.cmd token <ユーザー名> [-New]`n  接続用 URL を表示します。-New でトークンを再発行します (古い URL は使えなくなります)。"
    'logs'         = "jfs.cmd logs <ユーザー名|monitor> [-Follow]`n  サーバーのログと、利用者が実行したコマンドの記録 (user\<ユーザー名>\.logs) の末尾を表示します。`n  -Follow でサーバーのログの追記を表示し続けます (Ctrl+C で終了)。"
    'autostart'    = "jfs.cmd autostart on|off`n  on: この管理者が Windows にサインインしたとき、全ユーザーのサーバー (サーバー管理ウィンドウ) を自動で開く`n  off: 自動で開かない"
    'uninstall'    = "jfs.cmd uninstall [-DeleteFiles] [-Force]`n  jupyter-for-share が Windows に加えた変更をすべて元に戻します (uninstall.cmd と同じ)。`n  サーバーとリソースモニターの停止、自動起動タスク・ファイアウォール規則・実行用アカウント・グループの削除、`n  アクセス禁止 (拒否) の解除 (記録がないものも全ドライブから探す)、このフォルダのアクセス権を元に戻す。`n  ユーザーのフォルダ (user\<名前>\work など) は残します。-DeleteFiles で user フォルダも削除します。`n  実行後は、このフォルダを普通に削除できます。"
    'version'      = "jfs.cmd version`n  jupyter-for-share のバージョン (git のコミット) を表示します。"
    'refresh'      = "jfs.cmd refresh`n  全ユーザーの起動用ファイル・設定・起動用タスクを作り直します (更新後に setup.cmd から自動で実行されます)。"
    'upgrade'      = "jfs.cmd upgrade [ユーザー名]`n  JupyterLab 本体を最新版に更新します。省略で全員分。venv に入れたパッケージはそのまま。"
    'reset-venv'   = "jfs.cmd reset-venv <ユーザー名> [-Force]`n  venv を作り直します (pip で入れたパッケージは消えます。work フォルダのファイルは残ります)。"
    'monitor'      = "jfs.cmd monitor [-Port 番号] [-AllowFrom 範囲]`n  リソースモニター (CPU / メモリ / GPU) を設置・更新します。既定のポートは 8000。`n  モニターは jfs.cmd start のサーバー管理ウィンドウの中で、ユーザーのサーバーと一緒に動きます。"
    'monitor-stop' = "jfs.cmd monitor-stop`n  リソースモニターを停止します (再開は jfs.cmd monitor)。"
    'doctor'       = "jfs.cmd doctor [ユーザー名]`n  ユーザー名を付けると、そのユーザーの実行用アカウントとして各フォルダを読めるかのテストも行います。`n  つながらないときの診断です。アカウント・自動起動タスク・待ち受けポート・HTTP 応答・`n  ファイアウォール・ネットワークの種類・ログを確認し、問題のある箇所に [NG] を表示します。"
    'network'      = "jfs.cmd network [-SetPrivate] [-Yes]`n  他の PC から接続できないとき用。ネットワークとファイアウォールの現状を確認して表示し、`n  必要な変更 (ポートの許可・ping の許可・名前解決の許可・python をブロックする規則の無効化) を`n  一覧にしてから、確認のうえ適用します。適用後にもう一度状態を表示します。`n  -SetPrivate: 「パブリック」の LAN 接続を「プライベート」に変更する`n  -Yes: 確認せずに適用する"
    'firewall'     = "jfs.cmd firewall`n  Windows ファイアウォール規則を設定ファイル (servers.json) に合わせて作り直します。"
    'protect'      = "jfs.cmd protect [-Force]`njfs.cmd protect -Status`n  サーバー実行用アカウントから他のフォルダへのアクセスを禁止します。このウィンドウで実行し、終わるまで進み具合を表示します。`n  設定済みの場所は飛ばします。-Force: 設定済みの場所も付け直す / -Status: 設定状況を表示"
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
  jfs.cmd add <ユーザー名>              作成 (ポートは自動で決定)
  jfs.cmd list                          一覧と状態
  jfs.cmd url [ユーザー名]              接続用 URL を表示
  jfs.cmd start [ユーザー名]            起動 (省略で全員)。このウィンドウがサーバー管理ウィンドウになり、閉じると全員停止
  jfs.cmd stop|restart [ユーザー名]     停止 / 再起動 (省略で全員)
  jfs.cmd remove <ユーザー名>           フォルダごと削除 (-KeepFiles でフォルダは残す)
  jfs.cmd token <ユーザー名> -New       トークンを再発行
  jfs.cmd set <ユーザー名> -Port 番号   ポートなどを変更
  jfs.cmd logs <ユーザー名> [-Follow]   ログと実行コマンドの記録を表示
  jfs.cmd upgrade [ユーザー名]          JupyterLab を更新
  jfs.cmd reset-venv <ユーザー名>       venv を作り直す

リソースモニター (CPU / メモリ / GPU)
  jfs.cmd monitor [-Port 8000]          設置・更新 (サーバー管理ウィンドウの中で動く)
  jfs.cmd monitor-stop                  停止

サーバー全体
  jfs.cmd autostart on|off              サインイン時に全員のサーバーを自動で開く
  jfs.cmd refresh                       起動用ファイルなどを作り直す (更新後)
  jfs.cmd doctor [ユーザー名]           つながらないときの診断
  jfs.cmd network [-SetPrivate]         他の PC から接続できるようにネットワーク設定を確認・変更
  jfs.cmd firewall                      ファイアウォール規則を更新
  jfs.cmd protect                       他のフォルダへのアクセスを禁止 (-Status で設定状況)
  jfs.cmd unprotect                     アクセス禁止を解除

  jfs.cmd uninstall                     Windows に加えた変更をすべて元に戻す (uninstall.cmd と同じ)
  jfs.cmd version                       バージョンを表示

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
        RunCmd  = Join-Path $srv 'run.cmd'
        Heartbeat = Join-Path $srv 'heartbeat'
        Launcher  = Join-Path $srv 'config\launcher.py'
        TermInit  = Join-Path $srv 'config\terminal-init.ps1'
        IPyStartup = Join-Path $srv 'home\.ipython\profile_default\startup\00-jupyter-for-share.py'
        # ログ (サーバーの出力と、利用者が実行したコマンド)
        Logs       = Join-Path $root '.logs'
        Log        = Join-Path $root '.logs\server.log'
        CommandLog = Join-Path $root '.logs\commands.log'
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
        Heartbeat = Join-Path $rt 'heartbeat'
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
        } catch {
            if ($_.FullyQualifiedErrorId -notlike 'MemberExists*') { throw }   # 既にメンバーなら問題なし
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
#   user\<名前>\.server  … JupyterLab 本体・設定 (読み取りのみ) と、ホーム・一時ファイルなど (変更可)
#   user\<名前>\.logs    … サーバーのログと、利用者が実行したコマンドの記録 (変更可)
function Initialize-InstanceFolders($UserEnv, [string]$AccountSid) {
    $p = Get-InstancePaths $UserEnv
    # 以前の環境を引き継ぐとき: ユーザーが書き込める場所に作られたリンクをたどってフォルダを作らないようにする
    foreach ($t in @((Join-Path $p.Home 'AppData\Roaming'), (Join-Path $p.Home 'AppData\Local'), $p.IPyStartup)) {
        Remove-LinksOnPath $p.Server $t
    }
    foreach ($d in @($p.Root, $p.Work, $p.Venv, $p.Server, $p.Config, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs,
                     (Join-Path $p.Home 'AppData\Roaming'), (Join-Path $p.Home 'AppData\Local'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    (Get-Item -LiteralPath $p.Server -Force).Attributes = 'Directory, Hidden'
    New-Item -ItemType Directory -Path (Split-Path -Parent $p.IPyStartup) -Force | Out-Null

    Invoke-Native 'icacls.exe' @($p.Root, '/inheritance:r', '/grant:r',
        "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidAdmins):(OI)(CI)F",
        "*$(Get-CurrentUserSid):(OI)(CI)F", "*$($AccountSid):(OI)(CI)RX", '/Q') -Quiet
    # Config: JupyterLab が設定 (拡張機能の有効・無効など) を書き込むことがある
    foreach ($d in @($p.Work, $p.Venv, $p.Config, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs)) {
        Invoke-Native 'icacls.exe' @($d, '/grant', "*$($AccountSid):(OI)(CI)M", '/Q') -Quiet
    }
}

# 古いバージョンで作った環境に .logs フォルダを追加する (フォルダ全体のアクセス権は付け直さない)
# 起動前に、サーバー実行用アカウントが書き込む必要のあるフォルダに書き込めるようにしておく
# (以前のバージョンで作った環境にも、後から追加したフォルダの権限を付ける)
function Initialize-LogsFolder($UserEnv) {
    $p = Get-InstancePaths $UserEnv
    $user = Get-LocalUser -Name (Get-AccountName $UserEnv) -ErrorAction SilentlyContinue
    if (-not $user) { return }
    $sid = $user.SID.Value
    foreach ($d in @($p.Logs, $p.Config)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $canWrite = $false
        try {
            foreach ($r in (Get-Acl -LiteralPath $d).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                if ($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Value -eq $sid -and
                    ($r.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify) -eq [System.Security.AccessControl.FileSystemRights]::Modify) {
                    $canWrite = $true
                }
            }
        } catch { }
        if (-not $canWrite) { Invoke-Native 'icacls.exe' @($d, '/grant', "*$($sid):(OI)(CI)M", '/Q') -Quiet }
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
    if ((Test-Path -LiteralPath $py) -and (Get-PythonVersion $py)) {
        Write-Info "JupyterLab 用の venv は作成済みです: $($p.LabVenv)"
    } else {
        # 無いか、元にした Python が無くなって動かない (venv を作り直すと中のパッケージは残したまま直る)
        Invoke-Native (Get-BasePythonOrThrow $Config) @('-m', 'venv', $p.LabVenv) -Quiet
    }
    $pkgs = @('jupyterlab')
    $locale = [string](Get-Value $Config.defaults 'labLocale' 'ja_JP')
    if ($locale -and $locale -notmatch '^en') { $pkgs += "jupyterlab-language-pack-$($locale.Replace('_', '-'))" }
    $pkgs += @(Get-Value $Config.defaults 'extraServerPackages' @())

    # 入っていないものだけ入れる (-Upgrade のときは全部を最新にする)
    $todo = if ($Upgrade) { $pkgs } else { @(Get-MissingPackages $py $pkgs) }
    if ($todo.Count -eq 0) {
        Write-Ok "JupyterLab と関連パッケージはインストール済みです ($($pkgs -join ', '))。"
    } else {
        Write-Info "JupyterLab をインストールしています ($($UserEnv.name): $($todo -join ', '))。数分かかります..."
        Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip') -Quiet
        $a = @('-m', 'pip', 'install', '--disable-pip-version-check')
        if ($Upgrade) { $a += '--upgrade' }
        Invoke-Native $py ($a + $todo) -Quiet
    }

    if ($locale) {
        $dir = Join-Path $p.LabVenv 'share\jupyter\lab\settings'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = '{ "@jupyterlab/translation-extension:plugin": { "locale": "' + $locale + '" } }'
        [System.IO.File]::WriteAllText((Join-Path $dir 'overrides.json'), $json)
    }
    Write-Ok 'JupyterLab の準備ができました。'
}

# 利用者がパッケージを入れる venv を作り、JupyterLab の既定カーネル (python3) にする
function Install-UserVenv($Config, $UserEnv) {
    $p = Get-InstancePaths $UserEnv
    $py = Join-Path $p.Venv 'Scripts\python.exe'
    $pkgs = @('ipykernel') + @(Get-Value $Config.defaults 'venvPackages' @())
    # ユーザーが使ってきた venv の中身 (Python のコード) は、管理者の権限では実行しない。
    # (sitecustomize.py などを置かれると、管理者として任意の処理を実行されてしまうため)
    if (Test-Path -LiteralPath $py) {
        if (-not (Test-VenvBase $p.Venv)) {
            # 元にした Python が無くなっている: 作り直す (中のパッケージは残る)
            Write-Info "venv の元の Python が見つからないため、venv を作り直します: $($p.Venv)"
            Remove-LinksIn $p.Venv | Out-Null
            Invoke-Native (Get-BasePythonOrThrow $Config) @('-m', 'venv', $p.Venv) -Quiet
        }
        Write-Info "venv は作成済みのため、そのまま使います: $($p.Venv) (足りないパッケージはターミナルで pip install してください)"
        Register-VenvKernel $UserEnv
        return
    }
    Write-Info "venv を作成しています: $($p.Venv)"
    Invoke-Native (Get-BasePythonOrThrow $Config) @('-m', 'venv', $p.Venv) -Quiet
    $todo = @(Get-MissingPackages $py $pkgs)
    if ($todo.Count -eq 0) {
        Write-Ok "venv のパッケージはインストール済みです ($($pkgs -join ', '))。"
    } else {
        Write-Info "venv にインストールしています: $($todo -join ', ')"
        Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip') -Quiet
        Invoke-Native $py (@('-m', 'pip', 'install', '--disable-pip-version-check') + $todo) -Quiet
    }
    Register-VenvKernel $UserEnv
    Write-Ok "venv の準備ができました (パッケージ: $($pkgs -join ', '))。"
}

# JupyterLab の既定カーネル (python3) を利用者用 venv の Python にする。
# JupyterLab 側の ipykernel をインストール・更新すると python3 カーネルが上書きされるので、その後に必ず呼ぶ。
# venv の pyvenv.cfg に書かれた元の Python が残っているか (venv の Python は実行せずに確認する)
function Test-VenvBase([string]$Venv) {
    $cfgFile = Join-Path $Venv 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $cfgFile)) { return $false }
    foreach ($line in [System.IO.File]::ReadAllLines($cfgFile)) {
        if ($line -match '^\s*home\s*=\s*(.+?)\s*$') {
            try { return Test-Path -LiteralPath ([System.IO.Path]::Combine($Matches[1], 'python.exe')) } catch { return $false }
        }
    }
    return $false
}

# ノートブックで venv の Python を使うためのカーネルを、JupyterLab 側 (.server\lab) に登録する。
# venv の Python (ユーザーが中身を変えられる) は実行せず、kernel.json を直接書く
function Register-VenvKernel($UserEnv) {
    $p = Get-InstancePaths $UserEnv
    $py = Join-Path $p.Venv 'Scripts\python.exe'
    $dir = Join-Path $p.LabVenv 'share\jupyter\kernels\python3'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $spec = [ordered]@{
        argv         = @($py, '-m', 'ipykernel_launcher', '-f', '{connection_file}')
        display_name = 'Python 3 (venv)'
        language     = 'python'
        metadata     = @{ debugger = $true }
    }
    [System.IO.File]::WriteAllText((Join-Path $dir 'kernel.json'), (ConvertTo-Json -InputObject $spec -Depth 5),
                                   (New-Object System.Text.UTF8Encoding($false)))
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
# ターミナルは PowerShell。起動時に terminal-init.ps1 を読み込み、実行したコマンドを .logs に記録する
c.ServerApp.terminado_settings = {'shell_command': [
    'powershell.exe', '-NoLogo', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', r'@@TERMINIT@@']}
'@
    $py = Expand-Template $py @{ BIND = $bind; PORT = [string][int]$UserEnv.port; WORK = $p.Work
                                 TOKEN = [string]$UserEnv.token; TERMINIT = $p.TermInit }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    # config と home はユーザーも書き込めるので、書き込む先にリンクがあれば先に消す (リンク先を上書きしないように)
    foreach ($f in @((Join-Path $p.Config 'jupyter_server_config.py'), (Join-Path $p.Config 'migrated'), $p.Launcher, $p.TermInit)) {
        Remove-LinksOnPath $p.Server $f
    }
    Remove-LinksOnPath $p.Server $p.IPyStartup
    [System.IO.File]::WriteAllText((Join-Path $p.Config 'jupyter_server_config.py'), $py, $utf8)
    # IPython のフォルダがあると、Jupyter は起動時に古い設定の移行を試みて設定フォルダに 'migrated' を書き込もうとする。
    # 移行するものはないので、済んだ印を先に置いておく
    $marker = Join-Path $p.Config 'migrated'
    if (-not (Test-Path -LiteralPath $marker)) { [System.IO.File]::WriteAllText($marker, (Get-Date).ToUniversalTime().ToString('o'), $utf8) }

    # ランチャー (サーバー管理ウィンドウが閉じたら停止) と、コマンド記録用のスクリプトを配置する
    $src = Join-Path $script:RepoRoot 'server'
    Copy-Item -LiteralPath (Join-Path $src 'launcher.py') -Destination $p.Launcher -Force
    Copy-Item -LiteralPath (Join-Path $src 'terminal-init.ps1') -Destination $p.TermInit -Force
    New-Item -ItemType Directory -Path (Split-Path -Parent $p.IPyStartup) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $src 'ipython-startup.py') -Destination $p.IPyStartup -Force

    # HOME や AppData などを環境のフォルダ内に向け、venv を PATH の先頭に置いて JupyterLab を起動する
    $cmd = @'
@echo off
rem Generated by jupyter-for-share. Do not edit: the jfs.cmd command overwrites this file.
rem Everything is inside one ( ) block: cmd.exe reads the whole block before running it, so rewriting
rem this file while the server is running (jfs.cmd refresh, setup.cmd, git pull) cannot break it.
(
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
  set "JFS_COMMAND_LOG=@@CMDLOG@@"
  cd /d "@@WORK@@"
  if exist "@@LOG@@" for %%F in ("@@LOG@@") do if %%~zF GTR 10485760 move /y "@@LOG@@" "@@LOG@@.1" >nul
  echo ===== %DATE% %TIME% start >> "@@LOG@@"
  "@@LABVENV@@\Scripts\python.exe" "@@LAUNCHER@@" "@@HEARTBEAT@@" >> "@@LOG@@" 2>&1
  exit /b
)
'@
    $cmd = Expand-Template $cmd @{
        HOME = $p.Home; TMP = $p.Tmp; CONFIG = $p.Config; DATA = $p.Data; RUNTIME = $p.Runtime
        VENV = $p.Venv; WORK = $p.Work; LOG = $p.Log; LABVENV = $p.LabVenv
        CMDLOG = $p.CommandLog; LAUNCHER = $p.Launcher; HEARTBEAT = $p.Heartbeat
    }
    Write-BatchFile $p.RunCmd $cmd
    Write-UserReadme $Config $UserEnv
}

# 利用者向けの短い README を作業フォルダに置く (利用者が書き換えた場合は上書きしない)
function Write-UserReadme($Config, $UserEnv) {
    $p = Get-InstancePaths $UserEnv
    if (-not (Test-Path -LiteralPath $p.Work)) { return }
    $path = Join-Path $p.Work 'README.md'
    if (Test-ReparsePoint $path) { return }   # ユーザーがリンクに置き換えた: 触らない
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

# -OnDemand: Windows 起動時には起動せず、サーバー管理ウィンドウ (jfs.cmd start) からだけ起動する
function Register-JfsTask([string]$TaskName, [string]$Account, [string]$RunCmd, [string]$WorkDir, [string]$Description,
                          [switch]$OnDemand) {
    # パスワードは保存せず、登録のたびに新しいランダムなものを設定する
    $plain = New-RandomPassword
    Set-LocalUser -Name $Account -Password (ConvertTo-SecureString $plain -AsPlainText -Force)

    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -Argument "/d /c `"`"$RunCmd`"`"" -WorkingDirectory $WorkDir
    $taskArgs = @{
        TaskName = $TaskName; TaskPath = $script:TaskPath; Action = $action
        User = "$env:COMPUTERNAME\$Account"; Password = $plain; RunLevel = 'Limited'; Description = $Description
    }
    if ($OnDemand) {
        $taskArgs.Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 5
    } else {
        $taskArgs.Trigger = New-ScheduledTaskTrigger -AtStartup
        $taskArgs.Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -MultipleInstances IgnoreNew -Priority 5
    }
    Register-ScheduledTask @taskArgs -Force | Out-Null
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
    $procs = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -eq $full })
    if ($procs.Count -gt 0) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        # 強制終了直後はファイルのロックが残ることがあるので、終わるまで少し待つ
        $procs | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    }
    Write-Ok "$Label を停止しました。"
}

function Get-TaskStatus([string]$TaskName, [int]$P) {
    $task = Get-JfsTask $TaskName
    if (-not $task) { return '未設置' }
    if ($task.State -eq 'Disabled') { return '停止' }
    if (Test-PortListening $P) { return '起動中' }
    if ($task.State -eq 'Running') { return '起動処理中' }
    return "停止 ('jfs.cmd start' のサーバー管理ウィンドウで動きます)"
}

function Register-UserTask($UserEnv) {
    Register-JfsTask (Get-TaskName $UserEnv) (Get-AccountName $UserEnv) (Get-InstancePaths $UserEnv).RunCmd `
        (Get-InstancePaths $UserEnv).Work "jupyter-for-share: $($UserEnv.name) (port $($UserEnv.port))" -OnDemand
}

# ---- サーバー管理ウィンドウ (全ユーザーのサーバーを 1 つのウィンドウで動かす) ----
# jfs.cmd start でウィンドウを 1 つ開き (jfs.ps1 hub)、その中で起動対象のユーザーのサーバーを動かし、
# 全員分のログと実行コマンドを [ユーザー名] 付きで表示し続ける。
# ウィンドウはユーザーごとのハートビートファイルを毎秒更新し、更新が止まる (ウィンドウが閉じられる) と
# 各ユーザーのランチャー (server\launcher.py) が JupyterLab・カーネル・ターミナルを停止する。
# 起動対象のユーザーは .runtime\hub-wanted.json で管理し、jfs.cmd start / stop で変更する。

function Get-HubPaths {
    $dir = Join-Path $script:RepoRoot '.runtime'
    return [pscustomobject]@{
        Dir    = $dir
        Record = Join-Path $dir 'hub.json'
        Wanted = Join-Path $dir 'hub-wanted.json'
    }
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-TextFileSafe $Path (ConvertTo-Json -InputObject $Object -Depth 5)
}

# サーバー管理ウィンドウのプロセス (開いていなければ $null)
function Get-HubProcess {
    $f = (Get-HubPaths).Record
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $rec = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $proc = Get-Process -Id ([int]$rec.pid) -ErrorAction Stop
        if ($proc.ProcessName -eq 'powershell' -and [math]::Abs(($proc.StartTime - [datetime]$rec.started).TotalSeconds) -lt 5) {
            return $proc
        }
    } catch { }
    return $null
}

# 起動対象: all = 設定ファイルの全員 / users = 個別に指定したユーザー
function Get-Wanted {
    $f = (Get-HubPaths).Wanted
    # hold: 更新作業などで一時的に止めているユーザー (止めている間もサーバー管理ウィンドウは閉じない)
    $w = [pscustomobject]@{ all = $false; users = @(); hold = @() }
    if (Test-Path -LiteralPath $f) {
        try {
            $data = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            $w.all = [bool]$data.all
            $w.users = @(foreach ($x in @($data.users)) { if ($x) { [string]$x } })
            $w.hold = @(foreach ($x in @($data.hold)) { if ($x) { [string]$x } })
        } catch {
            # 読めなかったときは前回の内容を使う (空として扱うと全員のサーバーが止まってしまう)
            if ($script:LastWanted) { return $script:LastWanted }
        }
    }
    $script:LastWanted = $w
    return $w
}

function Save-Wanted([bool]$All, [string[]]$Users, $Hold = $null) {
    if ($null -eq $Hold) { $Hold = (Get-Wanted).hold }
    Write-JsonFile (Get-HubPaths).Wanted @{
        all = $All
        users = @($Users | Where-Object { $_ } | Select-Object -Unique)
        hold = @($Hold | Where-Object { $_ } | Select-Object -Unique)
    }
}

# 更新作業の間だけサーバーを止める / 再開する (サーバー管理ウィンドウは開いたまま)
function Suspend-UserEnv($UserEnv) {
    $w = Get-Wanted
    Save-Wanted $w.all $w.users (@($w.hold) + $UserEnv.name)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Test-PortListening ([int]$UserEnv.port)) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    Stop-JfsTask (Get-TaskName $UserEnv) (Get-AccountName $UserEnv) "ユーザー '$($UserEnv.name)' の環境"
}

function Resume-UserEnv($UserEnv) {
    $w = Get-Wanted
    Save-Wanted $w.all $w.users @($w.hold | Where-Object { $_ -ne $UserEnv.name })
    if (Wait-UserListening $UserEnv) { Write-Ok "ユーザー '$($UserEnv.name)' の環境を再開しました (ポート $($UserEnv.port))。" }
    else { Write-Warn "ユーザー '$($UserEnv.name)' の環境が起動しませんでした。サーバー管理ウィンドウの表示を確認してください。" }
}

function Test-Wanted($Wanted, [string]$UserName) {
    return ($Wanted.all -or ($Wanted.users -contains $UserName))
}

function Add-Wanted([string]$UserName) {
    $w = Get-Wanted
    Save-Wanted $w.all (@($w.users) + $UserName)
}

function Remove-Wanted($Config, [string]$UserName) {
    $w = Get-Wanted
    $users = if ($w.all) { @($Config.users | ForEach-Object { $_.name }) } else { @($w.users) }
    Save-Wanted $false @($users | Where-Object { $_ -ne $UserName })
}

function Get-UserStatus($UserEnv) {
    $listening = Test-PortListening ([int]$UserEnv.port)
    $hub = [bool](Get-HubProcess)
    $wanted = Test-Wanted (Get-Wanted) $UserEnv.name
    if ($hub -and $wanted -and $listening) { return '起動中' }
    if ($hub -and $wanted) { return '起動処理中' }
    if ($listening) { return "起動中 (管理ウィンドウの外で動いています。'jfs.cmd restart $($UserEnv.name)' で切り替え)" }
    return '停止'
}

function Wait-UserListening($UserEnv, [int]$TimeoutSec = 150) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortListening ([int]$UserEnv.port)) { return $true }
        if (-not (Get-HubProcess)) { return $false }   # ウィンドウが閉じられた
        Start-Sleep -Seconds 2
    }
    return $false
}

# ユーザーを起動対象にする。サーバー管理ウィンドウ (jfs.cmd start を実行したウィンドウ) が
# 動いていればそこで起動されるのを待ち、動いていなければ起動方法を案内する (新しいウィンドウは開かない)
function Start-UserEnv($UserEnv) {
    $label = "ユーザー '$($UserEnv.name)' の環境"
    Add-Wanted $UserEnv.name
    if (-not (Get-HubProcess)) {
        Write-Info "$label を起動するには 'jfs.cmd start $($UserEnv.name)' (全員なら 'jfs.cmd start') を実行してください。"
        Write-Info '実行したウィンドウがサーバー管理ウィンドウになり、ログが表示されます。'
        return $false
    }
    if (Test-PortListening ([int]$UserEnv.port)) { Write-Info "$label は起動済みです。"; return $true }
    Write-Info "$label の起動を待っています (サーバー管理ウィンドウで起動します。初回は 1 分ほどかかることがあります)..."
    if (Wait-UserListening $UserEnv) {
        Write-Ok "$label が起動しました (ポート $($UserEnv.port))。"
        return $true
    }
    Write-Warn "$label がポート $($UserEnv.port) で起動しませんでした。サーバー管理ウィンドウの表示を確認してください。"
    Show-LogTail (Get-InstancePaths $UserEnv).Log
    Write-Host '  詳しい診断: jfs.cmd doctor'
    return $false
}

# ユーザーを起動対象から外し、サーバー (実行用アカウントのプロセス) を停止する
function Stop-UserEnv($UserEnv, $Config) {
    if (-not $Config) { $Config = Read-Config }
    Remove-Wanted $Config $UserEnv.name
    if (Get-HubProcess) {
        # 管理ウィンドウ側で止めるのを少し待つ
        $deadline = (Get-Date).AddSeconds(15)
        while ((Test-PortListening ([int]$UserEnv.port)) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    }
    Remove-Item -LiteralPath (Get-InstancePaths $UserEnv).Heartbeat -ErrorAction SilentlyContinue
    Stop-JfsTask (Get-TaskName $UserEnv) (Get-AccountName $UserEnv) "ユーザー '$($UserEnv.name)' の環境"
}

# ログファイルに追記された分を読む (読み込み位置と、行の途中・文字の途中を覚えておく)
function New-LogTail([string]$Path) {
    $pos = 0
    if (Test-Path -LiteralPath $Path) { $pos = (Get-Item -LiteralPath $Path).Length }   # 過去の分は表示しない
    return [pscustomobject]@{ Path = $Path; Position = [long]$pos; Rest = ''; Decoder = [System.Text.Encoding]::UTF8.GetDecoder() }
}

function Read-LogTail($Tail) {
    if (-not (Test-Path -LiteralPath $Tail.Path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($Tail.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                     [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    } catch { return @() }   # ログの切り替え中などで開けなかった: 次の回に読む
    try {
        if ($fs.Length -lt $Tail.Position) { $Tail.Position = 0 }   # ログが切り替わった
        if ($fs.Length -eq $Tail.Position) { return @() }
        $fs.Position = $Tail.Position
        $buf = New-Object byte[] ([int][math]::Min($fs.Length - $Tail.Position, 1MB))
        $n = $fs.Read($buf, 0, $buf.Length)
        $Tail.Position += $n
    } finally {
        $fs.Dispose()
    }
    $chars = New-Object char[] ($Tail.Decoder.GetCharCount($buf, 0, $n))
    [void]$Tail.Decoder.GetChars($buf, 0, $n, $chars, 0)
    $parts = ($Tail.Rest + (-join $chars)) -split "`r?`n"
    $Tail.Rest = $parts[-1]
    if ($parts.Count -le 1) { return @() }
    return $parts[0..($parts.Count - 2)]
}

function Write-ServerLine([string]$Line) {
    if ($Line -match '^\[(E|C) ' -or $Line -match 'Traceback|Error') { Write-Host $Line -ForegroundColor Red }
    elseif ($Line -match '^\[W ') { Write-Host $Line -ForegroundColor Yellow }
    elseif ($Line -match '^\[jupyter-for-share\]|^=====') { Write-Host $Line -ForegroundColor Green }
    else { Write-Host $Line }
}

function Write-UserLine([string]$UserName, [string]$Line, [string]$Kind = 'server') {
    Write-Host ("[{0}] " -f $UserName) -NoNewline -ForegroundColor Magenta
    if ($Kind -eq 'command') { Write-Host "[コマンド] $Line" -ForegroundColor Cyan; return }
    Write-ServerLine $Line
}

# サーバー管理ウィンドウを閉じずに、1 人のサーバーだけを再起動する
# (プロセスを止めると、管理ウィンドウが設定ファイルを読み直して起動し直す)
function Restart-UserEnv($UserEnv, $Config) {
    if (-not ((Get-HubProcess) -and (Test-Wanted (Get-Wanted) $UserEnv.name))) {
        # サーバー管理ウィンドウで動いていない: 外で動いている古いサーバーがあれば止めておく
        if (Test-PortListening ([int]$UserEnv.port)) {
            Stop-JfsTask (Get-TaskName $UserEnv) (Get-AccountName $UserEnv) "ユーザー '$($UserEnv.name)' の環境"
        }
        Write-Info "変更は次回の起動から反映されます ('jfs.cmd start $($UserEnv.name)')。"
        return $false
    }
    Stop-JfsTask (Get-TaskName $UserEnv) (Get-AccountName $UserEnv) "ユーザー '$($UserEnv.name)' の環境"
    Write-Info "ユーザー '$($UserEnv.name)' の環境を再起動しています..."
    $deadline = (Get-Date).AddSeconds(5)
    while ((Test-PortListening ([int]$UserEnv.port)) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (Wait-UserListening $UserEnv) { Write-Ok "ユーザー '$($UserEnv.name)' の環境を再起動しました (ポート $($UserEnv.port))。"; return $true }
    Write-Warn "ユーザー '$($UserEnv.name)' の環境が起動しませんでした。サーバー管理ウィンドウの表示を確認してください。"
    return $false
}

# jfs.cmd start [ユーザー名|all]
# サーバー管理ウィンドウが動いていなければ、このウィンドウをサーバー管理ウィンドウにする (新しいウィンドウは開かない)
function Start-Users($Config, [string]$UserName) {
    $users = @($Config.users)
    if ($users.Count -eq 0) { throw "ユーザー環境がありません。'jfs.cmd add <ユーザー名>' で作成してください。" }
    $hub = Get-HubProcess
    if ($UserName -and $UserName -ne 'all') {
        $targets = @(Get-RequiredUser $Config $UserName)
        # サーバー管理ウィンドウが無いときは、前回 (閉じたときのまま) の起動対象・一時停止は引き継がない
        if ($hub) { Add-Wanted $targets[0].name } else { Save-Wanted $false @($targets[0].name) @() }
    } else {
        $targets = $users
        if ($hub) { Save-Wanted $true @() } else { Save-Wanted $true @() @() }
    }
    if (-not $hub) {
        Invoke-Hub
        return
    }
    Write-Info 'サーバー管理ウィンドウは既に開いています。そちらで起動されるのを待っています...'
    foreach ($u in $targets) {
        if (Wait-UserListening $u) { Write-Ok "ユーザー '$($u.name)' (ポート $($u.port)) が起動しました。" }
        else { Write-Warn "ユーザー '$($u.name)' が起動しませんでした。サーバー管理ウィンドウの表示を確認してください。" }
    }
}

# jfs.cmd stop [ユーザー名|all]
function Stop-Users($Config, [string]$UserName) {
    if ($UserName -and $UserName -ne 'all') { Stop-UserEnv (Get-RequiredUser $Config $UserName) $Config; return }
    Save-Wanted $false @()
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-HubProcess) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }   # ウィンドウ側で止めて閉じる
    foreach ($u in @($Config.users)) {
        Remove-Item -LiteralPath (Get-InstancePaths $u).Heartbeat -ErrorAction SilentlyContinue
        Stop-JfsTask (Get-TaskName $u) (Get-AccountName $u) "ユーザー '$($u.name)' の環境"
    }
}

# サーバー管理ウィンドウで動かしているもの (ユーザーのサーバー・リソースモニター) 1 つ分の処理:
# ハートビートを更新し、止まっていたら (10 秒おいて) 起動し直す
function Update-ManagedTask($St, [string]$Label) {
    [System.IO.File]::WriteAllText($St.Heartbeat, (Get-Date).ToString('o'))
    $task = Get-JfsTask $St.Task
    $stateName = if ($task) { [string]$task.State } else { 'Missing' }
    if ($stateName -eq 'Running' -or ((Get-Date) - $St.StartedAt).TotalSeconds -lt 10) { return }
    if ($St.Running) {
        $info = Get-ScheduledTaskInfo -TaskPath $script:TaskPath -TaskName $St.Task -ErrorAction SilentlyContinue
        $result = if ($info) { Get-TaskResultText $info.LastTaskResult } else { '不明' }
        Write-UserLine $Label "[jupyter-for-share] 停止しました (結果: $result)。10 秒後に再起動します。"
        $St.Running = $false
        $St.NextStart = (Get-Date).AddSeconds(10)
    }
    if ((Get-Date) -ge $St.NextStart) {
        if ($task -and $stateName -eq 'Disabled') { Enable-ScheduledTask -InputObject $task | Out-Null }
        Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $St.Task
        $St.Running = $true
        $St.StartedAt = Get-Date
    }
}

# ---- 自動更新 (サーバー管理ウィンドウから定期的に git pull) ----

# 更新後の jfs.ps1 / common.ps1 の関数を読み込み直す (サーバーは動かしたまま、次の処理から新しい内容で動く)。
# 構文エラーがあれば何も変えない
function Import-JfsCode {
    $files = @((Join-Path $script:RepoRoot 'scripts\common.ps1'), (Join-Path $script:RepoRoot 'scripts\jfs.ps1'))
    $code = @()
    foreach ($file in $files) {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { throw "$file に構文エラーがあります: $($errors[0].Message)" }
        # 一番外側の $script: 変数 (定数など。スクリプトの場所から決まるものは除く) と関数の定義
        foreach ($st in $ast.EndBlock.Statements) {
            if ($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $st.Left.Extent.Text -like '$script:*' -and $st.Extent.Text -notmatch 'PSScriptRoot|PSCommandPath') {
                $code += $st.Extent.Text
            }
        }
        foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            $code += ($f.Extent.Text -replace '^function\s+', 'function script:')
        }
    }
    foreach ($c in $code) { Invoke-Expression $c }
}

function Get-GitHead([string]$Git) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return [string](& $Git -c safe.directory=* -C $script:RepoRoot rev-parse HEAD 2>$null) }
    finally { $ErrorActionPreference = $prev }
}

# サーバー管理ウィンドウから毎秒呼ばれる。autoUpdateMinutes (既定 60 分。0 で無効) ごとに git pull を実行する。
# git はこのウィンドウの子プロセスとして動かし、終わるのを毎秒確認する (待っている間もハートビートは止めない)
function Update-AutoUpdate($State, $Config, [bool]$MonitorRunning) {
    $minutes = [int](Get-Value $Config.defaults 'autoUpdateMinutes' 60)
    if ($minutes -le 0) { return $null }
    if (-not $State) {
        # 最初の確認は起動の 1 分後
        return [pscustomobject]@{ Next = (Get-Date).AddMinutes(1); Proc = $null; Out = ''; Started = $null; Before = ''; Git = '' }
    }
    if (-not $State.Proc) {
        if ((Get-Date) -lt $State.Next) { return $State }
        $State.Next = (Get-Date).AddMinutes($minutes)
        $git = Get-GitExe
        if (-not $git -or -not (Test-Path -LiteralPath (Join-Path $script:RepoRoot '.git'))) { return $State }
        $State.Git = $git
        $State.Before = Get-GitHead $git
        $State.Out = [System.IO.Path]::GetTempFileName()
        # 認証の画面などで止まらないようにする (公開リポジトリなら認証は不要)
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        $State.Proc = Start-Process -FilePath $git -NoNewWindow -PassThru `
            -ArgumentList @('-c', 'safe.directory=*', '-C', "`"$($script:RepoRoot)`"", 'pull', '--ff-only', '--quiet') `
            -RedirectStandardOutput $State.Out -RedirectStandardError "$($State.Out).err"
        $null = $State.Proc.Handle   # 終了コードを後で取得するために必要
        $State.Started = Get-Date
        return $State
    }

    $proc = $State.Proc
    if (-not $proc.HasExited) {
        if (((Get-Date) - $State.Started).TotalMinutes -ge 5) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-UserLine '更新' '[jupyter-for-share] git pull が 5 分以内に終わらなかったため中止しました。次回また試します。'
            $State.Proc = $null
        }
        return $State
    }
    $proc.WaitForExit()
    $State.Proc = $null
    $msg = (Get-Content -LiteralPath $State.Out, "$($State.Out).err" -ErrorAction SilentlyContinue | Where-Object { $_ }) -join ' / '
    Remove-Item -LiteralPath $State.Out, "$($State.Out).err" -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        Write-UserLine '更新' "[jupyter-for-share] git pull に失敗しました (サーバーはそのまま動いています。$minutes 分後に再試行): $msg"
        return $State
    }
    $after = Get-GitHead $State.Git
    if (-not $after -or $after -eq $State.Before) { return $State }   # 更新なし

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $log = @(& $State.Git -c safe.directory=* -C $script:RepoRoot log --oneline "$($State.Before)..$after" 2>$null)
        $changed = @(& $State.Git -c safe.directory=* -C $script:RepoRoot diff --name-only $State.Before $after 2>$null)
    } finally { $ErrorActionPreference = $prev }
    Write-UserLine '更新' "[jupyter-for-share] 新しいバージョンを取得しました ($(Get-JfsVersion)):"
    foreach ($l in $log) { Write-UserLine '更新' "    $l" }
    try {
        Import-JfsCode
        Write-UserLine '更新' '[jupyter-for-share] サーバー管理の処理を新しいバージョンに切り替えました (サーバーは止めていません)。'
    } catch {
        Write-UserLine '更新' "[jupyter-for-share] 新しい処理を読み込めなかったため、今の処理のまま動かします: $($_.Exception.Message)"
        return $State
    }
    if ($MonitorRunning -and @($changed | Where-Object { $_ -like 'monitor/*' }).Count -gt 0) {
        Write-UserLine '更新' '[jupyter-for-share] リソースモニターを新しいバージョンで起動し直します。'
        Stop-JfsTask 'jfs-monitor' $script:MonitorAccount 'リソースモニター'   # 10 秒後にこのウィンドウが起動し直す
    }
    if (@($changed | Where-Object { $_ -like 'server/*' -or $_ -like 'scripts/*' }).Count -gt 0) {
        Write-UserLine '更新' ('[jupyter-for-share] 各ユーザーの JupyterLab は動かしたままです。JupyterLab 側の変更は次の起動から反映されます ' +
                              "(すぐ反映するには 'jfs.cmd restart <ユーザー名>')。")
    }
    if (@($changed | Where-Object { $_ -like 'setup.cmd' -or $_ -like 'scripts/setup-server.ps1' }).Count -gt 0) {
        Write-UserLine '更新' '[jupyter-for-share] セットアップの処理も変わりました。都合のよいときに setup.cmd を実行し直してください。'
    }
    return $State
}

# サーバー管理ウィンドウの本体 (jfs.ps1 hub)
function Invoke-Hub {
    if (Get-HubProcess) { throw 'サーバー管理ウィンドウは既に開いています。' }
    $hp = Get-HubPaths
    $me = Get-Process -Id $PID
    Write-JsonFile $hp.Record @{ pid = $PID; started = $me.StartTime.ToString('o') }

    $oldTitle = $Host.UI.RawUI.WindowTitle
    $Host.UI.RawUI.WindowTitle = 'jupyter-for-share サーバー - 閉じると全員のサーバーが停止します'
    Write-Host "jupyter-for-share サーバー管理ウィンドウ (バージョン $(Get-JfsVersion))" -ForegroundColor White
    Write-Host 'このウィンドウを閉じる (または Ctrl+C) と、全ユーザーのサーバーが停止します。' -ForegroundColor Yellow
    Write-Host "1 人だけ止める: jfs.cmd stop <ユーザー名> / 起動する: jfs.cmd start <ユーザー名>"
    Write-Host ('-' * 70)

    $states = @{}      # ユーザー名 → 状態 (起動中か、ログの読み込み位置など)
    $monitor = $null   # リソースモニターの状態
    $autoUpdate = $null   # 定期的な git pull の状態
    $cfg = Read-Config
    $lastConfigRead = Get-Date
    $everRan = $false
    try {
        Repair-AncestorDenies $cfg -Wait
        Grant-AncestorAccess
        try {
            $applied = @(Get-ProtectedApplied $cfg)
            $gsid = Get-LocalGroupSid
            $pending = @(Get-ProtectTargets $cfg | Where-Object { ($applied -notcontains $_) -and -not (Test-IsDenied $_ $gsid) })
            if ($pending.Count -gt 0) {
                Write-Warn "アクセス禁止がまだ設定されていない場所が $($pending.Count) か所あります (例: $(@($pending | Select-Object -First 3) -join ', '))。"
                Write-Warn "別のウィンドウで 'jfs.cmd protect' を実行してください。"
            }
        } catch { }
        while ($true) {
            if (((Get-Date) - $lastConfigRead).TotalSeconds -ge 5) {
                try { $cfg = Read-Config } catch { }   # 読めなかったときは前回の設定のまま続ける
                $lastConfigRead = Get-Date
            }
            $wanted = Get-Wanted
            $running = 0
            foreach ($u in @($cfg.users)) {
                $name = $u.name
                $st = $states[$name]
                $want = Test-Wanted $wanted $name
                $held = $want -and ($wanted.hold -contains $name)
                if (-not $want -or $held) {
                    if ($st -and $st.Active) {
                        Remove-Item -LiteralPath $st.Paths.Heartbeat -ErrorAction SilentlyContinue
                        Stop-JfsTask $st.Task (Get-AccountName $u) "ユーザー '$name' の環境"
                        $msg = if ($held) { 'サーバーを一時停止しました (更新作業中)。' } else { 'サーバーを停止しました。' }
                        Write-UserLine $name "[jupyter-for-share] $msg"
                        $st.Active = $false
                    }
                    if ($held) { $running++ }   # 一時停止中はウィンドウを閉じない
                    continue
                }
                $running++
                $everRan = $true
                if (-not $st -or -not $st.Active) {
                    # このユーザーのサーバーを準備して起動する
                    try {
                        if (Test-PortListening ([int]$u.port)) { Stop-JfsTask (Get-TaskName $u) (Get-AccountName $u) "前回のサーバー ($name)" }
                        Initialize-LogsFolder $u
                        Write-ServerFiles $cfg $u
                        Register-UserTask $u
                    } catch {
                        Write-UserLine $name "[jupyter-for-share] 起動の準備に失敗しました: $($_.Exception.Message)"
                        Remove-Wanted $cfg $name
                        continue
                    }
                    $paths = Get-InstancePaths $u
                    $st = [pscustomobject]@{
                        Active = $true; Task = (Get-TaskName $u); Paths = $paths; Port = [int]$u.port; Heartbeat = $paths.Heartbeat
                        ServerTail = (New-LogTail $paths.Log); CommandTail = (New-LogTail $paths.CommandLog)
                        Running = $false; StartedAt = [datetime]::MinValue; NextStart = (Get-Date)
                    }
                    $states[$name] = $st
                    Write-UserLine $name "[jupyter-for-share] 起動します (ポート $($u.port) / ログ: $($paths.Log))"
                    # 別の PC から開く URL (JupyterLab 自身がログに出す 127.0.0.1 の URL は、このPCでしか開けない)
                    Write-UserLine $name '[jupyter-for-share] 別の PC からはこの URL で開きます (どれか 1 つ。トークン付き):'
                    foreach ($h in (Get-ServerHosts $cfg)) { Write-UserLine $name "    http://$($h):$($u.port)/lab?token=$($u.token)" }
                }

                try {
                    Update-ManagedTask $st $name
                } catch {
                    Write-UserLine $name "[jupyter-for-share] 起動に失敗しました: $($_.Exception.Message)。30 秒後に再試行します。"
                    $st.Running = $false
                    $st.NextStart = (Get-Date).AddSeconds(30)
                    $st.StartedAt = [datetime]::MinValue
                }
                foreach ($line in (Read-LogTail $st.ServerTail)) { Write-UserLine $name $line }
                foreach ($line in (Read-LogTail $st.CommandTail)) { Write-UserLine $name $line 'command' }
            }
            # リソースモニター (設置済みなら、ユーザーのサーバーと一緒に動かす)
            $monitorOn = $running -gt 0 -and [bool](Get-Value $cfg.monitor 'enabled' $false) -and [bool](Get-JfsTask 'jfs-monitor')
            if ($monitorOn) {
                if (-not $monitor) {
                    $mp = Get-MonitorPaths
                    $monitor = [pscustomobject]@{
                        Task = 'jfs-monitor'; Heartbeat = $mp.Heartbeat; Tail = (New-LogTail $mp.Log)
                        Running = $false; StartedAt = [datetime]::MinValue; NextStart = (Get-Date)
                    }
                    Write-UserLine 'monitor' "[jupyter-for-share] リソースモニターを起動します: http://$(@(Get-ServerHosts $cfg)[0]):$($cfg.monitor.port)/"
                }
                try { Update-ManagedTask $monitor 'monitor' }
                catch {
                    Write-UserLine 'monitor' "[jupyter-for-share] 起動に失敗しました: $($_.Exception.Message)。30 秒後に再試行します。"
                    $monitor.Running = $false; $monitor.NextStart = (Get-Date).AddSeconds(30); $monitor.StartedAt = [datetime]::MinValue
                }
                foreach ($line in (Read-LogTail $monitor.Tail)) { Write-UserLine 'monitor' $line }
            } elseif ($monitor) {
                Remove-Item -LiteralPath $monitor.Heartbeat -ErrorAction SilentlyContinue
                Stop-JfsTask 'jfs-monitor' $script:MonitorAccount 'リソースモニター'
                $monitor = $null
            }
            # 定期的に git pull して、サーバー管理ウィンドウの処理を (サーバーを止めずに) 新しくする
            try { $autoUpdate = Update-AutoUpdate $autoUpdate $cfg ([bool]$monitor) }
            catch { Write-UserLine '更新' "[jupyter-for-share] 自動更新でエラーが発生しました: $($_.Exception.Message)"; $autoUpdate = $null }
            $Host.UI.RawUI.WindowTitle = "jupyter-for-share サーバー ($running 人) - 閉じると全員のサーバーが停止します"
            if ($everRan -and $running -eq 0) {
                Write-Host '起動対象のユーザーがいなくなったため、ウィンドウを閉じます。' -ForegroundColor Yellow
                Start-Sleep -Seconds 3
                break
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        # Ctrl+C やエラーで終わるとき。× で閉じた場合はここが実行されないことがあるが、
        # その場合もハートビートが止まるので各ランチャーがサーバーを停止する。
        foreach ($name in @($states.Keys)) {
            $st = $states[$name]
            if (-not $st.Active) { continue }
            Remove-Item -LiteralPath $st.Paths.Heartbeat -ErrorAction SilentlyContinue
            $u = Find-UserEnv $cfg $name
            if ($u) { Stop-JfsTask $st.Task (Get-AccountName $u) "ユーザー '$name' の環境" }
        }
        if ($monitor) {
            Remove-Item -LiteralPath $monitor.Heartbeat -ErrorAction SilentlyContinue
            Stop-JfsTask 'jfs-monitor' $script:MonitorAccount 'リソースモニター'
        }
        Remove-Item -LiteralPath $hp.Record -ErrorAction SilentlyContinue
        $Host.UI.RawUI.WindowTitle = $oldTitle
    }
}

# Windows にサインインしたときに、サーバー管理ウィンドウを開いて全ユーザーを起動する
function Set-AutoStart([bool]$Enabled) {
    $taskName = 'jfs-autostart'
    $task = Get-JfsTask $taskName
    if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
    if (-not $Enabled) { Write-Ok 'サインイン時の自動起動を無効にしました。'; return }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:RepoRoot 'scripts\jfs.ps1')`" start all"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'jupyter-for-share: サインイン時に全ユーザーのサーバーを起動' | Out-Null
    Write-Ok "$me がサインインしたときに、全ユーザーのサーバー (サーバー管理ウィンドウ) を自動で開くようにしました。"
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
    if (@(Get-MissingPackages $py @('psutil')).Count -gt 0) {
        Write-Info 'リソースモニター用の psutil をインストールしています...'
        Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip', 'psutil') -Quiet
    } else {
        Write-Info 'リソースモニター用の psutil はインストール済みです。'
    }

    $bind = [string](Get-Value $Config.defaults 'bindAddress' '0.0.0.0')
    $cmd = @'
@echo off
rem Generated by jupyter-for-share. Do not edit: the jfs.cmd command overwrites this file.
rem Everything is inside one ( ) block: cmd.exe reads the whole block before running it, so rewriting
rem this file while the server is running (jfs.cmd refresh, setup.cmd, git pull) cannot break it.
(
  set "TEMP=@@TMP@@"
  set "TMP=@@TMP@@"
  set "PYTHONUTF8=1"
  set "PYTHONUNBUFFERED=1"
  if exist "@@LOG@@" for %%F in ("@@LOG@@") do if %%~zF GTR 10485760 move /y "@@LOG@@" "@@LOG@@.1" >nul
  echo ===== %DATE% %TIME% start >> "@@LOG@@"
  "@@PY@@" "@@SCRIPT@@" --bind @@BIND@@ --port @@PORT@@ --users "@@USERS@@" --disk "@@DISK@@" --heartbeat "@@HB@@" >> "@@LOG@@" 2>&1
  exit /b
)
'@
    $cmd = Expand-Template $cmd @{
        TMP = $m.Tmp; LOG = $m.Log; PY = $py; SCRIPT = $m.Script; BIND = $bind
        PORT = [string][int]$Config.monitor.port; USERS = $m.UsersFile; DISK = (Get-InstancesRoot $Config)
        HB = $m.Heartbeat
    }
    Write-BatchFile $m.RunCmd $cmd

    Set-Value $Config.monitor 'enabled' $true
    Save-Config $Config   # users.json も書き出される
    # PC の起動時には動かさず、サーバー管理ウィンドウ (jfs.cmd start) の中でだけ動かす
    Register-JfsTask 'jfs-monitor' $script:MonitorAccount $m.RunCmd $m.Dir `
        "jupyter-for-share: resource monitor (port $($Config.monitor.port))" -OnDemand
}

# ---- 接続先の表示 ----

function Get-ServerHosts($Config) {
    $hosts = @()
    $domain = [string](Get-Value $Config.defaults 'domain' '')
    if ($domain) { $hosts += $domain }
    # コンピューター名は .local 付き (mDNS) だけを表示する。付けない名前は、つながらない環境が多いため
    $hosts += "$($env:COMPUTERNAME.ToLowerInvariant()).local"
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
    $profiles = [string](Get-Value $Config.defaults 'firewallProfiles' 'Any')
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
# 対象 (protectedPaths の "auto") は、このリポジトリがどのドライブ・フォルダにあるかを見て決める:
#   - リポジトリも Windows もないドライブ (D:\ など) … ドライブ全体
#   - リポジトリがあるドライブ (例: E:\jupyter-for-share) … ドライブ直下からリポジトリまでの各階層で、
#     リポジトリへ向かうフォルダ以外のすべて (ドライブやリポジトリの上の階層そのものは拒否しない)
#   - システムドライブ (C:\) … 直下の独自フォルダ (Windows / Program Files / Users など OS に必要なものと、
#     Python・リポジトリへ向かうフォルダは除く) と C:\Users\Public
# 他のユーザーのプロファイル (C:\Users\<名前>) は Windows の既定で読めないので対象外。
# このリポジトリのフォルダは Protect-RepoFolder で管理者専用にしてある。

# Root から下をたどり、KeepPaths (とその上の階層) 以外の項目を返す
function Get-SiblingTargets([string]$Root, [string[]]$KeepPaths, [string[]]$KeepNames = @(), [switch]$IncludeHidden) {
    $keep = @($KeepPaths | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
    $result = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $dir = [string]$queue.Dequeue()
        # システム属性の項目 (System Volume Information・ごみ箱など) は対象外。隠し項目は -IncludeHidden のときだけ対象
        $items = if ($IncludeHidden) {
            @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::System) })
        } else {
            @(Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue)
        }
        foreach ($c in $items) {
            $full = $c.FullName.TrimEnd('\')
            if ($dir -eq $Root -and $KeepNames -contains $c.Name) { continue }
            if (@($keep | Where-Object { $_ -ieq $full }).Count -gt 0) { continue }
            if (@($keep | Where-Object { $_.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                $queue.Enqueue($c.FullName)   # 残す場所へ向かう途中のフォルダ: 中を見る
                continue
            }
            $result += $full
        }
    }
    return $result
}

function Get-ProtectTargets($Config) {
    $repo = $script:RepoRoot.TrimEnd('\')
    $repoDrive = [System.IO.Path]::GetPathRoot($repo).TrimEnd('\')
    $sysDrive = $env:SystemDrive
    $python = Find-BasePython $Config
    $pythonDir = if ($python) { Split-Path -Parent $python } else { '' }
    $targets = @()
    foreach ($entry in @(Get-Value $Config.defaults 'protectedPaths' @('auto'))) {
        if ($entry -ne 'auto') { $targets += [string]$entry; continue }

        foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
            $drive = [string]$disk.DeviceID           # 'E:'
            $root = "$drive\"
            $keepHere = @(@($repo, $pythonDir) | Where-Object { $_ -and $_.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
            if ($drive -ieq $sysDrive) {
                $targets += Get-SiblingTargets $root $keepHere @('Windows', 'Program Files', 'Program Files (x86)', 'Users', 'PerfLogs')
                if ($env:PUBLIC) { $targets += $env:PUBLIC }
            } elseif ($keepHere.Count -gt 0) {
                $targets += Get-SiblingTargets $root $keepHere @() -IncludeHidden
            } else {
                # ドライブ全体を 1 回で処理すると時間がかかるので、ドライブ直下そのものと、直下の項目ごとに分けて並列に処理する
                $targets += $root
                $targets += Get-SiblingTargets $root @() @() -IncludeHidden
            }
        }
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

# 拒否が (自身に、または親から引き継いで) 効いているか。
# 旧バージョンがドライブ全体に付けた拒否が中まで引き継がれている場所を、もう一度処理しないようにするため
function Test-IsDenied([string]$Path, [string]$Sid) {
    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($r.AccessControlType -eq 'Deny' -and $r.IdentityReference.Value -eq $Sid) { return $true }
        }
    } catch { }
    return $false
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

# icacls を場所ごとに並列で (同時に最大 MaxParallel 個) 実行し、終わるまで経過を表示する。
# ArgsFor を渡すと、場所ごとに icacls の引数を変えられる (フォルダとファイルで付ける内容が違うときなど)
function Invoke-IcaclsParallel([string[]]$Targets, [string[]]$IcaclsArgs, [scriptblock]$ArgsFor = $null, [int]$MaxParallel = 8) {
    $queue = New-Object System.Collections.Queue
    foreach ($t in $Targets) { $queue.Enqueue($t) }
    $total = $queue.Count
    $running = @()
    $done = 0
    $started = Get-Date
    $lastReport = $started
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $MaxParallel) {
            $t = [string]$queue.Dequeue()
            $a = if ($ArgsFor) { @(& $ArgsFor $t) } else { $IcaclsArgs }
            # "D:\" のように \ で終わるパスは、引用符の直前の \ がエスケープ扱いされるので \ を重ねる
            $quoted = $t
            if ($quoted.EndsWith('\')) { $quoted += '\' }
            $out = [System.IO.Path]::GetTempFileName()
            $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList (@("`"$quoted`"") + $a) `
                -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
            $null = $proc.Handle   # 終了コードを後で取得するために必要
            $running += [pscustomobject]@{ Target = $t; Proc = $proc; Out = $out }
        }
        Start-Sleep -Milliseconds 500
        foreach ($j in @($running | Where-Object { $_.Proc.HasExited })) {
            $j.Proc.WaitForExit()
            if ($j.Proc.ExitCode -ne 0) {
                # /C 指定なので、一部のファイルで失敗しても残りは処理されている
                $msg = (Get-Content -LiteralPath $j.Out, "$($j.Out).err" -ErrorAction SilentlyContinue | Select-Object -Last 3) -join ' / '
                Write-Warn "$($j.Target): 一部のファイルを処理できませんでした ($msg)"
            }
            Remove-Item -LiteralPath $j.Out, "$($j.Out).err" -ErrorAction SilentlyContinue
            $done++
        }
        $running = @($running | Where-Object { -not $_.Proc.HasExited })
        if ($total -gt 1 -and ((Get-Date) - $lastReport).TotalSeconds -ge 30) {
            $lastReport = Get-Date
            Write-Info ("処理中: {0}/{1} か所完了 ({2} 分経過)。処理中の場所: {3}" -f $done, $total,
                [int]((Get-Date) - $started).TotalMinutes, (@($running | ForEach-Object { $_.Target }) -join ', '))
        }
    }
}

# リポジトリ (と Python) の上の階層 (E:\ など) に付いた拒否を探す。
# これがあると Python がパスをたどれず、サーバーが PermissionError で起動できない。
# (旧バージョンがドライブ全体に付けた拒否や、途中で中断して記録が残っていない拒否も見つける)
function Get-AncestorDenies($Config) {
    $group = Get-LocalGroup -Name $script:LocalGroup -ErrorAction SilentlyContinue
    if (-not $group) { return @() }
    $sid = $group.SID.Value
    $paths = @($script:RepoRoot)
    $py = Find-BasePython $Config
    if ($py) { $paths += (Split-Path -Parent $py) }
    $result = @()
    foreach ($p in $paths) {
        $dir = $p.TrimEnd('\')
        while ($dir) {
            if ((Test-HasDeny $dir $sid) -and ($result -notcontains $dir)) { $result += $dir }
            $parent = Split-Path -Parent $dir
            if (-not $parent -or $parent -eq $dir) { break }
            $dir = $parent
        }
        $root = [System.IO.Path]::GetPathRoot($p)
        if ((Test-HasDeny $root $sid) -and ($result -notcontains $root)) { $result += $root }
    }
    return $result
}

# 上の階層の拒否を外す。-Wait: 別の処理 (protect のバックグラウンド実行) が外している最中なら終わるまで待つ
function Repair-AncestorDenies($Config, [switch]$Wait) {
    $dirs = @(Get-AncestorDenies $Config)
    if ($dirs.Count -eq 0) { return }
    if ($Wait -and (Get-ProtectJobState) -eq 'running') {
        Write-Warn "リポジトリの上の階層 ($($dirs -join ', ')) の拒否をバックグラウンドで外している最中です。終わるまで待ちます..."
        $started = Get-Date
        while ((Get-ProtectJobState) -eq 'running') {
            Start-Sleep -Seconds 10
            Write-Host ("  待機中 ({0} 分経過)。進み具合: jfs.cmd protect -Status" -f [int]((Get-Date) - $started).TotalMinutes)
        }
        $dirs = @(Get-AncestorDenies $Config)
        if ($dirs.Count -eq 0) { return }
    }
    $sid = Get-LocalGroupSid
    Write-Warn "リポジトリの上の階層 ($($dirs -join ', ')) にサーバー実行用アカウントへの拒否が付いているため外します。"
    Write-Warn 'この拒否があるとサーバーが起動できません。ドライブ内のファイル数が多いと数分～数十分かかります...'
    Invoke-IcaclsParallel $dirs @('/remove:d', "*$sid", '/Q', '/C')
    $applied = @(Get-ProtectedApplied $Config | Where-Object { $dirs -notcontains $_ })
    Save-ProtectedApplied $applied
    $left = @(Get-AncestorDenies $Config)
    if ($left.Count -gt 0) { throw "拒否を外せませんでした: $($left -join ', ')" }
    Write-Ok '上の階層の拒否を外しました。'
}

function Protect-Folders($Config, [switch]$Reapply) {
    Repair-AncestorDenies $Config
    Grant-AncestorAccess
    $sid = Get-LocalGroupSid
    $targets = @(Get-ProtectTargets $Config)
    $applied = @(Get-ProtectedApplied $Config)
    # 最後まで処理が終わった記録があり、拒否も付いているフォルダは飛ばす
    # (付け直すと中の全ファイルを書き換えるため時間がかかる)。
    # 途中で中断した場所は記録がないので、次回もう一度最初から処理する。
    # 以前は対象だったが今は対象外になった場所 (例: 旧バージョンが拒否を付けた、リポジトリのあるドライブの直下) は拒否を外す
    $stale = @($applied | Where-Object { ($targets -notcontains $_) -and (Test-Path -LiteralPath $_) })
    if ($stale.Count -gt 0) {
        Write-Info "対象外になった次の場所の拒否を外します (ファイル数が多いと時間がかかります): $($stale -join ', ')"
        Invoke-IcaclsParallel $stale @('/remove:d', "*$sid", '/Q', '/C')
        $applied = @($applied | Where-Object { $stale -notcontains $_ })
        Save-ProtectedApplied $applied
    }
    # 拒否が親から引き継がれて既に効いている場所は、処理済みとして記録だけする
    foreach ($t in $targets) {
        if (-not $Reapply -and ($applied -notcontains $t) -and -not (Test-HasDeny $t $sid) -and (Test-IsDenied $t $sid)) { $applied += $t }
    }
    $todo = @($targets | Where-Object { $Reapply -or ($applied -notcontains $_) -or -not (Test-IsDenied $_ $sid) })

    if ($todo.Count -eq 0) {
        Save-ProtectedApplied $applied
        Write-Ok "アクセス禁止は設定済みです (対象 $($targets.Count) か所)。"
        return
    }
    Write-Info 'サーバー実行用アカウントから次のフォルダへのアクセスを禁止します。'
    Write-Info '中のファイル数が多いと時間がかかります (初回のみ。2 回目以降は設定済みの場所を飛ばします):'
    $todo | ForEach-Object { Write-Host "    $_" }
    # ドライブ直下そのもの: そのフォルダだけ (中は直下のフォルダごとに並列で処理する)
    # フォルダ: protectLevel が full なら中のファイルにも、folders ならフォルダにだけ引き継ぐ
    # ファイル: そのファイルだけ
    $level = [string](Get-Value $Config.defaults 'protectLevel' 'full')
    $folderAce = if ($level -eq 'folders') { '(CI)F' } else { '(OI)(CI)F' }
    $argsFor = {
        param($t)
        if ($t -match '^[A-Za-z]:\\$') { $ace = 'F' }
        elseif (Test-Path -LiteralPath $t -PathType Leaf) { $ace = 'F' }
        else { $ace = $folderAce }
        @('/deny', "*$($sid):$ace", '/Q', '/C')
    }.GetNewClosure()
    Invoke-IcaclsParallel $todo @() $argsFor

    foreach ($t in $todo) {
        if (Test-IsDenied $t $sid) {
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

# 旧バージョンが protect をバックグラウンドで実行していた場合の状態 (現在のバージョンはバックグラウンドで実行しない)
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
    Remove-Wanted (Read-Config) $UserName
    if ((Get-JfsTask $taskName) -or (Get-LocalUser -Name $account -ErrorAction SilentlyContinue)) {
        Stop-JfsTask $taskName $account "ユーザー '$UserName' の環境"
    }
    $task = Get-JfsTask $taskName
    if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
    Remove-ServiceAccount $account
    if ($Folder -and (Test-Path -LiteralPath $Folder)) {
        Remove-TreeSafe $Folder
        Write-Ok "フォルダを削除しました: $Folder"
    }
}

# ---- アンインストール (jfs.cmd uninstall / uninstall.cmd) ----
# 記録に頼らず、jupyter-for-share が作ったもの・変えたものを探して元に戻す。

# 拒否 (Deny) のアクセス権を探す場所: 全固定ドライブの直下とその中、リポジトリの上の階層の中、C:\Users\Public、記録済みの場所
function Find-JfsDenies($Config, [string]$GroupSid) {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
        $root = "$($disk.DeviceID)\"
        $candidates.Add($root)
        foreach ($c in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) { $candidates.Add($c.FullName) }
    }
    $dir = Split-Path -Parent $script:RepoRoot.TrimEnd('\')
    while ($dir) {
        foreach ($c in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) { $candidates.Add($c.FullName) }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    if ($env:PUBLIC) { $candidates.Add($env:PUBLIC) }
    foreach ($a in @(Get-ProtectedApplied $Config)) { $candidates.Add($a) }

    $found = @()
    foreach ($path in @($candidates | Select-Object -Unique)) {
        try { $acl = Get-Acl -LiteralPath $path } catch { continue }
        foreach ($r in $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
            if ($r.AccessControlType -ne 'Deny') { continue }
            $sid = $r.IdentityReference.Value
            $mine = $GroupSid -and $sid -eq $GroupSid
            if (-not $mine) {
                # 以前に作って消したグループなど、名前に変換できない (存在しない) アカウントへの拒否も片付ける
                try { [void]$r.IdentityReference.Translate([System.Security.Principal.NTAccount]) } catch { $mine = $true }
            }
            if ($mine) { $found += [pscustomobject]@{ Path = $path; Sid = $sid } }
        }
    }
    return $found
}

function Invoke-Uninstall($Config, [switch]$DeleteFiles) {
    $repo = $script:RepoRoot
    Write-Host '== jupyter-for-share のアンインストール ==' -ForegroundColor White
    Write-Host "対象: $repo"

    # 1. サーバー管理ウィンドウ・タスク・プロセスを止める
    Write-Info '[1/7] サーバーとリソースモニターを停止しています...'
    try { Save-Wanted $false @() @() } catch { }
    $hub = Get-HubProcess
    if ($hub) { $hub | Stop-Process -Force -ErrorAction SilentlyContinue }
    $tasks = @(Get-ScheduledTask -TaskPath $script:TaskPath -ErrorAction SilentlyContinue)
    foreach ($t in $tasks) {
        Stop-ScheduledTask -InputObject $t -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -InputObject $t -Confirm:$false -ErrorAction SilentlyContinue
        Write-Ok "タスクを削除: $($t.TaskPath)$($t.TaskName)"
    }
    try {   # 空になったタスクのフォルダも消す
        $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect()
        $svc.GetFolder('\').DeleteFolder($script:TaskPath.Trim('\'), 0)
    } catch { }
    $accounts = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "$($script:UserPrefix)*" -or $_.Name -eq $script:MonitorAccount })
    $names = @($accounts | ForEach-Object { "$env:COMPUTERNAME\$($_.Name)" })
    $procs = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object {
        ($names -contains $_.UserName) -or ($_.Path -and $_.Path.StartsWith("$repo\", [StringComparison]::OrdinalIgnoreCase)) })
    if ($procs.Count -gt 0) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        $procs | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
        Write-Ok "プロセスを停止: $($procs.Count) 個"
    }

    # 2. ファイアウォール規則
    Write-Info '[2/7] ファイアウォール規則を削除しています...'
    foreach ($g in @($script:FirewallGroup, $script:NetworkRuleGroup)) {
        $rules = @(Get-NetFirewallRule -Group $g -ErrorAction SilentlyContinue)
        if ($rules.Count -gt 0) { $rules | Remove-NetFirewallRule; Write-Ok "規則を削除: $g ($($rules.Count) 件)" }
    }

    # 3. アクセス禁止 (拒否) を外す
    Write-Info '[3/7] アクセス禁止 (拒否) を探しています (全ドライブの直下を確認します)...'
    $group = Get-LocalGroup -Name $script:LocalGroup -ErrorAction SilentlyContinue
    $groupSid = if ($group) { $group.SID.Value } else { '' }
    $denies = @(Find-JfsDenies $Config $groupSid)
    if ($denies.Count -gt 0) {
        Write-Info "拒否が付いている場所: $(@($denies | ForEach-Object { $_.Path } | Select-Object -Unique) -join ', ')"
        Write-Info '外しています (ドライブ全体に付いている場合、ファイル数が多いと時間がかかります)...'
        foreach ($sid in @($denies | ForEach-Object { $_.Sid } | Select-Object -Unique)) {
            $targets = @($denies | Where-Object { $_.Sid -eq $sid } | ForEach-Object { $_.Path } | Select-Object -Unique)
            Invoke-IcaclsParallel $targets @('/remove:d', "*$sid", '/Q', '/C')
        }
        Write-Ok '拒否を外しました。'
    } else {
        Write-Ok '拒否は見つかりませんでした。'
    }
    Remove-Item -LiteralPath (Get-ProtectStatePaths).Applied -ErrorAction SilentlyContinue

    # 4. アカウントとグループ
    Write-Info '[4/7] 実行用アカウントとグループを削除しています...'
    foreach ($a in $accounts) { Remove-ServiceAccount $a.Name }
    if ($group) {
        try { Remove-AllAccountRights $groupSid } catch { Write-Warn "ログオン権限の削除に失敗しました: $($_.Exception.Message)" }
        Remove-LocalGroup -Name $script:LocalGroup
        Write-Ok "グループ '$script:LocalGroup' を削除しました。"
    }

    # 5. このフォルダのアクセス権を元に戻す (所有者を Administrators にし、親フォルダからの継承に戻す)
    Write-Info "[5/7] $repo のアクセス権を元に戻しています..."
    # ユーザーのフォルダ内のリンクをたどって、外の場所のアクセス権を変えてしまわないように、リンクは先に消す
    $links = @(Remove-LinksIn (Get-InstancesRoot $Config))
    if ($links.Count -gt 0) { Write-Info "ユーザーのフォルダ内のリンクを削除しました (リンク先はそのまま): $($links -join ', ')" }
    Invoke-Native 'icacls.exe' @($repo, '/setowner', "*$($script:SidAdmins)", '/T', '/C', '/Q') -Quiet -IgnoreExitCode
    Invoke-Native 'icacls.exe' @($repo, '/reset', '/T', '/C', '/Q') -Quiet -IgnoreExitCode
    Get-ChildItem -LiteralPath $repo -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq '.server' } | ForEach-Object { $_.Attributes = 'Directory' }
    $pdj = Join-Path $env:ProgramData 'jupyter'
    if (Test-Path -LiteralPath $pdj) { Invoke-Native 'icacls.exe' @($pdj, '/reset', '/T', '/C', '/Q') -Quiet -IgnoreExitCode }
    Write-Ok 'アクセス権を元に戻しました。'

    # 6. 実行時のファイル
    Write-Info '[6/7] 実行時のファイルを削除しています...'
    foreach ($d in @((Join-Path $repo '.runtime'), (Join-Path $repo 'monitor\.runtime'), (Join-Path $repo 'monitor\.venv'))) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $script:ConfigPath) {
        Move-Item -LiteralPath $script:ConfigPath -Destination "$($script:ConfigPath).uninstalled" -Force
        Write-Ok "設定ファイルは $($script:ConfigPath).uninstalled に残しました (トークンを含みます)。"
    }

    # 7. ユーザーのフォルダ
    $userRoot = Get-InstancesRoot $Config
    if ($DeleteFiles -and (Test-Path -LiteralPath $userRoot)) {
        Write-Info "[7/7] ユーザーのフォルダを削除しています: $userRoot"
        Remove-TreeSafe $userRoot
        Write-Ok '削除しました。'
    } elseif (Test-Path -LiteralPath $userRoot) {
        Write-Info "[7/7] ユーザーのフォルダは残しました: $userRoot (ノートブックなど。不要なら削除してください)"
        Write-Info "      再インストール後に同じユーザー名で 'jfs.cmd add <ユーザー名>' を実行すると、中身をそのまま引き継ぎます。"
    }

    Write-Host ''
    Write-Ok 'アンインストールが完了しました。'
    Write-Host "このウィンドウ (と、$repo を開いているエクスプローラーやコマンドプロンプト) を閉じれば、フォルダを削除できます。"
    Write-Host 'もう一度使う場合は、setup.cmd を実行してください。'
}

# ---- 他の PC から接続できるようにする (jfs.cmd network) ----
# 現状を確認 → 必要な変更を一覧表示 → 確認 → 適用 → 再確認 の順に行う。
# ping と名前解決の規則は、ポートの規則 (Sync-FirewallRules で作り直す) とは別のグループにする。

$script:NetworkRuleGroup = 'jupyter-for-share-network'

function Get-LanAdapters {
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                      Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' })) {
        $prof = $profiles | Where-Object { $_.InterfaceIndex -eq $ip.InterfaceIndex } | Select-Object -First 1
        $result += [pscustomobject]@{
            Index     = $ip.InterfaceIndex
            Alias     = $ip.InterfaceAlias
            Address   = "$($ip.IPAddress)/$($ip.PrefixLength)"
            Category  = if ($prof) { [string]$prof.NetworkCategory } else { '(なし)' }
            Network   = if ($prof) { [string]$prof.Name } else { '' }
            Tailscale = ($ip.InterfaceAlias -match 'Tailscale') -or ($ip.IPAddress -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.')
            Virtual   = ($ip.InterfaceAlias -match 'vEthernet|WSL|VirtualBox|VMware|Hyper-V|Loopback')
        }
    }
    return $result
}

function Get-ExpectedPorts($Config) {
    $ports = @()
    foreach ($u in @($Config.users)) { $ports += [pscustomobject]@{ Label = "ユーザー '$($u.name)'"; Port = [int]$u.port; Rule = "jupyter-for-share-$($u.name)" } }
    if ([bool](Get-Value $Config.monitor 'enabled' $false)) {
        $ports += [pscustomobject]@{ Label = 'リソースモニター'; Port = [int]$Config.monitor.port; Rule = 'jupyter-for-share-_monitor' }
    }
    return $ports
}

function Get-PythonBlockRules {
    return @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -match 'python' } |
        ForEach-Object { Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_ -ErrorAction SilentlyContinue } |
        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' })
}

# 現状を表示し、必要な変更 (説明と実行内容) の一覧を返す
function Get-NetworkPlan($Config, [switch]$SetPrivate, [switch]$Quiet) {
    $plan = New-Object System.Collections.ArrayList
    $say = { param($ok, $msg) if (-not $Quiet) { Write-Check $ok $msg } }

    if (-not $Quiet) { Write-Host '-- ネットワーク接続 --' -ForegroundColor White }
    $adapters = @(Get-LanAdapters)
    foreach ($a in $adapters) {
        $kind = if ($a.Tailscale) { ' [Tailscale]' } elseif ($a.Virtual) { ' [仮想]' } else { '' }
        & $say ($a.Category -ne 'Public' -or $a.Tailscale -or $a.Virtual) "$($a.Alias)$kind : $($a.Address) / 種類: $($a.Category) $($a.Network)"
    }
    $publicLan = @($adapters | Where-Object { $_.Category -eq 'Public' -and -not $_.Tailscale -and -not $_.Virtual })
    if ($SetPrivate) {
        foreach ($a in $publicLan) {
            [void]$plan.Add([pscustomobject]@{
                Text = "ネットワーク '$($a.Alias)' の種類を「パブリック」から「プライベート」に変更"
                Kind = 'private'; Data = $a.Index
            })
        }
    } elseif ($publicLan.Count -gt 0 -and -not $Quiet) {
        Write-Host '       (パブリックのままでも、下の規則を全プロファイル対象にすることで接続できるようにします。'
        Write-Host '        種類自体をプライベートに変えたい場合は -SetPrivate を付けてください)'
    }

    if (-not $Quiet) { Write-Host '-- ファイアウォールのプロファイル --' -ForegroundColor White }
    foreach ($f in @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
        $localOk = -not ($f.AllowLocalFirewallRules -eq 'False')
        $msg = "$($f.Name): 有効=$($f.Enabled) / 受信の既定=$($f.DefaultInboundAction)"
        if (-not $localOk) { $msg += ' / グループ ポリシーにより、このPCで追加した規則が無視されます (管理者に確認が必要)' }
        & $say $localOk $msg
    }

    if (-not $Quiet) { Write-Host '-- ポートの許可 --' -ForegroundColor White }
    $profilesSetting = [string](Get-Value $Config.defaults 'firewallProfiles' 'Any')
    $needSync = $false
    if ($profilesSetting -ne 'Any') {
        & $say $false "規則の対象プロファイルが '$profilesSetting' のため、パブリックのネットワークからは接続できません"
        $needSync = $true
    }
    foreach ($e in @(Get-ExpectedPorts $Config)) {
        $rule = Get-NetFirewallRule -Name $e.Rule -ErrorAction SilentlyContinue
        $listen = @(Get-NetTCPConnection -LocalPort $e.Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalAddress } | Select-Object -Unique)
        $listenText = if ($listen.Count) { "待ち受け: $($listen -join ', ')" } else { '待ち受けていない (jfs.cmd start / doctor で確認)' }
        if ($listen | Where-Object { $_ -match '^(127\.|::1$)' }) { $listenText += ' ※ このPC内だけで待ち受けています' }
        if ($rule) {
            $addr = (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule).RemoteAddress -join ', '
            $ok = ($rule.Enabled -eq 'True') -and ([string]$rule.Profile -eq 'Any')
            & $say $ok "$($e.Label) TCP $($e.Port): 規則あり (有効=$($rule.Enabled) / プロファイル=$($rule.Profile) / 接続元=$addr) / $listenText"
            if (-not $ok) { $needSync = $true }
        } else {
            & $say $false "$($e.Label) TCP $($e.Port): 規則がありません / $listenText"
            $needSync = $true
        }
    }
    if ($needSync) {
        [void]$plan.Add([pscustomobject]@{
            Text = 'ポートの許可規則を、すべてのネットワークの種類 (ドメイン / プライベート / パブリック) で有効にして作り直す (接続元は allowFrom の範囲のまま)'
            Kind = 'ports'; Data = $null
        })
    }

    if (-not $Quiet) { Write-Host '-- ping と名前解決 --' -ForegroundColor White }
    $allow = @(Get-Value $Config.defaults 'allowFrom' @('LocalSubnet'))
    $extra = @(
        @{ Name = 'jupyter-for-share-ping4'; Text = 'ping (ICMPv4 エコー要求) の受信を許可'; Args = @{ Protocol = 'ICMPv4'; IcmpType = '8' } },
        @{ Name = 'jupyter-for-share-ping6'; Text = 'ping (ICMPv6 エコー要求) の受信を許可'; Args = @{ Protocol = 'ICMPv6'; IcmpType = '128' } },
        @{ Name = 'jupyter-for-share-names'; Text = 'コンピューター名での接続に使う名前解決 (mDNS 5353 / LLMNR 5355 / NetBIOS 137, UDP) の受信を許可'
           Args = @{ Protocol = 'UDP'; LocalPort = @('5353', '5355', '137') } }
    )
    foreach ($x in $extra) {
        $rule = Get-NetFirewallRule -Name $x.Name -ErrorAction SilentlyContinue
        $ok = $rule -and $rule.Enabled -eq 'True'
        & $say ([bool]$ok) "$($x.Text): $(if ($ok) { '許可済み' } else { '未設定' })"
        if (-not $ok) {
            [void]$plan.Add([pscustomobject]@{ Text = $x.Text; Kind = 'rule'; Data = $x })
        }
    }

    # コンピューター名 (pc / pc.local) で接続するには、このPCが名前の問い合わせに答える必要がある
    #   Windows の PC から: LLMNR と NetBIOS / Mac・iPhone などから: mDNS (.local)
    if (-not $Quiet) { Write-Host '-- コンピューター名での接続 --' -ForegroundColor White }
    $cn = $env:COMPUTERNAME.ToLowerInvariant()
    & $say $true "コンピューター名: $cn (URL では http://$($cn).local:<ポート>/)"
    $lanIndexes = @(Get-LanAdapters | Where-Object { -not $_.Virtual -and -not $_.Tailscale } | ForEach-Object { $_.Index })
    foreach ($c in @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue)) {
        if ($lanIndexes -notcontains $c.InterfaceIndex) { continue }
        # TcpipNetbiosOptions: 0 = DHCP の設定に従う / 1 = 有効 / 2 = 無効
        $nbOff = $c.TcpipNetbiosOptions -eq 2
        & $say (-not $nbOff) "$($c.Description): NetBIOS over TCP/IP = $(if ($nbOff) { '無効 (Windows の PC からコンピューター名で見つけられないことがあります)' } else { '有効' })"
        if ($nbOff) {
            [void]$plan.Add([pscustomobject]@{ Text = "'$($c.Description)' の NetBIOS over TCP/IP を有効にする"; Kind = 'netbios'; Data = $c.InterfaceIndex })
        }
    }
    $llmnr = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -ErrorAction SilentlyContinue
    if ($llmnr -and $llmnr.EnableMulticast -eq 0) {
        & $say $false 'LLMNR (Windows の PC からコンピューター名で見つける仕組み) がポリシーで無効になっています'
        [void]$plan.Add([pscustomobject]@{ Text = 'LLMNR を無効にしているポリシーの値を削除する (会社のドメイン参加 PC では元に戻されることがあります)'; Kind = 'llmnr'; Data = $null })
    } else {
        & $say $true 'LLMNR: 有効'
    }
    $mdns = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableMDNS' -ErrorAction SilentlyContinue
    if ($mdns -and $mdns.EnableMDNS -eq 0) {
        & $say $false 'mDNS (<コンピューター名>.local で見つける仕組み) が無効になっています'
        [void]$plan.Add([pscustomobject]@{ Text = 'mDNS を無効にしている設定を削除する (反映には PC の再起動が必要)'; Kind = 'mdns'; Data = $null })
    } else {
        & $say $true 'mDNS (.local): 有効'
    }
    # Windows 標準の「ネットワーク探索」「mDNS」の受信規則 (名前の問い合わせに答える DNS Client サービス用)
    $active = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NetworkCategory } |
        ForEach-Object { if ($_ -eq 'DomainAuthenticated') { 'Domain' } else { $_ } } | Select-Object -Unique)
    $nameRules = @(Get-NetFirewallRule -Name 'NETDIS-LLMNR-In-UDP*', 'NETDIS-NB_Name-In-UDP*', 'MDNS-In-UDP*' -ErrorAction SilentlyContinue |
        Where-Object { $rp = [string]$_.Profile; $rp -eq 'Any' -or @($active | Where-Object { $rp -match $_ }).Count -gt 0 })
    $off = @($nameRules | Where-Object { $_.Enabled -ne 'True' })
    & $say ($off.Count -eq 0) ("Windows 標準の名前解決の受信規則 (ネットワーク探索 / mDNS): " +
        $(if ($nameRules.Count -eq 0) { '見つかりません' } elseif ($off.Count -eq 0) { '有効' } else { "$($off.Count) 件が無効" }))
    if ($off.Count -gt 0) {
        [void]$plan.Add([pscustomobject]@{
            Text = "Windows 標準の名前解決の受信規則を有効にする ($(@($off | ForEach-Object { $_.DisplayName } | Select-Object -Unique) -join ' / '))"
            Kind = 'enable'; Data = @($off | ForEach-Object { $_.Name })
        })
    }

    if (-not $Quiet) { Write-Host '-- python をブロックする規則 --' -ForegroundColor White }
    $blocks = @(Get-PythonBlockRules)
    if ($blocks.Count -eq 0) { & $say $true 'ありません' }
    foreach ($b in $blocks) {
        & $say $false "'$($b.DisplayName)' (プロファイル=$($b.Profile)) が python の受信をブロックしています"
        [void]$plan.Add([pscustomobject]@{
            Text = "python をブロックしている規則 '$($b.DisplayName)' を無効にする (削除はしない)"
            Kind = 'unblock'; Data = $b.Name
        })
    }
    return $plan.ToArray()
}

function Invoke-NetworkChange($Item) {
    switch ($Item.Kind) {
        'private' { Set-NetConnectionProfile -InterfaceIndex ([int]$Item.Data) -NetworkCategory Private }
        'ports' {
            $c = Read-Config
            Set-Value $c.defaults 'firewallProfiles' 'Any'
            Save-Config $c
            Sync-FirewallRules $c
        }
        'rule' {
            $x = $Item.Data
            $ruleArgs = $x.Args
            $allow = @(Get-Value (Read-Config).defaults 'allowFrom' @('LocalSubnet'))
            Get-NetFirewallRule -Name $x.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            New-NetFirewallRule -Name $x.Name -DisplayName "jupyter-for-share: $($x.Text)" -Group $script:NetworkRuleGroup `
                -Direction Inbound -Action Allow -RemoteAddress $allow -Profile Any @ruleArgs | Out-Null
        }
        'unblock' { Disable-NetFirewallRule -Name ([string]$Item.Data) }
        'enable'  { Enable-NetFirewallRule -Name ([string[]]$Item.Data) }
        'netbios' {
            $c = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$([int]$Item.Data)"
            $r = Invoke-CimMethod -InputObject $c -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]1 }
            if ($r.ReturnValue -ne 0) { throw "SetTcpipNetbios の結果: $($r.ReturnValue)" }
        }
        'llmnr' { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' }
        'mdns'  { Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableMDNS' }
    }
}

function Invoke-NetworkSetup($Config, [switch]$SetPrivate, [switch]$Yes) {
    Write-Host '== 現在の状態 ==' -ForegroundColor White
    $plan = @(Get-NetworkPlan $Config -SetPrivate:$SetPrivate)
    Write-Host ''
    if ($plan.Count -eq 0) {
        Write-Ok '変更が必要な設定はありません。'
    } else {
        Write-Host '== 適用する変更 ==' -ForegroundColor White
        for ($i = 0; $i -lt $plan.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $plan[$i].Text) }
        Write-Host ''
        if (-not $Yes) {
            $ans = Read-Host '上の変更を適用しますか? [y/N]'
            if ($ans -notmatch '^[yY]') { Write-Info '変更せずに終了しました。'; return }
        }
        foreach ($item in $plan) {
            try {
                Invoke-NetworkChange $item
                Write-Ok $item.Text
            } catch {
                Write-Warn "$($item.Text): 失敗しました ($($_.Exception.Message))"
            }
        }
        Write-Host ''
        Write-Host '== 変更後の状態 ==' -ForegroundColor White
        $rest = @(Get-NetworkPlan (Read-Config) -SetPrivate:$SetPrivate)
        Write-Host ''
        if ($rest.Count -eq 0) { Write-Ok 'すべて設定済みです。' } else { Write-Warn "まだ $($rest.Count) 件の項目が残っています (上の [NG] を確認してください)。" }
    }
    Write-Host ''
    Write-Host 'このPCのアドレス (別の PC から ping や URL で使うもの):'
    foreach ($a in @(Get-LanAdapters | Where-Object { -not $_.Virtual })) { Write-Host "    $($a.Alias): $($a.Address)" }
    Write-Host ''
    $cn = $env:COMPUTERNAME.ToLowerInvariant()
    Write-Host "IP アドレスではつながるのに $cn.local でつながらない場合は、接続する側の PC で次を実行して確認してください:"
    Write-Host "    ping $cn.local       (名前が見つからない / 違うアドレスになるなら名前解決の問題)"
    Write-Host '  名前解決はネットワーク機器や接続する PC の設定でも止められることがあります。確実にするには、'
    Write-Host '  ルーターでこのPCの IP を固定して名前を登録するか、接続する PC の hosts に登録してください (README の「ドメイン名でアクセスする」)。'
    Write-Host '  Tailscale 経由なら、Tailscale の管理画面に表示されるマシン名 (MagicDNS) でつながります。'
    Write-Host ''
    Write-Host 'これでも別の PC から ping が通らない場合は、PC 側ではなくネットワーク側の原因が考えられます:'
    Write-Host '  - 接続元の PC が別のサブネット (アドレスの前半が違う) にいる → jfs.cmd set <ユーザー名> -AllowFrom で範囲を追加'
    Write-Host '  - Wi-Fi のゲストネットワークや「プライバシーセパレーター / AP アイソレーション」で端末同士の通信が禁止されている'
    Write-Host '  - セキュリティソフト (Windows Defender 以外のファイアウォール) が通信を止めている'
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
                            [string]$HttpPath, [string]$LogPath, [string]$Token = '', [string]$ConsoleUser = '') {
    Write-Host ''
    Write-Host "== $Label (ポート $P) ==" -ForegroundColor White
    $user = Get-LocalUser -Name $Account -ErrorAction SilentlyContinue
    Write-Check ([bool]$user -and $user.Enabled) "実行用アカウント $Account"
    $task = Get-JfsTask $TaskName
    if ($task) {
        $info = Get-ScheduledTaskInfo -InputObject $task
        if ($ConsoleUser) {
            Write-Check $true "起動用タスク $($script:TaskPath)$TaskName (状態: $($task.State))"
            Write-Check ([bool](Get-HubProcess) -and (Test-Wanted (Get-Wanted) $ConsoleUser)) "サーバー管理ウィンドウで起動中 (起動していないときは 'jfs.cmd start $ConsoleUser')"
        } else {
            Write-Check $true "起動用タスク $($script:TaskPath)$TaskName (状態: $($task.State))"
        }
        Write-Host "       前回の実行: $($info.LastRunTime) / 結果: $(Get-TaskResultText $info.LastTaskResult)"
    } else {
        Write-Check $false "自動起動タスク $($script:TaskPath)$TaskName がありません"
    }
    $conn = @(Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue)
    if ($conn.Count -gt 0) {
        $procs = @($conn | ForEach-Object { (Get-Process -Id $_.OwningProcess -IncludeUserName -ErrorAction SilentlyContinue) } |
                   Where-Object { $_ } | ForEach-Object { "$($_.ProcessName) ($($_.UserName))" } | Select-Object -Unique)
        Write-Check $true "ポート $P で待ち受け中: $($procs -join ', ') / アドレス: $(@($conn | ForEach-Object { $_.LocalAddress }) -join ', ')"
        $url = "http://127.0.0.1:$P$HttpPath"
        if ($Token) { $url += "?token=$Token" }
        Write-Check (Test-HttpOk $url) "このPCからの HTTP 接続 (http://127.0.0.1:$P$HttpPath)"
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
    # 権限まわりのエラーがログにあれば、前後の行と一緒に表示する
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        $hits = @(Get-Content -LiteralPath $LogPath -Tail 3000 -Encoding UTF8 |
            Select-String -Pattern 'not permitted|PermissionError|Permission denied|Access is denied|アクセスが拒否|WinError 5\b' -Context 2, 2 |
            Select-Object -Last 5)
        if ($hits.Count -gt 0) {
            Write-Check $false 'ログに権限のエラーがあります (直近 5 件):'
            foreach ($h in $hits) {
                $h.Context.PreContext | ForEach-Object { Write-Host "       $_" }
                Write-Host "     > $($h.Line)" -ForegroundColor Red
                $h.Context.PostContext | ForEach-Object { Write-Host "       $_" }
                Write-Host ''
            }
        }
    }
}

# サーバー実行用アカウントの権限で Python を一度だけ動かし、必要な場所にアクセスできるか確かめる
function Test-AccessAsUser($Config, $UserEnv) {
    $p = Get-InstancePaths $UserEnv
    $py = Join-Path $p.LabVenv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) { Write-Check $false "JupyterLab の Python がありません: $py"; return }
    foreach ($d in @($p.Tmp, $p.Logs)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    # 調べる場所: ドライブ直下から作業フォルダまでの各階層と、起動に必要なファイル
    $paths = @()
    $dir = $p.Work
    while ($dir) {
        $paths = @($dir) + $paths
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $paths += @($p.Venv, (Join-Path $p.Venv 'Scripts\python.exe'), $py, $p.Config, $p.Home, $p.Runtime, $p.Tmp, $p.Logs)
    $base = Find-BasePython $Config
    if ($base) { $paths += @((Split-Path -Parent $base), $base) }

    $out = Join-Path $p.Logs 'access-test.txt'
    $pyFile = Join-Path $p.Tmp 'access-test.py'
    $cmdFile = Join-Path $p.Tmp 'access-test.cmd'
    $pyCode = @'
import json, os, sys, getpass
print("account:", getpass.getuser(), "/ python:", sys.version.split()[0])
with open(sys.argv[1], encoding="utf-8") as f:
    paths = json.load(f)
for path in paths:
    try:
        os.lstat(path)
        result = "OK"
    except Exception as e:
        result = "NG  %s: %s" % (type(e).__name__, e)
    print("%-6s %s" % ("lstat", path), "->", result)
'@
    # Tmp はユーザーも書き込めるので、置き換えられたリンクなどを先に消してから書く
    foreach ($f in @($pyFile, $cmdFile, $out, (Join-Path $p.Tmp 'access-test.json'))) {
        Remove-LinksOnPath $p.Server $f
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    [System.IO.File]::WriteAllText($pyFile, $pyCode, (New-Object System.Text.UTF8Encoding($false)))
    # パスの一覧はファイルで渡す (コマンドラインだと "E:\" の末尾の \ が引用符のエスケープと解釈されるため)
    $jsonFile = Join-Path $p.Tmp 'access-test.json'
    [System.IO.File]::WriteAllText($jsonFile, (ConvertTo-Json -InputObject @($paths)), (New-Object System.Text.UTF8Encoding($false)))
    $cmd = "@echo off`r`nwhoami /groups > `"$out`" 2>&1`r`n`"$py`" `"$pyFile`" `"$jsonFile`" >> `"$out`" 2>&1`r`n"
    Write-BatchFile $cmdFile $cmd
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue

    $taskName = "jfs-test-$($UserEnv.name)"
    try {
        Register-JfsTask $taskName (Get-AccountName $UserEnv) $cmdFile $p.Tmp 'jupyter-for-share: access test' -OnDemand
        Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $taskName
        $deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Seconds 2
            $t = Get-JfsTask $taskName
        } while ($t -and [string]$t.State -eq 'Running' -and (Get-Date) -lt $deadline)
        $info = Get-ScheduledTaskInfo -TaskPath $script:TaskPath -TaskName $taskName -ErrorAction SilentlyContinue
    } finally {
        $t = Get-JfsTask $taskName
        if ($t) { Unregister-ScheduledTask -InputObject $t -Confirm:$false }
        # テスト用のタスク登録でパスワードを変えたので、本来のタスクを登録し直す
        Register-UserTask $UserEnv
    }
    if (-not (Test-Path -LiteralPath $out)) {
        $result = if ($info) { Get-TaskResultText $info.LastTaskResult } else { '不明' }
        Write-Check $false "実行用アカウントでのテストを実行できませんでした (タスクの結果: $result)"
        return
    }
    $lines = @(Get-Content -LiteralPath $out -Encoding UTF8)
    $ng = @($lines | Where-Object { $_ -match '-> NG' })
    Write-Check ($ng.Count -eq 0) "実行用アカウント $(Get-AccountName $UserEnv) として各場所を読めるか (結果: $out)"
    foreach ($l in @($lines | Where-Object { $_ -match '^(account|lstat)' })) {
        $color = if ($l -match '-> NG') { 'Red' } else { 'Gray' }
        Write-Host "       $l" -ForegroundColor $color
    }
    if ($ng.Count -gt 0) {
        Write-Host '       読めない場所のアクセス権 (icacls):'
        foreach ($l in $ng) {
            $path = ($l -replace '^lstat\s+', '' -replace '\s+->.*$', '').Trim()
            & icacls.exe $path 2>&1 | ForEach-Object { Write-Host "         $_" }
        }
    }
}

function Invoke-Doctor($Config, [string]$UserName) {
    Write-Host '== サーバー全体 ==' -ForegroundColor White
    Write-Host "  バージョン: $(Get-JfsVersion)" 
    $py = Find-BasePython $Config
    Write-Check ([bool]$py) "Python: $py"
    Write-Check ([bool](Get-LocalGroup -Name $script:LocalGroup -ErrorAction SilentlyContinue)) "グループ $script:LocalGroup"

    # リポジトリの場所と、その上の階層に拒否が付いていないか (付いているとサーバーが正しく動かない)
    $repo = $script:RepoRoot.TrimEnd('\')
    $letter = ([System.IO.Path]::GetPathRoot($repo)).TrimEnd('\').TrimEnd(':')
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    $fs = if ($vol) { [string]$vol.FileSystemType } else { '不明' }
    Write-Check ($fs -in @('NTFS', 'ReFS', '不明')) "リポジトリ: $repo (ドライブ $($letter): / $fs)"
    $groupSid = (Get-LocalGroup -Name $script:LocalGroup -ErrorAction SilentlyContinue).SID.Value
    if ($groupSid) {
        $dir = Split-Path -Parent $repo
        while ($dir) {
            if (Test-HasDeny $dir $groupSid) {
                Write-Check $false "$dir にサーバー実行用アカウントへの拒否が付いています (リポジトリの上の階層)。'jfs.cmd start' または 'jfs.cmd protect' で外せます"
            }
            $parent = Split-Path -Parent $dir
            if (-not $parent -or $parent -eq $dir) { break }
            $dir = $parent
        }
    }

    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    foreach ($n in $profiles) {
        Write-Check ($n.NetworkCategory -ne 'Public') ("ネットワーク '$($n.Name)' ($($n.InterfaceAlias)): $($n.NetworkCategory)" +
            $(if ($n.NetworkCategory -eq 'Public') { " → 'jfs.cmd network' で、パブリックのままでも接続できるように設定できます (-SetPrivate でプライベートに変更)" } else { '' }))
    }
    $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $_.AllowInboundRules -eq 'False' })
    foreach ($f in $fw) { Write-Check $false "ファイアウォールのプロファイル $($f.Name) で受信規則が無効化されています (グループ ポリシーなど)" }

    # 過去に「アクセスを許可しない」を選ぶと、python.exe をブロックする規則ができ、ポートの許可より優先される
    $blocks = @(Get-PythonBlockRules)
    if ($blocks.Count -gt 0) {
        foreach ($b in $blocks) { Write-Check $false "python をブロックする受信規則があります: '$($b.DisplayName)' ('jfs.cmd network' で無効化できます)" }
    } else {
        Write-Check $true 'python をブロックするファイアウォール規則はありません'
    }

    foreach ($u in (Get-TargetUsers $Config $UserName)) {
        if ($UserName) {
            Write-Host ''
            Write-Host "== ユーザー '$($u.name)' のアクセステスト ==" -ForegroundColor White
            Test-AccessAsUser $Config $u
        }
        Test-ServiceTarget "ユーザー '$($u.name)'" (Get-TaskName $u) (Get-AccountName $u) ([int]$u.port) `
            "jupyter-for-share-$($u.name)" '/api/status' (Get-InstancePaths $u).Log ([string]$u.token) $u.name
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
                    Write-Host ('{0,-18}{1,-8}{2}' -f $s.name, $s.port, (Get-UserStatus $s))
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
            $auto = if (Get-JfsTask 'jfs-autostart') { 'オン' } else { "オフ ('jfs.cmd autostart on' でオン)" }
            Write-Host "サインイン時の自動起動: $auto"
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
            # アンインストール時に残したフォルダ (work などがあり、アカウントはない) は、中身を残したまま引き継ぐ
            $hasAccount = [bool](Get-LocalUser -Name "$($script:UserPrefix)$userName" -ErrorAction SilentlyContinue)
            $reuse = (-not $hasAccount) -and (Test-Path -LiteralPath (Join-Path $folder 'work'))
            if ($reuse) {
                Write-Info "以前のフォルダ $folder が残っているので、中身 (ノートブック・venv など) をそのまま使います。"
            } elseif ((Test-Path -LiteralPath $folder) -or $hasAccount) {
                throw ("以前の作成途中のデータ (フォルダ $folder またはアカウント $($script:UserPrefix)$userName) が残っています。" +
                       "'jfs.cmd remove $userName' で片付けてから、もう一度作成してください。")
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

                Write-Info "[5/6] 設定ファイル・ファイアウォール・起動用タスクを登録 (ポート $($u.port))"
                $cfg.users = @($cfg.users) + $u
                Save-Config $cfg
                Sync-FirewallRules $cfg
                Register-UserTask $u
            } catch {
                $err = $_.Exception.Message
                Write-Warn "作成に失敗したため、途中まで作ったものを片付けます: $err"
                try {
                    if ($reuse) { Remove-UserLeftovers $userName '' }   # 引き継いだフォルダは消さない
                    else { Remove-UserLeftovers $userName $folder }
                    $cfg = Read-Config
                    $cfg.users = @($cfg.users | Where-Object { $_.name -ne $userName })
                    Save-Config $cfg
                    Sync-FirewallRules $cfg
                } catch {
                    Write-Warn "片付けの一部に失敗しました ($($_.Exception.Message))。'jfs.cmd remove $userName' で片付けてください。"
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
            Restart-UserEnv $u $cfg | Out-Null
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
                if ($KeepFiles) { $msg += "フォルダ $folder は残ります。" }
                else { $msg += "フォルダ $folder も中身 (ノートブックなど) ごと削除されます。" }
                $ans = Read-Host "$msg よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            if ($u) {
                $cfg.users = @($cfg.users | Where-Object { $_.name -ne $userName })
                Save-Config $cfg
            }
            Sync-FirewallRules $cfg
            if ($KeepFiles) { Remove-UserLeftovers $userName '' }
            else { Remove-UserLeftovers $userName $folder }
            Write-Ok "ユーザー '$userName' の環境を削除しました。"
        }

        'start' {
            $cfg = Read-Config
            Start-Users $cfg $Name
        }

        'stop' {
            $cfg = Read-Config
            Stop-Users $cfg $Name
        }

        'restart' {
            $cfg = Read-Config
            if (-not (Get-HubProcess)) { Start-Users $cfg $Name; break }   # このウィンドウで起動
            foreach ($u in (Get-TargetUsers $cfg $Name)) { Restart-UserEnv $u $cfg | Out-Null }
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
                Restart-UserEnv $u $cfg | Out-Null
                Write-Ok '新しいトークンを発行しました。古い URL は使えなくなります。'
            }
            Show-UserUrls $cfg $u
        }

        'logs' {
            $cfg = Read-Config
            if ($Name -eq 'monitor') { $log = (Get-MonitorPaths).Log }
            else {
                $ip = Get-InstancePaths (Get-RequiredUser $cfg $Name)
                $log = $ip.Log
                Write-Host "== 実行したコマンド ($($ip.CommandLog)) ==" -ForegroundColor White
                if (Test-Path -LiteralPath $ip.CommandLog) { Get-Content -LiteralPath $ip.CommandLog -Tail 50 -Encoding UTF8 }
                else { Write-Host '  (まだありません)' }
                Write-Host "== サーバーのログ ($log) ==" -ForegroundColor White
            }
            if (-not (Test-Path -LiteralPath $log)) { throw "ログファイルがまだありません: $log" }
            if ($Follow) { Get-Content -LiteralPath $log -Tail 100 -Wait -Encoding UTF8 }
            else { Get-Content -LiteralPath $log -Tail 100 -Encoding UTF8 }
        }

        'upgrade' {
            $cfg = Read-Config
            foreach ($u in (Get-TargetUsers $cfg $Name)) {
                $inHub = [bool](Get-HubProcess) -and (Test-Wanted (Get-Wanted) $u.name)
                if ($inHub) { Suspend-UserEnv $u }
                else { Stop-JfsTask (Get-TaskName $u) (Get-AccountName $u) "ユーザー '$($u.name)' の環境" }
                try {
                    Install-JupyterLab $cfg $u -Upgrade
                    Register-VenvKernel $u
                } finally {
                    if ($inHub) { Resume-UserEnv $u }
                }
            }
        }

        'reset-venv' {
            $cfg = Read-Config
            $u = Get-RequiredUser $cfg $Name
            if (-not $Force) {
                $ans = Read-Host "ユーザー '$($u.name)' の venv を作り直します (追加したパッケージは消えます)。よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            $inHub = [bool](Get-HubProcess) -and (Test-Wanted (Get-Wanted) $u.name)
            if ($inHub) { Suspend-UserEnv $u }
            else { Stop-JfsTask (Get-TaskName $u) (Get-AccountName $u) "ユーザー '$($u.name)' の環境" }
            try {
                $venv = (Get-InstancePaths $u).Venv
                Remove-TreeSafe $venv
                $sid = New-ServiceAccount (Get-AccountName $u) "jupyter-for-share: $($u.name)"
                Initialize-InstanceFolders $u $sid
                Install-UserVenv $cfg $u
            } finally {
                if ($inHub) { Resume-UserEnv $u }
            }
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
            foreach ($u in @($cfg.users)) { Write-UserReadme $cfg $u }
            if (Get-HubProcess) {
                Write-Info 'サーバー管理ウィンドウでリソースモニターを起動しています...'
                $deadline = (Get-Date).AddSeconds(90)
                while (-not (Test-PortListening ([int]$cfg.monitor.port)) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
                if (Test-PortListening ([int]$cfg.monitor.port)) { Write-Ok 'リソースモニターが起動しました。' }
                else { Write-Warn 'リソースモニターが起動しませんでした。サーバー管理ウィンドウの表示を確認してください。' }
            } else {
                Write-Info "リソースモニターは 'jfs.cmd start' で開くサーバー管理ウィンドウの中で、ユーザーのサーバーと一緒に動きます。"
            }
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

        'hub' {
            Invoke-Hub
        }

        'refresh' {
            $cfg = Read-Config
            foreach ($u in @($cfg.users)) {
                if (-not (Test-Path -LiteralPath (Get-InstancePaths $u).Config)) { Write-Warn "ユーザー '$($u.name)' のフォルダがありません。"; continue }
                Initialize-LogsFolder $u
                Write-ServerFiles $cfg $u
                Register-UserTask $u
                Write-Ok "ユーザー '$($u.name)' の起動用ファイルと設定を更新しました。"
            }
            Write-Info "起動中のサーバーに反映するには 'jfs.cmd restart' を実行してください。"
        }

        'autostart' {
            switch ("$Name".ToLowerInvariant()) {
                'on'  { Set-AutoStart $true }
                'off' { Set-AutoStart $false }
                default { throw "on か off を指定してください。例: jfs.cmd autostart on" }
            }
        }

        'network' {
            Invoke-NetworkSetup (Read-Config) -SetPrivate:$SetPrivate -Yes:$Yes
        }

        'uninstall' {
            $cfg = Read-Config
            if (-not $Force) {
                $msg = 'jupyter-for-share が Windows に加えた変更をすべて元に戻します (サーバーは停止し、実行用アカウントは削除されます)。'
                if ($DeleteFiles) { $msg += ' user フォルダ (ノートブックなど) も削除します。' }
                $ans = Read-Host "$msg よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            Invoke-Uninstall $cfg -DeleteFiles:$DeleteFiles
        }

        'version' {
            Write-Host "jupyter-for-share $(Get-JfsVersion)"
            Write-Host "場所: $script:RepoRoot"
        }

        'doctor' {
            Invoke-Doctor (Read-Config) $Name
        }

        'protect' {
            $cfg = Read-Config
            if ($Status) { Show-ProtectStatus $cfg; break }
            Initialize-LocalGroup
            if ($Background) { Write-Info 'バックグラウンドでの実行は廃止しました。このウィンドウで実行します (終わるまで進み具合を表示します)。' }
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
    if ($PauseAtEnd -or $Command -eq 'hub') { Complete-Window -Failed }
    exit 1
}
# 管理者権限で開き直したウィンドウは、終わったら閉じる (表示が目的のコマンドは読めるように Enter で閉じる)
$showCommands = @('help', 'list', 'url', 'token', 'logs', 'doctor', 'version', 'network')
if ($PauseAtEnd) { Complete-Window -Keep:(($showCommands -contains $Command) -or ($Command -eq 'protect' -and $Status)) }
exit 0
