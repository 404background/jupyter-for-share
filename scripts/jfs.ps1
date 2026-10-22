#Requires -Version 5.1
<#
.SYNOPSIS
    jupyter-for-share のサーバー (ポートごとの JupyterLab) を管理します。
.DESCRIPTION
    使い方は `jfs help` または README.md を参照してください。
    管理者権限が必要です (管理者でない場合は UAC で昇格して実行し直します)。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'list', 'add', 'set', 'remove', 'start', 'stop', 'restart',
                 'url', 'token', 'logs', 'upgrade', 'reset-venv', 'firewall', 'protect', 'unprotect')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name,

    [int]$Port,
    [string[]]$AllowFrom,
    [string[]]$Packages,

    [switch]$New,
    [switch]$DeleteFiles,
    [switch]$Follow,
    [switch]$Force,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Show-Help {
    Write-Host @'
jupyter-for-share 管理コマンド (管理者権限で実行)

使い方: jfs <コマンド> [サーバー名] [オプション]

  list                          サーバーの一覧と状態
  add <名前> -Port 8888         サーバーを作成して起動 (フォルダ: <instancesRoot>\<名前>)
      -AllowFrom <範囲>           接続を許可する相手 (既定: LocalSubnet。例: 192.168.1.0/24,192.168.1.50)
      -Packages numpy,pandas      venv に最初から入れておくパッケージ
  set <名前> -Port 8890         ポート / 接続許可範囲 (-AllowFrom) を変更
  remove <名前> [-DeleteFiles]  サーバーを削除 (-DeleteFiles でフォルダも削除)
  start|stop|restart [名前]     起動 / 停止 / 再起動 (名前省略または all で全サーバー)
  url [名前]                    接続用 URL を表示
  token <名前> -New             アクセストークンを再発行
  logs <名前> [-Follow]         サーバーのログを表示
  upgrade [名前]                JupyterLab 本体を最新版に更新
  reset-venv <名前>             venv (追加したパッケージ) を作り直す
  firewall                      Windows ファイアウォール規則を設定ファイルに合わせて更新
  protect / unprotect           サーバー用ユーザーから他のフォルダへのアクセス禁止を設定 / 解除
'@
}

# ---- サーバー情報 ----

function Find-Server($Config, [string]$ServerName) {
    foreach ($s in @($Config.servers)) {
        if ($s.name -eq $ServerName) { return $s }
    }
    return $null
}

function Get-TargetServers($Config, [string]$ServerName) {
    if (-not $ServerName -or $ServerName -eq 'all') { return @($Config.servers) }
    $s = Find-Server $Config $ServerName
    if (-not $s) { throw "サーバー '$ServerName' は登録されていません。'jfs list' で確認してください。" }
    return @($s)
}

function Get-RequiredServer($Config, [string]$ServerName) {
    if (-not $ServerName -or $ServerName -eq 'all') { throw 'サーバー名を指定してください。' }
    return (Get-TargetServers $Config $ServerName)[0]
}

function Get-UserName($Server) { return "$($script:UserPrefix)$($Server.name)" }
function Get-TaskName($Server) { return "jfs-$($Server.name)" }

