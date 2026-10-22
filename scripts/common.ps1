# jupyter-for-share: setup-server.ps1 / jfs.ps1 から読み込む共通処理

$script:RepoRoot          = Split-Path -Parent $PSScriptRoot
$script:ConfigPath        = Join-Path $script:RepoRoot 'servers.json'
$script:ExampleConfigPath = Join-Path $script:RepoRoot 'servers.example.json'
$script:FirewallGroup     = 'jupyter-for-share'
$script:LocalGroup        = 'jupyter-for-share-users'
$script:TaskPath          = '\jupyter-for-share\'
$script:UserPrefix        = 'jfs-'
$script:MonitorAccount    = 'jfsmon'
$script:MonitorDir        = Join-Path $script:RepoRoot 'monitor'
$script:RepositoryUrl     = 'https://github.com/404background/jupyter-for-share'

# Windows PowerShell 5.1 には配列に Count プロパティを足す型情報があり、関数の引数などを経由した配列を
# ConvertTo-Json が {"value": [...], "Count": n} という形で書き出してしまう (servers.json が壊れる)。
# この型情報を無効にして、配列が常に [...] で書き出されるようにする。
if ($PSVersionTable.PSVersion.Major -le 5) {
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
}

# よく使う SID (Windows の表示言語に関係なく使える)
$script:SidSystem = 'S-1-5-18'
$script:SidAdmins = 'S-1-5-32-544'
$script:SidUsers  = 'S-1-5-32-545'

function Write-Info([string]$Message) { Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 管理者でなければ、同じ引数で UAC 昇格して実行し直す (呼び出し元はこの後 exit すること)
function Start-Elevated([string]$ScriptPath, [System.Collections.IDictionary]$BoundParameters) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    foreach ($k in $BoundParameters.Keys) {
        $v = $BoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $argList += "-$k" }
        } else {
            $s = (@($v) | ForEach-Object { "$_" }) -join ','
            $argList += "-$k"
            $argList += "`"$($s.TrimEnd('\'))`""
        }
    }
    $argList += '-PauseAtEnd'
    Write-Info '管理者権限で実行します (UAC の確認が表示されます)...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
}

# 管理者権限で開き直したウィンドウを終わらせる。
#   成功: 10 秒後に自動で閉じる (何かキーを押すとすぐ閉じる)
#   -Failed / -Keep (エラーや、表示が目的のコマンド): 内容を読めるように Enter で閉じる
function Complete-Window([switch]$Failed, [switch]$Keep) {
    Write-Host ''
    if ($Failed -or $Keep) { Read-Host 'Enter キーでこのウィンドウを閉じます' | Out-Null; return }
    Write-Host '完了しました。このウィンドウは 10 秒後に閉じます (何かキーを押すとすぐ閉じます)。'
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        try {
            if ($Host.UI.RawUI.KeyAvailable) { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown'); break }
        } catch { break }
        Start-Sleep -Milliseconds 200
    }
}

# 外部コマンドを実行し、失敗したら出力を表示して例外にする
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$FilePath,
        [Parameter(Position = 1)][string[]]$Arguments = @(),
        [switch]$Quiet,
        [switch]$IgnoreExitCode   # 失敗しても例外にしない (一部のファイルで失敗しても続ける場合)
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0 -or -not $Quiet) {
        $out | ForEach-Object { Write-Host "    $_" }
    }
    if ($code -ne 0 -and -not $IgnoreExitCode) {
        throw "$(Split-Path -Leaf $FilePath) が失敗しました (exit code $code)。"
    }
}

