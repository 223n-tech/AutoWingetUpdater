# auto winget updater

Windowsにログオンした後に `winget upgrade --all` を管理者権限で自動実行するタスクスケジューラ設定一式です。

## 概要

- ログオンしてから2分後にタスクスケジューラから `winget upgrade --all` をループ実行します。
- 1回目の `--all` で更新しきれなかったパッケージは、最大3回までリトライします。
- 実行時はコンソールウィンドウを表示し、完了後30秒で自動クローズ（キー入力で即時クローズ）します。
- 実行結果をWindowsイベントログ（`アプリケーションとサービス ログ\223n.tech\AutoWingetUpdater`）に記録します。
- 各スクリプトは起動時にアプリ名とバージョン（`VERSION` ファイル）を表示します。

## 動作環境

- OS: Windows 10 / 11
- winget v1.x` が利用可能であること
- 管理者権限を持つユーザーアカウント（ログオン先）であること
- `Windows PowerShell 5.1` または `PowerShell 7`が利用可能であること
  - インストーラーが`pwsh.exe`を検出した場合、タスク実行にはPowerShell 7を優先採用します

## セットアップ

`install.bat` をダブルクリックしてください。
UAC昇格ダイアログが表示されるので許可してください。

インストーラーは、以下を行います。

1. `C:\ProgramData\WingetAutoUpgrade\` を作成します。
2. `payload\Invoke-WingetUpgrade.ps1` を `C:\ProgramData\WingetAutoUpgrade\` へ `UTF-8 BOM付き` でコピーします。配置時に冒頭の `$ScriptVersion` 行を `VERSION` ファイルの値で書き換えます。
3. タスク実行に使うPowerShellを検出します（`pwsh.exe` があればPowerShell 7を優先、なければ `powershell.exe`）。
4. `payload\Task.xml.template` の `{{USER_ID}}` と `{{POWERSHELL_PATH}}` を差し替え、`UTF-16 LE BOM付き` で書き出します。
5. `payload\AutoWingetUpdater.man`（ETWマニフェスト）とリソースDLLを `C:\ProgramData\WingetAutoUpgrade\` に配置し、`wevtutil im` でカスタムイベントログチャンネル `223n.tech/AutoWingetUpdater` を登録します。
6. `schtasks /Create /XML` で `WingetAutoUpgradeAtLogon` タスクを登録（既存があれば上書き）します。

## アンインストール

`uninstall.bat` をダブルクリックしてください。
UAC昇格後、以下を削除します。

1. スケジュールタスク `WingetAutoUpgradeAtLogon`
2. ETWマニフェスト（カスタムイベントログチャンネル `223n.tech/AutoWingetUpdater`）を `wevtutil um` で登録解除
3. `C:\ProgramData\WingetAutoUpgrade\` フォルダー
4. 旧バージョンからの移行用に、Applicationログのイベントソース `WingetAutoUpgrade` も残っていれば削除

## 動作確認

### 手動実行

ログオンを待たずに即時実行する場合:

```powershell
schtasks /Run /TN "WingetAutoUpgradeAtLogon"
```

### 実行結果の確認

イベントビューアーで「アプリケーションとサービス ログ > 223n.tech > AutoWingetUpdater」を開くか、PowerShellで以下を実行します。

```powershell
Get-WinEvent -LogName '223n.tech/AutoWingetUpdater' -MaxEvents 10 |
    Format-List TimeCreated, Id, LevelDisplayName, Message
```

イベントIDの意味:

| Event ID | Level       | 内容                                           |
| -------- | ----------- | ---------------------------------------------- |
| 1000     | Information | 全パッケージを更新完了                         |
| 1100     | Information | スクリプト起動（アプリ名とバージョンを記録）   |
| 2000     | Warning     | 一部パッケージが残存（ループ打ち切り or 失敗） |
| 9000     | Error       | winget コマンドが見つからない                  |

### タスク定義の確認

```powershell
Get-ScheduledTask -TaskName WingetAutoUpgradeAtLogon |
    Select-Object TaskName, State, @{N='Trigger';E={$_.Triggers[0].UserId}}
```

## ファイル構成

```text
auto winget updater/
├── install.bat                   # UAC 昇格ラッパー (install.ps1 を起動)
├── install.ps1                   # インストーラー本体
├── uninstall.bat                 # UAC 昇格ラッパー (uninstall.ps1 を起動)
├── uninstall.ps1                 # アンインストーラー本体
├── VERSION                       # バージョン番号（インストール時に payload に埋め込み）
├── README.md                     # このファイル
└── payload/
    ├── Invoke-WingetUpgrade.ps1  # タスクが実行するスクリプト本体
    ├── Task.xml.template         # タスク定義のテンプレート
    └── AutoWingetUpdater.man     # ETWマニフェスト（カスタムイベントログチャンネル定義）
