# 設定ファイル (servers.json)

([README](../README.md) に戻る)

setup が `servers.example.json` をコピーして `servers.json` を作ります。
各ユーザーのポートと**トークン**が含まれるので、共有しないでください (Git の管理対象外です。Linux では root だけが読めます)。

設定を変えたあとは、`jfs.cmd refresh` (Linux は `./jfs.sh refresh`) と `jfs.cmd restart` で反映します。
ファイアウォールに関わる項目 (`allowFrom` など) は `jfs.cmd firewall` (Linux は `./jfs.sh network`) も実行してください。

## defaults (全ユーザー共通)

| キー | 既定値 | 内容 | 対応 OS |
| --- | --- | --- | --- |
| `instancesRoot` | (空 = このリポジトリの `user`) | ユーザー環境を作る場所 | 共通 |
| `python` | (自動検出) | JupyterLab と venv に使う Python のパス | 共通 |
| `domain` | (なし) | URL に表示するドメイン名 (setup の `-Domain` で設定) | 共通 |
| `portRange` | `[20000, 29999]` | ユーザー環境のポートを選ぶ範囲 | 共通 |
| `bindAddress` | `0.0.0.0` | 待ち受けるアドレス (`0.0.0.0` はすべて) | 共通 |
| `allowFrom` | `["LocalSubnet"]` | ファイアウォールで接続を許可する相手。`LocalSubnet` (同じサブネット)・`192.168.0.0/16` のような範囲・`Any` (すべて) | 共通 |
| `labLocale` | `ja_JP` | JupyterLab の表示言語 (`en` で英語) | 共通 |
| `extraServerPackages` | `[]` | JupyterLab 側に追加するパッケージ (例: `"jupyterlab-git"`) | 共通 |
| `venvPackages` | `[]` | 新しく作る venv に最初から入れるパッケージ (例: `["numpy", "pandas"]`) | 共通 |
| `autoUpdateMinutes` | `60` | サーバー管理ウィンドウが `git pull` で自動更新する間隔 (分)。`0` で自動更新しない | 共通 |
| `firewallProfiles` | `Any` | ファイアウォール規則を有効にするネットワークの種類 | Windows |
| `protectedPaths` | `["auto"]` | アクセスを禁止する場所。`"auto"` は自動選択。`["auto", "D:\\data"]` のように追加できる | Windows |
| `protectLevel` | `full` | `full`: フォルダとファイルに拒否を付ける / `folders`: フォルダだけ (速いが弱い) | Windows |
| `venvSystemSitePackages` | `"auto"` | venv から OS 側の Python パッケージも使えるようにするか。`"auto"` は Jetson のときだけ `true` | Linux |
| `extraGroups` | `["video", "render"]` | 各ユーザーのサーバーに付けるグループ (GPU などのデバイス用。この PC に無いものは無視) | Linux |

## monitor (リソースモニター)

| キー | 既定値 | 内容 |
| --- | --- | --- |
| `enabled` | setup で `true` | リソースモニターを動かすか (`jfs.cmd monitor` / `monitor-stop` で切り替え) |
| `port` | `8000` | ポート (`jfs.cmd monitor -Port 9000` で変更) |

## users (ユーザー環境)

`jfs.cmd add` / `remove` が書き換えます。手で編集する必要はありません。

| キー | 内容 |
| --- | --- |
| `name` | ユーザー名 |
| `port` | ポート (`jfs.cmd set <名前> -Port` で変更) |
| `path` | 環境のフォルダ |
| `token` | 接続用トークン (`jfs.cmd token <名前> -New` で再発行) |
