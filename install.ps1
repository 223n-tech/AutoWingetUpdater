# UTF-8 BOM付きドキュメント
# WingetAutoUpgrade インストーラー
# ログオン2分後に winget upgrade --all をループ実行するスケジュールタスクを登録する。

$ErrorActionPreference = 'Stop'

$AppName = 'WingetAutoUpgrade'
$TaskName = 'WingetAutoUpgradeAtLogon'
$InstallDir = 'C:\ProgramData\WingetAutoUpgrade'
$ScriptSrc = Join-Path $PSScriptRoot 'payload\Invoke-WingetUpgrade.ps1'
$XmlSrc = Join-Path $PSScriptRoot 'payload\Task.xml.template'
$ManSrc = Join-Path $PSScriptRoot 'payload\AutoWingetUpdater.man'
$VersionFile = Join-Path $PSScriptRoot 'VERSION'
$ScriptDst = Join-Path $InstallDir 'Invoke-WingetUpgrade.ps1'
$XmlDst = Join-Path $InstallDir 'Task.xml'
$ManDst = Join-Path $InstallDir 'AutoWingetUpdater.man'
$DllDst = Join-Path $InstallDir 'AutoWingetUpdater.dll'
$ChannelName = '223n.tech/AutoWingetUpdater'

# VERSION ファイルからバージョンを取得 (BOMなし UTF-8 想定、空白・改行を除去)
if (Test-Path $VersionFile) {
    $ScriptVersion = ([System.IO.File]::ReadAllText($VersionFile, [System.Text.UTF8Encoding]::new($false))).Trim()
} else {
    $ScriptVersion = '0.0.0-dev'
}

Write-Host ""
Write-Host "===== $AppName Installer v$ScriptVersion =====" -ForegroundColor Cyan

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host '管理者権限が必要です。install.bat 経由で起動するか、PowerShell を管理者として実行してください。' -ForegroundColor Red
    exit 1
}

# ペイロード存在確認
foreach ($p in @($ScriptSrc, $XmlSrc, $ManSrc)) {
    if (-not (Test-Path $p)) {
        Write-Host "ペイロードが見つかりません: $p" -ForegroundColor Red
        exit 1
    }
}

# 実行ユーザー (タスクトリガー対象) を決定
$userId = "$env:USERDOMAIN\$env:USERNAME"
Write-Host "タスク登録対象ユーザー: $userId" -ForegroundColor Cyan

# 実行に使う PowerShell を決定
# 優先度: PATH 上の pwsh.exe → 既定インストール先 → powershell.exe (Windows PowerShell 5.1)
function Resolve-PowerShellPath {
    $fromPath = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($fromPath -and $fromPath.Source) {
        return $fromPath.Source
    }
    $defaultPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    if (Test-Path $defaultPwsh) {
        return $defaultPwsh
    }
    return 'powershell.exe'
}

$powershellPath = Resolve-PowerShellPath
if ($powershellPath -eq 'powershell.exe') {
    Write-Host "使用するPowerShell: Windows PowerShell 5.1 ($powershellPath)" -ForegroundColor Cyan
} else {
    Write-Host "使用するPowerShell: PowerShell 7 ($powershellPath)" -ForegroundColor Cyan
}

# インストール先フォルダ作成
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    Write-Host "作成: $InstallDir"
}
else {
    Write-Host "既存: $InstallDir"
}

# スクリプト本体を UTF-8 BOM で配置 ($ScriptVersion 行を VERSION の値で置換)
$scriptContent = [System.IO.File]::ReadAllText($ScriptSrc, [System.Text.UTF8Encoding]::new($false))
$scriptContent = [regex]::Replace(
    $scriptContent,
    "(?m)^(\`$ScriptVersion\s*=\s*)'[^']*'",
    { param($m) "$($m.Groups[1].Value)'$ScriptVersion'" }
)
[System.IO.File]::WriteAllText($ScriptDst, $scriptContent, [System.Text.UTF8Encoding]::new($true))
Write-Host "配置: $ScriptDst (UTF-8 BOM, version=$ScriptVersion)"

# XML を UTF-16 LE BOM で配置 (UserId と PowerShell パスを差し替え)
$xmlTemplate = [System.IO.File]::ReadAllText($XmlSrc, [System.Text.UTF8Encoding]::new($false))
$xmlContent = $xmlTemplate -replace '\{\{USER_ID\}\}', ([System.Security.SecurityElement]::Escape($userId))
$xmlContent = $xmlContent -replace '\{\{POWERSHELL_PATH\}\}', ([System.Security.SecurityElement]::Escape($powershellPath))
[System.IO.File]::WriteAllText($XmlDst, $xmlContent, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host "配置: $XmlDst (UTF-16 LE BOM)"

# ETW マニフェスト登録 (アプリケーションとサービス ログ > 223n.tech > AutoWingetUpdater)
# resourceFileName の実在チェックを満たすためにリソース dll を Add-Type で動的生成する。
# メッセージリソースは持たず、書き込み時の Payload に本文を渡す方式とする (mc.exe 不要)。
Write-Host ""
Write-Host "ETW マニフェスト登録: $ChannelName"

# 既存登録があれば一旦解除 (dll のロックを外し、再登録できるようにする)
if (Test-Path $ManDst) {
    $null = & wevtutil um $ManDst 2>&1
}

# リソース dll を生成 (空の型を 1 つ含むだけのバイナリで十分)
$csCode = 'namespace AutoWingetUpdater { internal class Resource { } }'
$tempDll = [System.IO.Path]::Combine($env:TEMP, "AutoWingetUpdater_$([guid]::NewGuid().ToString('N')).dll")
try {
    Add-Type -TypeDefinition $csCode -OutputAssembly $tempDll -ErrorAction Stop
} catch {
    Write-Host "リソース dll の生成に失敗: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Copy-Item -Path $tempDll -Destination $DllDst -Force
Remove-Item -Path $tempDll -Force -ErrorAction SilentlyContinue
Write-Host "配置: $DllDst"

# マニフェストを BOM なし UTF-8 で配置 ({{RESOURCE_PATH}} を実 dll パスに置換)
$manTemplate = [System.IO.File]::ReadAllText($ManSrc, [System.Text.UTF8Encoding]::new($false))
$manContent = $manTemplate -replace '\{\{RESOURCE_PATH\}\}', ([System.Security.SecurityElement]::Escape($DllDst))
[System.IO.File]::WriteAllText($ManDst, $manContent, [System.Text.UTF8Encoding]::new($false))
Write-Host "配置: $ManDst"

# wevtutil im で登録
$wevtResult = & wevtutil im $ManDst 2>&1
$wevtCode = $LASTEXITCODE
if ($wevtResult) { Write-Host $wevtResult }
if ($wevtCode -ne 0) {
    Write-Host "wevtutil im が失敗しました (exit=$wevtCode)" -ForegroundColor Red
    exit $wevtCode
}
Write-Host "登録完了: '$ChannelName' (provider=223n.tech-AutoWingetUpdater)"

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
Write-Host "ログ確認         : Get-WinEvent -LogName '$ChannelName' -MaxEvents 5"
