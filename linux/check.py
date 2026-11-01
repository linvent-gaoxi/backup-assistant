"""Run Linux end-to-end checks in disposable directories."""
import hashlib
from pathlib import Path
import os
import tempfile
import threading
import time
from urllib.error import HTTPError

from service import ConsoleState, Remote, invoke, provision, repository, save_json, load_json


def wait_job(state, predicate, timeout=25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        state.tick()
        with state.lock:
            if not state.busy and predicate():
                return
        time.sleep(.2)
    raise AssertionError(state.public())


def run(home):
    source = home / "中文资料"
    dest = home / "还原"
    output = home / "备份"
    state_home = home / "状态"
    for directory in (source, dest, output, state_home):
        directory.mkdir()
    (source / "空目录").mkdir()
    sample = source / "原始数据.bin"
    original = os.urandom(3 * 1024 * 1024 + 111)
    sample.write_bytes(original)
    archive = output / "测试.sbackup"
    password = "演示密码Demo2026"
    invoke("backup", "--source", source, "--output", archive, password=password)
    try:
        invoke("inspect", "--archive", archive, password="错误密码Demo2026")
    except ValueError:
        pass
    else:
        raise AssertionError("错误密码被接受")
    invoke("restore", "--archive", archive, "--destination", dest, password=password)
    assert (dest / source.name / sample.name).read_bytes() == original
    assert (dest / source.name / "空目录").is_dir()
    print("PASS Linux 中文路径、Huffman、AES-GCM、错误密码、空目录", flush=True)
    root = Path(__file__).resolve().parent.parent
    existing = root / "examples/备份输出/界面演示.sbackup"
    if existing.exists():
        invoke("inspect", "--archive", existing, password="DemoPass2026!")
        print("PASS Linux 读取现有 Windows 加密归档", flush=True)

    provision(state_home, 0)
    server = repository(state_home, "127.0.0.1", 0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        config = load_json(state_home / "client.json", {})
        config["url"] = f"https://127.0.0.1:{server.server_port}"
        remote = Remote(config)
        result = remote.upload(archive)
        assert result["uploaded"] == archive.stat().st_size
        assert remote.upload(archive)["uploaded"] == 0
        network_dest = home / "网络还原"
        network_dest.mkdir()
        remote.restore(result["id"], network_dest, password)
        assert (network_dest / source.name / sample.name).read_bytes() == original
        accounts = state_home / "repository/accounts.json"
        data = load_json(accounts, {})
        data["second"] = hashlib.sha256(b"test-second-user").hexdigest()
        save_json(accounts, data)
        second = Remote(dict(config, user="second", token="test-second-user"))
        assert second.call("/versions") == []
        try:
            second.call("/versions/" + result["id"])
        except HTTPError as error:
            assert error.code == 404
        else:
            raise AssertionError("版本跨账号可访问")
        try:
            Remote(dict(config, token="bad")).call("/versions")
        except HTTPError as error:
            assert error.code == 403
        else:
            raise AssertionError("错误令牌被接受")
        raw1, raw2 = output / "原始.sbackup", output / "更新.sbackup"
        invoke("backup", "--source", source, "--output", raw1, "--no-compress")
        remote.upload(raw1)
        sample.write_bytes(bytes([original[0] ^ 1]) + original[1:])
        invoke("backup", "--source", source, "--output", raw2, "--no-compress")
        delta = remote.upload(raw2)
        assert 0 < delta["uploaded"] < delta["bytes"], delta
        print(f"PASS HTTPS 上传、版本、还原、账号隔离、错误令牌、增量传输 {delta['uploaded']}/{delta['bytes']} 字节", flush=True)
    finally:
        server.shutdown()
        server.server_close()

    state = ConsoleState(state_home)
    state.make_space_folder(".", "课程归档")
    managed = state.space / "课程归档"
    (state.space / "越界链接").symlink_to(output, target_is_directory=True)
    for unsafe in (str(output / "outside.sbackup"), "../outside.sbackup", "越界链接/outside.sbackup"):
        try:
            state.space_path(unsafe, directory=False)
        except ValueError:
            pass
        else:
            raise AssertionError("接受了越界位置：" + unsafe)
    assert [entry["name"] for entry in state.list_space(".")["entries"]] == ["课程归档"]
    print("PASS 备份空间新建文件夹、目录列表和越界拒绝", flush=True)
    job = state.add_job({"source": str(source), "output": str(managed), "mode": "schedule", "period": 5, "keep": 1})
    wait_job(state, lambda: job["status"].startswith("成功"))
    first = job["status"]
    wait_job(state, lambda: job["status"].startswith("成功") and job["status"] != first)
    assert len(list(managed.glob("auto-" + job["id"] + "-*.sbackup"))) == 1
    assert archive.is_file()
    state.jobs.pop(job["id"])
    print("PASS 定时触发两次、仅保留最近一份、手动归档保留", flush=True)
    watch = state.add_job({"source": str(source), "output": str(managed), "mode": "watch", "period": 5, "keep": 2})
    state.tick()
    sample.write_bytes(b"modified")
    wait_job(state, lambda: watch["status"].startswith("成功"))
    assert len(list(managed.glob("auto-" + watch["id"] + "-*.sbackup"))) == 1
    saved = ConsoleState(state_home)
    assert saved.jobs[watch["id"]]["last_snapshot"] == watch["last_snapshot"]
    print("PASS 文件修改自动触发、任务和基线持久化", flush=True)


if __name__ == "__main__":
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="backup-linux-check-") as tmp:
        run(Path(tmp))
