@echo off
setlocal
chcp 65001 >nul

rem 管理者権限チェック
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 管理者権限が必要です。UAC昇格を要求します...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set EXITCODE=%errorLevel%

echo.
echo (install.ps1 exit code: %EXITCODE%)
pause
exit /b %EXITCODE%
