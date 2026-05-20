# UTF-8 BOM付きドキュメント
# WingetAutoUpgrade アンインストーラー
# スケジュールタスク、インストールフォルダ、イベントソースを削除する。

$ErrorActionPreference = 'Continue'

$AppName = 'WingetAutoUpgrade'
$TaskName = 'WingetAutoUpgradeAtLogon'
$InstallDir = 'C:\ProgramData\WingetAutoUpgrade'
$EventSrc = 'WingetAutoUpgrade'   # 旧 Application ログ用のソース名 (互換削除用)
$ManDst = Join-Path $InstallDir 'AutoWingetUpdater.man'
$ChannelName = '223n.tech/AutoWingetUpdater'
$VersionFile = Join-Path $PSScriptRoot 'VERSION'

# VERSION ファイルからバージョンを取得 (リポジトリ側の VERSION を参照)
if (Test-Path $VersionFile) {
    $ScriptVersion = ([System.IO.File]::ReadAllText($VersionFile, [System.Text.UTF8Encoding]::new($false))).Trim()
} else {
    $ScriptVersion = '0.0.0-dev'
}

Write-Host ""
Write-Host "===== $AppName Uninstaller v$ScriptVersion =====" -ForegroundColor Cyan

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
Write-Host "[1/4] スケジュールタスク削除: $TaskName"
$exists = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($exists) {
    $result = & schtasks /Delete /TN $TaskName /F 2>&1
    Write-Host $result
    if ($LASTEXITCODE -ne 0) { $hadError = $true }
}
else {
    Write-Host "  (存在しないためスキップ)" -ForegroundColor DarkGray
}

# ETW マニフェスト登録解除 (フォルダ削除前に行う。um 後は dll/man の参照が外れる)
Write-Host ""
Write-Host "[2/4] ETW マニフェスト解除: $ChannelName"
if (Test-Path $ManDst) {
    $result = & wevtutil um $ManDst 2>&1
    if ($result) { Write-Host $result }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  解除失敗 (exit=$LASTEXITCODE)" -ForegroundColor Yellow
        # 致命的とはしない: フォルダ削除に進む
    }
    else {
        Write-Host "  解除完了"
    }
}
else {
    Write-Host "  (マニフェスト未配置のためスキップ)" -ForegroundColor DarkGray
}

# インストールフォルダ削除
Write-Host ""
Write-Host "[3/4] フォルダ削除: $InstallDir"
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

# 旧 Application ログのイベントソース削除 (旧バージョンからのアップグレード時の互換用)
Write-Host ""
Write-Host "[4/4] 旧イベントソース削除: $EventSrc (Application ログ)"
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
