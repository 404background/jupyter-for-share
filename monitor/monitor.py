"""jupyter-for-share リソースモニター

サーバー PC の CPU / メモリ / GPU / ディスクの使用状況と、各ユーザー環境の稼働状況を
ブラウザで表示する小さな Web サーバーです。jfs.ps1 がタスクスケジューラから起動します。

    python monitor.py --port 8000 --users <users.json> --disk <フォルダ>
"""

import argparse
import collections
import contextlib
import ctypes
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psutil

INTERVAL = 2.0      # 計測間隔 (秒)
HISTORY = 150       # グラフに残す点の数 (2 秒 x 150 = 5 分)
HERE = os.path.dirname(os.path.abspath(__file__))


# ---- GPU: NVIDIA (nvidia-smi) ----

def find_nvidia_smi():
    path = shutil.which("nvidia-smi")
    if path:
        return path
    for p in (
        os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "nvidia-smi.exe"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                     "NVIDIA Corporation", "NVSMI", "nvidia-smi.exe"),
    ):
        if os.path.exists(p):
            return p
    return None


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


class NvidiaGpu:
    FIELDS = "index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw"

    def __init__(self, exe):
        self.exe = exe

    def read(self):
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        out = subprocess.run(
            [self.exe, "--query-gpu=" + self.FIELDS, "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10, creationflags=flags, check=True,
        ).stdout
        gpus = []
        for line in out.strip().splitlines():
            cols = [c.strip() for c in line.split(",")]
            if len(cols) < 7:
                continue
            mem_used, mem_total = to_float(cols[3]), to_float(cols[4])
            gpus.append({
                "name": cols[1],
                "util": to_float(cols[2]),
                "mem_used": mem_used * 1024 * 1024 if mem_used is not None else None,
                "mem_total": mem_total * 1024 * 1024 if mem_total is not None else None,
                "temp": to_float(cols[5]),
                "power": to_float(cols[6]),
            })
        return gpus


# ---- GPU: その他 (Windows のパフォーマンスカウンター。タスクマネージャーと同じ情報) ----

class PdhGpu:
    PDH_FMT_DOUBLE = 0x00000200
    PDH_FMT_NOCAP100 = 0x00008000
    PDH_MORE_DATA = 0x800007D2

    class _Value(ctypes.Structure):
        _fields_ = [("CStatus", ctypes.c_uint32), ("doubleValue", ctypes.c_double)]

    class _Item(ctypes.Structure):
        pass

    _Item._fields_ = [("szName", ctypes.c_wchar_p), ("FmtValue", _Value)]

    ENGINE_RE = re.compile(r"luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_(\d+)_eng_(\d+)_engtype_(.*)$", re.I)
    ADAPTER_RE = re.compile(r"luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_(\d+)$", re.I)

    def __init__(self):
        from ctypes import wintypes
        self.pdh = ctypes.WinDLL("pdh")
        self.query = wintypes.HANDLE()
        self.util = wintypes.HANDLE()
        self.mem = wintypes.HANDLE()
        self._check(self.pdh.PdhOpenQueryW(None, None, ctypes.byref(self.query)))
        # 英語名で指定するので、日本語版 Windows でも動く
        self._check(self.pdh.PdhAddEnglishCounterW(
            self.query, r"\GPU Engine(*)\Utilization Percentage", None, ctypes.byref(self.util)))
        self._check(self.pdh.PdhAddEnglishCounterW(
            self.query, r"\GPU Adapter Memory(*)\Dedicated Usage", None, ctypes.byref(self.mem)))
        self.pdh.PdhCollectQueryData(self.query)
        self.names = self._adapter_names()

    @staticmethod
    def _check(status):
        if status & 0xFFFFFFFF != 0:
            raise OSError("PDH error 0x%08X" % (status & 0xFFFFFFFF))

    @staticmethod
    def _adapter_names():
        try:
            out = subprocess.run(
                ["powershell.exe", "-NoProfile", "-Command",
                 "(Get-CimInstance Win32_VideoController).Name"],
                capture_output=True, text=True, timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            ).stdout
            return [n.strip() for n in out.splitlines() if n.strip()]
        except Exception:
            return []

    def _array(self, counter):
        size = ctypes.c_uint32(0)
        count = ctypes.c_uint32(0)
        fmt = self.PDH_FMT_DOUBLE | self.PDH_FMT_NOCAP100
        status = self.pdh.PdhGetFormattedCounterArrayW(counter, fmt, ctypes.byref(size), ctypes.byref(count), None)
        if status & 0xFFFFFFFF != self.PDH_MORE_DATA:
            return {}
        buf = (ctypes.c_byte * size.value)()
        status = self.pdh.PdhGetFormattedCounterArrayW(counter, fmt, ctypes.byref(size), ctypes.byref(count), buf)
        if status & 0xFFFFFFFF != 0:
            return {}
        items = ctypes.cast(buf, ctypes.POINTER(self._Item))
        result = {}
        for i in range(count.value):
            if items[i].FmtValue.CStatus in (0, 1):   # PDH_CSTATUS_VALID_DATA / NEW_DATA
                result[items[i].szName] = items[i].FmtValue.doubleValue
        return result

    def read(self):
        self.pdh.PdhCollectQueryData(self.query)
        engines = collections.defaultdict(float)
        for name, value in self._array(self.util).items():
            m = self.ENGINE_RE.search(name)
            if m:
                engines[(m.group(1).lower(), m.group(2), m.group(3), m.group(4))] += value
        adapters = {}
        for (luid, phys, _eng, _type), value in engines.items():
            key = (luid, phys)
            adapters[key] = max(adapters.get(key, 0.0), min(value, 100.0))
        memory = {}
        for name, value in self._array(self.mem).items():
            m = self.ADAPTER_RE.search(name)
            if m:
                memory[(m.group(1).lower(), m.group(2))] = value
        gpus = []
        for key in sorted(set(adapters) | set(memory)):
            if adapters.get(key, 0.0) == 0.0 and memory.get(key, 0.0) == 0.0:
                continue   # 使われていない仮想アダプターなどは表示しない
            gpus.append({
                "name": "GPU %d" % len(gpus),
                "util": adapters.get(key),
                "mem_used": memory.get(key),
                "mem_total": None,
                "temp": None,
                "power": None,
            })
        # カウンターからは GPU の名前が分からないので、台数が一致するときだけ WMI の名前を使う
        if len(gpus) == len(self.names):
            for g, n in zip(gpus, self.names):
                g["name"] = n
        return gpus


# ---- GPU: NVIDIA Jetson (nvidia-smi がない。GPU の使用率は /sys から読む。メモリは CPU と共有) ----

JETSON_LOAD_FILES = (
    "/sys/devices/gpu.0/load",                          # Xavier / Nano / TX2 (JetPack 4・5)
    "/sys/devices/platform/gpu.0/load",
    "/sys/devices/platform/17000000.gv11b/load",        # Xavier (JetPack 5)
    "/sys/devices/17000000.gv11b/load",
    "/sys/devices/platform/17000000.ga10b/load",        # Orin
    "/sys/devices/17000000.ga10b/load",
)


class JetsonGpu:
    def __init__(self, load_file):
        self.load_file = load_file
        try:
            with open("/proc/device-tree/model", encoding="utf-8", errors="replace") as f:
                self.name = f.read().strip("\0\n ") or "NVIDIA Jetson"
        except OSError:
            self.name = "NVIDIA Jetson"
        self.temp_file = None
        for zone in sorted(glob.glob("/sys/class/thermal/thermal_zone*/type")):
            try:
                with open(zone) as f:
                    if f.read().strip().lower().startswith("gpu"):
                        self.temp_file = os.path.join(os.path.dirname(zone), "temp")
                        break
            except OSError:
                pass

    def read(self):
        with open(self.load_file) as f:
            load = to_float(f.read().strip())   # 0 - 1000
        temp = None
        if self.temp_file:
            try:
                with open(self.temp_file) as f:
                    temp = to_float(f.read().strip()) / 1000
            except (OSError, TypeError):
                pass
        return [{"name": self.name, "util": load / 10 if load is not None else None, "mem_used": None,
                 "mem_total": None, "mem_note": "CPU と共有 (上のメモリの値を参照)", "temp": temp, "power": None}]


def create_gpu_reader():
    for path in JETSON_LOAD_FILES:
        if os.path.exists(path):
            try:
                reader = JetsonGpu(path)
                reader.read()
                return reader, "Jetson (" + path + ")"
            except Exception:
                pass
    exe = find_nvidia_smi()
    if exe:
        reader = NvidiaGpu(exe)
        try:
            reader.read()
            return reader, "nvidia-smi"
        except Exception:
            pass
    if sys.platform == "win32":
        try:
            return PdhGpu(), "Windows パフォーマンスカウンター"
        except Exception:
            pass
    return None, "なし"


# ---- 計測 ----

class Sampler(threading.Thread):
    def __init__(self, users_file, disk_path):
        super().__init__(daemon=True)
        self.users_file = users_file
        self.disk_path = disk_path
        self.lock = threading.Lock()
        self.latest = {}
        self.history = collections.deque(maxlen=HISTORY)
        self.gpu, self.gpu_source = create_gpu_reader()
        self.boot_time = psutil.boot_time()

    def load_users(self):
        try:
            with open(self.users_file, encoding="utf-8-sig") as f:
                users = json.load(f).get("users", [])
        except (OSError, ValueError):
            return []
        result = []
        for u in users:
            port = int(u.get("port", 0))
            running = False
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                    running = True
            except OSError:
                pass
            result.append({"name": u.get("name", ""), "port": port, "running": running})
        return result

    def sample(self):
        mem = psutil.virtual_memory()
        snap = {
            "time": time.time(),
            "hostname": socket.gethostname(),
            "uptime": time.time() - self.boot_time,
            "cpu": {
                "percent": psutil.cpu_percent(interval=None),
                "per_core": psutil.cpu_percent(interval=None, percpu=True),
                "cores": psutil.cpu_count(logical=False),
                "threads": psutil.cpu_count(logical=True),
            },
            "memory": {"total": mem.total, "used": mem.total - mem.available, "percent": mem.percent},
            "gpu_source": self.gpu_source,
            "gpus": [],
            "users": self.load_users(),
        }
        if self.disk_path:
            try:
                d = psutil.disk_usage(self.disk_path)
                snap["disk"] = {"path": self.disk_path, "total": d.total, "used": d.used, "percent": d.percent}
            except OSError:
                pass
        if self.gpu:
            try:
                snap["gpus"] = self.gpu.read()
            except Exception as e:  # GPU が取れなくても他の表示は続ける
                snap["gpu_error"] = str(e)
        return snap

    def run(self):
        psutil.cpu_percent(interval=None)
        psutil.cpu_percent(interval=None, percpu=True)
        while True:
            started = time.time()
            try:
                snap = self.sample()
            except Exception as e:
                snap = {"time": time.time(), "error": str(e)}
            point = {
                "t": snap["time"],
                "cpu": snap.get("cpu", {}).get("percent"),
                "mem": snap.get("memory", {}).get("percent"),
                "gpu": [g.get("util") for g in snap.get("gpus", [])],
            }
            with self.lock:
                self.latest = snap
                self.history.append(point)
            time.sleep(max(0.1, INTERVAL - (time.time() - started)))

    def snapshot(self):
        with self.lock:
            return dict(self.latest, history=list(self.history))


# ---- Web サーバー ----

def make_handler(sampler):
    with open(os.path.join(HERE, "index.html"), "rb") as f:
        page = f.read()

    class Handler(BaseHTTPRequestHandler):
        def _send(self, body, content_type):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                self._send(page, "text/html; charset=utf-8")
            elif path == "/api/stats":
                self._send(json.dumps(sampler.snapshot()).encode("utf-8"), "application/json")
            elif path == "/favicon.ico":
                self.send_response(204)
                self.end_headers()
            else:
                self.send_error(404)

        def log_message(self, fmt, *args):
            pass

    return Handler


class DualStackServer(ThreadingHTTPServer):
    """IPv6 と IPv4 の両方で待ち受ける (コンピューター名が IPv6 アドレスに解決されても接続できるように)"""
    address_family = socket.AF_INET6

    def server_bind(self):
        with contextlib.suppress(Exception):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def create_server(bind, port, handler):
    if bind in ("", "*", "0.0.0.0", "::") and socket.has_ipv6:
        try:
            return DualStackServer(("::", port), handler)
        except OSError:
            pass
    return ThreadingHTTPServer(("0.0.0.0" if bind in ("", "*", "::") else bind, port), handler)


def watch_heartbeat(path, timeout=20):
    """サーバー管理ウィンドウが更新するハートビートファイルが止まったら終了する (ウィンドウを閉じたら止まるように)"""
    while True:
        time.sleep(2)
        try:
            age = time.time() - os.path.getmtime(path)
        except OSError:
            age = float("inf")
        if age > timeout:
            print("monitor: サーバー管理ウィンドウが閉じられたため終了します", flush=True)
            os._exit(0)


def main():
    ap = argparse.ArgumentParser(description="jupyter-for-share resource monitor")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--users", default="", help="ユーザー一覧 (users.json)")
    ap.add_argument("--disk", default="", help="使用量を表示するフォルダ")
    ap.add_argument("--heartbeat", default="", help="サーバー管理ウィンドウのハートビートファイル")
    args = ap.parse_args()

    if args.heartbeat:
        threading.Thread(target=watch_heartbeat, args=(args.heartbeat,), daemon=True).start()

    sampler = Sampler(args.users, args.disk)
    sampler.start()
    server = create_server(args.bind, args.port, make_handler(sampler))
    print("monitor: http://%s:%d/ (GPU: %s)" % (args.bind, args.port, sampler.gpu_source), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
