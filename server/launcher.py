"""jupyter-for-share: JupyterLab を起動し、サーバー管理ウィンドウが閉じられたら停止するランチャー

jfs.ps1 が各ユーザー環境の .server\\config にコピーし、run.cmd から
    python launcher.py <ハートビートファイル>
として実行します (サーバー実行用アカウントの権限で動きます)。

- サーバー管理ウィンドウ (jfs.cmd start で開くウィンドウ) は、ハートビートファイルを毎秒更新します。
  更新が HEARTBEAT_TIMEOUT 秒止まったら (ウィンドウが閉じられたら) JupyterLab を停止します。
- Windows のジョブオブジェクトに入れておくことで、このランチャーが終了したときに
  JupyterLab が起動したカーネルやターミナルもまとめて終了させます。
"""

import ctypes
import os
import subprocess
import sys
import time

HEARTBEAT_TIMEOUT = 20   # 秒
CHECK_INTERVAL = 2       # 秒


def log(message):
    print("[jupyter-for-share] " + message, flush=True)


def create_kill_on_close_job():
    """このプロセスと子孫を、ランチャー終了時にまとめて終了させるジョブオブジェクトに入れる"""
    from ctypes import wintypes

    class IO_COUNTERS(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class BASIC_LIMIT(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_int64),
            ("PerJobUserTimeLimit", ctypes.c_int64),
            ("LimitFlags", wintypes.DWORD),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", wintypes.DWORD),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", wintypes.DWORD),
            ("SchedulingClass", wintypes.DWORD),
        ]

    class EXTENDED_LIMIT(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", BASIC_LIMIT),
            ("IoInfo", IO_COUNTERS),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
    JobObjectExtendedLimitInformation = 9

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    k32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    k32.SetInformationJobObject.restype = wintypes.BOOL
    k32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    k32.AssignProcessToJobObject.restype = wintypes.BOOL
    k32.GetCurrentProcess.restype = wintypes.HANDLE

    job = k32.CreateJobObjectW(None, None)
    if not job:
        return None
    info = EXTENDED_LIMIT()
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not k32.SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                       ctypes.byref(info), ctypes.sizeof(info)):
        return None
    if not k32.AssignProcessToJobObject(job, k32.GetCurrentProcess()):
        return None
    return job   # ハンドルはプロセス終了まで開いたままにする (閉じるとジョブ内のプロセスが終了する)


def heartbeat_age(path):
    try:
        return time.time() - os.path.getmtime(path)
    except OSError:
        return float("inf")


def main():
    heartbeat = sys.argv[1] if len(sys.argv) > 1 else ""
    job = None
    if os.name == "nt":
        job = create_kill_on_close_job()
        if job is None:
            log("警告: ジョブオブジェクトを作成できませんでした。停止時にカーネルが残る場合があります。")

    proc = subprocess.Popen([sys.executable, "-m", "jupyterlab"])
    log("JupyterLab を起動しました (pid %d)" % proc.pid)
    while True:
        code = proc.poll()
        if code is not None:
            log("JupyterLab が終了しました (終了コード %d)" % code)
            return code
        if heartbeat and heartbeat_age(heartbeat) > HEARTBEAT_TIMEOUT:
            log("サーバー管理ウィンドウが閉じられた (または停止の指示があった) ため、サーバーを停止します")
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
            return 0
        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