# ---- 設定ファイル (servers.json) ----

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Set-Value($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Remove-Value($Object, [string]$Name) {
    if ($Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties.Remove($Name) }
}

# 旧バージョンが書き出した {"value": [...], "Count": n} を配列に戻す
$script:ConfigRepaired = $false
function Repair-JsonValue($Value) {
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names.Count -eq 2 -and ($names -contains 'value') -and ($names -contains 'Count')) {
            $script:ConfigRepaired = $true
            return ,@(foreach ($x in @($Value.value)) { Repair-JsonValue $x })
        }
        foreach ($prop in @($Value.PSObject.Properties)) { $prop.Value = Repair-JsonValue $prop.Value }
        return $Value
    }
    if ($Value -is [System.Array]) {
        return ,@(foreach ($x in $Value) { Repair-JsonValue $x })
    }
    return $Value
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Copy-Item -LiteralPath $script:ExampleConfigPath -Destination $script:ConfigPath
        Write-Info "設定ファイルを作成しました: $script:ConfigPath"
    }
    $script:ConfigRepaired = $false
    $cfg = Repair-JsonValue (Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($null -eq (Get-Value $cfg 'defaults')) { Set-Value $cfg 'defaults' ([pscustomobject]@{}) }
    if ($null -eq (Get-Value $cfg 'monitor')) { Set-Value $cfg 'monitor' ([pscustomobject]@{ enabled = $false; port = 8000 }) }

    # ユーザー一覧: 入れ子になった配列を平らにし、名前のない壊れた要素は捨てる
    $users = New-Object System.Collections.ArrayList
    foreach ($item in @(Get-Value $cfg 'users' @())) {
        foreach ($u in @($item)) {
            if ($u -is [System.Management.Automation.PSCustomObject] -and $u.PSObject.Properties['name'] -and $u.name) {
                if (-not ($users | Where-Object { $_.name -eq $u.name })) { [void]$users.Add($u) }
            } else {
                $script:ConfigRepaired = $true
            }
        }
    }
    Set-Value $cfg 'users' $users.ToArray()

    if ($script:ConfigRepaired) {
        $backup = "$($script:ConfigPath).bak"
        Copy-Item -LiteralPath $script:ConfigPath -Destination $backup -Force
        Save-Config $cfg
        Write-Warn "設定ファイルの壊れていた部分を修復しました (修復前: $backup)。"
    }
    return $cfg
}

function Save-Config($Config) {
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    # リソースモニターに、ユーザー名とポートだけ (トークンは含めない) を渡す
    $runtime = Join-Path $script:MonitorDir '.runtime'
    if (Test-Path -LiteralPath $runtime) {
        $list = @($Config.users | ForEach-Object { [pscustomobject]@{ name = $_.name; port = [int]$_.port } })
        $json = ConvertTo-Json -InputObject @{ users = $list } -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $runtime 'users.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    }
}

# ユーザーごとの環境を作る場所 (既定: このリポジトリの user フォルダ)
function Get-InstancesRoot($Config) {
    $root = [string](Get-Value $Config.defaults 'instancesRoot' '')
    if (-not $root) { $root = Join-Path $script:RepoRoot 'user' }
    return [System.IO.Path]::GetFullPath($root).TrimEnd('\')
}

# ---- Python ----

# Python の実行ファイルのバージョン (取得できなければ $null)
function Get-PythonVersion([string]$Exe) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $v = & $Exe -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return [version]([string]$v).Trim() }
    } catch { } finally { $ErrorActionPreference = $prev }
    return $null
}

