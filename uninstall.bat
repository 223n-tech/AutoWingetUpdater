@echo off
setlocal
chcp 65001 >nul

rem UTF-8ドキュメント

rem 管理者権限チェック
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 管理者権限が必要です。UAC昇格を要求します...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
set EXITCODE=%errorLevel%

echo.
echo (uninstall.ps1 exit code: %EXITCODE%)
pause
exit /b %EXITCODE%
