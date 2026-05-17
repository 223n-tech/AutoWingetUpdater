# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

Windowsにログオンしてから2分後に `winget upgrade --all` をループ実行するスケジュールタスクを登録するためのインストーラー群です。
ビルド／テスト／lintは存在しません。
PowerShellスクリプト + バッチラッパー + タスク定義XMLテンプレートで構成されています。

ユーザー向けの詳細（動作条件、カスタマイズ項目、イベントIDの意味、トラブルシューティング）は `README.md` に集約されています。
本ファイルではREADMEだけでは把握しづらいアーキテクチャと編集時の注意点のみを記載します。

## 主要な操作コマンド

| 操作              | コマンド                                                                                                 |
| ----------------- | -------------------------------------------------------------------------------------------------------- |
| インストール      | `install.bat`（UAC 昇格 → `install.ps1`）                                                                |
| アンインストール  | `uninstall.bat`（UAC 昇格 → `uninstall.ps1`）                                                            |
| 手動実行（テスト）| `schtasks /Run /TN WingetAutoUpgradeAtLogon`                                                             |
| 実行結果確認      | `Get-WinEvent -LogName Application -ProviderName WingetAutoUpgrade -MaxEvents 10`                        |
| タスク状態確認    | `Get-ScheduledTask -TaskName WingetAutoUpgradeAtLogon`                                                   |

## アーキテクチャ

### 2 層構成

1. **インストーラー層** (`install.ps1` / `uninstall.ps1`)
   1. リポジトリ内から実行される。`.bat` はUAC昇格のためだけのラッパーです。
2. **ペイロード層** (`payload/`)
   1. インストール時に `C:\ProgramData\WingetAutoUpgrade\` へコピー・展開されます。
   2. タスクスケジューラが実行するのはペイロード層のみです。
   3. リポジトリの `payload/` を編集した後は、必ず `install.bat` で再配置する必要があります。

### インストール時の変換処理

`install.ps1` は単純コピーではなく、2つの変換を実行します。

- **`Invoke-WingetUpgrade.ps1`**
  - `UTF-8 BOM付き`で再書き出し（`UTF8Encoding($true)`）を実行します。
- **`Task.xml.template` → `Task.xml`**
  - `{{USER_ID}}` を `"$env:USERDOMAIN\$env:USERNAME"` に、`{{POWERSHELL_PATH}}` を検出したPowerShell実行ファイルパスに置換（いずれもXMLエスケープあり）したあと、**UTF-16 LE BOM付き**で書き出します（`UnicodeEncoding($false, $true)`）。

エンコーディングは`schtasks /Create /XML` の仕様上必須です。
`Set-Content` などのPowerShell既定エンコーディングでは `schtasks` がXMLを拒否する場合があるため、
両ファイルとも `[System.IO.File]::WriteAllText` + 明示的 `Encoding` で書き出しています。
編集時もこの方式を維持してください。

### PowerShell実行パスの決定ロジック

`install.ps1` の `Resolve-PowerShellPath` は、以下の優先度で`Task.xml`の`<Command>`に書き込む値を決定します。

1. `Get-Command pwsh` で解決できる `pwsh.exe`
2. `C:\Program Files\PowerShell\7\pwsh.exe`（既定インストール先のフォールバック）
3. `powershell.exe`（Windows PowerShell 5.1）

`payload/Invoke-WingetUpgrade.ps1` はPowerShell 5.1と7の両方で動く書き方を維持してください。
とくに以下のcmdletはPowerShell 7で削除されているため、**使用しないでください**。

- `New-EventLog` → `[System.Diagnostics.EventLog]::CreateEventSource()`で代替します
- `Write-EventLog` → `[System.Diagnostics.EventLog]::WriteEntry()`で代替します
- `Remove-EventLog` → `uninstall.ps1`内のみで使用可能（`uninstall.bat`が`powershell.exe`固定で起動するため許容されます）

### スケジュールタスクの設計意図

- **Principalは実行ユーザー（InteractiveToken + HighestAvailable）**です。SYSTEMでは実行しないでください。
  - 理由: `winget` はユーザースコープで解決されるため、SYSTEMだとPATH解決に失敗してイベントID:9000が記録されます。
- **タスクは特定ユーザーのログオンにバインドされる**ため、複数ユーザーで使う場合はユーザーごとに `install.bat` を実行する必要があります。
- `Task.xml.template` 内の `<UserId>` 2箇所（`LogonTrigger` と `Principal`）を両方差し替えています。片方だけ変更しないことに留意してください。

### ループ実行ロジック（`Invoke-WingetUpgrade.ps1`）

1回の `winget upgrade --all` で更新しきれないパッケージ（依存関係で後続ターンに再出現するものなど）に備え、
最大 `$MaxIterations` 回（既定は3回）までループします。

終了条件は3つ:

1. 残アップグレード可能数が0であること（成功）
2. 前回イテレーションから残数が減らないこと（進展なし → 失敗とみなす）
3. `$MaxIterations` に到達したこと（上限到達）

残数は `winget upgrade --include-unknown` の出力に対し、正規表現 `(\d+)\s*(?:アップグレード|upgrades?\s+available)` で抽出しています。
**日本語 UI と英語 UI の両方にマッチ**させているため、どちらかを変更する場合は両方更新してください。

イベントログは `Application` ログの `WingetAutoUpgrade` ソースに書き込んでください。
ソースは初回実行時に `New-EventLog` で自動登録してください（登録には管理者権限が必要だが、タスクはHighestAvailableで動くため通常問題にならない）。

### 進捗出力のノイズ対策（`Invoke-WingetUpgrade.ps1`）

`winget` の進捗スピナー／プログレスバーは `\r` で行を上書きしますが、パイプ経由では上書きが効かず大量改行になります。
これを2段構えで抑制しており、いずれもループ前の `Disable-WingetProgressBar` と表示パイプ上の `Format-WingetLine` に実装しています。

- **`Disable-WingetProgressBar`**: 実行ユーザーの `winget` `settings.json`（`%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json`）の `visual.progressBar` を `disabled` にします。
  - `settings.json` はJSONC（`//`・`/* */`）のことがあるため、**文字列リテラルを保持したまま**コメント除去してから解析しています（`$schema` のURL内 `//` を壊さないため）。
  - **ユーザー設定を破損させない方針**です。解析失敗・`visual` が非オブジェクト・すでに `disabled` の場合は書き換えず続行します。書き出しは `UTF-8 BOMなし`。
  - **アンインストールでは元に戻しません**（元の値を保持していないため）。`uninstall.ps1` に復元処理を足さない方針です。
