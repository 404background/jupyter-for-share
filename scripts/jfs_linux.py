#!/usr/bin/env python3
"""jupyter-for-share の Linux 版 (setup.sh / jfs.sh / uninstall.sh から呼ばれます)。

Windows 版 (jfs.cmd) と同じ考え方で動きます:
- ユーザーごとに実行用アカウント (jfs-<名前>) を作り、user/<名前> の中だけで JupyterLab を動かす
- 'jfs.sh start' を実行した端末がサーバー管理ウィンドウになり、全員のログを表示する。閉じると全員停止
- 設定ファイル (servers.json) の形式は Windows 版と同じ
"""

import datetime
import getpass
import grp
import importlib.util
import ipaddress
import json
import os
import pwd
import random
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRIPTS_DIR)
CONFIG_PATH = os.path.join(REPO, "servers.json")
EXAMPLE_CONFIG = os.path.join(REPO, "servers.example.json")
RUNTIME_DIR = os.path.join(REPO, ".runtime")
MONITOR_DIR = os.path.join(REPO, "monitor")
SERVER_SRC = os.path.join(REPO, "server")
REPOSITORY_URL = "https://github.com/404background/jupyter-for-share"
GROUP = "jupyter-for-share-users"
USER_PREFIX = "jfs-"
MONITOR_ACCOUNT = "jfsmon"
HEARTBEAT_INTERVAL = 1
RESTART_DELAY = 10
MIN_PYTHON = (3, 8)   # JupyterLab を動かす Python (Jetson の JetPack 5 は 3.8)
CMD = "jfs.sh"


# ---------------------------------------------------------------- 表示

def _color(code, text):
    return "\033[%sm%s\033[0m" % (code, text) if sys.stdout.isatty() else text


def info(msg):
    print(_color("36", "[*] " + msg), flush=True)


def ok(msg):
    print(_color("32", "[+] " + msg), flush=True)


def warn(msg):
    print(_color("33", "[!] " + msg), flush=True)


def check(good, msg):
    print("  " + (_color("32", "[OK]") if good else _color("31", "[NG]")) + " " + msg, flush=True)


def user_line(name, line, kind="server"):
    prefix = _color("35", "[%s] " % name)
    if kind == "command":
        print(prefix + _color("36", "[コマンド] " + line), flush=True)
    elif "[jupyter-for-share]" in line:
        print(prefix + _color("33", line), flush=True)
    elif re.search(r"\b(Error|Traceback|Exception)\b|\[E ", line):
        print(prefix + _color("31", line), flush=True)
    else:
        print(prefix + line, flush=True)


class JfsError(Exception):
    pass


def ask_yes(question):
    try:
        return input(question + " [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def run(args, check_rc=True, quiet=False, **kw):
    """外部コマンドを実行する (出力はそのまま表示。quiet なら失敗したときだけ表示)"""
    if quiet:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, **kw)
        if check_rc and p.returncode != 0:
            sys.stdout.write(p.stdout)
            raise JfsError("コマンドが失敗しました (終了コード %d): %s" % (p.returncode, " ".join(args)))
        return p
    p = subprocess.run(args, **kw)
    if check_rc and p.returncode != 0:
        raise JfsError("コマンドが失敗しました (終了コード %d): %s" % (p.returncode, " ".join(args)))
    return p


def output(args):
    try:
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True).stdout
    except OSError:
        return ""


# ---------------------------------------------------------------- ファイル

def write_text_atomic(path, text, mode=0o644):
    """一時ファイルに書いてから置き換える (読み込み中の別のコマンドが書きかけを読まないように)"""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with _suppress():
            os.unlink(tmp)
        raise


class _suppress:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return True


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_text_atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n", mode)


def write_file_nofollow(path, text, uid=None, gid=None, mode=0o644):
    """ユーザーも書き込めるフォルダにファイルを置く。リンクはたどらない (リンク先を上書きしない)"""
    with _suppress():
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            os.unlink(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    try:
        if uid is not None:
            os.fchown(fd, uid, gid)
        os.fchmod(fd, mode)
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)


def make_dir(path, uid=0, gid=0, mode=0o755):
    """フォルダを作り、所有者と権限を設定する。リンクに置き換えられていたらリンクを消して作り直す"""
    with _suppress():
        if os.path.islink(path):
            os.unlink(path)
    os.makedirs(path, exist_ok=True)
    os.lchown(path, uid, gid)
    os.chmod(path, mode)


def chown_tree(path, uid, gid):
    """フォルダの中身をまとめて所有者変更する (リンクはたどらない)"""
    if os.path.lexists(path):
        run(["chown", "-R", "-P", "%d:%d" % (uid, gid), path], quiet=True)


def remove_tree(path):
    """フォルダを中身ごと削除する。shutil.rmtree はリンクの先をたどらない"""
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.exists(path):
        shutil.rmtree(path)


# ---------------------------------------------------------------- 設定ファイル

def read_config():
    if not os.path.exists(CONFIG_PATH):
        shutil.copyfile(EXAMPLE_CONFIG, CONFIG_PATH)
        os.chmod(CONFIG_PATH, 0o600)
        info("設定ファイルを作成しました: " + CONFIG_PATH)
    cfg = read_json(CONFIG_PATH)
    if not isinstance(cfg, dict):
        raise JfsError("設定ファイルを読めません: " + CONFIG_PATH)
    cfg.setdefault("defaults", {})
    cfg.setdefault("monitor", {"enabled": False, "port": 8000})
    users = []
    for u in cfg.get("users") or []:
        if isinstance(u, dict) and u.get("name") and not any(x["name"] == u["name"] for x in users):
            users.append(u)
    cfg["users"] = users
    return cfg


def save_config(cfg):
    # トークンを含むので、管理者 (root) だけが読めるようにする
    write_json(CONFIG_PATH, cfg, 0o600)
    # リソースモニターにはユーザー名とポートだけ渡す
    rt = os.path.join(MONITOR_DIR, ".runtime")
    if os.path.isdir(rt):
        write_json(os.path.join(rt, "users.json"),
                   {"users": [{"name": u["name"], "port": int(u["port"])} for u in cfg["users"]]})


def dget(cfg, key, default=None):
    v = cfg.get("defaults", {}).get(key)
    return default if v in (None, "") else v


def find_user(cfg, name):
    for u in cfg["users"]:
        if u["name"] == name:
            return u
    return None


def required_user(cfg, name):
    if not name:
        raise JfsError("ユーザー名を指定してください。")
    u = find_user(cfg, normalize_name(name))
    if not u:
        raise JfsError("ユーザー '%s' は登録されていません。'%s list' で確認してください。" % (name, CMD))
    return u


def target_users(cfg, name):
    if not name or name == "all":
        return list(cfg["users"])
    return [required_user(cfg, name)]


def normalize_name(name):
    n = name.strip().lower()
    # Linux のアカウント名は 32 文字まで。Windows 版と同じく 16 文字までにそろえる
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,15}", n) or n in ("all", "monitor"):
        raise JfsError("ユーザー名 '%s' は使えません。英小文字で始まる半角英数字とハイフン (16 文字以内) で指定してください。" % name)
    return n


def instances_root(cfg):
    root = dget(cfg, "instancesRoot", "") or os.path.join(REPO, "user")
    return os.path.abspath(root)


def account_name(u):
    return USER_PREFIX + u["name"]


def paths(u):
    root = u["path"]
    srv = os.path.join(root, ".server")
    logs = os.path.join(root, ".logs")
    return {
        "root": root,
        "work": os.path.join(root, "work"),
        "venv": os.path.join(root, "venv"),
        "logs": logs,
        "log": os.path.join(logs, "server.log"),
        "cmdlog": os.path.join(logs, "commands.log"),
        "server": srv,
        "lab": os.path.join(srv, "jupyterlab"),
        "etc": os.path.join(srv, "etc"),             # サーバーの設定 (管理者が書く。本人は読むだけ)
        "config": os.path.join(srv, "config"),       # JupyterLab が書き込む設定 (本人のもの)
        "data": os.path.join(srv, "data"),
        "runtime": os.path.join(srv, "runtime"),
        "home": os.path.join(srv, "home"),
        "tmp": os.path.join(srv, "tmp"),
        "heartbeat": os.path.join(srv, "heartbeat"),
        "launcher": os.path.join(srv, "launcher.py"),
        "terminit": os.path.join(srv, "terminal-init.sh"),
        "ipystartup": os.path.join(srv, "ipython-startup.py"),
        "stamp": os.path.join(srv, "README.generated.md"),
    }


# ---------------------------------------------------------------- 環境

def require_root():
    if os.geteuid() != 0:
        raise JfsError("管理者 (root) の権限が必要です。sudo を付けて実行してください (jfs.sh は自動で sudo します)。")


def jfs_version():
    git = shutil.which("git")
    if git:
        v = output([git, "-c", "safe.directory=*", "-C", REPO, "log", "-1", "--format=%h %cd",
                    "--date=format:%Y-%m-%d %H:%M"]).strip()
        if v:
            return v
    return "不明 (git の情報を取得できません)"


def python_version(exe):
    out = output([exe, "-c", "import sys; print('.'.join(map(str, sys.version_info[:3])))"]).strip()
    try:
        return tuple(int(x) for x in out.split("."))
    except ValueError:
        return None


