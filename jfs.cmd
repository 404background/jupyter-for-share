@echo off
rem jupyter-for-share: environment management (see "jfs help")
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\jfs.ps1" %*
exit /b %ERRORLEVEL%
