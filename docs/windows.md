# Windows ガイド

Windows の PC を jupyter-for-share のサーバーにする手順と、管理に使うコマンドの説明です。
([README](../README.md) に戻る / [Linux・Jetson の場合](linux.md))

- [必要なもの](#必要なもの)
- [セットアップ](#セットアップ)
- [ユーザー環境を作る・起動する](#ユーザー環境を作る起動する)
- [コマンド一覧](#コマンド一覧)
- [他の PC からつながらないとき](#他の-pc-からつながらないとき)
- [名前 (ドメイン名) でアクセスする](#名前-ドメイン名-でアクセスする)
- [他のフォルダへのアクセス禁止](#他のフォルダへのアクセス禁止)
- [アンインストール](#アンインストール)
- [トラブルシューティング](#トラブルシューティング)

## 必要なもの

- Windows 10 / 11 (64bit) と、その PC の管理者権限
- インターネット接続 (Python・Git・JupyterLab のダウンロード用)
- 接続する PC が同じ LAN にあること
- リポジトリを置くドライブが NTFS であること (外付けの FAT32 / exFAT ドライブは不可)

Python と Git は、入っていなければ setup が winget で自動的にインストールします。
既に入っている場合はそれを使います (全ユーザー向けにインストールされた Python 3.9 以上)。

## セットアップ

1. リポジトリをクローンします。ユーザー環境はこのフォルダの中に作られるので、空き容量があり、
   パスに日本語や空白が無い場所をおすすめします (例: `C:\jupyter-for-share`、`E:\jupyter-for-share`)。

   ```bat
   cd C:\
   git clone https://github.com/404background/jupyter-for-share.git
   cd jupyter-for-share
   ```

   Git が無い場合は GitHub の「Code → Download ZIP」で展開しても構いません (自動更新は使えません)。

2. `setup.cmd` をダブルクリックするか、コマンドプロンプトで実行します。管理者権限の確認が出たら「はい」を選びます。

   ```bat
   setup.cmd
   ```

   オプション:

   | オプション | 内容 |
   | --- | --- |
   | `-Domain jupyter.home.arpa` | URL に表示するドメイン名 ([名前でアクセスする](#名前-ドメイン名-でアクセスする)) |
   | `-DisableSleep` | AC 電源時のスリープ・休止を無効にする (常時起動のサーバー向け) |
   | `-SkipProtect` | [他のフォルダへのアクセス禁止](#他のフォルダへのアクセス禁止) を設定しない |
   | `-MonitorPort 9000` / `-SkipMonitor` | リソースモニターのポートを変える / 設置しない |

   setup が行うこと (何度実行しても問題ありません):

   | 内容 | 詳細 |
   | --- | --- |
   | 最新版への更新 | 最初に `git pull` (失敗したときはメッセージを表示して止まり、キーを押すと今のファイルで続行) |
   | Python / Git | インストール済みか確認し、無ければ winget で全ユーザー向けにインストール |
   | 設定ファイル | `servers.json` を作成 (`servers.example.json` のコピー。[設定項目](configuration.md)) |
   | 実行用グループ・権限 | グループ `jupyter-for-share-users` と、そのログオン権限 |
   | フォルダのアクセス権 | このフォルダ・`user` フォルダ・`C:\ProgramData\jupyter` を管理者以外が変更できないようにする |
   | 他のフォルダへのアクセス禁止 | 初回は時間がかかります (進み具合を表示)。2 回目以降は設定済みの場所を飛ばします |
   | リソースモニター | 設置のみ (サーバー管理ウィンドウの中で動きます) |
   | 既存のユーザー環境 | 起動用ファイルなどを新しいバージョンに合わせて作り直す |

3. 「セットアップが完了しました」と表示されれば完了です。ウィンドウは Enter で閉じます。

## ユーザー環境を作る・起動する

`jfs.cmd` はこのフォルダで実行します (PowerShell では `.\jfs.cmd`)。管理者権限が必要なコマンドは、UAC の確認が表示されます。

```bat
jfs.cmd add alice
jfs.cmd start
```

- `add` はユーザーの実行用アカウント (`jfs-alice`)・フォルダ (`user\alice`)・JupyterLab・venv を作り、接続用 URL を表示します。
  ユーザー名は半角英数字とハイフン (16 文字以内) で、大文字は小文字になります。ポートは 20000〜29999 から空いている番号が選ばれます
- `start` を実行したウィンドウが**サーバー管理ウィンドウ**になり、全員のサーバーがその中で動きます。
  ウィンドウを閉じる (または Ctrl+C) と全員が停止します。サーバー管理ウィンドウが開いている間に別のウィンドウで
  `jfs.cmd add` / `start <名前>` / `stop <名前>` を実行すると、サーバー管理ウィンドウ側で起動・停止されます

```
jupyter-for-share サーバー管理ウィンドウ
このウィンドウを閉じる (または Ctrl+C) と、全ユーザーのサーバーが停止します。
----------------------------------------------------------------------
[alice] [jupyter-for-share] 起動します (ポート 23456 / ログ: C:\jupyter-for-share\user\alice\.logs\server.log)
[alice] [jupyter-for-share] 別の PC からはこの URL で開きます (どれか 1 つ。トークン付き):
[alice]     http://jupyter-pc.local:23456/lab?token=...
[alice] [コマンド] 2026-10-22 12:03:10 [terminal] pip install numpy
[bob] [コマンド] 2026-10-22 12:05:42 [analysis.ipynb] df = pd.read_csv("data.csv")
```

PC の再起動やサインアウトでサーバー管理ウィンドウは閉じます。再起動後は `jfs.cmd start` を実行するか、
`jfs.cmd autostart on` で管理者のサインイン時に自動で開くようにしてください。

## コマンド一覧

`jfs.cmd help <コマンド>` で各コマンドの詳しい説明が表示されます (`jfs.cmd -h`・`/?` でも一覧)。

| コマンド | 内容 |
| --- | --- |
| `jfs.cmd add <名前>` | ユーザー環境を作成 |
| `jfs.cmd list` | ユーザー環境とリソースモニターの一覧・状態 |
| `jfs.cmd url [名前]` | 接続用 URL を表示 (省略で全員分 + リソースモニター) |
| `jfs.cmd start [名前]` | 起動 (省略で全員)。サーバー管理ウィンドウが無ければ、このウィンドウがそれになる |
| `jfs.cmd stop [名前]` | 停止 (省略で全員。サーバー管理ウィンドウも閉じる) |
| `jfs.cmd restart [名前]` | 再起動 (更新を反映するときなど) |
| `jfs.cmd remove <名前> [-KeepFiles] [-Force]` | 環境をフォルダごと削除 (`-KeepFiles` でフォルダは残す) |
| `jfs.cmd token <名前> -New` | トークンを再発行 (古い URL は使えなくなる) |
| `jfs.cmd set <名前> -Port 23456` | ポートを変更 (`-AllowFrom 192.168.0.0/16` で接続を許可する相手も変更) |
| `jfs.cmd logs <名前> [-Follow]` | 実行したコマンドの記録とサーバーのログ (`logs monitor` でモニターのログ) |
| `jfs.cmd upgrade [名前]` | JupyterLab 本体を最新にする (venv のパッケージはそのまま) |
| `jfs.cmd reset-venv <名前> [-Venv sam3_env] [-Clean]` | venv を修復 (Python 本体・pip・ipykernel を本人のアカウントで確かめ、壊れているものだけ直す。入れたパッケージは残す)。`-Venv` で本人が work に作った venv、`-Clean` で空の状態から作り直し |
| `jfs.cmd monitor [-Port 8000]` / `monitor-stop` | リソースモニターを設置・変更 / 停止 |
| `jfs.cmd autostart on\|off` | 管理者のサインイン時にサーバー管理ウィンドウを自動で開く |
| `jfs.cmd network [-SetPrivate] [-Yes]` | 他の PC から接続できるようにネットワーク設定を確認・変更 |
| `jfs.cmd doctor [名前]` | つながらないときの診断 (`[NG]` の項目に原因を表示) |
| `jfs.cmd refresh` | 全ユーザーの起動用ファイルを作り直す (setup から自動で実行) |
| `jfs.cmd firewall` | ファイアウォール規則を作り直す |
| `jfs.cmd protect [-Force]` / `protect -Status` / `unprotect` | 他のフォルダへのアクセス禁止を設定 / 状況表示 / 解除 |
| `jfs.cmd version` | バージョン (git のコミット) |
| `uninstall.cmd [-DeleteFiles]` | すべて元に戻す ([アンインストール](#アンインストール)) |

管理者権限で開き直したウィンドウは、処理が終わると自動で閉じます。エラーのときや、一覧・URL・ログ・診断など表示が目的のコマンドは、読めるように Enter で閉じます。

## 他の PC からつながらないとき

サーバー PC 自身ではつながるのに、同じ LAN の別の PC からつながらない (ping も通らない) 場合は、
多くの場合 LAN の接続が「パブリック」ネットワークになっていて、ファイアウォールが受信を止めています。

```bat
jfs.cmd network -SetPrivate
```

1. 現在の状態 (ネットワークの種類・ファイアウォール・各ポートの許可と待ち受け・ping・名前解決の設定) を表示
2. 必要な変更を一覧にして、確認 (`y`) を求める
3. 変更を適用し、もう一度状態を表示

| 変更 | 内容 |
| --- | --- |
| ネットワークの種類 | `-SetPrivate` を付けた場合、「パブリック」の LAN 接続を「プライベート」に (Tailscale や仮想アダプターは対象外) |
| ポートの許可 | 各ユーザー環境とリソースモニターのポートを許可 (接続元は同じサブネットのまま) |
| ping | ICMP エコー要求の受信を許可 |
| 名前解決 | `<コンピューター名>.local` などで見つけられるよう、mDNS・LLMNR・NetBIOS の設定と受信規則を有効に |
| python のブロック | 過去に「アクセスを許可しない」を選んでできた、python をブロックする規則を無効化 (削除はしない) |

これでもつながらない場合は、ネットワーク側 (Wi-Fi の AP アイソレーション / ゲストネットワーク、別のサブネット、
他社製セキュリティソフトのファイアウォールなど) が原因の可能性があります。

## 名前 (ドメイン名) でアクセスする

1. **`<コンピューター名>.local`** (設定不要): URL にはこの形が表示されます。分かりやすい名前にするには
   サーバー PC の名前を変更します (PowerShell で `Rename-Computer -NewName jupyter-pc` → 再起動)。
   つながらない場合は `jfs.cmd network` で名前解決の設定を確認してください
2. **ルーター / 社内 DNS に登録** (おすすめ): ルーターでサーバー PC の IP を固定し、`jupyter.home.arpa → 192.168.1.10` のような名前を登録して、
   `setup.cmd -Domain jupyter.home.arpa` を実行します
3. **接続する PC の hosts に登録**: 接続する Windows PC で次を実行します (管理者権限)。Mac / Linux では `/etc/hosts` に追記します

   ```bat
   powershell -ExecutionPolicy Bypass -File scripts\client-add-hosts.ps1 -Domain jupyter.home.arpa -ServerIp 192.168.1.10
   ```

ドメイン名は `home.arpa` (家庭内 LAN 用に予約された名前) や社内のドメインを使ってください (`.local` は mDNS と衝突します)。

## 他のフォルダへのアクセス禁止

各ユーザーのサーバーは専用のアカウントで動くため、他のユーザーのフォルダやこのリポジトリには最初からアクセスできません。
ただし Windows の既定では、一般ユーザーも他のドライブ (`D:\` など) や `C:\` 直下の独自フォルダを読み書きできるため、
setup (または `jfs.cmd protect`) がそれらに「拒否」を設定します。

| 対象 | 実行用アカウント (`jfs-xxx`) からのアクセス |
| --- | --- |
| 自分の環境 (`work`, `venv` など) | 読み書きできる |
| 自分の `.server` (JupyterLab 本体など) | 読み取りのみ |
| 他のユーザーの環境、このリポジトリのスクリプト・設定 | できない |
| 他の Windows ユーザーのプロファイル (`C:\Users\<名前>`) | できない (Windows の既定) |
| 他のドライブ、リポジトリと同じドライブの他のフォルダ、`C:\` 直下の独自フォルダ、`C:\Users\Public` | できない (`protect` で拒否) |
| `C:\Windows`, `C:\Program Files` | 読み取りのみ (Python・Git を動かすため) |
| インターネット・LAN | 使える (pip / git のため) |

- 初回はドライブ内のファイル数に比例して時間がかかります (HDD では特に)。進み具合を表示し、最大 8 か所を同時に処理します。
  2 回目以降は設定済みの場所を飛ばします。サーバー管理ウィンドウを開いたときに未設定の場所があれば知らせます
- `servers.json` の `defaults.protectLevel` を `"folders"` にするとフォルダにだけ拒否を付けるので大幅に速くなりますが、守りは弱くなります
- 禁止する場所は `defaults.protectedPaths` で追加できます ([設定項目](configuration.md))
- 不要な場合は `setup.cmd -SkipProtect` で設定せず、`jfs.cmd unprotect` で解除できます

## アンインストール

```bat
uninstall.cmd
```

jupyter-for-share が Windows に加えた変更を、**記録に頼らず探して**すべて元に戻します (以前のバージョンが残したものも含む)。

1. サーバー・リソースモニターの停止
2. 自動起動タスクとファイアウォール規則の削除
3. アクセス禁止 (拒否) の解除 (全ドライブの直下とその中、このフォルダの上の階層、`C:\Users\Public` を確認)
4. 実行用アカウント (`jfs-*`, `jfsmon`)・グループ・ログオン権限の削除
5. このフォルダのアクセス権を元に戻す
6. 実行時のファイルの削除 (`servers.json` は `servers.json.uninstalled` として残す。トークンを含むので扱いに注意)
7. ユーザーのフォルダ (`user\`) は残す (`uninstall.cmd -DeleteFiles` で削除)

完了後、このウィンドウと、このフォルダを開いているエクスプローラーなどを閉じれば、フォルダを削除できます。

## トラブルシューティング

まず `jfs.cmd doctor` (1 人分なら `jfs.cmd doctor <名前>`) を実行してください。問題のある箇所に `[NG]` と原因を表示します。
別の PC からだけつながらない場合は [`jfs.cmd network`](#他の-pc-からつながらないとき) を使います。

| 症状 | 対処 |
| --- | --- |
| 別の PC からつながらない | `jfs.cmd list` で「起動中」か確認 → `jfs.cmd network -SetPrivate` → サーバー PC で `http://localhost:<ポート>/` が開けるか確認 |
| `<名前>.local` でつながらない | `jfs.cmd network` で名前解決を確認。だめなら IP アドレスの URL か、[ルーター / hosts に登録](#名前-ドメイン名-でアクセスする) |
| 接続元が別のサブネット | `jfs.cmd set <名前> -AllowFrom 192.168.0.0/16` のように許可範囲を広げる |
| 起動時に PermissionError | `jfs.cmd doctor <名前>` が、実行用アカウントとして各フォルダを読めるかをテストし、読めない場所を表示します |
| 処理が途中で止まり、Enter で進む | ウィンドウ内をクリックすると「選択」状態になって止まります。Esc か Enter で再開します |
| GPU が表示されない | NVIDIA はドライバ (`nvidia-smi`) を確認。`jfs.cmd logs monitor` にエラーが出ていないか確認 |
| スリープでつながらなくなる | `setup.cmd -DisableSleep` |
| ターミナルでスクリプトが実行できない | 実行ポリシーは RemoteSigned です。ダウンロードしたスクリプトは `Unblock-File` で許可 |
| 作成途中のデータが残っていて作成できない | `jfs.cmd remove <名前>` で片付けてから作り直す |
| フォルダを削除できない / 全部やり直したい | [アンインストール](#アンインストール) → `setup.cmd` |
| バージョンを確認したい | `jfs.cmd version` |
