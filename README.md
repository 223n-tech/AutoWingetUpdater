# auto winget updater

Windows へのログオン後に `winget upgrade --all` を管理者権限で自動実行するタスクスケジューラ設定一式。

## 概要

- ログオン 2 分後にタスクスケジューラから `winget upgrade --all` をループ実行する
- 1 回の `--all` で更新しきれなかったパッケージを最大 3 回までリトライする
- 実行時はコンソールウィンドウを表示し、完了後 30 秒で自動クローズ (キー入力で即時クローズ)
- 実行結果を Windows イベントログ (Application / `WingetAutoUpgrade`) に記録する

## 動作環境

- Windows 10 / 11
- winget v1.x が利用可能であること
- 管理者権限を持つユーザーアカウント (ログオン先)
- Windows PowerShell 5.1 または PowerShell 7

## セットアップ

`install.bat` をダブルクリックしてください。UAC 昇格ダイアログが表示されるので許可します。

インストーラーは以下を行います。

1. `C:\ProgramData\WingetAutoUpgrade\` を作成
2. `payload\Invoke-WingetUpgrade.ps1` を `C:\ProgramData\WingetAutoUpgrade\` へ UTF-8 BOM 付きでコピー
3. `payload\Task.xml.template` の `{{USER_ID}}` を実行ユーザー (`%USERDOMAIN%\%USERNAME%`) に差し替え、UTF-16 LE BOM 付きで書き出し
4. `schtasks /Create /XML` で `WingetAutoUpgradeAtLogon` タスクを登録 (既存があれば上書き)

## アンインストール

`uninstall.bat` をダブルクリックしてください。UAC 昇格後、以下を削除します。

1. スケジュールタスク `WingetAutoUpgradeAtLogon`
2. `C:\ProgramData\WingetAutoUpgrade\` フォルダ
3. イベントソース `WingetAutoUpgrade`

## 動作確認

### 手動実行

ログオンを待たずに即時実行する場合:

```powershell
schtasks /Run /TN "WingetAutoUpgradeAtLogon"
```

### 実行結果の確認

イベントログから過去の実行結果を確認できます。

```powershell
Get-WinEvent -LogName Application -ProviderName WingetAutoUpgrade -MaxEvents 10 |
    Format-List TimeCreated, Id, LevelDisplayName, Message
```

イベント ID の意味:

| Event ID | Level       | 内容                                         |
| -------- | ----------- | -------------------------------------------- |
| 1000     | Information | 全パッケージを更新完了                       |
| 2000     | Warning     | 一部パッケージが残存 (ループ打ち切り or 失敗) |
| 9000     | Error       | winget コマンドが見つからない                 |

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
├── README.md                     # このファイル
└── payload/
    ├── Invoke-WingetUpgrade.ps1  # タスクが実行するスクリプト本体
    └── Task.xml.template         # タスク定義のテンプレート
```

## カスタマイズ

`payload\Invoke-WingetUpgrade.ps1` の冒頭で以下を調整できます。

```powershell
$MaxIterations = 3   # リトライ回数の上限
$SettleSeconds = 5   # イテレーション間の待機秒数
```

`payload\Task.xml.template` で以下を調整できます。

- `<Delay>PT2M</Delay>`: ログオン後の遅延時間 (ISO 8601 期間形式)
- `<ExecutionTimeLimit>PT2H</ExecutionTimeLimit>`: タスクの最大実行時間
- `<Hidden>false</Hidden>`: `true` にするとウィンドウ非表示
- `--include-pinned` フラグ追加: ピン留めパッケージも対象にする場合

変更後は `install.bat` で再インストールしてください。

## 仕組み

### winget 実行フラグ

無人実行に必要な以下のフラグを付与しています。

- `--silent`: インストーラー UI を抑制
- `--accept-source-agreements`: ソース規約に自動同意
- `--accept-package-agreements`: パッケージ規約に自動同意
- `--include-unknown`: バージョン不明パッケージも対象に含める
- `--disable-interactivity`: 対話プロンプトを抑止

### ループ終了条件

いずれかを満たすとループを抜けます。

1. 残アップグレード可能数が 0
2. 前回イテレーションから残数が減らない (進展なし)
3. `MaxIterations` に到達

残数は `winget upgrade --include-unknown` の出力末尾にある `X アップグレードを利用できます` を正規表現で抽出して取得します。

### 実行コンテキスト

- Principal: 実行ユーザー (InteractiveToken + HighestAvailable)
- SYSTEM では実行しない (winget はユーザースコープのアプリを取り扱うため)

## 既知の制約

- 複数ユーザーで運用する場合、ユーザーごとに `install.bat` を実行する必要がある (タスクが特定ユーザーのログオンにバインドされるため)
- Microsoft Store 経由の一部アプリや MSIX パッケージは winget 単体で更新できないことがある
- 初回インストール時に winget のソース初期化が走ると時間がかかる場合がある

## トラブルシューティング

### タスクが起動しない

- バッテリー駆動中の場合、タスクスケジューラの既定動作で実行が抑制されないか確認
- `Get-ScheduledTask` で `State` が `Ready` か確認
- 最終実行結果は `Get-ScheduledTaskInfo -TaskName WingetAutoUpgradeAtLogon` の `LastTaskResult` で確認可能

### 日本語が文字化けする

- すべての `.ps1` ファイルは UTF-8 BOM 付きで配布される
- `.bat` は `chcp 65001` で UTF-8 コードページに切り替えている
- 手動編集後に文字化けが発生した場合は、エディタで UTF-8 BOM 付きで保存し直す

### winget が見つからないエラー (Event ID 9000)

- App Installer が未インストールの可能性。Microsoft Store から「アプリ インストーラー」を入手する
- タスクを SYSTEM 実行に変更すると winget が解決できなくなるため、変更しないこと