```

## カスタマイズ

リポジトリ直下の `VERSION` ファイルでバージョン番号を一元管理します。値はインストール時に `payload/Invoke-WingetUpgrade.ps1` の `$ScriptVersion` 行に埋め込まれ、起動時にコンソール表示とイベントログ（Event ID 1100）に記録されます。

`payload\Invoke-WingetUpgrade.ps1` の冒頭で、以下を調整できます。

```powershell
$MaxIterations = 3   # リトライ回数の上限
$SettleSeconds = 5   # イテレーション間の待機秒数
```

`payload\Task.xml.template` で以下を調整できます。

| XML要素 / フラグ                                | 内容                                             |
| ----------------------------------------------- | ------------------------------------------------ |
| `<Delay>PT2M</Delay>`                           | ログオン後の遅延時間（ISO 8601期間形式）         |
| `<ExecutionTimeLimit>PT2H</ExecutionTimeLimit>` | タスクの最大実行時間                             |
| `<Hidden>false</Hidden>`                        | `true` にするとウィンドウ非表示                  |
| `--include-pinned` フラグ                       | ピン留めパッケージも対象にする場合にフラグを追加 |

変更後は `install.bat` で再インストールしてください。

## 仕組み

### winget 実行フラグ

無人実行に必要な以下のフラグを付与しています。

- `--silent`: インストーラーUIを抑制します。
- `--accept-source-agreements`: ソース規約に自動同意します。
- `--accept-package-agreements`: パッケージ規約に自動同意します。
- `--include-unknown`: バージョン不明パッケージも対象に含めます。
- `--disable-interactivity`: 対話プロンプトを抑止します。

### 進捗表示の抑制

`winget` の進捗スピナー（`- \ | /`）やプログレスバーは、同じ行を上書きして描画されます。
タスク実行ではコンソール出力をパイプ経由で扱うため上書きが効かず、そのままでは進捗の更新ごとに改行され、ログが大量の行で埋まります。

これを次の2段構えで抑制しています。

1. 実行ユーザーの `winget` 設定（`settings.json`）の `visual.progressBar` を `disabled` に設定し、進捗バー描画自体を止めます（根本対処）。
2. それでも残るスピナー・進捗のみの行を、表示前にスクリプト側でフィルターして除去します（保険）。

`settings.json` は解析に失敗した場合は書き換えず、警告を出して処理を続行します（ユーザー設定を破損させないため）。

### ループ終了条件

いずれかを満たすとループを抜けます。

1. 残アップグレード可能数が `0`
2. 前回イテレーションから残数が減らない（進展なし）
3. `MaxIterations` に到達

残数は `winget upgrade --include-unknown` の出力末尾にある `X アップグレードを利用できます` を正規表現で抽出して取得します。

### 実行コンテキスト

- Principal: 実行ユーザー (InteractiveToken + HighestAvailable)
- `SYSTEM`では実行しません（`winget`はユーザースコープのアプリを取り扱うためです）

### 実行に使うPowerShellの選択

`install.bat`実行時に、以下の優先度で使用するPowerShellを決定し、タスク定義の`<Command>`に書き込みます。

1. `PATH`上の`pwsh.exe`（`Get-Command pwsh`で解決できるもの）
2. `C:\Program Files\PowerShell\7\pwsh.exe`（既定インストール先）
3. `powershell.exe`（Windows PowerShell 5.1）

PowerShell 7を導入した後に切り替えたい場合、および元に戻したい場合は、`install.bat`を再実行してください。
既存タスクは上書きされます。

### イベントログのカスタムチャンネル

実行結果はETWマニフェスト方式で登録したカスタムログ `223n.tech/AutoWingetUpdater` に書き込みます。イベントビューアー上は `アプリケーションとサービス ログ` > `223n.tech` > `AutoWingetUpdater` として階層表示されます。

- インストール時に `payload\AutoWingetUpdater.man` を `C:\ProgramData\WingetAutoUpgrade\` に配置し、空のリソースDLLを `Add-Type -OutputAssembly` で動的生成して `wevtutil im` でプロバイダーとチャンネルを登録します。
- 書き込みは `New-WinEvent -ProviderName '223n.tech-AutoWingetUpdater' -Id <id> -Payload @(<message>)` で行います。メッセージリソースは持たず、本文は `Payload` に直接渡します。
- アンインストール時は `wevtutil um` で登録解除してからフォルダーを削除します。

## 既知の制約

- 複数ユーザーで運用する場合には、ユーザーごとに `install.bat` を実行する必要があります（タスクが特定ユーザーのログオンにバインドされるため）
- Microsoft Store経由の一部アプリやMSIXパッケージは `winget` 単体で更新できないことがあります
- 初回インストール時に `winget` のソース初期化が走ると時間がかかる場合があります
- タスク実行ユーザーの `winget` 設定（`settings.json`）の `visual.progressBar` を `disabled` に変更します。これは手動の `winget` 実行にも影響し、アンインストールしても元に戻しません（元の値を保持していないため）

## トラブルシューティング

### タスクが起動しない

- バッテリー駆動中の場合は、タスクスケジューラの既定動作で実行が抑制されないか確認してください。
- `Get-ScheduledTask` で `State` が `Ready` か確認してください。
- 最終実行結果は `Get-ScheduledTaskInfo -TaskName WingetAutoUpgradeAtLogon` の `LastTaskResult` で確認することが可能です。

### 日本語が文字化けする

- すべての `.ps1` ファイルは `UTF-8 BOM付き` で配布されています。
- `.bat` は `chcp 65001` で `UTF-8コードページ` に切り替えています。
- 手動編集後に文字化けが発生した場合は、エディターで `UTF-8 BOM付き` で保存し直してください。

### winget が見つからないエラー (Event ID 9000)

- App Installerが未インストールの可能性があります。Microsoft Storeから「アプリ インストーラー」を入手してください。
- タスクを `SYSTEM` 実行に変更すると `winget` が解決できなくなるため、変更しないでください。
