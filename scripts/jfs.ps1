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
                     'hub', 'refresh', 'autostart',
                     'url', 'token', 'logs', 'upgrade', 'reset-venv', 'firewall', 'protect', 'unprotect',
                     'monitor', 'monitor-stop')

# コマンドごとの詳しい説明 (jfs.cmd help <コマンド>)
$script:CommandHelp = @{
    'list'         = "jfs.cmd list`n  ユーザー環境 (ユーザー名・ポート・状態・フォルダ) とリソースモニターの状態を一覧表示します。"
    'add'          = "jfs.cmd add <ユーザー名>`n  ユーザー環境を作成して起動し、接続用 URL を表示します。`n  フォルダは user\<ユーザー名>、ポートは空いている番号から自動で決まります。`n  ユーザー名は半角英数字とハイフン (16 文字以内)。`n例: jfs.cmd add alice"
    'set'          = "jfs.cmd set <ユーザー名> [-Port 番号] [-AllowFrom 範囲]`n  ポートや、接続を許可する相手 (ファイアウォール) を変更して再起動します。`n例: jfs.cmd set alice -Port 23456`n    jfs.cmd set alice -AllowFrom 192.168.1.0/24,192.168.2.10"
    'remove'       = "jfs.cmd remove <ユーザー名> [-KeepFiles] [-Force]`n  ユーザー環境 (実行用アカウント・自動起動・ファイアウォール規則) を、フォルダ user\<ユーザー名> ごと削除します。`n  -KeepFiles: フォルダは残す`n  -Force: 確認せずに削除"
    'start'        = "jfs.cmd start [ユーザー名]`n  サーバー管理ウィンドウ (全ユーザー共通で 1 つ) を開き、そのユーザーのサーバーを起動します。省略または all で全員分。`n  ウィンドウには全員のサーバーのログと実行したコマンドが [ユーザー名] 付きで表示されます。`n  ウィンドウを閉じる (または Ctrl+C) と全員のサーバーが停止します。"
    'stop'         = "jfs.cmd stop [ユーザー名]`n  そのユーザーのサーバーを停止します。省略または all で全員を停止し、サーバー管理ウィンドウも閉じます。"
    'restart'      = "jfs.cmd restart [ユーザー名]`n  ユーザー環境を再起動します。省略または all で全員分。"
    'url'          = "jfs.cmd url [ユーザー名]`n  接続用 URL (トークン付き) を表示します。省略すると全員分とリソースモニターの URL。"
    'token'        = "jfs.cmd token <ユーザー名> [-New]`n  接続用 URL を表示します。-New でトークンを再発行します (古い URL は使えなくなります)。"
    'logs'         = "jfs.cmd logs <ユーザー名|monitor> [-Follow]`n  サーバーのログと、利用者が実行したコマンドの記録 (user\<ユーザー名>\.logs) の末尾を表示します。`n  -Follow でサーバーのログの追記を表示し続けます (Ctrl+C で終了)。"
    'autostart'    = "jfs.cmd autostart on|off`n  on: この管理者が Windows にサインインしたとき、全ユーザーのサーバー (サーバー管理ウィンドウ) を自動で開く`n  off: 自動で開かない"
    'refresh'      = "jfs.cmd refresh`n  全ユーザーの起動用ファイル・設定・起動用タスクを作り直します (更新後に setup.cmd から自動で実行されます)。"
    'upgrade'      = "jfs.cmd upgrade [ユーザー名]`n  JupyterLab 本体を最新版に更新します。省略で全員分。venv に入れたパッケージはそのまま。"
    'reset-venv'   = "jfs.cmd reset-venv <ユーザー名> [-Force]`n  venv を作り直します (pip で入れたパッケージは消えます。work フォルダのファイルは残ります)。"
    'monitor'      = "jfs.cmd monitor [-Port 番号] [-AllowFrom 範囲]`n  リソースモニター (CPU / メモリ / GPU) を設置・更新して起動します。既定のポートは 8000。"
    'monitor-stop' = "jfs.cmd monitor-stop`n  リソースモニターを停止します (再開は jfs.cmd monitor)。"
    'doctor'       = "jfs.cmd doctor [ユーザー名]`n  つながらないときの診断です。アカウント・自動起動タスク・待ち受けポート・HTTP 応答・`n  ファイアウォール・ネットワークの種類・ログを確認し、問題のある箇所に [NG] を表示します。"
    'network'      = "jfs.cmd network [-SetPrivate] [-Yes]`n  他の PC から接続できないとき用。ネットワークとファイアウォールの現状を確認して表示し、`n  必要な変更 (ポートの許可・ping の許可・名前解決の許可・python をブロックする規則の無効化) を`n  一覧にしてから、確認のうえ適用します。適用後にもう一度状態を表示します。`n  -SetPrivate: 「パブリック」の LAN 接続を「プライベート」に変更する`n  -Yes: 確認せずに適用する"
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
  jfs.cmd start [ユーザー名]            起動 (省略で全員)。サーバー管理ウィンドウは 1 つだけ開き、閉じると全員停止
  jfs.cmd stop|restart [ユーザー名]     停止 / 再起動 (省略で全員)
  jfs.cmd remove <ユーザー名>           フォルダごと削除 (-KeepFiles でフォルダは残す)
  jfs.cmd token <ユーザー名> -New       トークンを再発行
  jfs.cmd set <ユーザー名> -Port 番号   ポートなどを変更
  jfs.cmd logs <ユーザー名> [-Follow]   ログと実行コマンドの記録を表示
  jfs.cmd upgrade [ユーザー名]          JupyterLab を更新
  jfs.cmd reset-venv <ユーザー名>       venv を作り直す

リソースモニター (CPU / メモリ / GPU)
  jfs.cmd monitor [-Port 8000]          設置・更新して起動
  jfs.cmd monitor-stop                  停止

サーバー全体
  jfs.cmd autostart on|off              サインイン時に全員のサーバーを自動で開く
  jfs.cmd refresh                       起動用ファイルなどを作り直す (更新後)
  jfs.cmd doctor [ユーザー名]           つながらないときの診断
  jfs.cmd network [-SetPrivate]         他の PC から接続できるようにネットワーク設定を確認・変更
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
    foreach ($d in @($p.Root, $p.Work, $p.Venv, $p.Server, $p.Config, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs,
                     (Join-Path $p.Home 'AppData\Roaming'), (Join-Path $p.Home 'AppData\Local'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    (Get-Item -LiteralPath $p.Server -Force).Attributes = 'Directory, Hidden'
    New-Item -ItemType Directory -Path (Split-Path -Parent $p.IPyStartup) -Force | Out-Null

    Invoke-Native 'icacls.exe' @($p.Root, '/inheritance:r', '/grant:r',
        "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidAdmins):(OI)(CI)F",
        "*$(Get-CurrentUserSid):(OI)(CI)F", "*$($AccountSid):(OI)(CI)RX", '/Q') -Quiet
    foreach ($d in @($p.Work, $p.Venv, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs)) {
        Invoke-Native 'icacls.exe' @($d, '/grant', "*$($AccountSid):(OI)(CI)M", '/Q') -Quiet
    }
}

# 古いバージョンで作った環境に .logs フォルダを追加する (フォルダ全体のアクセス権は付け直さない)
function Initialize-LogsFolder($UserEnv) {
    $p = Get-InstancePaths $UserEnv
    if (Test-Path -LiteralPath $p.Logs) { return }
    $user = Get-LocalUser -Name (Get-AccountName $UserEnv) -ErrorAction SilentlyContinue
    if (-not $user) { return }
    New-Item -ItemType Directory -Path $p.Logs -Force | Out-Null
    Invoke-Native 'icacls.exe' @($p.Logs, '/grant', "*$($user.SID.Value):(OI)(CI)M", '/Q') -Quiet
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
    Register-VenvKernel $UserEnv
    Write-Ok "venv の準備ができました (パッケージ: $($pkgs -join ', '))。"
}

# JupyterLab の既定カーネル (python3) を利用者用 venv の Python にする。
# JupyterLab 側の ipykernel をインストール・更新すると python3 カーネルが上書きされるので、その後に必ず呼ぶ。
function Register-VenvKernel($UserEnv) {
    $p = Get-InstancePaths $UserEnv
    $py = Join-Path $p.Venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) { return }
    Invoke-Native $py @('-m', 'ipykernel', 'install', '--prefix', $p.LabVenv,
                        '--name', 'python3', '--display-name', 'Python 3 (venv)') -Quiet
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
    [System.IO.File]::WriteAllText((Join-Path $p.Config 'jupyter_server_config.py'), $py, $utf8)

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
exit /b %ERRORLEVEL%
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
    return '停止 (自動起動待ち)'
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
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Object -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
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
    $w = [pscustomobject]@{ all = $false; users = @() }
    if (Test-Path -LiteralPath $f) {
        try {
            $data = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            $w.all = [bool]$data.all
            $w.users = @(foreach ($x in @($data.users)) { if ($x) { [string]$x } })
        } catch { }
    }
    return $w
}

function Save-Wanted([bool]$All, [string[]]$Users) {
    Write-JsonFile (Get-HubPaths).Wanted @{ all = $All; users = @($Users | Where-Object { $_ } | Select-Object -Unique) }
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

# サーバー管理ウィンドウが開いていなければ開く (ウィンドウは常に 1 つだけ)
function Open-Hub {
    if (Get-HubProcess) { return }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'hub') | Out-Null
    Write-Info 'サーバー管理ウィンドウを開きました (全ユーザーのログはこのウィンドウに表示されます)。'
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Get-HubProcess) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
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

# ユーザーを起動対象にし、サーバー管理ウィンドウで起動されるのを待つ
function Start-UserEnv($UserEnv) {
    $label = "ユーザー '$($UserEnv.name)' の環境"
    Add-Wanted $UserEnv.name
    if ((Get-HubProcess) -and (Test-PortListening ([int]$UserEnv.port))) {
        Write-Info "$label は起動済みです。"
        return $true
    }
    Open-Hub
    Write-Info "$label の起動を待っています (初回は 1 分ほどかかることがあります)..."
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
    $fs = [System.IO.File]::Open($Tail.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                 [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
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
        Stop-UserEnv $UserEnv $Config
        return (Start-UserEnv $UserEnv)
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
function Start-Users($Config, [string]$UserName) {
    if ($UserName -and $UserName -ne 'all') { Start-UserEnv (Get-RequiredUser $Config $UserName) | Out-Null; return }
    $users = @($Config.users)
    if ($users.Count -eq 0) { throw "ユーザー環境がありません。'jfs.cmd add <ユーザー名>' で作成してください。" }
    Save-Wanted $true @()
    Open-Hub
    Write-Info '全ユーザーのサーバーの起動を待っています...'
    foreach ($u in $users) {
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

# サーバー管理ウィンドウの本体 (jfs.ps1 hub)
function Invoke-Hub {
    if (Get-HubProcess) { throw 'サーバー管理ウィンドウは既に開いています。' }
    $hp = Get-HubPaths
    $me = Get-Process -Id $PID
    Write-JsonFile $hp.Record @{ pid = $PID; started = $me.StartTime.ToString('o') }

    Write-Host 'jupyter-for-share サーバー管理ウィンドウ' -ForegroundColor White
    Write-Host 'このウィンドウを閉じる (または Ctrl+C) と、全ユーザーのサーバーが停止します。' -ForegroundColor Yellow
    Write-Host "1 人だけ止める: jfs.cmd stop <ユーザー名> / 起動する: jfs.cmd start <ユーザー名>"
    Write-Host ('-' * 70)

    $states = @{}      # ユーザー名 → 状態 (起動中か、ログの読み込み位置など)
    $cfg = Read-Config
    $lastConfigRead = Get-Date
    $everRan = $false
    try {
        while ($true) {
            if (((Get-Date) - $lastConfigRead).TotalSeconds -ge 5) { $cfg = Read-Config; $lastConfigRead = Get-Date }
            $wanted = Get-Wanted
            $running = 0
            foreach ($u in @($cfg.users)) {
                $name = $u.name
                $st = $states[$name]
                $want = Test-Wanted $wanted $name
                if (-not $want) {
                    if ($st -and $st.Active) {
                        Remove-Item -LiteralPath $st.Paths.Heartbeat -ErrorAction SilentlyContinue
                        Stop-JfsTask $st.Task (Get-AccountName $u) "ユーザー '$name' の環境"
                        Write-UserLine $name '[jupyter-for-share] サーバーを停止しました。'
                        $st.Active = $false
                    }
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
                        Active = $true; Task = (Get-TaskName $u); Paths = $paths; Port = [int]$u.port
                        ServerTail = (New-LogTail $paths.Log); CommandTail = (New-LogTail $paths.CommandLog)
                        Running = $false; StartedAt = [datetime]::MinValue; NextStart = (Get-Date)
                    }
                    $states[$name] = $st
                    Write-UserLine $name "[jupyter-for-share] 起動します (ポート $($u.port) / ログ: $($paths.Log))"
                }

                [System.IO.File]::WriteAllText($st.Paths.Heartbeat, (Get-Date).ToString('o'))
                $task = Get-JfsTask $st.Task
                $stateName = if ($task) { [string]$task.State } else { 'Missing' }
                if ($stateName -ne 'Running' -and ((Get-Date) - $st.StartedAt).TotalSeconds -ge 10) {
                    if ($st.Running) {
                        $info = Get-ScheduledTaskInfo -TaskPath $script:TaskPath -TaskName $st.Task -ErrorAction SilentlyContinue
                        $result = if ($info) { Get-TaskResultText $info.LastTaskResult } else { '不明' }
                        Write-UserLine $name "[jupyter-for-share] サーバーが停止しました (結果: $result)。10 秒後に再起動します。"
                        $st.Running = $false
                        $st.NextStart = (Get-Date).AddSeconds(10)
                    }
                    if ((Get-Date) -ge $st.NextStart) {
                        if ($task -and $stateName -eq 'Disabled') { Enable-ScheduledTask -InputObject $task | Out-Null }
                        Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $st.Task
                        $st.Running = $true
                        $st.StartedAt = Get-Date
                    }
                }
                foreach ($line in (Read-LogTail $st.ServerTail)) { Write-UserLine $name $line }
                foreach ($line in (Read-LogTail $st.CommandTail)) { Write-UserLine $name $line 'command' }
            }
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
        Remove-Item -LiteralPath $hp.Record -ErrorAction SilentlyContinue
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
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" start all"
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
    Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip', 'psutil') -Quiet

    $bind = [string](Get-Value $Config.defaults 'bindAddress' '0.0.0.0')
    $cmd = @'
@echo off
rem Generated by jupyter-for-share. Do not edit: the jfs.cmd command overwrites this file.
set "TEMP=@@TMP@@"
set "TMP=@@TMP@@"
set "PYTHONUTF8=1"
set "PYTHONUNBUFFERED=1"
if exist "@@LOG@@" for %%F in ("@@LOG@@") do if %%~zF GTR 10485760 move /y "@@LOG@@" "@@LOG@@.1" >nul
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
function Get-SiblingTargets([string]$Root, [string[]]$KeepPaths, [string[]]$KeepNames = @()) {
    $keep = @($KeepPaths | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
    $result = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $dir = [string]$queue.Dequeue()
        # 隠し・システム属性の項目 (System Volume Information など) は対象外
        foreach ($c in @(Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue)) {
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
                $targets += Get-SiblingTargets $root $keepHere
            } else {
                $targets += $root
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
    # 以前は対象だったが今は対象外になった場所 (例: 旧バージョンが拒否を付けた、リポジトリのあるドライブの直下) は拒否を外す
    $stale = @($applied | Where-Object { ($targets -notcontains $_) -and (Test-Path -LiteralPath $_) })
    if ($stale.Count -gt 0) {
        Write-Info "対象外になった次の場所の拒否を外します (ファイル数が多いと時間がかかります): $($stale -join ', ')"
        Invoke-IcaclsParallel $stale @('/remove:d', "*$sid", '/Q', '/C')
        $applied = @($applied | Where-Object { $stale -notcontains $_ })
        Save-ProtectedApplied $applied
    }
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
    Remove-Wanted (Read-Config) $UserName
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
            Write-Check ($task.State -ne 'Disabled') "自動起動タスク $($script:TaskPath)$TaskName (状態: $($task.State))"
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

function Invoke-Doctor($Config, [string]$UserName) {
    Write-Host '== サーバー全体 ==' -ForegroundColor White
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
                Write-Check $false "$dir にサーバー実行用アカウントへの拒否が付いています (リポジトリの上の階層)。'jfs.cmd protect' で外せます"
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
            if ((Test-Path -LiteralPath $folder) -or (Get-LocalUser -Name "$($script:UserPrefix)$userName" -ErrorAction SilentlyContinue)) {
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
                    Remove-UserLeftovers $userName $folder
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
            if (-not (Get-HubProcess)) { Start-Users $cfg $Name; break }
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
                $wasRunning = (Test-Wanted (Get-Wanted) $u.name) -or (Test-PortListening ([int]$u.port))
                Stop-UserEnv $u $cfg
                Install-JupyterLab $cfg $u -Upgrade
                Register-VenvKernel $u
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
            Stop-UserEnv $u $cfg
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
    if ($PauseAtEnd -or $Command -eq 'hub') { Read-Host 'Enter キーで終了します' | Out-Null }
    exit 1
}
if ($PauseAtEnd) { Read-Host 'Enter キーで終了します' | Out-Null }
exit 0
