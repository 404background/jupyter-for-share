# jupyter-for-share

Windows PC を JupyterLab サーバーにして、LAN 内の別の PC からブラウザで使うためのセットアップスクリプトです。

- **ユーザー名を指定するだけ**でユーザーごとの環境を作れます (`jfs add alice`)。ポートは空いている番号が自動 (ランダム) で割り当てられます
- 環境は**このリポジトリの `user` フォルダの中にユーザーごとに作られ**、各環境は**自分のフォルダの中だけ**読み書きできます
- ノートブック・**ターミナル (PowerShell)** の両方が使えます
- パッケージはユーザーごとの **Python 仮想環境 (venv)** に `pip install` で自由に入れられます。`git clone` も使えます
- **リソースモニター**専用のポート (既定 8000) で、サーバーの CPU・メモリ・GPU の使用率をブラウザで確認できます
- **コンピューター名やドメイン名**でアクセスできます (例: `http://jupyter-pc:23456/`)
- Docker は使いません。Windows 標準の機能 (ローカルアカウント・NTFS アクセス権・タスクスケジューラ・ファイアウォール) で構成します

## 仕組み

```
jupyter-for-share\                    ← このリポジトリ (管理者だけが読み書きできるように設定されます)
├─ setup.cmd / jfs.cmd               ← セットアップ / 管理コマンド
├─ servers.json                      ← 設定 (各ユーザーのポート・トークン)
├─ monitor\                          ← リソースモニター (ポート 8000 / アカウント jfsmon で実行)
└─ user\
    ├─ alice\                        ← ユーザー alice の環境 (ポート例 23456 / アカウント jfs-alice で実行)
    │   ├─ work\                     ← JupyterLab のルート。ノートブックや git clone したものはここ
    │   │   └─ README.md             ← 本人向けの説明 (環境とリソースモニターのアドレス)
    │   ├─ venv\                     ← パッケージを入れる venv (カーネル・ターミナルの python/pip)
    │   └─ .server\                  ← JupyterLab 本体・設定・ログ (隠しフォルダ)
    └─ bob\                          ← ユーザー bob の環境 (別のポート / アカウント jfs-bob)
```

- 各環境は専用の Windows ローカルアカウント (`jfs-<ユーザー名>`) として動きます。JupyterLab だけでなく、
  ノートブックのコードやターミナルもこのアカウントの権限で動くため、**NTFS のアクセス権で読み書きできる範囲が制限**されます。
  (JupyterLab の設定だけで制限すると、ターミナルやコードからは PC 中のファイルが見えてしまうため、この方式にしています)
- サーバー実行用アカウントは画面からのサインイン・リモートデスクトップ・ネットワーク共有へのログオンが禁止され、サインイン画面にも表示されません。
- タスクスケジューラで起動するので、**誰もサインインしていなくても**PC の起動時に自動で動きます。
- リポジトリのフォルダ (スクリプトや `servers.json`) はサーバー実行用アカウントからは読み書きできません。

## 必要なもの

- Windows 10 / 11 (64bit)。サーバーとして使う PC の管理者権限
- インターネット接続 (Python・Git・JupyterLab のダウンロード用)
- 接続する PC と同じ LAN
- (GPU の使用率表示) NVIDIA の GPU はドライバ付属の `nvidia-smi` で詳しく表示します。その他の GPU も Windows の情報から使用率を表示します

## セットアップ (サーバー PC で 1 回だけ)

1. このリポジトリをサーバー PC にクローンします。
   ユーザー環境はこのフォルダの中に作られるので、空き容量があり、パスに日本語や空白が無い場所 (例: `C:\jupyter-for-share`) をおすすめします。

   ```bat
   cd C:\
   git clone https://github.com/404background/jupyter-for-share.git
   cd jupyter-for-share
   ```

   (Git が無い場合は ZIP をダウンロードして展開しても構いません)

2. `setup.cmd` をダブルクリック (またはコマンドプロンプトで実行) します。管理者権限の確認が出たら「はい」を選びます。

   ```bat
   setup.cmd
   rem オプションの例: ドメイン名を設定し、スリープを無効にする
   setup.cmd -Domain jupyter.home.arpa -DisableSleep
   ```

