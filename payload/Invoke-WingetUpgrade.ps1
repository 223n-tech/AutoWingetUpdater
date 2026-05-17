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

# winget の進捗スピナー(- \ | /)やプログレスバーは \r で同じ行を上書きするが、
# パイプ経由ではティックごとに 1 行ずつ吐き出され大量改行になる。
# 表示行から ANSI / 上書き分 / 進捗ノイズだけの行を除去する保険のフィルタ。
# winget の出力仕様が変わった場合はここの正規表現を見直すこと。
function Format-WingetLine {
    param([Parameter(ValueFromPipeline = $true)] $InputObject)
    process {
        $esc  = [char]27
        $line = [string]$InputObject

        # VT 出力時の ANSI エスケープシーケンス(CSI / OSC)を除去
        $line = $line -replace "$esc\[[0-9;?]*[ -/]*[@-~]", ''
        $line = $line -replace "$esc\][^$esc`a]*(`a|$esc\\)", ''

        # \r による行内上書き(スピナー描画)は最終状態のみ採用
        $line = $line -split "`r" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1
        if ($null -eq $line) { return }

        $trimmed = $line.Trim()
        if ($trimmed -eq '') { return }
        if ($trimmed -match '^[-\\|/]+$') { return }   # スピナーのみ

        # 罫線/ブロック文字(U+2500-U+259F)と空白・% だけの行 = プログレスバー。
        # 日本語等(U+3000-U+9FFF)の文字を含む行は実出力なので残す。
        # ソースを ASCII のみに保つため範囲文字は [char] で組み立てる。
        $boxLo = [char]0x2500; $boxHi = [char]0x259F
        $txtLo = [char]0x3000; $txtHi = [char]0x9FFF
        if ($trimmed -notmatch "[A-Za-z$txtLo-$txtHi]" -and
            $trimmed -match "^[$boxLo-$boxHi\s]*\d{0,3}%?$") { return }

        # ダウンロード進捗 (12.3 MB / 45.6 MB ...)
        if ($trimmed -match '^[\d.,]+\s*[KMGT]?i?B\s*/\s*[\d.,]+\s*[KMGT]?i?B') { return }

        $line
    }
}

# winget 本体の進捗バーを無効化(visual.progressBar=disabled)し、ノイズを根本から減らす。
# settings.json は JSONC(// , /* */)のことがあるため文字列を保持したままコメント除去して解析する。
# ユーザー設定を壊さない方針: 解析できない場合は書き換えず警告のみで続行する。
# 注: アンインストールではこの設定を元に戻さない(README の既知の制約に記載)。
function Disable-WingetProgressBar {
    try {
        $settingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
        $dir = Split-Path $settingsPath -Parent

        $raw = ''
        if (Test-Path -LiteralPath $settingsPath) {
            $raw = [System.IO.File]::ReadAllText($settingsPath)
        }

        # 文字列リテラルは保持し、// 行コメントと /* */ ブロックコメントのみ除去
        $clean = [regex]::Replace(
            $raw,
            '("(?:[^"\\]|\\.)*")|/\*[\s\S]*?\*/|//[^\r\n]*',
            { param($m) if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' } }
        )
        if ([string]::IsNullOrWhiteSpace($clean)) { $clean = '{}' }

        $obj = $clean | ConvertFrom-Json
        if ($null -eq $obj) { $obj = [pscustomobject]@{} }

        $hasVisual = $obj.PSObject.Properties.Name -contains 'visual'
        if ($hasVisual -and ($obj.visual -isnot [pscustomobject])) {
            Write-Host 'winget settings の visual が想定形式でないため進捗バー設定の変更をスキップしました' -ForegroundColor Yellow
            return
        }

        $current = $null
        if ($hasVisual -and ($obj.visual.PSObject.Properties.Name -contains 'progressBar')) {
            $current = $obj.visual.progressBar
        }
        if ($current -eq 'disabled') { return }  # 既に無効。コメント保持のためファイルを書き換えない

        if (-not $hasVisual) {
            $obj | Add-Member -NotePropertyName 'visual' -NotePropertyValue ([pscustomobject]@{ progressBar = 'disabled' }) -Force
        } elseif ($obj.visual.PSObject.Properties.Name -notcontains 'progressBar') {
            $obj.visual | Add-Member -NotePropertyName 'progressBar' -NotePropertyValue 'disabled' -Force
        } else {
            $obj.visual.progressBar = 'disabled'
        }

        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $json = $obj | ConvertTo-Json -Depth 32
        [System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Host 'winget の進捗バーを無効化しました (visual.progressBar=disabled)' -ForegroundColor DarkGray
    } catch {
        Write-Host "winget 設定の更新をスキップしました: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$wingetPath = (Get-Command winget -ErrorAction SilentlyContinue).Source
if (-not $wingetPath) {
    Write-Host 'winget が見つかりません。' -ForegroundColor Red
    Write-AppEventLog -Message 'winget not found in PATH.' -EntryType 'Error' -EventId 9000
    Start-Sleep -Seconds 10
    exit 1
}

Disable-WingetProgressBar

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
        Format-WingetLine
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
