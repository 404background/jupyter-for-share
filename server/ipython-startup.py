# jupyter-for-share: ノートブックで実行したセル (!コマンド や %pip を含む) を .logs/commands.log に記録する。
# jfs.cmd が各ユーザー環境の IPython の startup フォルダにコピーする。


def _jfs_setup_cell_log():
    import datetime
    import os

    path = os.environ.get("JFS_COMMAND_LOG")
    shell = get_ipython()  # noqa: F821 (IPython の startup ファイル内で使える)
    if not path or shell is None:
        return
    notebook = os.path.basename(os.environ.get("JPY_SESSION_NAME", "")) or "notebook"

    def log_cell(info):
        try:
            source = (getattr(info, "raw_cell", "") or "").rstrip()
            if not source:
                return
            stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with open(path, "a", encoding="utf-8") as f:
                f.write("%s [%s] %s\n" % (stamp, notebook, source.replace("\n", "\n    ")))
        except Exception:
            pass

    shell.events.register("pre_run_cell", log_cell)


_jfs_setup_cell_log()
del _jfs_setup_cell_log
