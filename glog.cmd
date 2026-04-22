@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%glog.ps1" %*
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%glog.ps1" %*
exit /b
