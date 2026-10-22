@echo off
rem jupyter-for-share: environment management. Run "jfs.cmd help" for usage.
setlocal
set "JFS_ARG1=%~1"
if "%JFS_ARG1%"=="" goto help
if /i "%JFS_ARG1%"=="-h" goto help
if /i "%JFS_ARG1%"=="-help" goto help
if /i "%JFS_ARG1%"=="--help" goto help
if /i "%JFS_ARG1%"=="/h" goto help
if "%JFS_ARG1%"=="/?" goto help
if "%JFS_ARG1%"=="-?" goto help
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\jfs.ps1" %*
exit /b %ERRORLEVEL%

:help
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\jfs.ps1" help %2
exit /b 0