setup で行うこと:

| 内容 | 詳細 |
| --- | --- |
| Python / Git のインストール | winget で全ユーザー向けにインストール (インストール済みならスキップ) |
| 設定ファイル作成 | `servers.json` (`servers.example.json` をコピー) |
| サーバー実行用グループ | `jupyter-for-share-users` を作成し、ログオン権限を設定 |
| フォルダのアクセス権 | このリポジトリ・`user` フォルダ・`C:\ProgramData\jupyter` を管理者以外が変更できないようにする |
| 他フォルダへのアクセス禁止 | 後述の「アクセス制限」。バックグラウンドで実行されるので setup はすぐ終わります (`-SkipProtect` で省略可) |
| リソースモニター | ポート 8000 で起動 (`-MonitorPort 9000` で変更、`-SkipMonitor` で省略可) |

## ユーザー環境を作る・管理する

`jfs.cmd` を使います (管理者権限が必要です。通常のコマンドプロンプトから実行すると UAC の確認が出ます)。

```bat
rem ユーザー alice の環境を作成して起動 (フォルダ: user\alice、ポートは自動)
jfs add alice
```

作成が終わると接続用 URL (トークン付き) が表示されるので、本人に伝えてください。
ユーザー名は半角英数字とハイフン (16 文字以内) で、大文字は小文字に変換されます。

| コマンド | 内容 |
| --- | --- |
| `jfs list` | ユーザー環境とリソースモニターの一覧・状態・ポート |
| `jfs url [ユーザー名]` | 接続用 URL を表示 (省略で全員分 + リソースモニター) |
| `jfs start / stop / restart [ユーザー名]` | 起動 / 停止 / 再起動 (省略すると全員)。停止した環境は PC を再起動しても止まったまま |
| `jfs token <ユーザー名> -New` | アクセストークン (パスワード代わり) を再発行 |
| `jfs set <ユーザー名> -Port 23456` | ポートを固定の番号に変更 (`-AllowFrom` で接続を許可する相手も変更可) |
| `jfs logs <ユーザー名> [-Follow]` | ログを表示 (`jfs logs monitor` でリソースモニターのログ) |
| `jfs upgrade [ユーザー名]` | JupyterLab 本体を更新 |
| `jfs reset-venv <ユーザー名>` | venv を作り直す (入れたパッケージを初期化) |
| `jfs remove <ユーザー名> [-DeleteFiles]` | 環境を削除。`-DeleteFiles` を付けるとフォルダも削除 |
| `jfs monitor [-Port 8000]` | リソースモニターを設置・更新して起動 |
| `jfs monitor-stop` | リソースモニターを停止 |
| `jfs firewall` | ファイアウォール規則を作り直す |
| `jfs protect [-Background]` | 他フォルダへのアクセス禁止を設定 (設定済みの場所は飛ばす。`-Force` で付け直し) |
| `jfs protect -Status` | アクセス禁止の設定状況 (バックグラウンド処理の進み具合) |
| `jfs unprotect` | アクセス禁止を解除 |

## 別の PC から接続する

`jfs url` で表示される URL をブラウザで開きます。

```
http://jupyter.home.arpa:23456/lab?token=xxxx   ← setup で -Domain を指定した場合
http://jupyter-pc:23456/lab?token=xxxx          ← コンピューター名
http://jupyter-pc.local:23456/lab?token=xxxx    ← mDNS (Mac / iPhone / Linux など)
http://192.168.1.10:23456/lab?token=xxxx        ← IP アドレス
```

一度開くとブラウザに記憶されるので、2 回目以降は `http://jupyter-pc:23456/` だけで入れます。
トークンはパスワードと同じなので、本人以外に知られないようにしてください。

各ユーザーの `work` フォルダには、本人向けの短い `README.md` (自分の環境とリソースモニターのアドレス、使い方) が自動で作られます。
JupyterLab を開くとファイル一覧に表示されます。

## リソースモニター

`http://<サーバー>:8000/` をブラウザで開くと、次の情報が 2 秒ごとに更新されます (トークンは不要です)。

