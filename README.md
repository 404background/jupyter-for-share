# jupyter-for-share

Windows PC を JupyterLab サーバーにして、LAN 内の別の PC からブラウザで使うためのセットアップスクリプトです。

- **ポートごとに別のサーバー**を作れます (`jfs add alice -Port 8888`、`jfs add bob -Port 8889` …)
- **サーバーごとにフォルダが分かれ**、各サーバーは**自分のフォルダの中だけ**読み書きできます
- ノートブック・**ターミナル (PowerShell)** の両方が使えます
- パッケージはサーバーごとの **Python 仮想環境 (venv)** に `pip install` で自由に入れられます。`git clone` も使えます
- **コンピューター名やドメイン名**でアクセスできます (例: `http://jupyter-pc:8888/`)
- Docker は使いません。Windows 標準の機能 (ローカルユーザー・NTFS アクセス権・タスクスケジューラ・ファイアウォール) で構成します

## しくみ

```
サーバー PC (Windows)
├─ C:\JupyterShare\              ← サーバーフォルダの置き場 (instancesRoot)
│   ├─ alice\                    ← サーバー "alice" (ポート 8888) / Windows ユーザー jfs-alice で実行
│   │   ├─ work\                 ← JupyterLab のルート。ノートブックや git clone したものはここ
│   │   ├─ venv\                 ← パッケージを入れる venv (ノートブックのカーネル・ターミナルの python/pip)
│   │   └─ .server\              ← JupyterLab 本体・設定・ログ (隠しフォルダ)
│   └─ bob\                      ← サーバー "bob" (ポート 8889) / ユーザー jfs-bob
└─ タスクスケジューラ \jupyter-for-share\jfs-alice, jfs-bob  ← Windows 起動時に自動起動
```

- 各サーバーは専用の Windows ローカルユーザー (`jfs-<名前>`) として動きます。JupyterLab だけでなく、
  ノートブックのコードやターミナルもこのユーザーの権限で動くため、**NTFS のアクセス権で読み書きできる範囲が制限**されます。
  (JupyterLab の設定だけで制限すると、ターミナルやコードからは PC 中のファイルが見えてしまうため、この方式にしています)
- サーバー用ユーザーは画面からのサインイン・リモートデスクトップ・ネットワーク共有へのログオンが禁止され、サインイン画面にも表示されません。
- タスクスケジューラで起動するので、**誰もサインインしていなくても**サーバーが動きます。

## 必要なもの

- Windows 10 / 11 (64bit)。サーバーとして使う PC の管理者権限
- インターネット接続 (Python・Git・JupyterLab のダウンロード用)
- 接続する PC と同じ LAN

## セットアップ (サーバー PC で 1 回だけ)

1. このリポジトリをサーバー PC にダウンロードします (`git clone` または ZIP をダウンロードして展開)。
   パスに日本語や空白が無い場所 (例: `C:\tools\jupyter-for-share`) をおすすめします。
2. `setup.cmd` をダブルクリック (またはコマンドプロンプトで実行) します。管理者権限の確認が出たら「はい」を選びます。

```bat
setup.cmd
rem オプションの例: サーバーフォルダの場所を D ドライブにし、ドメイン名を設定し、スリープを無効にする
setup.cmd -InstancesRoot D:\JupyterShare -Domain jupyter.home.arpa -DisableSleep
```

setup で行うこと:

| 内容 | 詳細 |
| --- | --- |
| Python / Git のインストール | winget で全ユーザー向けにインストール (インストール済みならスキップ) |
| 設定ファイル作成 | `servers.json` (`servers.example.json` をコピー) |
| サーバー用グループ | `jupyter-for-share-users` を作成し、ログオン権限を設定 |
| フォルダのアクセス権 | サーバーフォルダの置き場と `C:\ProgramData\jupyter` を管理者以外が変更できないようにする |
| 他フォルダへのアクセス禁止 | 後述の「アクセス制限」(`-SkipProtect` で省略可) |

## サーバーを作る・管理する

`jfs.cmd` を使います (管理者権限が必要です。通常のコマンドプロンプトから実行すると UAC の確認が出ます)。

```bat
rem ポート 8888 にサーバー "alice" を作成して起動 (フォルダ: C:\JupyterShare\alice)
jfs add alice -Port 8888

rem 名前を省略するとポート番号から自動で名前を付けます (この例では "port8889")
jfs add -Port 8889

rem よく使うパッケージを最初から入れておく / 接続できる相手を限定する
jfs add lab -Port 8890 -Packages numpy,pandas,matplotlib -AllowFrom 192.168.1.0/24
```

