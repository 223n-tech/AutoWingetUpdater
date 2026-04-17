# WingetAutoUpgrade インストーラー
# ログオン2分後に winget upgrade --all をループ実行するスケジュールタスクを登録する。

$ErrorActionPreference = 'Stop'

$TaskName   = 'WingetAutoUpgradeAtLogon'
$InstallDir = 'C:\ProgramData\WingetAutoUpgrade'
$ScriptSrc  = Join-Path $PSScriptRoot 'payload\Invoke-WingetUpgrade.ps1'
$XmlSrc     = Join-Path $PSScriptRoot 'payload\Task.xml.template'
$ScriptDst  = Join-Path $InstallDir 'Invoke-WingetUpgrade.ps1'
$XmlDst     = Join-Path $InstallDir 'Task.xml'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '管理者権限が必要です。install.bat 経由で起動するか、PowerShell を管理者として実行してください。' -ForegroundColor Red
    exit 1
}

# ペイロード存在確認
foreach ($p in @($ScriptSrc, $XmlSrc)) {
    if (-not (Test-Path $p)) {
        Write-Host "ペイロードが見つかりません: $p" -ForegroundColor Red
        exit 1
    }
}

# 実行ユーザー (タスクトリガー対象) を決定
$userId = "$env:USERDOMAIN\$env:USERNAME"
Write-Host "タスク登録対象ユーザー: $userId" -ForegroundColor Cyan

# インストール先フォルダ作成
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    Write-Host "作成: $InstallDir"
} else {
    Write-Host "既存: $InstallDir"
}

# スクリプト本体を UTF-8 BOM で配置
$scriptContent = [System.IO.File]::ReadAllText($ScriptSrc, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($ScriptDst, $scriptContent, [System.Text.UTF8Encoding]::new($true))
Write-Host "配置: $ScriptDst (UTF-8 BOM)"

# XML を UTF-16 LE BOM で配置 (UserId 差し替え)
$xmlTemplate = [System.IO.File]::ReadAllText($XmlSrc, [System.Text.UTF8Encoding]::new($false))
$xmlContent  = $xmlTemplate -replace '\{\{USER_ID\}\}', ([System.Security.SecurityElement]::Escape($userId))
[System.IO.File]::WriteAllText($XmlDst, $xmlContent, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host "配置: $XmlDst (UTF-16 LE BOM)"

# 既存タスクがあれば上書き
Write-Host ""
Write-Host "タスク登録: $TaskName"
$result = & schtasks /Create /TN $TaskName /XML $XmlDst /F 2>&1
$code = $LASTEXITCODE
Write-Host $result
if ($code -ne 0) {
    Write-Host "schtasks が失敗しました (exit=$code)" -ForegroundColor Red
    exit $code
}

# 登録内容確認
Write-Host ""
Write-Host "=== 登録内容 ===" -ForegroundColor Green
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ("TaskName       : {0}" -f $task.TaskName)
Write-Host ("State          : {0}" -f $task.State)
Write-Host ("Trigger UserId : {0}" -f $task.Triggers[0].UserId)
Write-Host ("Trigger Delay  : {0}" -f $task.Triggers[0].Delay)
Write-Host ("Run as         : {0} (RunLevel={1})" -f $task.Principal.UserId, $task.Principal.RunLevel)
Write-Host ("Action         : {0} {1}" -f $task.Actions[0].Execute, $task.Actions[0].Arguments)

Write-Host ""
Write-Host "インストール完了。" -ForegroundColor Green
Write-Host "手動実行 (テスト): schtasks /Run /TN $TaskName"
Write-Host "ログ確認         : Get-WinEvent -LogName Application -ProviderName WingetAutoUpgrade -MaxEvents 5"
