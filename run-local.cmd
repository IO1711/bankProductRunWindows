@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-local.ps1"
if errorlevel 1 (
  echo.
  echo Startup failed. Read the error above, then press any key to close.
  pause >nul
  exit /b 1
)