# インストール済みの Python を探す (Program Files・C:\Python3*・レジストリ・py ランチャー・PATH)
# Shared: サーバー実行用アカウントからも使える場所か (ユーザー個人のフォルダや Microsoft Store 版は不可)
function Find-PythonCandidates {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:SystemDrive\")) {
        if (-not $dir) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue)) {
            $paths.Add((Join-Path $d.FullName 'python.exe'))
        }
    }
    foreach ($key in @('HKLM:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore', 'HKCU:\SOFTWARE\Python\PythonCore')) {
        foreach ($k in @(Get-ChildItem -Path $key -ErrorAction SilentlyContinue)) {
            $ip = Get-ItemProperty -Path (Join-Path $k.PSPath 'InstallPath') -ErrorAction SilentlyContinue
            if ($ip -and $ip.ExecutablePath) { $paths.Add([string]$ip.ExecutablePath) }
            elseif ($ip -and $ip.'(default)') { $paths.Add((Join-Path ([string]$ip.'(default)') 'python.exe')) }
        }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (Get-Command py.exe -ErrorAction SilentlyContinue) {
            foreach ($line in @(& py.exe -0p 2>$null)) {
                if ($line -match '([A-Za-z]:\\.*python\.exe)\s*$') { $paths.Add($Matches[1]) }
            }
        }
        foreach ($line in @(& where.exe python 2>$null)) { if ($line) { $paths.Add([string]$line) } }
    } finally { $ErrorActionPreference = $prev }

    $result = @()
    $seen = @{}
    foreach ($path in $paths) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $full = [System.IO.Path]::GetFullPath($path)
        if ($seen.ContainsKey($full.ToLowerInvariant())) { continue }
        $seen[$full.ToLowerInvariant()] = $true
        $store = $full -match '\\WindowsApps\\'
        $personal = $full.StartsWith((Join-Path $env:SystemDrive 'Users') + '\', [StringComparison]::OrdinalIgnoreCase)
        $result += [pscustomobject]@{
            Path    = $full
            Version = if ($store) { $null } else { Get-PythonVersion $full }
            Shared  = -not ($store -or $personal)
            Note    = if ($store) { 'Microsoft Store の入口 (実体ではない)' } elseif ($personal) { 'ユーザー個人のフォルダにあるため、サーバー実行用アカウントから使えません' } else { '' }
        }
    }
    return $result
}

# 使う Python を決める。設定ファイルの python が最優先。なければインストール済みのものから、
# 全ユーザー向け・3.9 以上で一番新しいものを選ぶ。-Report で見つかったものを表示する
function Find-BasePython($Config, [switch]$Report) {
    $p = [string](Get-Value $Config.defaults 'python' '')
    if ($p) {
        if (Test-Path -LiteralPath $p) { return $p }
        throw "設定ファイルの python ($p) が見つかりません。"
    }
    $cands = @(Find-PythonCandidates)
    if ($Report) {
        if ($cands.Count -eq 0) { Write-Info 'インストール済みの Python は見つかりませんでした。' }
        foreach ($c in $cands) {
            $ver = if ($c.Version) { $c.Version } else { '?' }
            $note = if ($c.Note) { " … $($c.Note)" } elseif ($c.Version -and $c.Version -lt [version]'3.9') { ' … バージョンが古いため使いません (3.9 以上が必要)' } else { '' }
            Write-Info "見つかった Python: $($c.Path) ($ver)$note"
        }
    }
    $usable = @($cands | Where-Object { $_.Shared -and $_.Version -and $_.Version -ge [version]'3.9' } |
        Sort-Object -Property Version -Descending)
    if ($usable.Count -gt 0) { return $usable[0].Path }
    return $null
}

# インストールされていないパッケージ名を返す (pip を実行する前の確認用)
function Get-MissingPackages([string]$Python, [string[]]$Packages) {
    $names = @($Packages | Where-Object { $_ } | ForEach-Object { ($_ -replace '[<>=!~\[; ].*$', '') })
    if ($names.Count -eq 0) { return @() }
    $code = "import sys; from importlib import metadata as m; " +
            "n = {(d.metadata['Name'] or '').lower().replace('_', '-') for d in m.distributions()}; " +
            "print(' '.join(p for p in sys.argv[1:] if p.lower().replace('_', '-') not in n))"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Python -c $code @names 2>$null
        if ($LASTEXITCODE -ne 0) { return $Packages }
    } catch {
        return $Packages   # Python を実行できない: すべて未インストールとして扱う
    } finally { $ErrorActionPreference = $prev }
    $missing = @("$out".Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    # 元の指定 (バージョン指定付きなど) で返す
    return @($Packages | Where-Object { $missing -contains ($_ -replace '[<>=!~\[; ].*$', '') })
}

# ---- アカウント・権限 ----

function Get-LocalGroupSid {
    return (Get-LocalGroup -Name $script:LocalGroup).SID.Value
}

