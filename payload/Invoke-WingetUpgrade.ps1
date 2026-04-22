$ErrorActionPreference = 'Continue'
$source = 'WingetAutoUpgrade'
$MaxIterations = 3
$SettleSeconds = 5

# winget の stdout は UTF-8。既定の cp932 コンソールでは取り込み時に mojibake になり、
# 残数抽出の正規表現がマッチしなくなるためコンソールを UTF-8 に統一する。
$null = chcp 65001
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

# New-EventLog / Write-EventLog は PowerShell 7 に存在しないため、
# Windows PowerShell 5.1 / PowerShell 7 の両対応として .NET API を直接利用する。
if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
    try {
        [System.Diagnostics.EventLog]::CreateEventSource($source, 'Application')
    } catch {
        Write-Host "イベントソース登録に失敗しました: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-AppEventLog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Information','Warning','Error')] [string] $EntryType = 'Information',
        [int] $EventId = 1000
    )
    try {
        $msg = if ($Message.Length -gt 30000) { $Message.Substring(0, 30000) + "`n...(truncated)" } else { $Message }
        $entryTypeEnum = [System.Diagnostics.EventLogEntryType]::$EntryType
        [System.Diagnostics.EventLog]::WriteEntry($source, $msg, $entryTypeEnum, $EventId)
    } catch {
        Write-Host "イベントログ書き込みに失敗: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-UpgradableCount {
    param([Parameter(Mandatory)] [string] $WingetPath)
    $output = & $WingetPath upgrade --include-unknown 2>&1 | Out-String
    if ($output -match '(\d+)\s*(?:アップグレード|upgrades?\s+available)') {
        return [int]$matches[1]
    }
    return 0
}

$wingetPath = (Get-Command winget -ErrorAction SilentlyContinue).Source
if (-not $wingetPath) {
    Write-Host 'winget が見つかりません。' -ForegroundColor Red
    Write-AppEventLog -Message 'winget not found in PATH.' -EntryType 'Error' -EventId 9000
    Start-Sleep -Seconds 10
    exit 1
}

Write-Host "[$(Get-Date -Format o)] winget upgrade --all をループ実行 (最大 $MaxIterations 回)" -ForegroundColor Cyan
Write-Host "winget: $wingetPath" -ForegroundColor DarkGray

$initialCount = Get-UpgradableCount -WingetPath $wingetPath
Write-Host "初期アップグレード可能数: $initialCount" -ForegroundColor DarkGray

$iterationLog = New-Object System.Collections.Generic.List[string]
$iterationLog.Add("Initial upgradable count: $initialCount")

$lastCode = 0
$prevCount = [int]::MaxValue
$stopReason = ''

for ($i = 1; $i -le $MaxIterations; $i++) {
    Write-Host ""
    Write-Host "===== Iteration $i / $MaxIterations =====" -ForegroundColor Cyan

    & $wingetPath upgrade --all --silent --accept-source-agreements --accept-package-agreements --include-unknown --disable-interactivity 2>&1 |
        Tee-Object -Variable iterOutput
    $lastCode = $LASTEXITCODE

    Start-Sleep -Seconds $SettleSeconds
    $currentCount = Get-UpgradableCount -WingetPath $wingetPath

    Write-Host ""
    Write-Host "Iteration $i 終了。残り: $currentCount (前回: $prevCount, 終了コード: $lastCode)" -ForegroundColor DarkGray
    $iterationLog.Add("Iter ${i}: exitCode=$lastCode, remaining=$currentCount, prev=$prevCount")

    if ($currentCount -eq 0) {
        $stopReason = 'all upgraded'
        break
    }
    if ($currentCount -ge $prevCount) {
        $stopReason = "no progress (still $currentCount remaining)"
        break
    }
    $prevCount = $currentCount
}

if (-not $stopReason) { $stopReason = "max iterations ($MaxIterations) reached" }

$finalCount = Get-UpgradableCount -WingetPath $wingetPath
$summary = @"
winget loop finished.
Stop reason : $stopReason
Final code  : $lastCode
Initial #   : $initialCount
Final #     : $finalCount

--- iteration log ---
$($iterationLog -join "`n")
"@

$entryType = if ($lastCode -eq 0 -and $finalCount -eq 0) { 'Information' } else { 'Warning' }
$eventId   = if ($lastCode -eq 0 -and $finalCount -eq 0) { 1000 } else { 2000 }
Write-AppEventLog -Message $summary -EntryType $entryType -EventId $eventId

Write-Host ""
$resultColor = if ($finalCount -eq 0) { 'Green' } else { 'Yellow' }
Write-Host "[$(Get-Date -Format o)] 終了 (理由: $stopReason / 残り: $finalCount / 終了コード: $lastCode)" -ForegroundColor $resultColor
Write-Host "30秒後に自動で閉じます (キー入力で即時クローズ)..." -ForegroundColor DarkGray

$end = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $end -and -not [Console]::KeyAvailable) {
    Start-Sleep -Milliseconds 200
}
if ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }

exit $lastCode
