@echo off
rem jupyter-for-share: server setup (requests administrator rights)
rem Everything is inside one ( ) block: cmd.exe reads the whole block before running it,
rem so "git pull" can safely update this file while it is running.
(
  if exist "%~dp0.git" (
    where git >nul 2>&1 && (
      echo [*] Updating jupyter-for-share: git pull
      git -C "%~dp0." pull --ff-only || echo [!] git pull failed. Continuing with the current files.
    )
  )
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-server.ps1" %*
  exit /b
)