- **`Format-WingetLine`**: 残ったスピナー・プログレスバー・ダウンロード進捗・ANSIエスケープのみの行を表示前に除去します。
  - 罫線/ブロック文字（U+2500–U+259F）と日本語等（U+3000–U+9FFF）の判定範囲は、ソースをASCIIに保つため `[char]` で組み立てています。リテラル文字を直書きしないでください。
  - `winget` の出力仕様が変わった場合は、残数抽出の正規表現（前述）と同様にここの正規表現も見直す必要があります。

両関数とも **Windows PowerShell 5.1 / PowerShell 7 の両対応**を維持してください。

## 編集時の注意

### 日本語を含むファイルのエンコーディング

- **`.ps1`**
  - `UTF-8 BOM付き`で保存します。
  - `install.ps1` の配置処理も `UTF-8 BOM付き` を強制する前提です。
- **`.bat`**
  - 冒頭 `chcp 65001` で `UTF-8 コードページ`に切り替えています。
  - `UTF-8 BOMなし`が無難です（`cmd.exe` が `BOM` をコマンドとして解釈する事故を避けるためです）。
- **`Task.xml.template`**
  - 編集時は任意のエンコーディングで可能ですが、`install.ps1` が `UTF-8` として読み込むため `UTF-8（BOMなし可）`で保存するのが安全です。
  - 最終的な `Task.xml` は `UTF-16 LE BOM` で書き出されます。

### カスタマイズ可能なパラメーターの所在

- リトライ回数・イテレーション間待機
  - `payload/Invoke-WingetUpgrade.ps1` 冒頭（`$MaxIterations`, `$SettleSeconds`）
- ログオン遅延・実行時間上限・ウィンドウ表示有無
  - `payload/Task.xml.template`（`<Delay>`, `<ExecutionTimeLimit>`, `<Hidden>`）
- `winget` 実行フラグ
  - `Invoke-WingetUpgrade.ps1` のメインループ内（`--silent` 他）

これらを変更した後は `install.bat` の再実行が必要です（既存タスクは `/F` で上書きされる）。

### アンインストーラーの方針

`uninstall.ps1` は `$ErrorActionPreference = 'Continue'` で動き、3ステップ（タスク削除 / フォルダー削除 / イベントソース削除）のうち
**イベントソース削除の失敗は致命的としません**（ほかのコンピューターにも影響する可能性があるため）。
タスクとフォルダーの削除は、失敗した場合に `exit 1` を返します。