作成が終わると接続用 URL が表示されます。

| コマンド | 内容 |
| --- | --- |
| `jfs list` | サーバーの一覧と状態 |
| `jfs url [名前]` | 接続用 URL を表示 |
| `jfs start / stop / restart [名前]` | 起動 / 停止 / 再起動 (名前を省略すると全サーバー)。停止したサーバーは PC を再起動しても止まったまま |
| `jfs set <名前> -Port 8895` | ポートを変更 (`-AllowFrom` で接続許可範囲も変更可) |
| `jfs token <名前> -New` | アクセストークン (パスワード代わり) を再発行 |
| `jfs logs <名前> [-Follow]` | サーバーのログを表示 |
| `jfs upgrade [名前]` | JupyterLab 本体を更新 |
| `jfs reset-venv <名前>` | venv を作り直す (入れたパッケージを初期化) |
| `jfs remove <名前> [-DeleteFiles]` | サーバーを削除。`-DeleteFiles` を付けるとフォルダも削除 |
| `jfs firewall` | ファイアウォール規則を作り直す |
| `jfs protect / unprotect` | 他フォルダへのアクセス禁止を設定 / 解除 |

## 別の PC から接続する

`jfs url` で表示される URL をブラウザで開きます。

```
http://jupyter.home.arpa:8888/lab?token=xxxx   ← setup で -Domain を指定した場合
http://jupyter-pc:8888/lab?token=xxxx          ← コンピューター名
http://jupyter-pc.local:8888/lab?token=xxxx    ← mDNS (Mac / iPhone / Linux など)
http://192.168.1.10:8888/lab?token=xxxx        ← IP アドレス
```

一度開くとブラウザに記憶されるので、2 回目以降は `http://jupyter-pc:8888/` だけで入れます。
トークンはパスワードと同じなので、使う人以外に知られないようにしてください。

### ドメイン名でアクセスする

IP アドレスの代わりに名前でアクセスする方法は 3 つあります。

1. **コンピューター名** (設定不要): 同じ LAN の Windows PC からは `http://<コンピューター名>:8888/` で通常つながります。
   分かりやすい名前にしたい場合は、サーバー PC の名前を変更します (`Rename-Computer -NewName jupyter-pc` → 再起動)。
   Mac などからは `http://jupyter-pc.local:8888/` を試してください。
2. **ルーター / 社内 DNS に登録** (おすすめ): ルーターの DHCP 設定でサーバー PC の IP を固定し、
   ルーターや DNS サーバーに `jupyter.home.arpa → 192.168.1.10` のような名前を登録します。
   そのうえで `setup.cmd -Domain jupyter.home.arpa` を実行すると、URL がその名前で表示されます。
3. **接続する PC の hosts ファイルに登録**: DNS を触れない場合は、接続する Windows PC で次を実行します (管理者権限)。

   ```bat
   powershell -ExecutionPolicy Bypass -File scripts\client-add-hosts.ps1 -Domain jupyter.home.arpa -ServerIp 192.168.1.10
   ```

   Mac / Linux では `/etc/hosts` に `192.168.1.10 jupyter.home.arpa` を追記します。

ドメイン名は `home.arpa` (家庭内 LAN 用に予約された名前) や社内のドメインを使うのが安全です。
`.local` は mDNS と衝突するので避けてください。

## パッケージのインストールと git

JupyterLab のターミナルを開くと PowerShell が `work` フォルダで起動し、`python` / `pip` はそのサーバーの venv を指しています。

```powershell
pip install numpy pandas          # venv にインストールされ、ノートブックからすぐ使える
pip install -r requirements.txt
git clone https://github.com/xxx/yyy.git
```

ノートブックの中では `%pip install パッケージ名` が使えます。インストール後はカーネルを再起動してください。

別の venv を追加で作ってカーネルとして使うこともできます。

```powershell
python -m venv .venv-exp          # 例: work 内に別の venv を作成
.\.venv-exp\Scripts\python -m pip install ipykernel
.\.venv-exp\Scripts\python -m ipykernel install --user --name exp --display-name "Python (exp)"
```

※ Python 本体のバージョンはサーバー PC にインストールされたもの (既定 3.12) になります。
※ git の HTTPS 認証は、ターミナル内でユーザー名と個人アクセストークンを入力する形になります。

