# 環境を使う人向けの説明

管理者から受け取った URL で、自分専用の JupyterLab 環境を使えます。このページは、そのまま利用者に渡せるように書いています。
([README](../README.md) に戻る)

## 開き方

1. 管理者から受け取った URL (`http://<サーバー名>.local:<ポート>/lab?token=...`) をブラウザで開きます
2. 一度開けば、2 回目以降は `http://<サーバー名>.local:<ポート>/lab` だけで開けます (ブラウザに記憶されます)
3. つながらない場合は、IP アドレスの URL (`http://192.168.x.x:<ポート>/lab?token=...`) を試すか、管理者に連絡してください

URL の `token=` の部分はパスワードと同じです。他の人に教えないでください。

## ファイルの保存場所

- JupyterLab の左のファイル一覧に表示される場所 (`work` フォルダ) が自分の作業場所です。ノートブックやデータはここに保存してください
- 他の人の環境や、サーバーの他のフォルダは見えません
- `work` にある `README.md` には、自分の環境とリソースモニターのアドレスが書かれています

## パッケージのインストール

自分専用の Python 仮想環境 (venv) に、自由にパッケージを入れられます。

```
pip install numpy pandas            # ターミナルで
%pip install numpy pandas           # ノートブックのセルで
```

インストールしたら、ノートブックのカーネルを再起動してください (メニューの Kernel → Restart Kernel)。
venv を初期状態に戻したいときは管理者に依頼してください (`work` のファイルは消えません)。

## 別の venv を作る (プロジェクトごと・別のバージョンの Python など)

自分で書き込めるのは **`work` フォルダの中だけ**です。venv も `work` の中に作ってください
(`work` の一つ上のフォルダ `user\<名前>` などに作ろうとすると「アクセスが拒否されました」/「Permission denied」になります)。

Windows のサーバー (ターミナルは PowerShell):

```powershell
python -m venv sam3_env                         # work の中に作られる (py -3.12 -m venv sam3_env のように版も指定できます)
.\sam3_env\Scripts\python -m pip install ipykernel
.\sam3_env\Scripts\python -m ipykernel install --user --name sam3 --display-name "Python (sam3)"
```

Linux / Jetson のサーバー (ターミナルは bash):

```bash
python3 -m venv sam3_env
./sam3_env/bin/python -m pip install ipykernel
./sam3_env/bin/python -m ipykernel install --user --name sam3 --display-name "Python (sam3)"
```

最後の行でノートブックのカーネルとして登録され、JupyterLab を再読み込みすると「Python (sam3)」を選べるようになります。

ノートブックから作る場合は、パスを `work` の中にします。`os.getcwd()` はそのノートブックがあるフォルダです。

```python
import os, subprocess, sys
target = os.path.join(os.getcwd(), "sam3_env")          # work の中
result = subprocess.run([sys.executable, "-m", "venv", target], capture_output=True, text=True)
print(result.returncode, result.stderr)
```

## ターミナルと git

メニューの File → New → Terminal でターミナルが開きます (Windows のサーバーでは PowerShell、Linux のサーバーでは bash)。
`python` と `pip` は自分の venv を指しています。

```
git clone https://github.com/xxx/yyy.git
```

HTTPS で非公開リポジトリを使う場合は、ターミナルでユーザー名と個人アクセストークンを入力します。

## サーバーの混み具合を見る

`http://<サーバー名>.local:8000/` (リソースモニター) で、サーバーの CPU・メモリ・GPU の使用率を確認できます。
重い処理を始める前に確認してください。

## 知っておいてほしいこと

- サーバーは管理者が起動している間だけ使えます。サーバーの再起動などで止まることがあるので、作業はこまめに保存してください
- 管理者は、サーバーの動作確認のために、ターミナルで実行したコマンドとノートブックで実行したセルの記録を見られます
- 通信は暗号化されていません。パスワードなどの秘密の情報をノートブックに書かないでください