def python_has_venv(exe):
    return subprocess.run([exe, "-c", "import venv, ensurepip"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def find_base_python(cfg, report=False):
    configured = dget(cfg, "python", "")
    if configured:
        if os.path.exists(configured):
            return configured
        raise JfsError("設定ファイルの python (%s) が見つかりません。" % configured)
    candidates = []
    for name in ("python3", "python3.13", "python3.12", "python3.11", "python3.10", "python3.9", "python3.8"):
        p = shutil.which(name)
        if p and os.path.realpath(p) not in [os.path.realpath(c) for c in candidates]:
            candidates.append(p)
    usable = []
    for p in candidates:
        v = python_version(p)
        venv_ok = bool(v) and python_has_venv(p)
        if report:
            note = ""
            if not v:
                note = " … 実行できません"
            elif v < MIN_PYTHON:
                note = " … バージョンが古いため使いません (3.8 以上が必要)"
            elif not venv_ok:
                note = " … venv が使えません (python3-venv パッケージが必要)"
            info("見つかった Python: %s (%s)%s" % (p, ".".join(map(str, v)) if v else "?", note))
        if v and v >= MIN_PYTHON and venv_ok:
            usable.append((v, p))
    if not usable:
        return None
    # 自分のホームフォルダなど、実行用アカウントから使えない場所の Python は避ける
    usable.sort(key=lambda x: (not x[1].startswith(("/usr/", "/opt/")), [-n for n in x[0]]))
    return usable[0][1]


def base_python_or_raise(cfg):
    py = find_base_python(cfg)
    if not py:
        raise JfsError("使える Python 3.8 以上 (venv 付き) が見つかりません。'sudo ./setup.sh' を実行してください。")
    return py


def package_manager():
    for pm in ("apt-get", "dnf", "yum", "zypper", "pacman"):
        if shutil.which(pm):
            return pm
    return None


def install_packages(packages_by_pm, what):
    pm = package_manager()
    pkgs = packages_by_pm.get(pm)
    if not pm or not pkgs:
        raise JfsError("%s を自動でインストールできません。手動でインストールしてから、もう一度実行してください。" % what)
    if pm == "apt-get":
        cmds = [["apt-get", "update"], ["apt-get", "install", "-y"] + pkgs]
    elif pm == "pacman":
        cmds = [["pacman", "-S", "--noconfirm", "--needed"] + pkgs]
    else:
        cmds = [[pm, "install", "-y"] + pkgs]
    info("%s をインストールします: %s" % (what, " && ".join(" ".join(c) for c in cmds)))
    if not ask_yes("実行しますか?"):
        raise JfsError("%s のインストールを中止しました。" % what)
    for c in cmds:
        run(c)


def demote(uid, gid, groups=()):
    """子プロセスを指定のアカウントの権限に切り替える (subprocess の preexec_fn に渡す)"""
    def fn():
        os.setgroups(list(groups))
        os.setgid(gid)
        os.setuid(uid)
        os.umask(0o077)
    return fn


def is_jetson():
    if os.path.exists("/etc/nv_tegra_release"):
        return True
    try:
        with open("/proc/device-tree/model", encoding="utf-8", errors="replace") as f:
            return "jetson" in f.read().lower()
    except OSError:
        return False


def device_gids(cfg):
    """GPU などのデバイスを使うためのグループ (Jetson で CUDA を使うには video が必要)。
    defaults.extraGroups で変更できる (既定: video と render のうち、この PC にあるもの)"""
    gids = []
    for name in dget(cfg, "extraGroups", ["video", "render"]) or []:
        try:
            gids.append(grp.getgrnam(name).gr_gid)
        except KeyError:
            pass
    return gids


def use_system_site_packages(cfg):
    """venv から OS の Python パッケージも使えるようにするか。
    Jetson では JetPack の TensorRT・OpenCV (CUDA 対応) などが OS 側に入っているので、既定で使えるようにする"""
    v = dget(cfg, "venvSystemSitePackages", "auto")
    if isinstance(v, bool):
        return v
    return is_jetson()


def apt_python_packages():
    """apt で入れる Python。OS の python3 が古い場合 (Ubuntu 18.04 / JetPack 4 は 3.6) は、新しい版を選ぶ"""
    v = python_version(shutil.which("python3")) if shutil.which("python3") else None
    if v and v >= MIN_PYTHON:
        return ["python3", "python3-venv", "python3-pip"]
    for minor in (12, 11, 10, 9, 8):
        name = "python3.%d" % minor
        if subprocess.run(["apt-cache", "show", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return [name, name + "-venv", name + "-dev"]
    return ["python3", "python3-venv", "python3-pip"]


def nologin_shell():
    for s in ("/usr/sbin/nologin", "/sbin/nologin", "/bin/false"):
        if os.path.exists(s):
            return s
    return "/bin/false"


def ensure_group():
    try:
        return grp.getgrnam(GROUP).gr_gid
    except KeyError:
        run(["groupadd", "--system", GROUP], quiet=True)
        ok("グループ '%s' を作成しました。" % GROUP)
        return grp.getgrnam(GROUP).gr_gid


def account_exists(name):
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


def ensure_account(name, home, comment):
    """実行用アカウント (ログインできない) を作り、(uid, gid) を返す"""
    ensure_group()
    if not account_exists(name):
        run(["useradd", "--system", "--user-group", "--no-create-home", "--home-dir", home,
             "--shell", nologin_shell(), "--comment", comment, name], quiet=True)
        ok("サーバー実行用アカウント '%s' を作成しました。" % name)
    run(["usermod", "-a", "-G", GROUP, name], quiet=True)
    pw = pwd.getpwnam(name)
    return pw.pw_uid, pw.pw_gid


def kill_account_processes(name):
    if account_exists(name):
        subprocess.run(["pkill", "-KILL", "-u", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def remove_account(name):
    if not account_exists(name):
        return
    kill_account_processes(name)
    time.sleep(0.5)
    run(["userdel", name], quiet=True, check_rc=False)
    with _suppress():
        grp.getgrnam(name)
        run(["groupdel", name], quiet=True, check_rc=False)
    ok("サーバー実行用アカウント '%s' を削除しました。" % name)


def ensure_ancestor_access(path):
    """リポジトリまでの上の階層を、実行用アカウントがたどれるようにする (中の一覧は見せない)"""
    record = os.path.join(RUNTIME_DIR, "ancestors.json")
    changed = read_json(record, []) or []
    d = os.path.dirname(os.path.abspath(path))
    while True:
        st = os.stat(d)
        if not st.st_mode & stat.S_IXOTH:
            if shutil.which("setfacl"):
                run(["setfacl", "-m", "g:%s:--x" % GROUP, d], quiet=True)
                how = "acl"
            else:
                os.chmod(d, st.st_mode | stat.S_IXOTH)
                how = "chmod"
            if not any(c["path"] == d for c in changed):
                changed.append({"path": d, "how": how})
            info("%s を実行用アカウントがたどれるようにしました (中の一覧は見えません)。" % d)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    os.chmod(RUNTIME_DIR, 0o700)
    write_json(record, changed, 0o600)


def init_instances_root(cfg):
    root = instances_root(cfg)
    if len(root) <= 1:
        raise JfsError("instancesRoot にルート (/) は指定できません。")
    ensure_ancestor_access(root)
    # 実行用アカウントは通り抜けだけでき、中の一覧 (他のユーザーの名前) は見えない
    make_dir(root, 0, 0, 0o711)
    return root


def new_token():
    return secrets.token_hex(24)


def port_listening(port):
    for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as s:   # IPv6 が無効な PC もある
                s.settimeout(0.5)
                if s.connect_ex((addr, int(port))) == 0:
                    return True
        except OSError:
            pass
    return False


def reserved_ports(cfg, self_name=""):
    ports = [int(u["port"]) for u in cfg["users"] if u["name"] != self_name]
    ports.append(int(cfg["monitor"].get("port", 8000)))
    return ports


def random_port(cfg):
    lo, hi = (dget(cfg, "portRange", [20000, 29999]) + [20000, 29999])[:2]
    reserved = reserved_ports(cfg)
    for _ in range(500):
        p = random.randint(int(lo), int(hi))
        if p not in reserved and not port_listening(p):
            return p
    raise JfsError("空いているポートが見つかりません (portRange: %s-%s)。" % (lo, hi))


def lan_addresses():
    """(インターフェース名, IPv4 アドレス, プレフィックス長) の一覧。Docker などの仮想的なものは除く"""
    result = []
    out = output(["ip", "-o", "-4", "addr", "show"])
    for line in out.splitlines():
        m = re.match(r"\d+:\s+(\S+)\s+inet\s+([\d.]+)/(\d+)", line)
        if not m:
            continue
        ifname, addr, prefix = m.group(1), m.group(2), int(m.group(3))
        if addr.startswith(("127.", "169.254.")) or re.match(r"(lo|docker|br-|veth|virbr|cni|flannel|lxc|vnet)", ifname):
            continue
        result.append((ifname, addr, prefix))
    if not result:
        # ip コマンドがない場合: 外向きの通信に使うアドレス
        with _suppress():
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("192.0.2.1", 9))
                result.append(("?", s.getsockname()[0], 24))
    return result


def server_hosts(cfg):
    hosts = []
    domain = dget(cfg, "domain", "")
    if domain:
        hosts.append(domain)
    # コンピューター名は .local 付き (mDNS) だけを表示する
    hosts.append(socket.gethostname().split(".")[0].lower() + ".local")
    hosts += [a for _, a, _ in lan_addresses()]
    return hosts


def user_urls(cfg, u):
    return ["http://%s:%s/lab?token=%s" % (h, u["port"], u["token"]) for h in server_hosts(cfg)]


def show_user_urls(cfg, u):
    print()
    print("ユーザー '%s' (ポート %s / フォルダ: %s)" % (u["name"], u["port"], u["path"]))
    print("  接続 URL (どれか 1 つが使えれば OK。トークンはパスワードと同じ扱いで本人にだけ伝えてください):")
    for url in user_urls(cfg, u):
        print("    " + url)
    print()


def show_monitor_urls(cfg):
    port = cfg["monitor"].get("port", 8000)
    print("リソースモニター (CPU / メモリ / GPU):")
    for h in server_hosts(cfg):
        print("    http://%s:%s/" % (h, port))


# ---------------------------------------------------------------- ユーザー環境のファイル

def init_instance_folders(u, uid, gid):
    """フォルダの所有者と権限:
    user/<名前>          root:<本人> 750  (本人は中を見られるが、ここには書けない)
      work venv .logs    <本人> 700       (本人だけが読み書きできる)
      .server            root:<本人> 750  (起動用ファイル。本人は読むだけ)
        jupyterlab etc   root             (JupyterLab 本体とサーバーの設定。本人は読むだけ)
        config data runtime home tmp  <本人> 700
    """
    p = paths(u)
    make_dir(p["root"], 0, gid, 0o750)
    for d in ("work", "venv", "logs"):
        make_dir(p[d], uid, gid, 0o700)
    make_dir(p["server"], 0, gid, 0o750)
    make_dir(p["lab"], 0, 0, 0o755)
    make_dir(p["etc"], 0, gid, 0o750)
    for d in ("config", "data", "runtime", "home", "tmp"):
        make_dir(p[d], uid, gid, 0o700)
    copy_ca_bundle(u)


def adopt_existing_folder(u, uid, gid):
    """以前の環境 (アンインストール時に残したフォルダ) を、新しいアカウントのものにする"""
    p = paths(u)
    for d in ("work", "venv", "logs", "config", "data", "runtime", "home", "tmp"):
        if os.path.isdir(p[d]) and not os.path.islink(p[d]):
            chown_tree(p[d], uid, gid)


def labpython(u):
    return os.path.join(paths(u)["lab"], "bin", "python")


def venvpython(u):
    return os.path.join(paths(u)["venv"], "bin", "python")


def missing_packages(python, packages, as_user=None):
    names = [re.sub(r"[<>=!~\[; ].*$", "", p) for p in packages if p]
    if not names:
        return []
    code = ("import sys; from importlib import metadata as m; "
            "n = {(d.metadata['Name'] or '').lower().replace('_', '-') for d in m.distributions()}; "
            "print(' '.join(p for p in sys.argv[1:] if p.lower().replace('_', '-') not in n))")
    kw = as_user_kwargs(as_user) if as_user else {}
    try:
        p = subprocess.run([python, "-c", code] + names, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, **kw)
    except OSError:
        return list(packages)
    if p.returncode != 0:
        return list(packages)
    missing = p.stdout.split()
    return [pkg for pkg in packages if re.sub(r"[<>=!~\[; ].*$", "", pkg) in missing]


def as_user_kwargs(u):
    """本人のアカウントで動かすための subprocess の引数 (本人の venv の中身は管理者の権限では実行しない)"""
    pw = pwd.getpwnam(account_name(u))
    p = paths(u)
    return {"preexec_fn": demote(pw.pw_uid, pw.pw_gid, device_gids(read_config())), "env": user_env(u), "cwd": p["work"]}


def install_jupyterlab(cfg, u, upgrade=False):
    p = paths(u)
    py = labpython(u)
    if os.path.exists(py) and python_version(py):
        info("JupyterLab 用の venv は作成済みです: " + p["lab"])
    else:
        run([base_python_or_raise(cfg), "-m", "venv", p["lab"]], quiet=True)
    pkgs = ["jupyterlab"]
    locale = dget(cfg, "labLocale", "ja_JP")
    if locale and not locale.startswith("en"):
        pkgs.append("jupyterlab-language-pack-" + locale.replace("_", "-"))
    pkgs += list(dget(cfg, "extraServerPackages", []) or [])
    todo = pkgs if upgrade else missing_packages(py, pkgs)
    if not todo:
        ok("JupyterLab と関連パッケージはインストール済みです (%s)。" % ", ".join(pkgs))
    else:
        info("JupyterLab をインストールしています (%s: %s)。数分かかります..." % (u["name"], ", ".join(todo)))
        run([py, "-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pip"], quiet=True)
        run([py, "-m", "pip", "install", "--disable-pip-version-check"] + (["--upgrade"] if upgrade else []) + todo,
            quiet=True)
    if locale:
        d = os.path.join(p["lab"], "share", "jupyter", "lab", "settings")
        os.makedirs(d, exist_ok=True)
        write_text_atomic(os.path.join(d, "overrides.json"),
                          '{ "@jupyterlab/translation-extension:plugin": { "locale": "%s" } }' % locale)
    run(["chmod", "-R", "go+rX,go-w", p["lab"]], quiet=True)
    ok("JupyterLab の準備ができました。")


def install_user_venv(cfg, u):
    """本人の venv。作るのもパッケージを入れるのも本人のアカウントで行う"""
    p = paths(u)
    py = venvpython(u)
    if os.path.exists(os.path.join(p["venv"], "pyvenv.cfg")):
        if not venv_base_exists(p["venv"]):
            # 元にした Python が無くなっている (OS の更新など): 本人のアカウントで作り直す (中のパッケージは残る)
            info("venv の元の Python が見つからないため、venv を作り直します: " + p["venv"])
            run([base_python_or_raise(cfg), "-m", "venv", p["venv"]], quiet=True, **as_user_kwargs(u))
        info("venv は作成済みのため、そのまま使います: %s (足りないパッケージはターミナルで pip install してください)" % p["venv"])
    else:
        info("venv を作成しています: " + p["venv"])
        args = [base_python_or_raise(cfg), "-m", "venv"]
        if use_system_site_packages(cfg):
            args.append("--system-site-packages")   # Jetson: JetPack の TensorRT・OpenCV なども使えるように
        run(args + [p["venv"]], quiet=True, **as_user_kwargs(u))
        pkgs = ["ipykernel"] + list(dget(cfg, "venvPackages", []) or [])
        todo = missing_packages(py, pkgs, as_user=u)
        if todo:
            info("venv にインストールしています: " + ", ".join(todo))
            kw = as_user_kwargs(u)
            run([py, "-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pip"], quiet=True, **kw)
            run([py, "-m", "pip", "install", "--disable-pip-version-check"] + todo, quiet=True, **kw)
    register_kernel(u)
    ok("venv の準備ができました。")


def venv_base_exists(venv):
    """venv の pyvenv.cfg に書かれた元の Python が残っているか (venv の Python は実行せずに確認する)"""
    try:
        with os.fdopen(open_regular(os.path.join(venv, "pyvenv.cfg"), os.O_RDONLY), encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*home\s*=\s*(.+?)\s*$", line)
                if m:
                    return any(os.path.exists(os.path.join(m.group(1), n)) for n in ("python3", "python"))
    except OSError:
        pass
    return False


def register_kernel(u):
    """ノートブックで本人の venv の Python を使うカーネルを、JupyterLab 側に登録する。
    実行したセルを .logs/commands.log に記録するスクリプトも、ここで読み込ませる"""
    p = paths(u)
    d = os.path.join(p["lab"], "share", "jupyter", "kernels", "python3")
    os.makedirs(d, exist_ok=True)
    spec = {
        "argv": [venvpython(u), "-m", "ipykernel_launcher", "-f", "{connection_file}",
                 "--IPKernelApp.exec_files=%s" % p["ipystartup"]],
        "display_name": "Python 3 (venv)",
        "language": "python",
        "metadata": {"debugger": True},
    }
    write_text_atomic(os.path.join(d, "kernel.json"), json.dumps(spec, indent=2) + "\n")


PASS_ENV = ("http_proxy", "https_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
            "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL", "PIP_TRUSTED_HOST", "PIP_CERT", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE",
            "CUDA_VISIBLE_DEVICES", "LD_LIBRARY_PATH")


CA_ENV = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "PIP_CERT")


def passthrough_env(u=None):
    """プロキシなど、管理者の環境から引き継ぐ設定 (pip install や git clone に必要なことがある)。
    証明書のファイルが実行用アカウントから読めない場所にある場合は、.server にコピーしたものを使う"""
    env = {k: os.environ[k] for k in PASS_ENV if os.environ.get(k)}
    if u:
        copy = os.path.join(paths(u)["server"], "ca-bundle.crt")
        for k in CA_ENV:
            if k in env and os.path.exists(copy):
                env[k] = copy
    return env


def copy_ca_bundle(u):
    for k in CA_ENV:
        src = os.environ.get(k)
        if src and os.path.isfile(src):
            write_text_atomic(os.path.join(paths(u)["server"], "ca-bundle.crt"),
                              open(src, encoding="utf-8", errors="replace").read(), 0o644)
            return


def user_env(u):
    p = paths(u)
    acct = account_name(u)
    home = p["home"]
    return dict(passthrough_env(u), **{
        "HOME": home, "USER": acct, "LOGNAME": acct, "SHELL": "/bin/bash",
        "LANG": os.environ.get("LANG") or "C.UTF-8",
        "PATH": os.path.join(p["venv"], "bin") + (":/usr/local/cuda/bin" if os.path.isdir("/usr/local/cuda/bin") else "")
                + ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TMPDIR": p["tmp"],
        "XDG_CONFIG_HOME": os.path.join(home, ".config"),
        "XDG_CACHE_HOME": os.path.join(home, ".cache"),
        "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
        "JUPYTER_CONFIG_DIR": p["config"],
        "JUPYTER_CONFIG_PATH": p["etc"],
        "JUPYTER_DATA_DIR": p["data"],
        "JUPYTER_RUNTIME_DIR": p["runtime"],
        "JUPYTERLAB_SETTINGS_DIR": os.path.join(home, ".jupyter", "lab", "user-settings"),
        "JUPYTERLAB_WORKSPACES_DIR": os.path.join(home, ".jupyter", "lab", "workspaces"),
        "IPYTHONDIR": os.path.join(home, ".ipython"),
        "PIP_CACHE_DIR": os.path.join(home, ".cache", "pip"),
        "VIRTUAL_ENV": p["venv"],
        "PYTHONUNBUFFERED": "1",
        "JFS_COMMAND_LOG": p["cmdlog"],
        "GIT_TERMINAL_PROMPT": "1",
    })


def write_server_files(cfg, u):
    p = paths(u)
    gid = pwd.getpwnam(account_name(u)).pw_gid
    bind = dget(cfg, "bindAddress", "0.0.0.0")
    if bind == "0.0.0.0":
        bind = ""   # すべてのアドレス (IPv4 / IPv6) で待ち受ける
    conf = "\n".join([
        "# jupyter-for-share が生成したファイルです。%s で上書きされるため直接編集しないでください。" % CMD,
        "c = get_config()  # noqa",
        "c.ServerApp.ip = %r" % bind,
        "c.ServerApp.port = %d" % int(u["port"]),
        "c.ServerApp.port_retries = 0",
        "c.ServerApp.open_browser = False",
        "c.ServerApp.allow_remote_access = True",
        "c.ServerApp.root_dir = %r" % p["work"],
        "c.IdentityProvider.token = %r" % u["token"],
        "# ターミナルは bash。起動時に terminal-init.sh を読み込み、実行したコマンドを .logs に記録する",
        "c.ServerApp.terminado_settings = {'shell_command': ['/bin/bash', '--rcfile', %r, '-i']}" % p["terminit"],
        "",
    ])
    # トークンを含むので、本人 (と管理者) だけが読めるようにする
    write_text_atomic(os.path.join(p["etc"], "jupyter_server_config.py"), conf, 0o640)
    os.chown(os.path.join(p["etc"], "jupyter_server_config.py"), 0, gid)
    for src, dst in (("launcher.py", "launcher"), ("terminal-init.sh", "terminit"), ("ipython-startup.py", "ipystartup")):
        with open(os.path.join(SERVER_SRC, src), encoding="utf-8") as f:
            write_text_atomic(p[dst], f.read(), 0o644)
    register_kernel(u)
    write_user_readme(cfg, u)


def write_user_readme(cfg, u):
    p = paths(u)
    path = os.path.join(p["work"], "README.md")
    if os.path.islink(path) or not os.path.isdir(p["work"]):
        return
    if os.path.lexists(path):
        try:
            with os.fdopen(open_regular(path, os.O_RDONLY), encoding="utf-8") as f:
                current = f.read()
            with open(p["stamp"], encoding="utf-8") as f:
                previous = f.read()
        except OSError:
            return
        if current != previous:
            return   # 本人が編集した: 上書きしない
    hosts = server_hosts(cfg)
    ips = [h for h in hosts if re.fullmatch(r"[\d.]+", h)]
    lab = "- この環境: http://%s:%s/lab" % (hosts[0], u["port"])
    if ips:
        lab += "  (つながらない場合: http://%s:%s/lab)" % (ips[0], u["port"])
    mport = cfg["monitor"].get("port", 8000)
    mon = "- リソース確認 (CPU / メモリ / GPU の使用率): http://%s:%s/" % (hosts[0], mport)
    if ips:
        mon += "  (つながらない場合: http://%s:%s/)" % (ips[0], mport)
    if not cfg["monitor"].get("enabled"):
        mon += "  ※ 現在は停止中"
    text = """<!-- generated by jupyter-for-share -->
# {name} さんの JupyterLab 環境

## アドレス

{lab}
{mon}

初回はトークン付きの URL で開いてください (管理者から受け取ったもの)。2 回目以降は上のアドレスだけで開けます。

## 使い方

- このフォルダ (work) の中が作業場所です。ノートブックやファイルはここに保存してください。
  他のユーザーのフォルダは見えません。
- パッケージ: ターミナルで ``pip install パッケージ名``、ノートブックでは ``%pip install パッケージ名``
  (この環境専用の venv に入ります。インストール後はカーネルを再起動してください)
- git: ターミナルで ``git clone https://...``
- ターミナルは bash です (メニューの File → New → Terminal)。

## このサーバーについて

この環境は jupyter-for-share で作られています: {repo}

このファイルは削除・編集してかまいません (編集すると自動更新されなくなります)。
""".format(name=u["name"], lab=lab, mon=mon, repo=dget(cfg, "repositoryUrl", REPOSITORY_URL))
    pw = pwd.getpwnam(account_name(u))
    write_file_nofollow(path, text, pw.pw_uid, pw.pw_gid, 0o644)
    write_text_atomic(p["stamp"], text, 0o644)


# ---------------------------------------------------------------- ファイアウォール (ufw / firewalld)

def firewall_kind():
    if shutil.which("ufw"):
        out = output(["ufw", "status"])
        if "Status: active" in out or "状態: アクティブ" in out:
            return "ufw"
    if shutil.which("firewall-cmd") and output(["firewall-cmd", "--state"]).strip() == "running":
        return "firewalld"
    return None


def allow_sources(cfg):
    result = []
    for a in dget(cfg, "allowFrom", ["LocalSubnet"]) or ["LocalSubnet"]:
        if str(a).lower() == "localsubnet":
            for _, addr, prefix in lan_addresses():
                result.append(str(ipaddress.ip_network("%s/%d" % (addr, prefix), strict=False)))
        elif str(a).lower() in ("any", "*"):
            result.append("any")
        else:
            result.append(str(a))
    return sorted(set(result)) or ["any"]


def expected_rules(cfg):
    ports = [(u["name"], int(u["port"])) for u in cfg["users"]]
    if cfg["monitor"].get("enabled"):
        ports.append(("monitor", int(cfg["monitor"].get("port", 8000))))
    return [{"label": label, "port": port, "source": src} for label, port in ports for src in allow_sources(cfg)]


def _fw_args(kind, rule, add):
    src, port = rule["source"], rule["port"]
    if kind == "ufw":
        args = ["ufw"] + ([] if add else ["delete"]) + ["allow"]
        if src != "any":
            args += ["from", src]
        args += ["to", "any", "port", str(port), "proto", "tcp"]
        if add:
            args += ["comment", "jupyter-for-share " + rule["label"]]
        return [args]
    family = "ipv6" if ":" in src else "ipv4"
    if src == "any":
        spec = "--%s-port=%d/tcp" % ("add" if add else "remove", port)
    else:
        spec = "--%s-rich-rule=rule family=%s source address=%s port port=%d protocol=tcp accept" % (
            "add" if add else "remove", family, src, port)
    return [["firewall-cmd", "--permanent", spec]]


def sync_firewall(cfg, quiet=False):
    """設定ファイルに合わせて、ufw または firewalld の許可規則を足し引きする (作った規則は .runtime に記録)"""
    kind = firewall_kind()
    record_path = os.path.join(RUNTIME_DIR, "firewall.json")
    record = read_json(record_path, {"kind": None, "rules": []}) or {"kind": None, "rules": []}
    if not kind:
        if not quiet:
            info("ファイアウォール (ufw / firewalld) は動いていないため、ポートの許可は不要です。")
        return
    want = expected_rules(cfg)
    have = record.get("rules", []) if record.get("kind") == kind else []
    key = lambda r: (r["port"], r["source"])
    for r in have:
        if key(r) not in [key(w) for w in want]:
            for a in _fw_args(kind, r, False):
                subprocess.run(a, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for r in want:
        for a in _fw_args(kind, r, True):
            subprocess.run(a, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not quiet:
            ok("ファイアウォール (%s): TCP %d を許可 (%s / 接続元: %s)" % (kind, r["port"], r["label"], r["source"]))
    if kind == "firewalld":
        subprocess.run(["firewall-cmd", "--reload"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    write_json(record_path, {"kind": kind, "rules": want}, 0o600)


def remove_firewall_rules():
    record = read_json(os.path.join(RUNTIME_DIR, "firewall.json"), {}) or {}
    kind = record.get("kind")
    if not kind or not shutil.which("ufw" if kind == "ufw" else "firewall-cmd"):
        return 0
    for r in record.get("rules", []):
        for a in _fw_args(kind, r, False):
            subprocess.run(a, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if kind == "firewalld":
        subprocess.run(["firewall-cmd", "--reload"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return len(record.get("rules", []))


# ---------------------------------------------------------------- サーバー管理ウィンドウ (hub)

def hub_paths():
    return {"record": os.path.join(RUNTIME_DIR, "hub.json"), "wanted": os.path.join(RUNTIME_DIR, "hub-wanted.json")}


def process_start_ticks(pid):
    """プロセスの起動時刻 (同じ番号の別のプロセスと区別するため)"""
    try:
        with open("/proc/%d/stat" % int(pid)) as f:
            return int(f.read().rsplit(")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def hub_pid():
    rec = read_json(hub_paths()["record"], {}) or {}
    pid = rec.get("pid")
    if not pid:
        return None
    ticks = process_start_ticks(pid)
    if ticks is None or (rec.get("ticks") is not None and rec.get("ticks") != ticks):
        return None
    try:
        with open("/proc/%d/cmdline" % int(pid), "rb") as f:
            cmd = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    return int(pid) if "jfs_linux.py" in cmd else None


_last_wanted = None


def get_wanted():
    global _last_wanted
    data = read_json(hub_paths()["wanted"], None)
    if not isinstance(data, dict):
        if os.path.exists(hub_paths()["wanted"]) and _last_wanted:
            return _last_wanted   # 読めなかった: 前回の内容を使う
        data = {}
    w = {"all": bool(data.get("all")), "users": [x for x in data.get("users") or [] if x],
         "hold": [x for x in data.get("hold") or [] if x]}
    _last_wanted = w
    return w


def save_wanted(all_users, users, hold=None):
    if hold is None:
        hold = get_wanted()["hold"]
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    os.chmod(RUNTIME_DIR, 0o700)
    write_json(hub_paths()["wanted"], {"all": all_users, "users": sorted(set(users)), "hold": sorted(set(hold))}, 0o600)


def is_wanted(w, name):
    return w["all"] or name in w["users"]


def add_wanted(name):
    w = get_wanted()
    save_wanted(w["all"], w["users"] + [name])


def remove_wanted(cfg, name):
    w = get_wanted()
    if w["all"]:
        save_wanted(False, [u["name"] for u in cfg["users"] if u["name"] != name])
    else:
        save_wanted(False, [x for x in w["users"] if x != name])


def set_hold(name, on):
    w = get_wanted()
    hold = [x for x in w["hold"] if x != name] + ([name] if on else [])
    save_wanted(w["all"], w["users"], hold)


def wait_listening(port, seconds=90):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if port_listening(port):
            return True
        time.sleep(1)
    return False


class LogTail:
    def __init__(self, path):
        self.path = path
        self.pos = os.path.getsize(path) if os.path.isfile(path) else 0   # 過去の分は表示しない
        self.rest = b""

    def read_lines(self):
        try:
            with os.fdopen(open_regular(self.path, os.O_RDONLY), "rb") as f:
                size = os.fstat(f.fileno()).st_size
                if size < self.pos:
                    self.pos = 0   # ログが切り替わった
                if size == self.pos:
                    return []
                f.seek(self.pos)
                data = f.read(min(size - self.pos, 1 << 20))
                self.pos += len(data)
        except OSError:
            return []
        parts = (self.rest + data).split(b"\n")
        self.rest = parts.pop()
        return [x.decode("utf-8", "replace").rstrip("\r") for x in parts]


def open_regular(path, flags, mode=0o640):
    """ユーザーも書き込める場所のファイルを開く。リンクやパイプ (FIFO) などに置き換えられていたら開かない
    (管理者がリンクの先のファイルを読み書きしたり、パイプで待たされたりしないように)"""
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, mode)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError("通常のファイルではありません: " + path)
    return fd


def open_log_for_child(path):
    """子プロセスの出力先のログを開く (管理者が開いて渡すので、本人がログを書き換えても影響しない)。
    10 MB を超えたら .1 に切り替える。リンクなどはたどらずに消す"""
    with _suppress():
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            os.unlink(path)
        elif st.st_size > 10 * 1024 * 1024:
            os.replace(path, path + ".1")
    fd = open_regular(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
    os.write(fd, ("===== %s start\n" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")).encode())
    return fd


def start_process(args, account, env, cwd, log_path, groups=()):
    pw = pwd.getpwnam(account)
    fd = open_log_for_child(log_path)
    try:
        os.fchown(fd, 0, pw.pw_gid)   # 本人も自分のログを読める
        return subprocess.Popen(args, preexec_fn=demote(pw.pw_uid, pw.pw_gid, groups),
                                env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=fd, stderr=subprocess.STDOUT,
                                start_new_session=True)
    finally:
        os.close(fd)


def stop_process(proc, account, label, wait=10):
    """サーバーとその子 (カーネル・ターミナル) をまとめて止める"""
    if proc and proc.poll() is None:
        with _suppress():
            os.killpg(proc.pid, signal.SIGTERM)
        deadline = time.time() + wait
        while proc.poll() is None and time.time() < deadline:
            time.sleep(0.2)
        with _suppress():
            os.killpg(proc.pid, signal.SIGKILL)
        with _suppress():
            proc.wait(5)
    # 別のセッションに逃げたプロセスも残さない
    kill_account_processes(account)
    if label:
        ok("%s を停止しました。" % label)


def prepare_user(cfg, u):
    pw = pwd.getpwnam(account_name(u))
    init_instance_folders(u, pw.pw_uid, pw.pw_gid)
    write_server_files(cfg, u)


def monitor_paths():
    rt = os.path.join(MONITOR_DIR, ".runtime")
    return {"runtime": rt, "venv": os.path.join(MONITOR_DIR, ".venv"), "log": os.path.join(rt, "monitor.log"),
            "users": os.path.join(rt, "users.json"), "heartbeat": os.path.join(rt, "heartbeat"),
            "tmp": os.path.join(rt, "tmp"), "script": os.path.join(MONITOR_DIR, "monitor.py")}


def hub_new_state():
    return {"users": {}, "monitor": None, "cfg": read_config(), "cfg_read": time.time(), "ever_ran": False,
            "update": None, "running": 0}


def hub_tick(state):
    """サーバー管理ウィンドウから毎秒呼ばれる。戻り値 'reload' で新しいバージョンの処理に切り替える"""
    if time.time() - state["cfg_read"] >= 5:
        with _suppress():
            state["cfg"] = read_config()
        state["cfg_read"] = time.time()
    cfg = state["cfg"]
    wanted = get_wanted()
    running = 0
    for u in cfg["users"]:
        name = u["name"]
        st = state["users"].get(name)
        want = is_wanted(wanted, name)
        held = want and name in wanted["hold"]
        if not want or held:
            if st and st["active"]:
                with _suppress():
                    os.unlink(paths(u)["heartbeat"])
                stop_process(st["proc"], account_name(u), None)
                user_line(name, "[jupyter-for-share] " + ("サーバーを一時停止しました (更新作業中)。" if held else "サーバーを停止しました。"))
                st["active"] = False
            if held:
                running += 1
            continue
        running += 1
        state["ever_ran"] = True
        p = paths(u)
        if not st or not st["active"]:
            try:
                if port_listening(u["port"]):
                    kill_account_processes(account_name(u))
                prepare_user(cfg, u)
            except Exception as e:   # noqa: BLE001
                user_line(name, "[jupyter-for-share] 起動の準備に失敗しました: %s" % e)
                remove_wanted(cfg, name)
                continue
            os.makedirs(p["logs"], exist_ok=True)
            st = {"active": True, "proc": None, "next_start": time.time(), "started": 0,
                  "server_tail": LogTail(p["log"]), "command_tail": LogTail(p["cmdlog"])}
            state["users"][name] = st
            user_line(name, "[jupyter-for-share] 起動します (ポート %s / ログ: %s)" % (u["port"], p["log"]))
            user_line(name, "[jupyter-for-share] 別の PC からはこの URL で開きます (どれか 1 つ。トークン付き):")
            for url in user_urls(cfg, u):
                user_line(name, "    " + url)
        write_heartbeat(p["heartbeat"])
        manage_process(st, name, lambda u=u, p=p: start_process(
            [labpython(u), p["launcher"], p["heartbeat"]], account_name(u), user_env(u), p["work"], p["log"],
            device_gids(cfg)))
        for line in st["server_tail"].read_lines():
            user_line(name, line)
        for line in st["command_tail"].read_lines():
            user_line(name, line, "command")

    # リソースモニター (設置済みなら、ユーザーのサーバーと一緒に動かす)
    mp = monitor_paths()
    monitor_on = running > 0 and cfg["monitor"].get("enabled") and os.path.exists(os.path.join(mp["venv"], "bin", "python"))
    if monitor_on:
        if not state["monitor"]:
            state["monitor"] = {"active": True, "proc": None, "next_start": time.time(), "started": 0,
                                "tail": LogTail(mp["log"])}
            user_line("monitor", "[jupyter-for-share] リソースモニターを起動します: http://%s:%s/" % (
                server_hosts(cfg)[0], cfg["monitor"].get("port", 8000)))
        write_heartbeat(mp["heartbeat"])
        manage_process(state["monitor"], "monitor", lambda: start_monitor_process(cfg))
        for line in state["monitor"]["tail"].read_lines():
            user_line("monitor", line)
    elif state["monitor"]:
        with _suppress():
            os.unlink(mp["heartbeat"])
        stop_process(state["monitor"]["proc"], MONITOR_ACCOUNT, None)
        state["monitor"] = None

    # 設定から消えたユーザー (jfs.sh remove) のサーバーは止める
    names = {u["name"] for u in cfg["users"]}
    for name, st in state["users"].items():
        if st["active"] and name not in names:
            stop_process(st["proc"], USER_PREFIX + name, None)
            user_line(name, "[jupyter-for-share] ユーザーが削除されたため、サーバーを停止しました。")
            st["active"] = False

    state["running"] = running
    result = None
    try:
        result = update_tick(state, cfg)
    except Exception as e:   # noqa: BLE001
        user_line("更新", "[jupyter-for-share] 自動更新でエラーが発生しました: %s" % e)
        state["update"] = None
    set_title("jupyter-for-share サーバー (%d 人) - 閉じると全員のサーバーが停止します" % running)
    if state["ever_ran"] and running == 0:
        print(_color("33", "起動対象のユーザーがいなくなったため、サーバー管理ウィンドウを終了します。"), flush=True)
        return "exit"
    return result


def write_heartbeat(path):
    with _suppress():
        if os.path.islink(path):
            os.unlink(path)
    write_text_atomic(path, datetime.datetime.now().isoformat(), 0o644)


def manage_process(st, label, starter):
    """止まっていたら 10 秒おいて起動し直す"""
    proc = st["proc"]
    if proc is not None and proc.poll() is None:
        return
    if proc is not None:
        user_line(label, "[jupyter-for-share] 停止しました (終了コード %s)。%d 秒後に再起動します。" % (proc.returncode, RESTART_DELAY))
        st["proc"] = None
        st["next_start"] = time.time() + RESTART_DELAY
    if time.time() >= st["next_start"]:
        try:
            st["proc"] = starter()
            st["started"] = time.time()
        except Exception as e:   # noqa: BLE001
            user_line(label, "[jupyter-for-share] 起動に失敗しました: %s。30 秒後に再試行します。" % e)
            st["next_start"] = time.time() + 30


def start_monitor_process(cfg):
    mp = monitor_paths()
    pw = pwd.getpwnam(MONITOR_ACCOUNT)
    make_dir(mp["tmp"], pw.pw_uid, pw.pw_gid, 0o700)
    bind = dget(cfg, "bindAddress", "0.0.0.0")
    env = {"PATH": "/usr/local/bin:/usr/bin:/sbin:/bin", "HOME": mp["tmp"], "TMPDIR": mp["tmp"], "PYTHONUNBUFFERED": "1",
           "LANG": os.environ.get("LANG") or "C.UTF-8"}
    return start_process([os.path.join(mp["venv"], "bin", "python"), mp["script"], "--bind", bind,
                          "--port", str(cfg["monitor"].get("port", 8000)), "--users", mp["users"],
                          "--disk", instances_root(cfg), "--heartbeat", mp["heartbeat"]],
                         MONITOR_ACCOUNT, env, mp["tmp"], mp["log"])


def set_title(text):
    if sys.stdout.isatty():
        sys.stdout.write("\033]0;%s\007" % text)
        sys.stdout.flush()


def hub_stop_all(state):
    for name, st in state["users"].items():
        if st["active"]:
            u = find_user(state["cfg"], name)
            if u:
                with _suppress():
                    os.unlink(paths(u)["heartbeat"])
            stop_process(st["proc"], USER_PREFIX + name, "ユーザー '%s' の環境" % name)
    if state["monitor"]:
        stop_process(state["monitor"]["proc"], MONITOR_ACCOUNT, "リソースモニター")


def load_fresh_module():
    """git pull で更新された jfs_linux.py を読み込む (構文エラーなら例外になり、今の処理のまま動く)"""
    spec = importlib.util.spec_from_file_location("jfs_linux_live", os.path.join(SCRIPTS_DIR, "jfs_linux.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def invoke_hub():
    if hub_pid():
        raise JfsError("サーバー管理ウィンドウは既に開いています。")
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    os.chmod(RUNTIME_DIR, 0o700)
    write_json(hub_paths()["record"], {"pid": os.getpid(), "ticks": process_start_ticks(os.getpid()), "started": time.time()}, 0o600)
    print("jupyter-for-share サーバー管理ウィンドウ (バージョン %s)" % jfs_version())
    print(_color("33", "この端末を閉じる (または Ctrl+C) と、全ユーザーのサーバーが停止します。"))
    print("1 人だけ止める: %s stop <ユーザー名> / 起動する: %s start <ユーザー名>  (別の端末で実行)" % (CMD, CMD))
    print("-" * 70, flush=True)

    def on_signal(signum, frame):
        if signum == signal.SIGHUP:
            # 端末が閉じられた: 表示先がないので、出力を捨ててサーバーを止める
            with _suppress():
                sys.stdout = sys.stderr = open(os.devnull, "w")
        raise KeyboardInterrupt
    for s in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, on_signal)

    # 実行用アカウントがリポジトリまでたどれるか、起動のたびに確かめる (誰かが上の階層の権限を変えた場合など)
    with _suppress():
        ensure_ancestor_access(instances_root(read_config()))
        ensure_ancestor_access(MONITOR_DIR)
    lib = sys.modules[__name__]
    state = lib.hub_new_state()
    try:
        while True:
            try:
                result = lib.hub_tick(state)
            except KeyboardInterrupt:
                raise
            except Exception as e:   # noqa: BLE001
                print("[x] %s" % e, flush=True)
                result = None
            if result == "exit":
                break
            if result == "reload":
                try:
                    lib = load_fresh_module()
                    user_line("更新", "[jupyter-for-share] サーバー管理の処理を新しいバージョンに切り替えました (サーバーは止めていません)。")
                except Exception as e:   # noqa: BLE001
                    user_line("更新", "[jupyter-for-share] 新しい処理を読み込めなかったため、今の処理のまま動かします: %s" % e)
            time.sleep(HEARTBEAT_INTERVAL)
    except KeyboardInterrupt:
        print()
        print(_color("33", "サーバー管理ウィンドウを終了します。全員のサーバーを停止しています..."), flush=True)
    finally:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        lib.hub_stop_all(state)
        with _suppress():
            os.unlink(hub_paths()["record"])


# ---------------------------------------------------------------- 自動更新

def git_head(git):
    return output([git, "-c", "safe.directory=*", "-C", REPO, "rev-parse", "HEAD"]).strip()


def update_tick(state, cfg):
    minutes = int(dget(cfg, "autoUpdateMinutes", 60) or 0)
    git = shutil.which("git")
    if minutes <= 0 or not git or not os.path.isdir(os.path.join(REPO, ".git")):
        return None
    st = state["update"]
    if st is None:
        state["update"] = {"next": time.time() + 60, "proc": None}   # 最初の確認は 1 分後
        return None
    if st["proc"] is None:
        if time.time() < st["next"]:
            return None
        st["next"] = time.time() + minutes * 60
        st["before"] = git_head(git)
        st["out"] = tempfile.TemporaryFile()
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
        # 管理者 (sudo した人) のアカウントで実行する (リポジトリの持ち主・認証情報がその人のもののため)
        kw = {}
        owner = os.stat(REPO).st_uid
        if owner != 0:
            pw = pwd.getpwuid(owner)
            groups = os.getgrouplist(pw.pw_name, pw.pw_gid)
            kw = {"preexec_fn": lambda: (os.setgroups(groups), os.setgid(pw.pw_gid), os.setuid(pw.pw_uid))}
            env["HOME"] = pw.pw_dir
        st["proc"] = subprocess.Popen([git, "-c", "safe.directory=*", "-C", REPO, "pull", "--ff-only", "--quiet"],
                                      stdin=subprocess.DEVNULL, stdout=st["out"], stderr=subprocess.STDOUT, env=env, **kw)
        st["started"] = time.time()
        return None
    proc = st["proc"]
    if proc.poll() is None:
        if time.time() - st["started"] > 300:
            proc.kill()
            user_line("更新", "[jupyter-for-share] git pull が 5 分以内に終わらなかったため中止しました。次回また試します。")
            st["proc"] = None
        return None
    st["proc"] = None
    st["out"].seek(0)
    msg = " / ".join(l.strip() for l in st["out"].read().decode("utf-8", "replace").splitlines() if l.strip())
    st["out"].close()
    if proc.returncode != 0:
        user_line("更新", "[jupyter-for-share] git pull に失敗しました (サーバーはそのまま動いています。%d 分後に再試行): %s" % (minutes, msg))
        return None
    after = git_head(git)
    if not after or after == st["before"]:
        return None
    log = output([git, "-c", "safe.directory=*", "-C", REPO, "log", "--oneline", "%s..%s" % (st["before"], after)])
    changed = output([git, "-c", "safe.directory=*", "-C", REPO, "diff", "--name-only", st["before"], after]).split()
    user_line("更新", "[jupyter-for-share] 新しいバージョンを取得しました (%s):" % jfs_version())
    for l in log.splitlines():
        user_line("更新", "    " + l)
    if state["monitor"] and any(c.startswith("monitor/") for c in changed):
        user_line("更新", "[jupyter-for-share] リソースモニターを新しいバージョンで起動し直します。")
        stop_process(state["monitor"]["proc"], MONITOR_ACCOUNT, None)
    if any(c.startswith(("server/", "scripts/")) for c in changed):
        user_line("更新", "[jupyter-for-share] 各ユーザーの JupyterLab は動かしたままです。JupyterLab 側の変更は次の起動から反映されます "
                          "(すぐ反映するには '%s restart <ユーザー名>')。" % CMD)
    if any(c in ("setup.sh",) for c in changed):
        user_line("更新", "[jupyter-for-share] セットアップの処理も変わりました。都合のよいときに 'sudo ./setup.sh' を実行し直してください。")
    return "reload" if any(c == "scripts/jfs_linux.py" for c in changed) else None


# ---------------------------------------------------------------- コマンド

def user_status(cfg, u, wanted=None, hub=None):
    hub = hub_pid() if hub is None else hub
    wanted = get_wanted() if wanted is None else wanted
    if port_listening(u["port"]):
        return "起動中"
    if hub and is_wanted(wanted, u["name"]):
        return "起動処理中"
    return "停止"


def cmd_list(cfg, a):
    hub, wanted = hub_pid(), get_wanted()
    if not cfg["users"]:
        info("ユーザー環境はまだありません。'%s add <ユーザー名>' で作成してください。" % CMD)
    else:
        print("%-16s %-7s %s" % ("ユーザー", "ポート", "状態"))
        for u in cfg["users"]:
            print("%-16s %-7s %s" % (u["name"], u["port"], user_status(cfg, u, wanted, hub)))
        print("(フォルダ: %s/<ユーザー名>)" % instances_root(cfg))
    print()
    m = cfg["monitor"]
    mstate = "未設置 ('%s monitor' で設置)" % CMD if not m.get("enabled") else (
        "起動中" if port_listening(m.get("port", 8000)) else "停止 ('%s start' のサーバー管理ウィンドウで動きます)" % CMD)
    print("リソースモニター: ポート %s / %s" % (m.get("port", 8000), mstate))
    print("サーバー管理ウィンドウ: " + ("動作中 (pid %d)" % hub if hub else "なし ('%s start' で開きます)" % CMD))


def cmd_add(cfg, a):
    if not a.name:
        raise JfsError("ユーザー名を指定してください。例: %s add alice" % CMD)
    name = normalize_name(a.name)
    if find_user(cfg, name):
        raise JfsError("ユーザー '%s' は既に存在します ('%s list' で確認)。" % (name, CMD))
    base_python_or_raise(cfg)
    root = init_instances_root(cfg)
    folder = os.path.join(root, name)
    acct = USER_PREFIX + name
    # アンインストール時に残したフォルダ (work があり、アカウントはない) は、中身を残したまま引き継ぐ
    reuse = not account_exists(acct) and os.path.isdir(os.path.join(folder, "work"))
    if reuse:
        info("以前のフォルダ %s が残っているので、中身 (ノートブック・venv など) をそのまま使います。" % folder)
    elif os.path.lexists(folder) or account_exists(acct):
        raise JfsError("以前の作成途中のデータ (フォルダ %s またはアカウント %s) が残っています。"
                       "'%s remove %s' で片付けてから、もう一度作成してください。" % (folder, acct, CMD, name))
    u = {"name": name, "port": random_port(cfg), "path": folder, "token": new_token()}
    try:
        info("[1/5] 実行用アカウント %s を作成" % acct)
        uid, gid = ensure_account(acct, paths(u)["home"], "jupyter-for-share " + name)
        info("[2/5] フォルダとアクセス権を設定: " + folder)
        if reuse:
            adopt_existing_folder(u, uid, gid)
        init_instance_folders(u, uid, gid)
        info("[3/5] JupyterLab をインストール")
        install_jupyterlab(cfg, u)
        info("[4/5] venv を作成")
        install_user_venv(cfg, u)
        write_server_files(cfg, u)
        info("[5/5] 設定ファイル・ファイアウォールを登録 (ポート %s)" % u["port"])
        cfg = read_config()
        cfg["users"].append(u)
        save_config(cfg)
        sync_firewall(cfg)
    except BaseException as e:
        warn("作成に失敗したため、途中まで作ったものを片付けます: %s" % e)
        with _suppress():
            remove_leftovers(name, None if reuse else folder)
            cfg = read_config()
            cfg["users"] = [x for x in cfg["users"] if x["name"] != name]
            save_config(cfg)
        raise JfsError("ユーザー '%s' の作成に失敗しました: %s" % (name, e))
    if hub_pid():
        add_wanted(name)
        info("サーバー管理ウィンドウで起動しています...")
        if wait_listening(u["port"]):
            ok("ユーザー '%s' (ポート %s) が起動しました。" % (name, u["port"]))
        else:
            warn("まだ起動していません。サーバー管理ウィンドウの表示を確認してください。")
    else:
        info("サーバーを起動するには '%s start' を実行してください (実行した端末がサーバー管理ウィンドウになります)。" % CMD)
    show_user_urls(cfg, u)


def remove_leftovers(name, folder):
    with _suppress():
        remove_wanted(read_config(), name)
    with _suppress():
        set_hold(name, False)
    remove_account(USER_PREFIX + name)
    if folder and os.path.lexists(folder):
        remove_tree(folder)
        ok("フォルダを削除しました: " + folder)


def cmd_remove(cfg, a):
    if not a.name:
        raise JfsError("ユーザー名を指定してください。")
    name = normalize_name(a.name)
    u = find_user(cfg, name)
    folder = u["path"] if u else os.path.join(instances_root(cfg), name)
    if not u and not os.path.lexists(folder) and not account_exists(USER_PREFIX + name):
        raise JfsError("ユーザー '%s' は登録されていません。'%s list' で確認してください。" % (name, CMD))
    if not a.force:
        msg = "ユーザー '%s' の環境を削除します。" % name
        msg += ("フォルダ %s は残ります。" % folder) if a.keep_files else ("フォルダ %s も中身 (ノートブックなど) ごと削除されます。" % folder)
        if not ask_yes(msg + " よろしいですか?"):
            info("中止しました。")
            return
    if hub_pid():
        remove_wanted(cfg, name)
        time.sleep(3)   # サーバー管理ウィンドウ側で止める
    if u:
        cfg["users"] = [x for x in cfg["users"] if x["name"] != name]
        save_config(cfg)
    sync_firewall(cfg, quiet=True)
    remove_leftovers(name, None if a.keep_files else folder)
    ok("ユーザー '%s' の環境を削除しました。" % name)


def cmd_start(cfg, a):
    if not cfg["users"]:
        raise JfsError("ユーザー環境がありません。'%s add <ユーザー名>' で作成してください。" % CMD)
    if a.name and a.name != "all":
        targets = [required_user(cfg, a.name)]
        add_wanted(targets[0]["name"])
    else:
        targets = cfg["users"]
        save_wanted(True, [])
    if not hub_pid():
        invoke_hub()
        return
    info("サーバー管理ウィンドウは既に開いています。そちらで起動されるのを待っています...")
    for u in targets:
        if wait_listening(u["port"]):
            ok("ユーザー '%s' (ポート %s) が起動しました。" % (u["name"], u["port"]))
        else:
            warn("ユーザー '%s' が起動しませんでした。サーバー管理ウィンドウの表示を確認してください。" % u["name"])


def cmd_stop(cfg, a):
    if a.name and a.name != "all":
        u = required_user(cfg, a.name)
        remove_wanted(cfg, u["name"])
        if not hub_pid():
            kill_account_processes(account_name(u))
        ok("ユーザー '%s' の環境を停止しました。" % u["name"])
        return
    save_wanted(False, [])
    deadline = time.time() + 20
    while hub_pid() and time.time() < deadline:
        time.sleep(1)   # サーバー管理ウィンドウ側で止めて終わる
    for u in cfg["users"]:
        kill_account_processes(account_name(u))
    kill_account_processes(MONITOR_ACCOUNT)
    ok("全員のサーバーを停止しました。")


def restart_user(cfg, u):
    if not (hub_pid() and is_wanted(get_wanted(), u["name"])):
        kill_account_processes(account_name(u))
        info("変更は次回の起動から反映されます ('%s start %s')。" % (CMD, u["name"]))
        return False
    info("ユーザー '%s' の環境を再起動しています..." % u["name"])
    set_hold(u["name"], True)          # サーバー管理ウィンドウ側で止めてもらう
    deadline = time.time() + 15
    while port_listening(u["port"]) and time.time() < deadline:
        time.sleep(0.5)
    set_hold(u["name"], False)         # 起動用ファイルを作り直して起動し直す
    if wait_listening(u["port"]):
        ok("ユーザー '%s' の環境を再起動しました (ポート %s)。" % (u["name"], u["port"]))
        return True
    warn("ユーザー '%s' の環境が起動しませんでした。サーバー管理ウィンドウの表示を確認してください。" % u["name"])
    return False


def cmd_restart(cfg, a):
    for u in target_users(cfg, a.name):
        restart_user(cfg, u)


def cmd_url(cfg, a):
    for u in target_users(cfg, a.name):
        show_user_urls(cfg, u)
    if not a.name and cfg["monitor"].get("enabled"):
        show_monitor_urls(cfg)


def cmd_token(cfg, a):
    u = required_user(cfg, a.name)
    if a.new:
        u["token"] = new_token()
        save_config(cfg)
        restart_user(cfg, u)
        ok("新しいトークンを発行しました。古い URL は使えなくなります。")
    show_user_urls(cfg, u)


def cmd_set(cfg, a):
    u = required_user(cfg, a.name)
    if a.port:
        if a.port in reserved_ports(cfg, u["name"]) or (port_listening(a.port) and a.port != int(u["port"])):
            raise JfsError("ポート %d は既に使われています。" % a.port)
        u["port"] = a.port
    if a.allow_from:
        cfg["defaults"]["allowFrom"] = a.allow_from
        info("接続を許可する相手は全ユーザー共通の設定です (defaults.allowFrom)。")
    if not a.port and not a.allow_from:
        raise JfsError("変更する内容を指定してください。例: %s set %s -Port 23456" % (CMD, u["name"]))
    save_config(cfg)
    sync_firewall(cfg)
    restart_user(cfg, u)
    show_user_urls(cfg, u)


def cmd_logs(cfg, a):
    if not a.name:
        raise JfsError("ユーザー名 (または monitor) を指定してください。")
    if a.name == "monitor":
        log = monitor_paths()["log"]
    else:
        p = paths(required_user(cfg, a.name))
        log = p["log"]
        print("== 実行したコマンド (%s) ==" % p["cmdlog"])
        if os.path.exists(p["cmdlog"]):
            run(["tail", "-n", "50", p["cmdlog"]], check_rc=False)
        else:
            print("  (まだありません)")
        print("== サーバーのログ (%s) ==" % log)
    if not os.path.exists(log):
        raise JfsError("ログファイルがまだありません: " + log)
    try:
        run(["tail", "-n", "100"] + (["-F"] if a.follow else []) + [log], check_rc=False)
    except KeyboardInterrupt:
        pass


def suspend_for(cfg, u, fn):
    in_hub = bool(hub_pid()) and is_wanted(get_wanted(), u["name"])
    if in_hub:
        set_hold(u["name"], True)
        deadline = time.time() + 15
        while port_listening(u["port"]) and time.time() < deadline:
            time.sleep(0.5)
    else:
        kill_account_processes(account_name(u))
    try:
        fn()
    finally:
        if in_hub:
            set_hold(u["name"], False)


def cmd_upgrade(cfg, a):
    for u in target_users(cfg, a.name):
        suspend_for(cfg, u, lambda u=u: (install_jupyterlab(cfg, u, upgrade=True), register_kernel(u)))


def cmd_reset_venv(cfg, a):
    u = required_user(cfg, a.name)
    if not a.force and not ask_yes("ユーザー '%s' の venv を作り直します (追加したパッケージは消えます)。よろしいですか?" % u["name"]):
        info("中止しました。")
        return

    def reset():
        remove_tree(paths(u)["venv"])
        pw = pwd.getpwnam(account_name(u))
        init_instance_folders(u, pw.pw_uid, pw.pw_gid)
        install_user_venv(cfg, u)
    suspend_for(cfg, u, reset)


def cmd_refresh(cfg, a):
    for u in cfg["users"]:
        if not os.path.isdir(paths(u)["server"]):
            warn("ユーザー '%s' のフォルダがありません。" % u["name"])
            continue
        if not account_exists(account_name(u)):
            warn("ユーザー '%s' の実行用アカウントがありません。'%s remove %s -KeepFiles' のあと '%s add %s' で作り直してください。"
                 % (u["name"], CMD, u["name"], CMD, u["name"]))
            continue
        prepare_user(cfg, u)
        ok("ユーザー '%s' の起動用ファイルと設定を更新しました。" % u["name"])
    info("起動中のサーバーに反映するには '%s restart' を実行してください。" % CMD)


def install_monitor(cfg):
    mp = monitor_paths()
    uid, gid = ensure_account(MONITOR_ACCOUNT, mp["tmp"], "jupyter-for-share resource monitor")
    make_dir(mp["runtime"], 0, 0, 0o755)
    py = os.path.join(mp["venv"], "bin", "python")
    if not (os.path.exists(py) and python_version(py)):
        info("リソースモニター用の venv を作成しています...")
        run([base_python_or_raise(cfg), "-m", "venv", mp["venv"]], quiet=True)
    if missing_packages(py, ["psutil"]):
        try:
            run([py, "-m", "pip", "install", "--disable-pip-version-check", "psutil"], quiet=True)
        except JfsError:
            # Jetson など、配布されているビルド済みのものがない場合はビルドが必要
            raise JfsError("psutil をインストールできませんでした。ビルドに必要なものを入れてから再実行してください "
                           "(Ubuntu / Jetson の例: sudo apt-get install -y build-essential python3-dev)。")
    run(["chmod", "-R", "go+rX,go-w", mp["venv"]], quiet=True)
    save_config(cfg)   # users.json を書く


def cmd_monitor(cfg, a):
    if a.port and a.port != int(cfg["monitor"].get("port", 8000)):
        if a.port in reserved_ports(cfg) or port_listening(a.port):
            raise JfsError("ポート %d は既に使われています。" % a.port)
        cfg["monitor"]["port"] = a.port
    if a.allow_from:
        cfg["defaults"]["allowFrom"] = a.allow_from
    cfg["monitor"]["enabled"] = True
    install_monitor(cfg)
    save_config(cfg)
    sync_firewall(cfg)
    for u in cfg["users"]:
        with _suppress():
            write_user_readme(cfg, u)
    if hub_pid():
        info("サーバー管理ウィンドウでリソースモニターを起動します (設定を変えた場合は、ウィンドウを開き直すと反映されます)。")
    else:
        info("リソースモニターは '%s start' で開くサーバー管理ウィンドウの中で、ユーザーのサーバーと一緒に動きます。" % CMD)
    show_monitor_urls(cfg)


def cmd_monitor_stop(cfg, a):
    cfg["monitor"]["enabled"] = False
    save_config(cfg)
    kill_account_processes(MONITOR_ACCOUNT)
    sync_firewall(cfg, quiet=True)
    ok("リソースモニターを停止しました (再開は '%s monitor')。" % CMD)


def service_active(name):
    return shutil.which("systemctl") and output(["systemctl", "is-active", name]).strip() == "active"


def network_plan(cfg, say=True):
    plan = []
    if say:
        print("-- ネットワーク --")
    for ifname, addr, prefix in lan_addresses():
        if say:
            check(True, "%s: %s/%d" % (ifname, addr, prefix))
    if say:
        print("-- ファイアウォール --")
    kind = firewall_kind()
    if not kind:
        if say:
            check(True, "ufw / firewalld は動いていません (受信は制限されていません)")
    else:
        record = read_json(os.path.join(RUNTIME_DIR, "firewall.json"), {}) or {}
        have = {(r["port"], r["source"]) for r in record.get("rules", [])} if record.get("kind") == kind else set()
        missing = [r for r in expected_rules(cfg) if (r["port"], r["source"]) not in have]
        for r in expected_rules(cfg):
            good = (r["port"], r["source"]) in have
            if say:
                check(good, "%s: TCP %d (%s / 接続元: %s) %s" % (kind, r["port"], r["label"], r["source"], "許可済み" if good else "未設定"))
        if missing:
            plan.append(("ポートの許可規則を %s に追加する" % kind, "firewall"))
    if say:
        print("-- コンピューター名での接続 (%s.local) --" % socket.gethostname().split(".")[0].lower())
    if service_active("avahi-daemon"):
        if say:
            check(True, "avahi-daemon (mDNS): 動作中")
        if kind == "ufw" and say:
            info("ufw を使っている場合、mDNS (UDP 5353) の受信も許可が必要なことがあります: sudo ufw allow 5353/udp")
    elif shutil.which("avahi-daemon"):
        if say:
            check(False, "avahi-daemon (mDNS) がインストール済みですが動いていません")
        plan.append(("avahi-daemon を起動し、PC の起動時に自動で起動するようにする", "avahi-enable"))
    else:
        if say:
            check(False, "avahi-daemon (mDNS) がありません。<コンピューター名>.local で接続できません")
        plan.append(("avahi-daemon (mDNS) をインストールして起動する", "avahi-install"))
    return plan


def cmd_network(cfg, a):
    print("== 現在の状態 ==")
    plan = network_plan(cfg)
    print()
    if not plan:
        ok("変更が必要な設定はありません。")
    else:
        print("== 適用する変更 ==")
        for i, (text, _) in enumerate(plan, 1):
            print("  %d. %s" % (i, text))
        print()
        if not a.yes and not ask_yes("上の変更を適用しますか?"):
            info("変更せずに終了しました。")
            return
        for text, kind in plan:
            try:
                if kind == "firewall":
                    sync_firewall(cfg)
                elif kind == "avahi-enable":
                    run(["systemctl", "enable", "--now", "avahi-daemon"], quiet=True)
                elif kind == "avahi-install":
                    install_packages({"apt-get": ["avahi-daemon"], "dnf": ["avahi", "nss-mdns"], "yum": ["avahi"],
                                      "zypper": ["avahi"], "pacman": ["avahi", "nss-mdns"]}, "avahi-daemon")
                    if shutil.which("systemctl"):
                        run(["systemctl", "enable", "--now", "avahi-daemon"], quiet=True, check_rc=False)
                ok(text)
            except Exception as e:   # noqa: BLE001
                warn("%s: 失敗しました (%s)" % (text, e))
        print()
        print("== 変更後の状態 ==")
        rest = network_plan(cfg)
        print()
        if rest:
            warn("まだ %d 件の項目が残っています (上の [NG] を確認してください)。" % len(rest))
        else:
            ok("すべて設定済みです。")
    print()
    print("IP アドレスではつながるのに <コンピューター名>.local でつながらない場合は、接続する側の PC で次を実行して確認してください:")
    print("    ping %s.local" % socket.gethostname().split(".")[0].lower())
    print("  確実にするには、ルーターでこの PC の IP を固定して名前を登録するか、接続する PC の hosts に登録してください。")


def as_user_check(u, check_paths):
    """本人のアカウントとして、各場所をたどれるかを確かめる"""
    code = ("import os, sys\nfor p in sys.argv[1:]:\n    try:\n        os.lstat(p); r = 'OK'\n"
            "    except Exception as e:\n        r = 'NG  %s: %s' % (type(e).__name__, e)\n    print(p, '->', r)\n")
    pw = pwd.getpwnam(account_name(u))
    p = subprocess.run([labpython(u), "-c", code] + check_paths, preexec_fn=demote(pw.pw_uid, pw.pw_gid),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd="/")
    return p.stdout


def cmd_doctor(cfg, a):
    print("== jupyter-for-share 診断 (バージョン %s) ==" % jfs_version())
    print("-- 全体 --")
    py = find_base_python(cfg)
    check(bool(py), "Python: %s" % (py or "見つかりません ('sudo ./setup.sh' を実行)"))
    try:
        grp.getgrnam(GROUP)
        check(True, "グループ %s" % GROUP)
    except KeyError:
        check(False, "グループ %s がありません ('sudo ./setup.sh' を実行)" % GROUP)
    hub = hub_pid()
    check(bool(hub), "サーバー管理ウィンドウ: " + ("動作中 (pid %d)" % hub if hub else "なし ('%s start' で開きます)" % CMD))
    for u in target_users(cfg, a.name):
        p = paths(u)
        print("-- ユーザー '%s' (ポート %s) --" % (u["name"], u["port"]))
        check(account_exists(account_name(u)), "実行用アカウント %s" % account_name(u))
        check(os.path.exists(labpython(u)), "JupyterLab: " + p["lab"])
        check(os.path.exists(os.path.join(p["venv"], "pyvenv.cfg")), "venv: " + p["venv"])
        listening = port_listening(u["port"])
        check(listening, "ポート %s で待ち受け" % u["port"] + ("" if listening else " していません"))
        if listening:
            try:
                urllib.request.urlopen("http://127.0.0.1:%s/api/status?token=%s" % (u["port"], u["token"]), timeout=5)
                check(True, "このPCからの HTTP 応答")
            except Exception as e:   # noqa: BLE001
                check(False, "このPCからの HTTP 応答: %s" % e)
        if a.name and account_exists(account_name(u)) and os.path.exists(labpython(u)):
            print("   実行用アカウントとして各場所をたどれるか:")
            targets = []
            d = p["work"]
            while True:
                targets.insert(0, d)
                if d == "/":
                    break
                d = os.path.dirname(d)
            targets += [p["venv"], venvpython(u), p["etc"], p["config"], p["home"], p["runtime"], p["tmp"], p["logs"]]
            for line in as_user_check(u, targets).splitlines():
                print("     " + line)
        if os.path.exists(p["log"]):
            print("   サーバーのログ (末尾):")
            for line in output(["tail", "-n", "8", p["log"]]).splitlines():
                print("     " + line)
    network_plan(cfg)


def cmd_uninstall(cfg, a):
    if not a.force:
        msg = "jupyter-for-share がこの PC に加えた変更をすべて元に戻します (サーバーは停止し、実行用アカウントは削除されます)。"
        if a.delete_files:
            msg += " user フォルダ (ノートブックなど) も削除します。"
        if not ask_yes(msg + " よろしいですか?"):
            info("中止しました。")
            return
    print("== jupyter-for-share のアンインストール ==")
    info("[1/6] サーバーとリソースモニターを停止しています...")
    with _suppress():
        save_wanted(False, [], [])
    hub = hub_pid()
    if hub:
        with _suppress():
            os.kill(hub, signal.SIGTERM)
        deadline = time.time() + 20
        while hub_pid() and time.time() < deadline:
            time.sleep(0.5)
    accounts = [pw.pw_name for pw in pwd.getpwall() if pw.pw_name.startswith(USER_PREFIX) or pw.pw_name == MONITOR_ACCOUNT]
    for acct in accounts:
        kill_account_processes(acct)
    info("[2/6] ファイアウォール規則を削除しています...")
    n = remove_firewall_rules()
    ok("規則を削除しました (%d 件)。" % n) if n else ok("削除する規則はありません。")
    info("[3/6] 実行用アカウントとグループを削除しています...")
    for acct in accounts:
        remove_account(acct)
    with _suppress():
        grp.getgrnam(GROUP)
        run(["groupdel", GROUP], quiet=True, check_rc=False)
        ok("グループ '%s' を削除しました。" % GROUP)
    info("[4/6] 上の階層に付けた通り抜けの許可を元に戻しています...")
    for c in read_json(os.path.join(RUNTIME_DIR, "ancestors.json"), []) or []:
        with _suppress():
            if c.get("how") == "acl":
                run(["setfacl", "-x", "g:%s" % GROUP, c["path"]], quiet=True, check_rc=False)
            else:
                os.chmod(c["path"], os.stat(c["path"]).st_mode & ~stat.S_IXOTH)
            ok("元に戻しました: " + c["path"])
    info("[5/6] 実行時のファイルを削除しています...")
    for d in (RUNTIME_DIR, os.path.join(MONITOR_DIR, ".runtime"), os.path.join(MONITOR_DIR, ".venv")):
        remove_tree(d)
    if os.path.exists(CONFIG_PATH):
        os.replace(CONFIG_PATH, CONFIG_PATH + ".uninstalled")
        ok("設定ファイルは %s.uninstalled に残しました (トークンを含みます)。" % CONFIG_PATH)
    root = instances_root(cfg)
    if a.delete_files and os.path.exists(root):
        info("[6/6] ユーザーのフォルダを削除しています: " + root)
        remove_tree(root)
        ok("削除しました。")
    elif os.path.exists(root):
        # 削除したアカウントのファイルが残るので、持ち主を管理者 (sudo した人) にしておく
        owner = int(os.environ.get("SUDO_UID") or os.stat(REPO).st_uid)
        ogid = int(os.environ.get("SUDO_GID") or os.stat(REPO).st_gid)
        chown_tree(root, owner, ogid)
        run(["chmod", "-R", "u+rwX", root], quiet=True, check_rc=False)
        info("[6/6] ユーザーのフォルダは残しました: %s (不要なら削除してください)" % root)
        info("      再セットアップ後に同じユーザー名で '%s add <ユーザー名>' を実行すると、中身をそのまま引き継ぎます。" % CMD)
    print()
    ok("アンインストールが完了しました。もう一度使う場合は 'sudo ./setup.sh' を実行してください。")


def cmd_setup(cfg, a):
    print()
    print("=== jupyter-for-share サーバーセットアップ (Linux / バージョン %s) ===" % jfs_version())
    if a.domain:
        cfg["defaults"]["domain"] = a.domain
    save_config(cfg)
    ok("設定ファイル: " + CONFIG_PATH)
    ok("インストール先: %s (ユーザー環境はこの中の user フォルダに作られます)" % REPO)

    # Python: まずインストール済みのものを探す
    py = find_base_python(cfg, report=True)
    if py:
        ok("インストール済みの Python を使います: %s" % py)
    else:
        info("使える Python (3.8 以上・venv 付き) がないため、インストールします。")
        install_packages({"apt-get": apt_python_packages(), "dnf": ["python3", "python3-pip"],
                          "yum": ["python3", "python3-pip"], "zypper": ["python3", "python3-pip"],
                          "pacman": ["python", "python-pip"]}, "Python")
        py = find_base_python(cfg)
        if not py:
            raise JfsError("Python のインストールを確認できませんでした。")
    # Git
    if shutil.which("git"):
        ok("インストール済みの Git を使います: " + shutil.which("git"))
    else:
        install_packages({"apt-get": ["git"], "dnf": ["git"], "yum": ["git"], "zypper": ["git"], "pacman": ["git"]}, "Git")

    ensure_group()
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    os.chmod(RUNTIME_DIR, 0o700)
    root = init_instances_root(cfg)
    ok("ユーザー環境を作る場所: " + root)

    if not a.skip_monitor:
        if a.port:
            cfg["monitor"]["port"] = a.port
        cfg["monitor"]["enabled"] = True
        install_monitor(cfg)
        save_config(cfg)
        ok("リソースモニターを設置しました (ポート %s)。" % cfg["monitor"]["port"])
    sync_firewall(cfg)
    cmd_refresh(cfg, a)
    if not service_active("avahi-daemon"):
        warn("mDNS (avahi-daemon) が動いていないため、<コンピューター名>.local では接続できません。'%s network' で設定できます。" % CMD)
    print()
    ok("セットアップが完了しました。")
    print("""
次の手順:
  1. ユーザー環境を作成する (例: alice さん用。ポートは自動で決まります)
       ./jfs.sh add alice
  2. サーバーを起動する (実行した端末がサーバー管理ウィンドウになり、全員のログが表示されます。閉じると停止)
       ./jfs.sh start
  3. 表示された URL を本人に伝え、別の PC のブラウザで開いてもらう
  4. 別の PC からつながらない場合は './jfs.sh network'、それ以外の問題は './jfs.sh doctor'
""")


HELP = """jupyter-for-share 管理コマンド (Linux)

使い方: ./jfs.sh <コマンド> [ユーザー名] [オプション]
        管理者 (root) の権限が必要なコマンドは、自動で sudo します。

ユーザー環境
  ./jfs.sh add <ユーザー名>              作成 (ポートは自動で決定)
  ./jfs.sh list                          一覧と状態
  ./jfs.sh url [ユーザー名]              接続用 URL を表示
  ./jfs.sh start [ユーザー名]            起動 (省略で全員)。この端末がサーバー管理ウィンドウになり、閉じると全員停止
  ./jfs.sh stop|restart [ユーザー名]     停止 / 再起動 (省略で全員)
  ./jfs.sh remove <ユーザー名>           フォルダごと削除 (-KeepFiles でフォルダは残す)
  ./jfs.sh token <ユーザー名> -New       トークンを再発行
  ./jfs.sh set <ユーザー名> -Port 番号   ポートなどを変更
  ./jfs.sh logs <ユーザー名> [-Follow]   ログと実行コマンドの記録を表示
  ./jfs.sh upgrade [ユーザー名]          JupyterLab を更新
  ./jfs.sh reset-venv <ユーザー名>       venv を作り直す

リソースモニター (CPU / メモリ / GPU)
  ./jfs.sh monitor [-Port 8000]          設置・更新 (サーバー管理ウィンドウの中で動く)
  ./jfs.sh monitor-stop                  停止

サーバー全体
  ./jfs.sh refresh                       起動用ファイルなどを作り直す (更新後)
  ./jfs.sh doctor [ユーザー名]           つながらないときの診断
  ./jfs.sh network [-Yes]                他の PC から接続できるように、ファイアウォールと mDNS を確認・設定
  ./jfs.sh uninstall [-DeleteFiles]      この PC に加えた変更をすべて元に戻す (uninstall.sh と同じ)
  ./jfs.sh version                       バージョンを表示
"""


class Args:
    def __init__(self, argv):
        self.command = ""
        self.name = ""
        self.port = 0
        self.allow_from = []
        self.domain = ""
        self.force = self.keep_files = self.new = self.follow = self.yes = False
        self.delete_files = self.skip_monitor = False
        rest = list(argv)
        positional = []
        while rest:
            x = rest.pop(0)
            if x.startswith("-") and len(x) > 1:
                key = x.lstrip("-").lower().replace("-", "")
                if key in ("port", "monitorport"):
                    self.port = int(rest.pop(0))
                elif key == "allowfrom":
                    self.allow_from = [s.strip() for s in rest.pop(0).split(",") if s.strip()]
                elif key == "domain":
                    self.domain = rest.pop(0)
                elif key in ("force", "f"):
                    self.force = True
                elif key == "keepfiles":
                    self.keep_files = True
                elif key == "new":
                    self.new = True
                elif key == "follow":
                    self.follow = True
                elif key in ("yes", "y"):
                    self.yes = True
                elif key == "deletefiles":
                    self.delete_files = True
                elif key == "skipmonitor":
                    self.skip_monitor = True
                elif key in ("h", "help", "?"):
                    positional.insert(0, "help")
                else:
                    raise JfsError("不明なオプションです: %s ('%s help' で使い方を表示)" % (x, CMD))
            else:
                positional.append(x)
        if positional:
            self.command = positional[0].lower()
        if len(positional) > 1:
            self.name = positional[1].lower()


COMMANDS = {
    "list": cmd_list, "add": cmd_add, "remove": cmd_remove, "start": cmd_start, "stop": cmd_stop,
    "restart": cmd_restart, "url": cmd_url, "token": cmd_token, "set": cmd_set, "logs": cmd_logs,
    "upgrade": cmd_upgrade, "reset-venv": cmd_reset_venv, "refresh": cmd_refresh, "monitor": cmd_monitor,
    "monitor-stop": cmd_monitor_stop, "network": cmd_network, "doctor": cmd_doctor, "uninstall": cmd_uninstall,
    "setup": cmd_setup,
}
WINDOWS_ONLY = {
    "autostart": "Linux 版では自動起動の機能はありません。PC の起動後に './jfs.sh start' を実行してください。",
    "protect": "Linux 版では不要です。実行用アカウントは通常の Linux の権限により、他のユーザーのフォルダやシステムのファイルを変更できません。",
    "unprotect": "Linux 版では不要です (protect の説明を参照)。",
    "firewall": "Linux 版では './jfs.sh network' を使ってください。",
}


def main(argv):
    try:
        a = Args(argv)
        if a.command in ("", "help"):
            print(HELP)
            return 0
        if a.command == "version":
            print("jupyter-for-share %s\n場所: %s" % (jfs_version(), REPO))
            return 0
        if a.command in WINDOWS_ONLY:
            info(WINDOWS_ONLY[a.command])
            return 0
        os.umask(0o022)
        if a.command not in ("hub", "start"):
            signal.signal(signal.SIGPIPE, signal.SIG_DFL)   # '| head' などで出力先が閉じられたら静かに終わる
        if a.command == "hub":
            require_root()
            invoke_hub()
            return 0
        fn = COMMANDS.get(a.command)
        if not fn:
            raise JfsError("不明なコマンドです: %s ('%s help' で使い方を表示)" % (a.command, CMD))
        require_root()
        fn(read_config(), a)
        return 0
    except JfsError as e:
        print(_color("31", "[x] %s" % e), flush=True)
        return 1
    except KeyboardInterrupt:
        print()
        return 130
    except Exception as e:   # noqa: BLE001 - 想定外のエラーも、内容が分かるように表示して終わる
        import traceback
        traceback.print_exc()
        print(_color("31", "[x] 予期しないエラーが発生しました: %s" % e), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