function Get-InstancePaths($Server) {
    $root = [string]$Server.path
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

function Assert-ServerName([string]$ServerName) {
    # Windows のユーザー名は 20 文字まで ("jfs-" + 16 文字)
    if ($ServerName -notmatch '^[a-z0-9][a-z0-9-]{0,15}$' -or $ServerName -eq 'all') {
        throw "サーバー名 '$ServerName' は使えません。半角英小文字・数字・ハイフン (16 文字以内) で指定してください。"
    }
}

function Test-PortListening([int]$P) {
    return [bool](Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue)
}

function Assert-PortAvailable($Config, [int]$P, [string]$Self) {
    if ($P -lt 1024 -or $P -gt 65535) { throw "ポート番号 $P は使えません (1024-65535)。" }
    foreach ($s in @($Config.servers)) {
        if ($s.name -ne $Self -and [int]$s.port -eq $P) {
            throw "ポート $P はサーバー '$($s.name)' が使用しています。"
        }
    }
    if (Test-PortListening $P) { throw "ポート $P は他のプログラムが使用中です。" }
}

function Get-FreePort($Config) {
    $p = [int](Get-Value $Config.defaults 'portStart' 8888)
    $used = @($Config.servers | ForEach-Object { [int]$_.port })
    while (($used -contains $p) -or (Test-PortListening $p)) { $p++ }
    return $p
}

function Get-AllowFromList([string[]]$Values) {
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---- サーバー用 Windows ユーザー ----

function New-ServerUser($Server) {
    $u = Get-UserName $Server
    if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) {
        $pw = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
        New-LocalUser -Name $u -Password $pw -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires `
            -Description "jupyter-for-share: $($Server.name)" | Out-Null
        Write-Ok "サーバー用ユーザー '$u' を作成しました。"
    }
    $sid = (Get-LocalUser -Name $u).SID.Value
    foreach ($g in @($script:SidUsers, (Get-LocalGroupSid))) {
        try {
            Add-LocalGroupMember -SID $g -Member $u -ErrorAction Stop
        } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
            # 既にメンバー
        }
    }
    # サインイン画面に表示しない
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name $u -Value 0 -PropertyType DWord -Force | Out-Null
    return $sid
}

function Remove-ServerUser($Server) {
    $u = Get-UserName $Server
    $user = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
    if (-not $user) { return }
    $sid = $user.SID.Value
    Remove-LocalUser -Name $u
    Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.SID -eq $sid } | Remove-CimInstance -ErrorAction SilentlyContinue
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    Remove-ItemProperty -Path $key -Name $u -ErrorAction SilentlyContinue
    Write-Ok "サーバー用ユーザー '$u' を削除しました。"
}

# ---- フォルダとアクセス権 ----
#   <root>          … 管理者: フル / サーバー用ユーザー: 読み取りのみ
#   <root>\work     … ノートブック等の作業フォルダ (JupyterLab のルート) : 変更可
#   <root>\venv     … パッケージを入れる Python 仮想環境 : 変更可
#   <root>\.server  … JupyterLab 本体・設定 (読み取りのみ) と、ホーム・ログなど (変更可)
function Initialize-InstanceFolders($Server, [string]$UserSid) {
    $p = Get-InstancePaths $Server
    foreach ($d in @($p.Root, $p.Work, $p.Venv, $p.Server, $p.Config, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs,
                     (Join-Path $p.Home 'AppData\Roaming'), (Join-Path $p.Home 'AppData\Local'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    (Get-Item -LiteralPath $p.Server).Attributes = 'Directory, Hidden'

    Invoke-Native 'icacls.exe' @($p.Root, '/inheritance:r', '/grant:r',
        "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidAdmins):(OI)(CI)F",
        "*$(Get-CurrentUserSid):(OI)(CI)F", "*$($UserSid):(OI)(CI)RX", '/Q') -Quiet
    foreach ($d in @($p.Work, $p.Venv, $p.Data, $p.Runtime, $p.Home, $p.Tmp, $p.Logs)) {
        Invoke-Native 'icacls.exe' @($d, '/grant', "*$($UserSid):(OI)(CI)M", '/Q') -Quiet
    }
}

# ---- Python 環境 ----

function Install-JupyterLab($Config, $Server, [switch]$Upgrade) {
    $p = Get-InstancePaths $Server
    $py = Join-Path $p.LabVenv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) {
        $base = Find-BasePython $Config
        if (-not $base) { throw 'Python が見つかりません。先に setup.cmd を実行してください。' }
        Invoke-Native $base @('-m', 'venv', $p.LabVenv) -Quiet
    }
    $pkgs = @('jupyterlab')
    $locale = [string](Get-Value $Config.defaults 'labLocale' 'ja_JP')
    if ($locale -and $locale -notmatch '^en') { $pkgs += "jupyterlab-language-pack-$($locale.Replace('_', '-'))" }
    $pkgs += @(Get-Value $Config.defaults 'extraServerPackages' @())

    Write-Info "JupyterLab をインストールしています ($($Server.name))。数分かかります..."
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
function Install-UserVenv($Config, $Server, [string[]]$ExtraPackages) {
    $p = Get-InstancePaths $Server
    $base = Find-BasePython $Config
    if (-not $base) { throw 'Python が見つかりません。先に setup.cmd を実行してください。' }
    Write-Info "venv を作成しています: $($p.Venv)"
    Invoke-Native $base @('-m', 'venv', $p.Venv) -Quiet
    $py = Join-Path $p.Venv 'Scripts\python.exe'
    Invoke-Native $py @('-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'pip') -Quiet
    $pkgs = @('ipykernel') + @(Get-Value $Config.defaults 'venvPackages' @()) + @($ExtraPackages | Where-Object { $_ })
    Invoke-Native $py (@('-m', 'pip', 'install', '--disable-pip-version-check') + $pkgs) -Quiet
    Invoke-Native $py @('-m', 'ipykernel', 'install', '--prefix', $p.LabVenv,
                        '--name', 'python3', '--display-name', 'Python 3 (venv)') -Quiet
    Write-Ok "venv の準備ができました (パッケージ: $($pkgs -join ', '))。"
}

# ---- 起動スクリプトと Jupyter の設定 ----

function Write-ServerFiles($Config, $Server) {
    $p = Get-InstancePaths $Server
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
    $py = $py.Replace('@@BIND@@', $bind).Replace('@@PORT@@', [string][int]$Server.port).
              Replace('@@WORK@@', $p.Work).Replace('@@TOKEN@@', [string]$Server.token)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $p.Config 'jupyter_server_config.py'), $py, $utf8)

    # HOME や AppData などをサーバーのフォルダ内に向け、venv を PATH の先頭に置いて JupyterLab を起動する
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
    # cmd.exe はバッチファイルを OEM コードページ (日本語環境では CP932) で読む
    $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [System.IO.File]::WriteAllText($p.RunCmd, $cmd.Replace("`r`n", "`n").Replace("`n", "`r`n"), $oem)
}

# ---- タスクスケジューラ (Windows 起動時に、サーバー用ユーザーとして自動起動) ----

function Register-ServerTask($Server) {
    $p = Get-InstancePaths $Server
    $u = Get-UserName $Server
    # パスワードは保存せず、登録のたびに新しいランダムなものを設定する
    $plain = New-RandomPassword
    Set-LocalUser -Name $u -Password (ConvertTo-SecureString $plain -AsPlainText -Force)

    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -Argument "/d /c `"`"$($p.RunCmd)`"`"" -WorkingDirectory $p.Work
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -Priority 5
    Register-ScheduledTask -TaskName (Get-TaskName $Server) -TaskPath $script:TaskPath `
        -Action $action -Trigger $trigger -Settings $settings `
        -User "$env:COMPUTERNAME\$u" -Password $plain -RunLevel Limited `
        -Description "jupyter-for-share: $($Server.name) (port $($Server.port))" -Force | Out-Null
}

function Get-ServerTask($Server) {
    return Get-ScheduledTask -TaskPath $script:TaskPath -TaskName (Get-TaskName $Server) -ErrorAction SilentlyContinue
}

function Stop-ServerProcesses($Server) {
    $full = "$env:COMPUTERNAME\$(Get-UserName $Server)"
    Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -eq $full } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-Server($Server) {
    $task = Get-ServerTask $Server
    if (-not $task) { throw "サーバー '$($Server.name)' のタスクがありません。'jfs remove' してから作り直してください。" }
    Enable-ScheduledTask -InputObject $task | Out-Null
    if (Test-PortListening ([int]$Server.port)) {
        Write-Info "サーバー '$($Server.name)' は起動済みです。"
        return
    }
    Start-ScheduledTask -InputObject $task
    Write-Info "サーバー '$($Server.name)' を起動しています..."
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-PortListening ([int]$Server.port)) {
            Write-Ok "サーバー '$($Server.name)' が起動しました (ポート $($Server.port))。"
            return
        }
    }
    Write-Warn "サーバー '$($Server.name)' がポート $($Server.port) で応答しません。'jfs logs $($Server.name)' でログを確認してください。"
}

# 停止したサーバーは Windows を再起動しても起動しない (start で再開)
function Stop-Server($Server) {
    $task = Get-ServerTask $Server
    if ($task) {
        Disable-ScheduledTask -InputObject $task | Out-Null
        Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
    }
    Stop-ServerProcesses $Server
    Write-Ok "サーバー '$($Server.name)' を停止しました。"
}

function Get-ServerStatus($Server) {
    $task = Get-ServerTask $Server
    if (-not $task) { return 'タスクなし' }
    if ($task.State -eq 'Disabled') { return '停止' }
    if (Test-PortListening ([int]$Server.port)) { return '起動中' }
    if ($task.State -eq 'Running') { return '起動処理中' }
    return '停止 (自動起動待ち)'
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

function Show-ServerUrls($Config, $Server) {
    Write-Host ''
    Write-Host "サーバー '$($Server.name)' (フォルダ: $($Server.path))" -ForegroundColor White
    Write-Host '  接続 URL (どれか 1 つが使えれば OK。トークンはパスワードと同じ扱いで共有してください):'
    foreach ($h in Get-ServerHosts $Config) {
        Write-Host "    http://$($h):$($Server.port)/lab?token=$($Server.token)"
    }
    Write-Host ''
}

# ---- ファイアウォール ----

function Sync-FirewallRules($Config) {
    Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $profiles = [string](Get-Value $Config.defaults 'firewallProfiles' 'Domain,Private')
    foreach ($s in @($Config.servers)) {
        $allow = @(Get-Value $s 'allowFrom' (Get-Value $Config.defaults 'allowFrom' @('LocalSubnet')))
        New-NetFirewallRule -Name "jupyter-for-share-$($s.name)" `
            -DisplayName "jupyter-for-share: $($s.name) (TCP $($s.port))" `
            -Group $script:FirewallGroup `
            -Direction Inbound -Protocol TCP -LocalPort ([int]$s.port) -Action Allow `
            -RemoteAddress $allow -Profile $profiles | Out-Null
        Write-Ok "ファイアウォール: TCP $($s.port) を許可 ($($s.name) / 接続元: $($allow -join ', '))"
    }
}

# ---- 他のフォルダへのアクセス禁止 ----
# サーバー用ユーザーのグループに「拒否」のアクセス権を付ける。
# 対象 (protectedPaths の "auto"):
#   - システムドライブ以外の固定ドライブ全体 (D:\ など)
#   - システムドライブ直下の独自フォルダ (Windows / Program Files / Users など OS に必要なものは除く)
#   - C:\Users\Public
# 他のユーザーのプロファイル (C:\Users\<名前>) は Windows の既定で読めないので対象外。

function Get-ProtectTargets($Config) {
    $root = Get-InstancesRoot $Config
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
            $isAncestor = ($root -eq $dir) -or $root.StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)
            $hasPython = $python -and $python.StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase)
            if (($keep -notcontains $_.Name) -and -not $isAncestor -and -not $hasPython) { $targets += $dir }
        }
        if ($env:PUBLIC) { $targets += $env:PUBLIC }
    }
    return @($targets | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}

function Protect-Folders($Config) {
    $sid = Get-LocalGroupSid
    $targets = Get-ProtectTargets $Config
    if ($targets.Count -eq 0) { Write-Info 'アクセス禁止の対象フォルダはありません。'; return }
    Write-Info 'サーバー用ユーザーから次のフォルダへのアクセスを禁止します (ファイル数が多いと時間がかかります):'
    $targets | ForEach-Object { Write-Host "    $_" }
    $applied = @(Get-Value $Config 'protectedApplied' @())
    foreach ($t in $targets) {
        try {
            Invoke-Native 'icacls.exe' @($t, '/deny', "*$($sid):(OI)(CI)F", '/Q', '/C') -Quiet
            if ($applied -notcontains $t) { $applied += $t }
        } catch {
            Write-Warn "$t : $($_.Exception.Message)"
        }
    }
    Set-Value $Config 'protectedApplied' $applied
    Save-Config $Config
    Write-Ok 'アクセス禁止を設定しました。'
}

function Unprotect-Folders($Config) {
    $sid = Get-LocalGroupSid
    foreach ($t in @(Get-Value $Config 'protectedApplied' @())) {
        if (Test-Path -LiteralPath $t) {
            try {
                Invoke-Native 'icacls.exe' @($t, '/remove:d', "*$sid", '/Q', '/C') -Quiet
                Write-Ok "解除: $t"
            } catch { Write-Warn "$t : $($_.Exception.Message)" }
        }
    }
    Set-Value $Config 'protectedApplied' @()
    Save-Config $Config
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
            $rows = foreach ($s in @($cfg.servers)) {
                [pscustomobject]@{
                    Name   = $s.name
                    Port   = $s.port
                    Status = Get-ServerStatus $s
                    Folder = $s.path
                }
            }
            if ($rows) { $rows | Format-Table -AutoSize | Out-Host }
            else { Write-Info "サーバーはまだありません。'jfs add <名前> -Port <番号>' で作成してください。" }
        }

        'add' {
            $cfg = Read-Config
            if (-not $Name) {
                if (-not $bound.ContainsKey('Port')) { throw '名前かポートを指定してください。例: jfs add alice -Port 8888' }
                $Name = "port$Port"
            }
            Assert-ServerName $Name
            if (Find-Server $cfg $Name) { throw "サーバー '$Name' は既に存在します。" }
            $p = $Port
            if (-not $bound.ContainsKey('Port')) { $p = Get-FreePort $cfg }
            Assert-PortAvailable $cfg $p $Name

            $base = Find-BasePython $cfg
            if (-not $base) { throw 'Python が見つかりません。先に setup.cmd を実行してください。' }
            Initialize-LocalGroup
            $root = Initialize-InstancesRoot $cfg
            $folder = Join-Path $root $Name
            if (Test-Path -LiteralPath $folder) { throw "フォルダ $folder が既に存在します。別の名前にするか、フォルダを移動してください。" }
            if ($folder -match "[%`"',]") { throw "フォルダのパスに使えない文字 (% `" ' ,) が含まれています: $folder" }

            $s = [pscustomobject]@{ name = $Name; port = $p; path = $folder; token = (New-Token) }
            if ($bound.ContainsKey('AllowFrom')) { Set-Value $s 'allowFrom' (Get-AllowFromList $AllowFrom) }

            $sid = New-ServerUser $s
            Initialize-InstanceFolders $s $sid
            Install-JupyterLab $cfg $s
            Install-UserVenv $cfg $s (Get-AllowFromList $Packages)
            Write-ServerFiles $cfg $s

            $cfg.servers = @($cfg.servers) + $s
            Save-Config $cfg
            Sync-FirewallRules $cfg
            Register-ServerTask $s
            Start-Server $s
            Show-ServerUrls $cfg $s
        }

        'set' {
            $cfg = Read-Config
            $s = Get-RequiredServer $cfg $Name
            if ($bound.ContainsKey('Port') -and $Port -ne [int]$s.port) {
                Assert-PortAvailable $cfg $Port $s.name
                Set-Value $s 'port' $Port
            }
            if ($bound.ContainsKey('AllowFrom')) {
                $list = Get-AllowFromList $AllowFrom
                if ($list.Count -gt 0) { Set-Value $s 'allowFrom' $list } else { Remove-Value $s 'allowFrom' }
            }
            Save-Config $cfg
            Write-ServerFiles $cfg $s
            Sync-FirewallRules $cfg
            Register-ServerTask $s
            Stop-Server $s
            Start-Server $s
            Show-ServerUrls $cfg $s
        }

        'remove' {
            $cfg = Read-Config
            $s = Get-RequiredServer $cfg $Name
            if (-not $Force) {
                $msg = "サーバー '$($s.name)' を削除します。"
                if ($DeleteFiles) { $msg += "フォルダ $($s.path) も中身ごと削除されます。" }
                else { $msg += "フォルダ $($s.path) は残ります。" }
                $ans = Read-Host "$msg よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            Stop-Server $s
            $task = Get-ServerTask $s
            if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
            $cfg.servers = @($cfg.servers | Where-Object { $_.name -ne $s.name })
            Save-Config $cfg
            Sync-FirewallRules $cfg
            Remove-ServerUser $s
            if ($DeleteFiles -and (Test-Path -LiteralPath $s.path)) {
                Remove-Item -LiteralPath $s.path -Recurse -Force
                Write-Ok "フォルダを削除しました: $($s.path)"
            }
            Write-Ok "サーバー '$($s.name)' を削除しました。"
        }

        'start' {
            $cfg = Read-Config
            foreach ($s in (Get-TargetServers $cfg $Name)) { Start-Server $s }
        }

        'stop' {
            $cfg = Read-Config
            foreach ($s in (Get-TargetServers $cfg $Name)) { Stop-Server $s }
        }

        'restart' {
            $cfg = Read-Config
            foreach ($s in (Get-TargetServers $cfg $Name)) { Stop-Server $s; Start-Server $s }
        }

        'url' {
            $cfg = Read-Config
            foreach ($s in (Get-TargetServers $cfg $Name)) { Show-ServerUrls $cfg $s }
        }

        'token' {
            $cfg = Read-Config
            $s = Get-RequiredServer $cfg $Name
            if ($New) {
                Set-Value $s 'token' (New-Token)
                Save-Config $cfg
                Write-ServerFiles $cfg $s
                Stop-Server $s
                Start-Server $s
                Write-Ok '新しいトークンを発行しました。古い URL は使えなくなります。'
            }
            Show-ServerUrls $cfg $s
        }

        'logs' {
            $cfg = Read-Config
            $s = Get-RequiredServer $cfg $Name
            $log = (Get-InstancePaths $s).Log
            if (-not (Test-Path -LiteralPath $log)) { throw "ログファイルがまだありません: $log" }
            if ($Follow) { Get-Content -LiteralPath $log -Tail 100 -Wait -Encoding UTF8 }
            else { Get-Content -LiteralPath $log -Tail 100 -Encoding UTF8 }
        }

        'upgrade' {
            $cfg = Read-Config
            foreach ($s in (Get-TargetServers $cfg $Name)) {
                $wasRunning = (Get-ServerStatus $s) -eq '起動中'
                Stop-Server $s
                Install-JupyterLab $cfg $s -Upgrade
                if ($wasRunning) { Start-Server $s }
            }
        }

        'reset-venv' {
            $cfg = Read-Config
            $s = Get-RequiredServer $cfg $Name
            if (-not $Force) {
                $ans = Read-Host "サーバー '$($s.name)' の venv を作り直します (追加したパッケージは消えます)。よろしいですか? [y/N]"
                if ($ans -notmatch '^[yY]') { Write-Info '中止しました。'; break }
            }
            Stop-Server $s
            $venv = (Get-InstancePaths $s).Venv
            if (Test-Path -LiteralPath $venv) { Remove-Item -LiteralPath $venv -Recurse -Force }
            $sid = New-ServerUser $s
            Initialize-InstanceFolders $s $sid
            Install-UserVenv $cfg $s (Get-AllowFromList $Packages)
            Start-Server $s
        }

        'firewall' {
            Sync-FirewallRules (Read-Config)
        }

        'protect' {
            $cfg = Read-Config
            Initialize-LocalGroup
            Protect-Folders $cfg
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
