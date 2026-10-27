@echo off
rem jupyter-for-share: environment management. Run "jfs.cmd help" for usage.
rem Everything is inside one ( ) block: cmd.exe reads the whole block before running it,
rem so the server window's automatic "git pull" can update this file while it is running.
setlocal
set "JFS_HELP="
(
  if "%~1"=="" set "JFS_HELP=1"
  if /i "%~1"=="-h" set "JFS_HELP=1"
  if /i "%~1"=="-help" set "JFS_HELP=1"
  if /i "%~1"=="--help" set "JFS_HELP=1"
  if /i "%~1"=="/h" set "JFS_HELP=1"
  if "%~1"=="/?" set "JFS_HELP=1"
  if "%~1"=="-?" set "JFS_HELP=1"
  if defined JFS_HELP (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\jfs.ps1" help %2
  ) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\jfs.ps1" %*
  )
  exit /b
)
