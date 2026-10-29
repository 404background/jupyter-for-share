# jupyter-for-share

1 台の PC を JupyterLab サーバーにして、同じ LAN の別の PC からブラウザで使うためのツールです。
**Windows** と **Linux** (Ubuntu などのほか、**NVIDIA Jetson** も可) で動きます。Docker は使いません。

- ユーザー名を指定するだけで、ユーザーごとの環境を作れます (ポートは自動で割り当て)
- 各ユーザーは**自分のフォルダの中だけ**読み書きでき、他の人のフォルダは見えません
- ノートブックとターミナルの両方が使え、`pip install` や `git clone` も自由にできます (ユーザーごとの venv)
- 起動したウィンドウ (端末) に全員のログと実行したコマンドが表示され、**閉じると全員のサーバーが止まります**
- CPU・メモリ・GPU の使用率を見られる**リソースモニター** (ポート 8000) 付き
- `http://<コンピューター名>.local:<ポート>/` のように名前でアクセスできます

```
別の PC のブラウザ ──→ http://jupyter-pc.local:23456/lab   (alice さんの環境)
                   ──→ http://jupyter-pc.local:27811/lab   (bob さんの環境)
                   ──→ http://jupyter-pc.local:8000/       (リソースモニター)
```

## はじめかた

サーバーにする PC で、管理者が次の 3 つを行います。詳しい説明は OS ごとのガイドを見てください。

### Windows の場合 ([詳しいガイド](docs/windows.md))

```bat
cd C:\
git clone https://github.com/404background/jupyter-for-share.git
cd jupyter-for-share

rem 1. セットアップ (管理者権限の確認で「はい」。最初の 1 回だけ)
setup.cmd
rem 2. ユーザー alice の環境を作る (接続用 URL が表示される)
jfs.cmd add alice
rem 3. サーバーを起動 (このウィンドウを開いている間だけ動く)
jfs.cmd start
```

### Linux / Jetson の場合 ([詳しいガイド](docs/linux.md))

```bash
cd ~
git clone https://github.com/404background/jupyter-for-share.git
cd jupyter-for-share

./setup.sh                # 1. セットアップ (sudo のパスワードを聞かれます。最初の 1 回だけ)
./jfs.sh add alice        # 2. ユーザー alice の環境を作る (接続用 URL が表示される)
./jfs.sh start            # 3. サーバーを起動 (この端末を開いている間だけ動く)
```

ここから先のコマンドは、Windows では `jfs.cmd`、Linux では `./jfs.sh` と読み替えてください (使い方は同じです)。

## 別の PC から使う

`jfs.cmd add` や `jfs.cmd url` で表示される URL を、使う人に伝えます。

```
http://jupyter-pc.local:23456/lab?token=xxxxxxxx   ← コンピューター名 + .local
http://192.168.1.10:23456/lab?token=xxxxxxxx       ← IP アドレス (名前でつながらない場合)
```

- `token=` の後ろはパスワードの代わりです。**本人にだけ**伝えてください (`jfs.cmd token <名前> -New` で再発行)
- 一度開けば、2 回目以降は `http://jupyter-pc.local:23456/lab` だけで開けます
- 使う人向けの説明は [docs/for-users.md](docs/for-users.md) にまとめてあります (各ユーザーの `work` フォルダにも短い README が自動で置かれます)

## ふだんの操作

