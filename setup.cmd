@echo off
rem jupyter-for-share: server setup (requests administrator rights)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-server.ps1" %*
