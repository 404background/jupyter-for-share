#Requires -Version 5.1
<#
.SYNOPSIS
    (接続する側の PC 用) サーバーのドメイン名を hosts ファイルに登録します。
.DESCRIPTION
    ルーターや社内 DNS にドメイン名を登録できない場合に使います。管理者権限が必要です。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File client-add-hosts.ps1 -Domain jupyter.home.arpa -ServerIp 192.168.1.10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Domain,
    [Parameter(Mandatory = $true)][string]$ServerIp,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"",
                 '-Domain', $Domain, '-ServerIp', $ServerIp)
    if ($Remove) { $argList += '-Remove' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit 0
}

$ip = $null
if (-not [System.Net.IPAddress]::TryParse($ServerIp, [ref]$ip)) { throw "IP アドレスが不正です: $ServerIp" }
if ($Domain -notmatch '^[A-Za-z0-9.-]+$') { throw "ドメイン名が不正です: $Domain" }

$hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$marker = '# jupyter-for-share'
$lines = @(Get-Content -LiteralPath $hosts -Encoding ASCII | Where-Object {
    -not ($_ -match $marker -and ($_ -split '\s+') -contains $Domain)
})
if (-not $Remove) { $lines += "$ServerIp`t$Domain`t$marker" }
Set-Content -LiteralPath $hosts -Value $lines -Encoding ASCII
& ipconfig.exe /flushdns | Out-Null

if ($Remove) { Write-Host "hosts から $Domain を削除しました。" -ForegroundColor Green }
else { Write-Host "hosts に登録しました: $Domain -> $ServerIp" -ForegroundColor Green }