| やりたいこと | コマンド |
| --- | --- |
| サーバーを起動する (実行したウィンドウがサーバー管理ウィンドウになる) | `jfs.cmd start` |
| 全員のサーバーを止める | サーバー管理ウィンドウを閉じる / Ctrl+C / `jfs.cmd stop` |
| ユーザーを追加する | `jfs.cmd add <名前>` |
| 1 人だけ止める・起動する・再起動する | `jfs.cmd stop <名前>` / `start <名前>` / `restart <名前>` |
| 一覧と状態を見る | `jfs.cmd list` |
| 接続用 URL をもう一度表示する | `jfs.cmd url [名前]` |
| ログと、その人が実行したコマンドを見る | `jfs.cmd logs <名前>` |
| ユーザーを削除する (フォルダごと) | `jfs.cmd remove <名前>` (`-KeepFiles` でフォルダは残す) |
| venv が壊れたので直す (入れたパッケージは残す) | `jfs.cmd reset-venv <名前>` (work に作った venv は `-Venv <フォルダ名>`) |
| つながらない原因を調べる | `jfs.cmd doctor [名前]` / 別の PC からだけつながらないときは `jfs.cmd network` |
| コマンドの一覧・詳しい説明 | `jfs.cmd help` / `jfs.cmd help <コマンド>` |

サーバー管理ウィンドウには、全員のサーバーのログと実行したコマンドが `[名前]` 付きで流れます。
サーバーが異常終了しても 10 秒後に自動で再起動します。PC を再起動したあとは、もう一度 `jfs.cmd start` を実行してください。

## 更新

- サーバー管理ウィンドウが開いている間は、**1 時間ごとに自動で `git pull`** して、サーバーを止めずに管理側の処理を新しくします
  (JupyterLab 側に関わる変更は、各ユーザーの次の起動から反映。すぐ反映するには `jfs.cmd restart`)
- 手動で更新するときや、セットアップの内容が変わったときは、`setup.cmd` (Linux は `./setup.sh`) をもう一度実行します。
  ユーザーの環境やトークンはそのまま残ります

## アンインストール

`uninstall.cmd` (Linux は `./uninstall.sh`) を実行すると、この PC に加えた変更 (実行用アカウント・ファイアウォール規則・アクセス権など) をすべて元に戻します。
ユーザーのフォルダ (`user/`) は残ります (`-DeleteFiles` で削除)。残したフォルダは、再セットアップ後に同じ名前で `add` すると中身ごと引き継げます。

## ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [docs/windows.md](docs/windows.md) | Windows での準備・セットアップ・全コマンド・ネットワーク設定・アクセス制限・トラブルシューティング |
| [docs/linux.md](docs/linux.md) | Linux / **Jetson** での準備・セットアップ・全コマンド・ネットワーク設定・Jetson の注意点・トラブルシューティング |
| [docs/for-users.md](docs/for-users.md) | 環境を使う人向け (開き方・保存場所・pip・git・ターミナル) |
| [docs/configuration.md](docs/configuration.md) | 設定ファイル `servers.json` の項目 |
| [docs/how-it-works.md](docs/how-it-works.md) | 仕組み (フォルダ構成・実行用アカウント・サーバー管理ウィンドウ・ログ・自動更新・安全性) |

## 注意

- 通信は HTTP (暗号化なし) です。**信頼できる LAN 内で使い、インターネットには公開しないでください**。
  ファイアウォールは既定で同じサブネットからの接続だけを許可します
- 実行したコマンドの記録は、利用者自身の権限で書かれる操作確認用のものです (改ざんできない監査ログではありません)

## ライセンス

このリポジトリのスクリプト・ドキュメントは [MIT License](LICENSE) で公開しています。

セットアップ時に次のソフトウェアをインターネットからインストールしますが、このリポジトリには含まれていません。それぞれのライセンスに従って利用してください。

| ソフトウェア | ライセンス | 用途 |
| --- | --- | --- |
| [Python](https://www.python.org/) | PSF License | 実行環境 |
| [Git](https://git-scm.com/) / [Git for Windows](https://gitforwindows.org/) | GPL v2 | git clone など |
| [JupyterLab](https://github.com/jupyterlab/jupyterlab) / [ipykernel](https://github.com/ipython/ipykernel) | BSD 3-Clause | ノートブック・ターミナル |
| [jupyterlab-language-pack-ja-JP](https://github.com/jupyterlab/language-packs) | BSD 3-Clause | 日本語表示 |
| [psutil](https://github.com/giampaolo/psutil) | BSD 3-Clause | リソースモニター |
