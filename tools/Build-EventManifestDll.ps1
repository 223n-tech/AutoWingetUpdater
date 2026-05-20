# ETW マニフェスト用リソース DLL ビルドスクリプト (開発用 / 必要時のみ実行)
#
# payload/AutoWingetUpdater.man をコンパイルし、WEVT_TEMPLATE リソースを含む
# payload/AutoWingetUpdater.dll を生成する。
# マニフェスト (プロバイダ定義・チャンネル・イベント ID) を変更したら再実行すること。
#
# 必要ツール:
#   - mc.exe / rc.exe : NuGet パッケージ Microsoft.Windows.SDK.BuildTools から取得する
#   - csc.exe         : .NET Framework 同梱 (C:\Windows\Microsoft.NET\Framework64\...)
#
# 生成された payload/AutoWingetUpdater.dll はリポジトリにコミットする想定。
# install.ps1 はこの DLL をインストール先へコピーするだけで、DLL の生成は行わない。

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ManSrc   = Join-Path $RepoRoot 'payload\AutoWingetUpdater.man'
$DllDst   = Join-Path $RepoRoot 'payload\AutoWingetUpdater.dll'

if (-not (Test-Path $ManSrc)) {
    Write-Host "マニフェストが見つかりません: $ManSrc" -ForegroundColor Red
    exit 1
}

$work = Join-Path $env:TEMP "awu-manbuild-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$pushed = $false

try {
    # --- 1. SDK BuildTools (mc.exe / rc.exe) を NuGet から取得 ---
    Write-Host '[1/5] Microsoft.Windows.SDK.BuildTools を取得中...'
    $nupkg = Join-Path $work 'sdk.zip'
    Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools' -OutFile $nupkg
    $sdk = Join-Path $work 'sdk'
    Expand-Archive -Path $nupkg -DestinationPath $sdk -Force

    $mc = Get-ChildItem -Path $sdk -Recurse -File -Filter 'mc.exe' |
        Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
    $rc = Get-ChildItem -Path $sdk -Recurse -File -Filter 'rc.exe' |
        Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
    if (-not $mc) {
        Write-Host 'mc.exe が NuGet パッケージ内に見つかりませんでした。' -ForegroundColor Red
        Write-Host 'この場合は Windows SDK 本体の手動インストールが必要です。' -ForegroundColor Yellow
        exit 1
    }
    if (-not $rc) {
        Write-Host 'rc.exe が NuGet パッケージ内に見つかりませんでした。' -ForegroundColor Red
        exit 1
    }
    Write-Host "  mc.exe: $($mc.FullName)"
    Write-Host "  rc.exe: $($rc.FullName)"

    # --- 2. csc.exe (.NET Framework) ---
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) {
        Write-Host "csc.exe が見つかりません: $csc" -ForegroundColor Red
        exit 1
    }

    # --- 3. mc.exe でマニフェストをコンパイル (.rc / .h / .bin を生成) ---
    Write-Host '[2/5] mc.exe でマニフェストをコンパイル...'
    Copy-Item -Path $ManSrc -Destination (Join-Path $work 'AutoWingetUpdater.man') -Force
    Push-Location $work
    $pushed = $true
    & $mc.FullName -um -z 'AutoWingetUpdater' 'AutoWingetUpdater.man'
    if ($LASTEXITCODE -ne 0) { throw "mc.exe が失敗しました (exit=$LASTEXITCODE)" }

    # --- 4. rc.exe で .rc -> .res ---
    Write-Host '[3/5] rc.exe でリソースをコンパイル...'
    if (-not (Test-Path (Join-Path $work 'AutoWingetUpdater.rc'))) {
        throw 'mc.exe が AutoWingetUpdater.rc を生成しませんでした'
    }
    & $rc.FullName '/nologo' '/fo' 'AutoWingetUpdater.res' 'AutoWingetUpdater.rc'
    if ($LASTEXITCODE -ne 0) { throw "rc.exe が失敗しました (exit=$LASTEXITCODE)" }

    # --- 5. csc.exe で .res を埋め込んだリソース専用 DLL を生成 ---
    Write-Host '[4/5] csc.exe でリソース DLL を生成...'
    Set-Content -Path (Join-Path $work 'res.cs') `
        -Value 'namespace AutoWingetUpdater { internal static class EventManifestResource { } }' `
        -Encoding ascii
    & $csc '/nologo' '/target:library' '/win32res:AutoWingetUpdater.res' '/out:AutoWingetUpdater.dll' 'res.cs'
    if ($LASTEXITCODE -ne 0) { throw "csc.exe が失敗しました (exit=$LASTEXITCODE)" }

    # --- 6. payload へ配置 ---
    Write-Host '[5/5] payload へ配置...'
    Copy-Item -Path (Join-Path $work 'AutoWingetUpdater.dll') -Destination $DllDst -Force
    Write-Host ''
    Write-Host "生成完了: $DllDst" -ForegroundColor Green
    Write-Host 'このあと install.bat を再実行すると、新しい DLL が配置されます。'
}
finally {
    if ($pushed) { Pop-Location }
    if (Test-Path $work) { Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue }
}