function Get-CurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Add-AccountRight([string]$Sid, [string]$Right, [switch]$LoadOnly) {
    # setup-server.ps1 から jfs.ps1 を同じプロセスで呼ぶため、型が既に読み込まれていれば再定義しない
    if (-not ('JfsLsa2' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class JfsLsa2 {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }

    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES {
        public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
        public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll")]
    static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")]
    static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")]
    static extern uint LsaRemoveAccountRights(IntPtr handle, byte[] sid, bool allRights, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")]
    static extern int LsaNtStatusToWinError(uint status);

    public static void AddRight(string sidString, string right) {
        SecurityIdentifier sid = new SecurityIdentifier(sidString);
        byte[] sidBytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(sidBytes, 0);

        LSA_OBJECT_ATTRIBUTES attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr handle;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x00000811, out handle);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        try {
            LSA_UNICODE_STRING[] rights = new LSA_UNICODE_STRING[1];
            rights[0].Buffer = Marshal.StringToHGlobalUni(right);
            rights[0].Length = (ushort)(right.Length * 2);
            rights[0].MaximumLength = (ushort)((right.Length + 1) * 2);
            try {
                status = LsaAddAccountRights(handle, sidBytes, rights, 1);
                if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
            } finally {
                Marshal.FreeHGlobal(rights[0].Buffer);
            }
        } finally {
            LsaClose(handle);
        }
    }

    // アカウント (グループ) に割り当てたすべての権利を外す (アンインストール用)
    public static void RemoveAllRights(string sidString) {
        SecurityIdentifier sid = new SecurityIdentifier(sidString);
        byte[] sidBytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(sidBytes, 0);
        LSA_OBJECT_ATTRIBUTES attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr handle;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x00000811, out handle);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        try {
            status = LsaRemoveAccountRights(handle, sidBytes, true, null, 0);
            // STATUS_OBJECT_NAME_NOT_FOUND (権利が何もない) は問題なし
            if (status != 0 && status != 0xC0000034) throw new Win32Exception(LsaNtStatusToWinError(status));
        } finally {
            LsaClose(handle);
        }
    }
}
'@
    }
    if (-not $LoadOnly) { [JfsLsa2]::AddRight($Sid, $Right) }
}

function Remove-AllAccountRights([string]$Sid) {
    Add-AccountRight -LoadOnly
    [JfsLsa2]::RemoveAllRights($Sid)
}

# jupyter-for-share のバージョン (git のコミット)。setup で git pull に失敗して古いままになっていないかの確認用
function Get-JfsVersion {
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) { $git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe' }
    if (Test-Path -LiteralPath $git) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $v = & $git -c safe.directory=* -C $script:RepoRoot log -1 '--format=%h %cd' '--date=format:%Y-%m-%d %H:%M' 2>$null
            if ($LASTEXITCODE -eq 0 -and $v) { return [string]$v }
        } finally { $ErrorActionPreference = $prev }
    }
    return '不明 (git の情報を取得できません)'
}

# サーバー用ユーザーをまとめるグループを作り、ログオン権限を設定する
#   - タスクスケジューラから起動するため「バッチ ジョブとしてログオン」を許可
#   - 画面・リモートデスクトップ・ネットワーク経由のログオンは拒否
function Initialize-LocalGroup {
    if (-not (Get-LocalGroup -Name $script:LocalGroup -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $script:LocalGroup -Description 'jupyter-for-share のサーバー実行用アカウント' | Out-Null
        Write-Ok "ローカルグループ '$script:LocalGroup' を作成しました。"
    }
    $sid = Get-LocalGroupSid
    foreach ($r in @('SeBatchLogonRight', 'SeDenyInteractiveLogonRight',
                     'SeDenyRemoteInteractiveLogonRight', 'SeDenyNetworkLogonRight')) {
        Add-AccountRight $sid $r
    }
}

# Python/Jupyter が全ユーザー共通で読む設定フォルダ (C:\ProgramData\jupyter) を
# 管理者以外が書き換えられないようにする (他のサーバーの設定に影響させないため)
function Protect-ProgramDataJupyter {
    $dir = Join-Path $env:ProgramData 'jupyter'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Invoke-Native 'icacls.exe' @($dir, '/inheritance:r', '/grant:r',
        "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidAdmins):(OI)(CI)F", "*$($script:SidUsers):(OI)(CI)RX", '/Q') -Quiet
}

# リポジトリのフォルダ: 管理者だけが読み書きできるようにする。
# (スクリプトは管理者権限で実行され、servers.json にはトークンがあるため、サーバー用ユーザーに触らせない)
# サーバー用ユーザーは user / monitor フォルダへたどり着くために、このフォルダ自体の参照だけ許可する。
function Protect-RepoFolder {
    # 設定済みなら何もしない (付け直すとリポジトリ内の全ファイルを書き換えるため)
    $acl = Get-Acl -LiteralPath $script:RepoRoot
    $groupSid = Get-LocalGroupSid
    $hasGroup = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
        Where-Object { $_.IdentityReference.Value -eq $groupSid }).Count -gt 0
    if ($acl.AreAccessRulesProtected -and $hasGroup) { return }
    Invoke-Native 'icacls.exe' @($script:RepoRoot, '/inheritance:r', '/grant:r',
        "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidAdmins):(OI)(CI)F",
        "*$(Get-CurrentUserSid):(OI)(CI)F", "*$(Get-LocalGroupSid):(RX)", '/Q') -Quiet
}