## アクセス制限について

| 対象 | サーバー用ユーザー (jfs-xxx) からのアクセス |
| --- | --- |
| 自分のサーバーフォルダ (`work`, `venv` など) | 読み書きできる |
| 自分の `.server\jupyterlab`, `.server\config` (JupyterLab 本体・設定) | 読み取りのみ |
| 他のサーバーのフォルダ | できない |
| 他のユーザーのプロファイル (`C:\Users\<名前>`、デスクトップ・ドキュメントなど) | できない (Windows の既定) |
| システムドライブ以外のドライブ (D:\ など)、`C:\` 直下の独自フォルダ、`C:\Users\Public` | できない (`jfs protect` で拒否を設定) |
| `C:\Windows`, `C:\Program Files` など OS・アプリ | 読み取りのみ (Python・Git を動かすために必要) |
| インターネット・LAN | 使える (pip / git のため) |

- 禁止するフォルダは `servers.json` の `defaults.protectedPaths` で変更できます。`"auto"` は上の表の自動選択で、
  `["auto", "C:\\Users\\Public"]` のようにパスを追加できます。変更したら `jfs protect` を実行してください。
  (後から作ったドライブやフォルダも `jfs protect` を再実行すると対象になります)
- ドライブ全体へのアクセス権設定は、ファイル数が多いと数分〜数十分かかることがあります。
- 1 つのサーバーを複数人で使う場合、その人たちの間ではファイルが共有されます。人ごとに分けたいときはサーバーを分けてください。
- 通信は HTTP (暗号化なし) です。信頼できる LAN 内で使い、インターネットには公開しないでください。
  ファイアウォールは既定で同じサブネット (`LocalSubnet`) からの接続だけを許可します。

## 設定ファイル (servers.json)

`setup.cmd` で `servers.example.json` からコピーされます。トークンが含まれるので共有しないでください (`.gitignore` 済み)。

| キー | 既定値 | 内容 |
| --- | --- | --- |
| `instancesRoot` | `C:\JupyterShare` | サーバーフォルダを作る場所 |
| `python` | (自動検出) | 使う Python (全ユーザー向けにインストールされたもの) |
| `domain` | (なし) | URL に表示するドメイン名 |
| `portStart` | `8888` | ポート省略時に探し始める番号 |
| `bindAddress` | `0.0.0.0` | 待ち受けるアドレス |
| `allowFrom` | `["LocalSubnet"]` | ファイアウォールで接続を許可する相手 (サーバーごとに `-AllowFrom` で上書き可) |
| `firewallProfiles` | `Domain,Private` | ファイアウォール規則を有効にするネットワークの種類 |
| `labLocale` | `ja_JP` | JupyterLab の表示言語 (`en` で英語) |
| `extraServerPackages` | `[]` | JupyterLab 側に追加する拡張機能など (例: `"jupyterlab-git"`) |
| `venvPackages` | `[]` | 新しく作る venv に最初から入れるパッケージ |
| `protectedPaths` | `["auto"]` | アクセスを禁止するフォルダ |

## トラブルシューティング

- **別の PC からつながらない**
  - `jfs list` で「起動中」になっているか確認。なっていなければ `jfs logs <名前>` でエラーを確認
  - サーバー PC のネットワークが「パブリック」になっていないか (setup が警告を出します)。「プライベート」に変更してください
  - 接続元が別のサブネットの場合は `jfs set <名前> -AllowFrom 192.168.0.0/16` のように許可範囲を広げる
  - サーバー PC 上のブラウザで `http://localhost:8888/` が開けるか確認
- **コンピューター名でつながらない**: IP アドレスの URL を使うか、「ドメイン名でアクセスする」の 2 か 3 を設定してください
- **PC のスリープでつながらなくなる**: `setup.cmd -DisableSleep` で AC 電源時のスリープを無効にできます
- **ターミナルでスクリプト (Activate.ps1 など) が実行できない**: 実行ポリシーは RemoteSigned に設定済みです。
  インターネットから取得したスクリプトはブロックされることがあるので `Unblock-File` を使ってください
- **全部やり直したい**: `jfs remove <名前> -DeleteFiles` で各サーバーを削除し、`jfs unprotect` でアクセス禁止を解除します。
  グループ `jupyter-for-share-users` は「コンピューターの管理」から削除できます
