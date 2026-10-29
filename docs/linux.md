# Linux / Jetson ガイド

Linux の PC や NVIDIA Jetson を jupyter-for-share のサーバーにする手順と、管理に使うコマンドの説明です。
([README](../README.md) に戻る / [Windows の場合](windows.md))

- [必要なもの](#必要なもの)
- [セットアップ](#セットアップ)
- [ユーザー環境を作る・起動する](#ユーザー環境を作る起動する)
- [SSH で使う場合 (tmux)](#ssh-で使う場合-tmux)
- [コマンド一覧](#コマンド一覧)
- [他の PC からつながらないとき](#他の-pc-からつながらないとき)
- [NVIDIA Jetson で使う](#nvidia-jetson-で使う)
- [アクセスできる範囲](#アクセスできる範囲)
- [アンインストール](#アンインストール)
- [トラブルシューティング](#トラブルシューティング)

## 必要なもの

- Linux (Ubuntu 18.04 以降・Debian・Fedora など。Jetson の JetPack 4 / 5 / 6 を含む) と `sudo` を使える管理者
- インターネット接続 (JupyterLab などのダウンロード用)
- 接続する PC が同じ LAN にあること

Python (3.8 以上・venv 付き) と Git は、入っていなければ setup が `apt-get` / `dnf` などでインストールします (実行前に確認を求めます)。
既に入っている場合はそれを使います。

## セットアップ

1. リポジトリをクローンします。ユーザー環境はこのフォルダの中 (`user/`) に作られるので、空き容量のある場所に置いてください。

   ```bash
   cd ~
   git clone https://github.com/404background/jupyter-for-share.git
   cd jupyter-for-share
   ```

2. セットアップを実行します。`sudo` のパスワードを聞かれます。

   ```bash
   ./setup.sh
   ```

   オプション:

   | オプション | 内容 |
   | --- | --- |
   | `-Domain jupyter.home.arpa` | URL に表示するドメイン名 |
   | `-Port 9000` / `-SkipMonitor` | リソースモニターのポートを変える / 設置しない |

   setup が行うこと (何度実行しても問題ありません):

   | 内容 | 詳細 |
   | --- | --- |
   | 最新版への更新 | 最初に `git pull` (クローンした人のアカウントで実行。失敗したときはメッセージを表示して止まり、Enter で今のファイルのまま続行) |
   | Python / Git | インストール済みか確認し、無ければパッケージマネージャーでインストール (確認あり) |
   | 設定ファイル | `servers.json` を作成 (root だけが読めます。[設定項目](configuration.md)) |
   | 実行用グループ | `jupyter-for-share-users` |
   | 上の階層の通り抜け | このフォルダまでの上の階層 (例: `/home/you`) を、実行用アカウントが**通り抜けだけ**できるようにする (中の一覧は見えません。`setfacl` があればそのグループだけに許可) |
   | リソースモニター | 設置のみ (サーバー管理ウィンドウの中で動きます) |
   | ファイアウォール | ufw / firewalld が動いていれば、ポートの許可を追加 |
   | 既存のユーザー環境 | 起動用ファイルなどを新しいバージョンに合わせて作り直す |

## ユーザー環境を作る・起動する

`./jfs.sh` はこのフォルダで実行します。管理者の権限が必要なコマンドは、自動で `sudo` して実行し直します。

```bash
./jfs.sh add alice
./jfs.sh start
```

- `add` はユーザーの実行用アカウント (`jfs-alice`。ログインはできないアカウント)・フォルダ (`user/alice`)・JupyterLab・venv を作り、接続用 URL を表示します。
  ユーザー名は英小文字で始まる半角英数字とハイフン (16 文字以内) です
- `start` を実行した端末が**サーバー管理ウィンドウ**になり、全員のサーバーがその中で動きます。
  端末を閉じる (または Ctrl+C) と全員が停止します。別の端末で `./jfs.sh add` / `start <名前>` / `stop <名前>` を実行すると、サーバー管理ウィンドウ側で起動・停止されます
- PC の起動時に自動で起動する機能はありません。再起動後はもう一度 `./jfs.sh start` を実行してください

## SSH で使う場合 (tmux)

サーバー管理ウィンドウは端末を閉じると止まるため、SSH で接続して起動した場合は、**SSH を切るとサーバーも止まります**。
Jetson などを SSH で操作する場合は、`tmux` の中で起動してください。

```bash
sudo apt-get install -y tmux      # 入っていなければ
tmux new -s jfs                   # tmux の中で
./jfs.sh start                    # サーバーを起動
# Ctrl+B を押してから D で tmux を抜ける (サーバーは動いたまま)。SSH を切っても大丈夫
tmux attach -t jfs                # あとでサーバー管理ウィンドウに戻る
```

## コマンド一覧

`./jfs.sh help` で一覧が表示されます。オプションは `-Port 23456` でも `--port 23456` でも構いません。

| コマンド | 内容 |
| --- | --- |
| `./jfs.sh add <名前>` | ユーザー環境を作成 |
| `./jfs.sh list` | ユーザー環境とリソースモニターの一覧・状態 |
| `./jfs.sh url [名前]` | 接続用 URL を表示 (省略で全員分 + リソースモニター) |
| `./jfs.sh start [名前]` | 起動 (省略で全員)。サーバー管理ウィンドウが無ければ、この端末がそれになる |
| `./jfs.sh stop [名前]` | 停止 (省略で全員。サーバー管理ウィンドウも終了) |
| `./jfs.sh restart [名前]` | 再起動 (更新を反映するときなど) |
| `./jfs.sh remove <名前> [-KeepFiles] [-Force]` | 環境をフォルダごと削除 (`-KeepFiles` でフォルダは残す) |
| `./jfs.sh token <名前> -New` | トークンを再発行 (古い URL は使えなくなる) |
| `./jfs.sh set <名前> -Port 23456` | ポートを変更 (`-AllowFrom 192.168.0.0/16` で接続を許可する相手も変更) |
| `./jfs.sh logs <名前> [-Follow]` | 実行したコマンドの記録とサーバーのログ (`logs monitor` でモニターのログ) |
| `./jfs.sh upgrade [名前]` | JupyterLab 本体を最新にする (venv のパッケージはそのまま) |
| `./jfs.sh reset-venv <名前> [-Venv sam3_env] [-Clean]` | venv を修復 (Python 本体・pip・ipykernel を本人のアカウントで確かめ、壊れているものだけ直す。入れたパッケージは残す)。`-Venv` で本人が work に作った venv、`-Clean` で空の状態から作り直し |
| `./jfs.sh monitor [-Port 8000]` / `monitor-stop` | リソースモニターを設置・変更 / 停止 |
| `./jfs.sh network [-Yes]` | 他の PC から接続できるように、ファイアウォールと mDNS を確認・設定 |
| `./jfs.sh doctor [名前]` | つながらないときの診断 (`[NG]` の項目に原因を表示) |
| `./jfs.sh refresh` | 全ユーザーの起動用ファイルを作り直す (setup から自動で実行) |
| `./jfs.sh version` | バージョン (git のコミット) |
| `./uninstall.sh [-DeleteFiles]` | すべて元に戻す ([アンインストール](#アンインストール)) |

Windows 版にある `autostart`・`protect`・`firewall` は Linux 版にはありません (`firewall` の代わりは `network`)。

## 他の PC からつながらないとき

```bash
./jfs.sh network
```

現在の状態 (アドレス・ファイアウォールの許可・mDNS) を表示し、必要な変更を一覧にして確認 (`y`) のうえ適用します。

| 確認・変更 | 内容 |
| --- | --- |
| ファイアウォール | ufw / firewalld が動いていれば、各ポートを同じサブネットから許可 (動いていなければ変更不要) |
| mDNS (`<名前>.local`) | `avahi-daemon` が無ければインストール、止まっていれば起動 |

`<コンピューター名>.local` でつながらない場合は、IP アドレスの URL を使うか、ルーターや接続する PC の hosts に名前を登録してください
([Windows ガイドの説明](windows.md#名前-ドメイン名-でアクセスする)と同じです)。コンピューター名は `sudo hostnamectl set-hostname jupyter-pc` で変えられます。

## NVIDIA Jetson で使う

Jetson (AGX Xavier・Xavier NX・Orin など) でも同じ手順で使えます。Jetson 向けに次のことを自動で行います。

| 内容 | 詳細 |
| --- | --- |
| GPU を使えるようにする | Jetson で CUDA を使うには `video` グループが必要なため、各ユーザーのサーバーに `video` (と `render`) グループを付けて動かします |
| JetPack のパッケージを使えるようにする | ユーザーの venv を `--system-site-packages` 付きで作ります。JetPack が OS に入れる TensorRT・OpenCV (CUDA 対応) などを、venv からそのまま `import` できます |
| GPU の使用率 | `nvidia-smi` が無いので、リソースモニターは `/sys` から GPU の使用率と温度を読みます (GPU のメモリは CPU と共有のため、メモリの欄を見てください) |
| CUDA のコマンド | `/usr/local/cuda/bin` (nvcc など) をターミナルの PATH に入れます |

### JetPack のバージョンと Python

| JetPack | Ubuntu | OS の Python | 動作 |
| --- | --- | --- | --- |
| 6.x (Orin) | 22.04 | 3.10 | そのまま使えます |
| 5.x (Xavier / Orin) | 20.04 | 3.8 | そのまま使えます (**Xavier ではこちらをおすすめします**) |
| 4.x (Xavier / Nano / TX2) | 18.04 | 3.6 | JupyterLab には 3.8 以上が必要なため、setup が `python3.8` を追加でインストールして使います。ただし JetPack の TensorRT・OpenCV は 3.6 用なので、venv からは使えません |

### Jetson でのヒント

- **PyTorch**: Jetson 用の PyTorch は NVIDIA が配布しているもの (JetPack と Python のバージョンに合ったもの) を使います。
  管理者が OS 側 (`sudo pip3 install ...`) に入れておくと、`--system-site-packages` により全員の venv から使えます。
  各ユーザーが自分の venv に入れることもできます (ターミナルで `pip install <配布元の .whl の URL>`)
- **パッケージのビルド**: aarch64 用のビルド済みパッケージが無いものは、インストール時にビルドが必要です。
  `sudo apt-get install -y build-essential python3-dev` を入れておくと、多くの場合ビルドできます
- **性能**: 最大性能で動かすには `sudo nvpmodel -m 0` と `sudo jetson_clocks` (電力・発熱が増えます)
- **メモリ**: JupyterLab 1 人分で数百 MB、カーネルごとにさらに使います。メモリの少ない機種 (8 GB など) では人数を絞ってください
- **SSH で操作する場合**は、[tmux の中で起動](#ssh-で使う場合-tmux)してください
- OS 側に入っているパッケージを使わせたくない場合は、`servers.json` の `defaults.venvSystemSitePackages` を `false` にします ([設定項目](configuration.md))

## アクセスできる範囲

各ユーザーのサーバー (ノートブック・ターミナルを含む) は、そのユーザー専用のアカウント (`jfs-<名前>`) の権限で動きます。

| 対象 | 実行用アカウントからのアクセス |
| --- | --- |
| 自分の環境 (`work`, `venv`, `.logs` など) | 読み書きできる (本人だけ) |
| 自分の `.server` (JupyterLab 本体・サーバーの設定) | 読み取りのみ |
| 他のユーザーの環境 | できない (一覧も見えない) |
| `servers.json` (全員のトークン) | できない (root のみ) |
| 管理者などのホームフォルダ | Ubuntu 21.04 以降などの既定 (750) ではできない。古い OS では読めることがあるので注意 |
| `/usr`・`/etc` などのシステムのファイル | 一般ユーザーと同じ (読めるものは読める。変更はできない) |
| `/tmp` | 一般ユーザーと同じく使える |
| インターネット・LAN | 使える (pip / git のため) |

Linux では一般ユーザーがシステムや他の人のファイルを変更できない仕組みが最初からあるため、Windows 版の「アクセス禁止」(`protect`) のような追加設定はありません。

## アンインストール

```bash
./uninstall.sh
```

1. サーバー・リソースモニターの停止
2. ファイアウォール規則の削除 (jupyter-for-share が追加したもの)
3. 実行用アカウント (`jfs-*`, `jfsmon`) とグループの削除
4. 上の階層に付けた通り抜けの許可を元に戻す
5. 実行時のファイルの削除 (`servers.json` は `servers.json.uninstalled` として残す。トークンを含むので扱いに注意)
6. ユーザーのフォルダ (`user/`) は残し、持ち主を sudo した人に変更 (`./uninstall.sh -DeleteFiles` で削除)

残したフォルダは、再セットアップ後に同じ名前で `./jfs.sh add <名前>` を実行すると、中身 (ノートブック・venv など) をそのまま引き継ぎます。

## トラブルシューティング

まず `./jfs.sh doctor` (1 人分なら `./jfs.sh doctor <名前>`) を実行してください。`<名前>` を付けると、
実行用アカウントとして `/` から作業フォルダまでの各場所をたどれるかもテストします。

| 症状 | 対処 |
| --- | --- |
| 別の PC からつながらない | `./jfs.sh list` で「起動中」か確認 → `./jfs.sh network` → サーバー上で `curl http://localhost:<ポート>/` |
| 起動に失敗し `Permission denied` が出る | `./jfs.sh doctor <名前>` で NG の場所を確認。上の階層の権限を変えた場合は、サーバー管理ウィンドウを開き直すと直します |
| `<名前>.local` でつながらない | `./jfs.sh network` で avahi-daemon を確認。だめなら IP アドレスの URL を使う |
| SSH を切るとサーバーが止まる | [tmux の中で起動](#ssh-で使う場合-tmux) |
| pip のインストールでビルドに失敗する | `sudo apt-get install -y build-essential python3-dev` |
| プロキシ環境で pip が失敗する | 管理者の環境変数 (`https_proxy` など) を引き継ぎます。`sudo` 前のシェルで設定してから実行してください |
| Jetson で CUDA が使えない | `./jfs.sh doctor` で確認。`video` グループがあるか (`getent group video`)、`defaults.extraGroups` を変えていないか |
| GPU が表示されない | NVIDIA の PC は `nvidia-smi` が動くか、Jetson は `/sys/devices/gpu.0/load` などがあるか。`./jfs.sh logs monitor` も確認 |
| 全部やり直したい | `./uninstall.sh` → `./setup.sh` |
