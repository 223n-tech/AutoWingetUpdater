# UTF-8 BOM付きドキュメント
# WingetAutoUpgrade アンインストーラー
# スケジュールタスク、インストールフォルダ、イベントソースを削除する。

$ErrorActionPreference = 'Continue'

$TaskName = 'WingetAutoUpgradeAtLogon'
$InstallDir = 'C:\ProgramData\WingetAutoUpgrade'
$EventSrc = 'WingetAutoUpgrade'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '管理者権限が必要です。uninstall.bat 経由で起動するか、PowerShell を管理者として実行してください。' -ForegroundColor Red
    exit 1
}

$hadError = $false

# スケジュールタスク削除
Write-Host "[1/3] スケジュールタスク削除: $TaskName"
$exists = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($exists) {
    $result = & schtasks /Delete /TN $TaskName /F 2>&1
    Write-Host $result
    if ($LASTEXITCODE -ne 0) { $hadError = $true }
}
else {
    Write-Host "  (存在しないためスキップ)" -ForegroundColor DarkGray
}

# インストールフォルダ削除
Write-Host ""
Write-Host "[2/3] フォルダ削除: $InstallDir"
if (Test-Path $InstallDir) {
    try {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop
        Write-Host "  削除完了"
    }
    catch {
        Write-Host "  削除失敗: $($_.Exception.Message)" -ForegroundColor Red
        $hadError = $true
    }
}
else {
    Write-Host "  (存在しないためスキップ)" -ForegroundColor DarkGray
}

# イベントソース削除
Write-Host ""
Write-Host "[3/3] イベントソース削除: $EventSrc"
try {
    if ([System.Diagnostics.EventLog]::SourceExists($EventSrc)) {
        Remove-EventLog -Source $EventSrc -ErrorAction Stop
        Write-Host "  削除完了"
    }
    else {
        Write-Host "  (未登録のためスキップ)" -ForegroundColor DarkGray
    }
}
catch {
    Write-Host "  削除失敗: $($_.Exception.Message)" -ForegroundColor Yellow
    # イベントソースの削除失敗は致命的ではない
}

Write-Host ""
if ($hadError) {
    Write-Host "アンインストールに一部失敗があります。上記出力を確認してください。" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "アンインストール完了。" -ForegroundColor Green
}
