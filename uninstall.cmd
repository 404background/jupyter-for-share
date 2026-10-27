@echo off
rem jupyter-for-share: undo everything this tool changed in Windows (requests administrator rights).
rem Stops the servers, removes scheduled tasks, firewall rules, accounts, the group and folder permissions.
rem Afterwards this folder can be deleted. Add -DeleteFiles to also delete the user folders.
rem Everything is inside one ( ) block so that changes to this file while it runs cannot break it.
(
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\jfs.ps1" uninstall %*
  exit /b
)