# アクセス権 (ACL) を設定できるファイルシステムか確認する (FAT32 / exFAT の USB ドライブなどは不可)
function Assert-AclFileSystem([string]$Path) {
    $letter = ([System.IO.Path]::GetPathRoot($Path)).TrimEnd('\').TrimEnd(':')
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($vol -and $vol.FileSystemType -notin @('NTFS', 'ReFS')) {
        throw ("$($letter): ドライブのファイルシステムは $($vol.FileSystemType) のため、ユーザーごとのアクセス制限を設定できません。" +
               'jupyter-for-share は NTFS のドライブ (C: など) に置いてください。')
    }
}

# リポジトリの上の階層 (E:\jupyter-for-share なら E:\) を、サーバー実行用アカウントが参照できるようにする。
# Python などはパスの途中のフォルダ (ドライブ直下を含む) の情報を読むため、ここが読めないと PermissionError になる。
# このフォルダ自体だけへの許可 (下のフォルダには引き継がない) なので、他のフォルダの中身は見えない。
function Grant-AncestorAccess {
    $sid = Get-LocalGroupSid
    $dir = Split-Path -Parent $script:RepoRoot.TrimEnd('\')
    while ($dir) {
        $acl = Get-Acl -LiteralPath $dir
        $has = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' }).Count -gt 0
        if (-not $has) {
            Invoke-Native 'icacls.exe' @((Format-IcaclsPath $dir), '/grant', "*$($sid):(RX)", '/Q') -Quiet
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
}

# icacls に渡すパス: "E:\" のようにドライブ直下は末尾の \ を外す (E: だとカレントディレクトリの意味になるので E:\. にする)
function Format-IcaclsPath([string]$Path) {
    if ($Path -match '^[A-Za-z]:\\?$') { return ($Path.Substring(0, 2) + '\.') }
    return $Path
}

# ユーザー環境の親フォルダ: 管理者だけがフル権限。サーバー用ユーザーはこのフォルダ自体の参照のみ
function Initialize-InstancesRoot($Config) {
    Assert-AclFileSystem $script:RepoRoot
    Protect-RepoFolder
    Grant-AncestorAccess
    $root = Get-InstancesRoot $Config
    if ($root.Length -le 3) { throw "instancesRoot にドライブ直下 ($root) は指定できません。" }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    Invoke-Native 'icacls.exe' @($root, '/inheritance:r', '/grant:r',
        "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidAdmins):(OI)(CI)F",
        "*$(Get-CurrentUserSid):(OI)(CI)F", "*$(Get-LocalGroupSid):(RX)", '/Q') -Quiet
    return $root
}

# ---- その他 ----

function New-Token {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

# サーバー用ユーザーのパスワード (タスク登録時にだけ使い、保存しない)
function New-RandomPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#$%*+-=?@_'
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    # 複雑さの要件を必ず満たすよう各文字種を 1 文字ずつ足す
    return "$pw" + 'Aa1!'
}