- CPU 使用率 (全体・コアごと・直近 5 分のグラフ)
- メモリ使用量
- GPU 使用率・GPU メモリ・温度・消費電力 (NVIDIA の場合。その他の GPU は使用率と使用メモリ)
- ユーザー環境のフォルダがあるディスクの使用量
- 各ユーザー環境の稼働状況とリンク

モニターも専用アカウント (`jfsmon`) で動き、他のフォルダにはアクセスできません。

## ドメイン名でアクセスする

IP アドレスの代わりに名前でアクセスする方法は 3 つあります。

1. **コンピューター名** (設定不要): 同じ LAN の Windows PC からは `http://<コンピューター名>:<ポート>/` で通常つながります。
   分かりやすい名前にしたい場合は、サーバー PC の名前を変更します (`Rename-Computer -NewName jupyter-pc` → 再起動)。
   Mac などからは `http://jupyter-pc.local:<ポート>/` を試してください。
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

JupyterLab のターミナルを開くと PowerShell が `work` フォルダで起動し、`python` / `pip` はそのユーザーの venv を指しています。

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

| 対象 | サーバー実行用アカウント (jfs-xxx) からのアクセス |
| --- | --- |
| 自分の環境のフォルダ (`work`, `venv` など) | 読み書きできる |
| 自分の `.server\jupyterlab`, `.server\config` (JupyterLab 本体・設定) | 読み取りのみ |
| 他のユーザーの環境、このリポジトリのスクリプト・設定ファイル | できない |
| 他の Windows ユーザーのプロファイル (`C:\Users\<名前>`、デスクトップ・ドキュメントなど) | できない (Windows の既定) |
| システムドライブ以外のドライブ (D:\ など)、`C:\` 直下の独自フォルダ、`C:\Users\Public` | できない (`jfs protect` で拒否を設定) |
| `C:\Windows`, `C:\Program Files` など OS・アプリ | 読み取りのみ (Python・Git を動かすために必要) |
| インターネット・LAN | 使える (pip / git のため) |

- 禁止するフォルダは `servers.json` の `defaults.protectedPaths` で変更できます。`"auto"` は上の表の自動選択で、
  `["auto", "C:\\data"]` のようにパスを追加できます。変更したら `jfs protect` を実行してください。
  (後から作ったドライブやフォルダも `jfs protect` を再実行すると対象になります)
- このリポジトリを含む `C:\` 直下のフォルダ (例: `C:\tools\jupyter-for-share` の `C:\tools`) は、自動選択の対象から外れます。
  リポジトリは `C:\jupyter-for-share` のように専用の場所に置くのがおすすめです。
- **処理時間について**: Windows のアクセス権 (NTFS) は、フォルダに付けた設定が中のファイル 1 つ 1 つにコピーされる仕組みのため、
  初回はドライブ内のファイル数に比例して時間がかかります (数分〜数十分)。次の工夫で待ち時間を減らしています。
  - setup ではバックグラウンドで実行し、すぐに次の作業 (`jfs add` など) に進めます。進み具合は `jfs protect -Status` で確認できます
  - 複数のドライブ・フォルダを並列に処理します
  - 2 回目以降は、設定済みの場所を飛ばします (新しく作られたファイルには自動で引き継がれるので付け直し不要)
- 「許可した場所以外をすべて禁止する」方式 (ホワイトリスト) も検討しましたが、Windows では
  サーバー実行用アカウントが「Authenticated Users」などの標準グループに必ず含まれ、多くのフォルダがそのグループに読み取りを許可しているため、
  アクセス権だけで実現するには結局それらのフォルダ側に拒否を付ける必要があり、速くなりません。
  (AppContainer などのサンドボックスを使えば可能ですが、Python・pip・git・ターミナルの動作に制約が出るため採用していません)
- 通信は HTTP (暗号化なし) です。信頼できる LAN 内で使い、インターネットには公開しないでください。
  ファイアウォールは既定で同じサブネット (`LocalSubnet`) からの接続だけを許可します。
- セットアップ後、このリポジトリのフォルダは管理者だけが読み書きできます。`git pull` などは管理者として実行してください。

## 設定ファイル (servers.json)

`setup.cmd` で `servers.example.json` からコピーされます。トークンが含まれるので共有しないでください (`.gitignore` 済み)。

| キー | 既定値 | 内容 |
| --- | --- | --- |
| `defaults.instancesRoot` | (空 = このリポジトリの `user`) | ユーザー環境を作る場所 |
| `defaults.python` | (自動検出) | 使う Python (全ユーザー向けにインストールされたもの) |
| `defaults.domain` | (なし) | URL に表示するドメイン名 |
| `defaults.portRange` | `[20000, 29999]` | ユーザー環境のポートをランダムに選ぶ範囲 |
| `defaults.bindAddress` | `0.0.0.0` | 待ち受けるアドレス |
| `defaults.allowFrom` | `["LocalSubnet"]` | ファイアウォールで接続を許可する相手 |
| `defaults.firewallProfiles` | `Domain,Private` | ファイアウォール規則を有効にするネットワークの種類 |
| `defaults.labLocale` | `ja_JP` | JupyterLab の表示言語 (`en` で英語) |
| `defaults.extraServerPackages` | `[]` | JupyterLab 側に追加する拡張機能など (例: `"jupyterlab-git"`) |
| `defaults.venvPackages` | `[]` | 新しく作る venv に最初から入れるパッケージ |
| `defaults.protectedPaths` | `["auto"]` | アクセスを禁止するフォルダ |
| `monitor.port` | `8000` | リソースモニターのポート (`jfs monitor -Port` で変更) |

## ライセンス

このリポジトリのスクリプト・ドキュメントは [MIT License](LICENSE) で公開しています。

セットアップ時に次のソフトウェアをインターネットからインストールしますが、このリポジトリには含まれていません。
それぞれのライセンスに従って利用してください。

| ソフトウェア | ライセンス | 用途 |
| --- | --- | --- |
| [Python](https://www.python.org/) | PSF License | 実行環境 |
| [Git for Windows](https://gitforwindows.org/) | GPL v2 | git clone など |
| [JupyterLab](https://github.com/jupyterlab/jupyterlab) / [ipykernel](https://github.com/ipython/ipykernel) | BSD 3-Clause | ノートブック・ターミナル |
| [jupyterlab-language-pack-ja-JP](https://github.com/jupyterlab/language-packs) | BSD 3-Clause | 日本語表示 |
| [psutil](https://github.com/giampaolo/psutil) | BSD 3-Clause | リソースモニター |

## トラブルシューティング

- **別の PC からつながらない**
  - `jfs list` で「起動中」になっているか確認。なっていなければ `jfs logs <ユーザー名>` でエラーを確認
  - サーバー PC のネットワークが「パブリック」になっていないか (setup が警告を出します)。「プライベート」に変更してください
  - 接続元が別のサブネットの場合は `jfs set <ユーザー名> -AllowFrom 192.168.0.0/16` のように許可範囲を広げる
  - サーバー PC 上のブラウザで `http://localhost:<ポート>/` が開けるか確認
- **コンピューター名でつながらない**: IP アドレスの URL を使うか、「ドメイン名でアクセスする」の 2 か 3 を設定してください
- **GPU が表示されない**: NVIDIA の場合はドライバが入っているか (`nvidia-smi` が動くか) を確認してください。`jfs logs monitor` にエラーが出ていないかも確認できます
- **PC のスリープでつながらなくなる**: `setup.cmd -DisableSleep` で AC 電源時のスリープを無効にできます
- **ターミナルでスクリプト (Activate.ps1 など) が実行できない**: 実行ポリシーは RemoteSigned に設定済みです。
  インターネットから取得したスクリプトはブロックされることがあるので `Unblock-File` を使ってください
- **アクセス禁止の設定が終わったか知りたい**: `jfs protect -Status` で、実行中かどうか・設定済みの場所・ログの末尾が表示されます
- **全部やり直したい**: `jfs remove <ユーザー名> -DeleteFiles` で各環境を削除し、`jfs monitor-stop`、`jfs unprotect` を実行します。
  アカウント `jfsmon` とグループ `jupyter-for-share-users` は「コンピューターの管理」から削除できます
