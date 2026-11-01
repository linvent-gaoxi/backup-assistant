"""Windows-side task runner. Files are packed locally and stored on TencentCloud."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.parse import urlencode
from urllib.request import Request
from urllib.error import HTTPError

from service import BLOCK, HTTP, ROOT, ConsoleState, Remote, check, identifier, invoke, load_json, save_json

PORT = 18765
WSL_CLIENT_PORT = 18766
WSL_REPOSITORY_PORT = 19444
WSL = ["wsl.exe", "-d", "Ubuntu", "--", "python3", "-B", "linux/wsl-storage.py"]
SSH = ["ssh.exe", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
SERVER_HOME = "~/.local/share/backup-assistant-cloud"
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


class CloudStorage(Remote):
    def authenticate(self, action, data):
        try:
            return self.call("/auth/" + action, "POST", json.dumps(data, ensure_ascii=False).encode())
        except HTTPError as error:
            if action == "logout" and error.code == 403:
                return {"ok": True}
            try:
                message = json.loads(error.read(4096))["error"]
            except (ValueError, KeyError):
                message = "账号请求失败"
            raise ValueError(message) from error

    def operation(self, action, data):
        return self.call("/managed/" + action, "POST", json.dumps(data, ensure_ascii=False).encode())

    def archive_info(self, archive):
        return self.call("/managed/archive-info?" + urlencode({"path": archive}))

    def transfer(self, source, target, progress=None):
        digest = hashlib.sha256()
        size = source.stat().st_size
        hashes = []
        with source.open("rb") as data:
            encrypted = data.read(8) == b"SBKENC01"
            data.seek(0)
            while block := data.read(BLOCK):
                digest.update(block)
                hashes.append(hashlib.sha256(block).hexdigest())
        base = None
        manifest = b""
        reuse = [False] * len(hashes)
        if not encrypted:
            try:
                folder = str(PurePosixPath(target).parent)
                entries = self.operation("space", {"path": folder})["entries"]
                prefix = PurePosixPath(target).name.rsplit("-", 2)[0]
                candidates = [entry for entry in entries if not entry["folder"] and entry["name"].startswith(prefix + "-")]
                if candidates:
                    candidate = max(candidates, key=lambda entry: entry["modified"])["path"]
                    known = set(self.call("/managed/archive-blocks?" + urlencode({"path": candidate}))["hashes"])
                    reuse = [key in known for key in hashes]
                    if any(reuse):
                        base = candidate
                        manifest = json.dumps(list(zip(hashes, reuse)), separators=(",", ":")).encode()
            except (HTTPError, KeyError):
                pass
        payload_size = size if base is None else len(manifest) + sum(
            min(BLOCK, size - index * BLOCK) for index, flag in enumerate(reuse) if not flag)
        headers = {**self.headers, "Content-Length": str(payload_size),
                   "X-Archive-SHA256": digest.hexdigest(), "Content-Type": "application/octet-stream"}
        query = {"path": target}
        route = "/managed/archive"
        if base is not None:
            route += "-delta"
            query["base"] = base
            headers["X-Manifest-Size"] = str(len(manifest))
            headers["X-Archive-Size"] = str(size)

        def chunks():
            sent = 0
            phase = "增量上传" if base is not None else "上传归档"
            if progress:
                progress(phase, sent, payload_size)
            if manifest:
                yield manifest
                sent += len(manifest)
            with source.open("rb") as data:
                for skip in reuse if base is not None else [False] * len(hashes):
                    block = data.read(BLOCK)
                    if skip:
                        continue
                    yield block
                    sent += len(block)
                    if progress:
                        progress(phase if sent < payload_size else "等待服务器校验", sent, payload_size)

        request = Request(self.url + route + "?" + urlencode(query), data=chunks(), headers=headers, method="PUT")
        with self.opener.open(request, timeout=90) as response:
            return json.load(response)

    def retrieve(self, archive, local, progress=None):
        request = Request(self.url + "/managed/archive?" + urlencode({"path": archive}), headers=self.headers)
        with self.opener.open(request, timeout=90) as response, local.open("wb") as out:
            size = int(response.headers["Content-Length"])
            check(0 < size <= 5_000_000_000, "远端归档大小无效")
            received = 0
            if progress:
                progress("下载归档", received, size)
            while chunk := response.read(256 * 1024):
                out.write(chunk)
                received += len(chunk)
                if progress:
                    progress("下载归档", received, size)
            check(out.tell() == size, "下载内容不完整")


class ClientState(ConsoleState):
    def __init__(self, home, storage, label):
        super().__init__(home)
        self.cloud = storage
        self.server_label = label
        self.progress = None
        self.client_home = home
        self.cloud_root = ""
        self.username = ""
        self.expires = 0
        self.jobs = {}
        self.status = "请登录后使用备份空间。"
        self.email_verification = bool(storage.call("/auth/health").get("email_verification"))
        self.next_auth_config_check = 0

    def login(self, data):
        with self.lock:
            check(not self.busy and not self.username, "请先退出当前账号")
            session = self.cloud.authenticate("login", data)
            name = session["username"]
            self.cloud.headers = {"X-Backup-User": name, "Authorization": "Bearer " + session["token"]}
            try:
                root = self.cloud.operation("space", {"path": "."})["root"]
                profile = self.client_home / "profiles" / hashlib.sha256(name.encode()).hexdigest()
                profile.mkdir(parents=True, exist_ok=True)
                jobs = load_json(profile / "jobs.json", {})
            except Exception:
                self.cloud.headers = {}
                raise
            self.home = profile
            self.jobs = jobs
            self.watch = {}
            self.username = name
            self.expires = session["expires"]
            self.cloud_root = root
            self.status = "登录成功：" + name

    def logout(self):
        with self.lock:
            check(not self.busy, "请等待当前任务结束再退出")
            if self.username:
                self.cloud.authenticate("logout", {})
            self.clear_session("已退出登录")

    def clear_session(self, message):
        self.cloud.headers = {}
        self.cloud_root = ""
        self.username = ""
        self.expires = 0
        self.jobs = {}
        self.watch = {}
        self.home = self.client_home
        self.status = message

    def public(self):
        with self.lock:
            if self.username and not self.busy and self.expires <= time.time():
                self.clear_session("登录已过期，请重新登录。")
            result = super().public()
            result["progress"] = self.progress if result["busy"] else None
            result["username"] = self.username
            result["authenticated"] = bool(self.username)
            result["email_verification"] = self.email_verification
            result["example"]["output"] = self.cloud_root
        result["example"]["source"] = str(ROOT.parent / "测试文件夹/示例资料")
        result["example"]["destination"] = str(ROOT.parent / "测试文件夹/还原位置")
        return result

    def report_progress(self, phase, done=0, total=0):
        with self.lock:
            now = time.monotonic()
            previous = self.progress
            started = now
            if total and previous and previous["total"] == total and done >= previous["done"]:
                started = previous["started"]
            elapsed = now - started
            rate = done / elapsed if total and elapsed >= .15 else 0
            self.progress = {"phase": phase, "done": done, "total": total, "started": started, "rate": rate}

    def launch(self, label, action):
        with self.lock:
            check(not self.busy, "有任务正在执行")
            self.report_progress(label)
            super().launch(label, action)

    def backup(self, data, archive):
        with tempfile.TemporaryDirectory(prefix="backup-cloud-pack-") as temp:
            local = Path(temp) / "archive.sbackup"
            self.report_progress("本地打包")
            packed = self.pack(data, local)
            self.report_progress("计算归档校验值")
            transfer = self.cloud.transfer(local, str(archive), self.report_progress)
            details = [line for line in packed.splitlines() if not line.startswith("位置：")]
            details.append(f"实际传输：{transfer.get('uploaded', transfer['bytes'])} 字节；复用：{transfer.get('reused', 0)} 字节")
            return f"已保存到{self.server_label}服务器\n" + "\n".join(details)

    def restore(self, data, command):
        with tempfile.TemporaryDirectory(prefix="backup-cloud-fetch-") as temp:
            local = Path(temp) / "archive.sbackup"
            self.cloud.retrieve(data["archive"], local, self.report_progress)
            args = ["--archive", local]
            if command == "restore":
                destination = Path(data["destination"])
                check(destination.is_absolute() and destination.is_dir(), "请选择 Windows 中已存在的还原文件夹")
                args.extend(["--destination", destination])
            self.report_progress("校验并解包" if command == "restore" else "检查归档完整性")
            return invoke(command, *args, password=data.get("password", ""))

    def add_job(self, data):
        source = Path(data["source"]).resolve()
        check(source.is_dir(), "请选择已存在的本地源文件夹")
        directory = self.cloud.operation("space", {"path": data["output"]})["path"]
        mode = data["mode"]
        period, keep = int(data["period"]), int(data["keep"])
        check(mode in ("schedule", "watch") and 5 <= period <= 604800 and 1 <= keep <= 100, "任务参数超出范围")
        job = {"id": identifier(), "source": str(source), "output": directory, "mode": mode,
               "period": period, "keep": keep, "next": time.time() + period, "status": "等待"}
        if mode == "watch":
            from service import fingerprint
            job["last_snapshot"] = fingerprint(source)
        with self.lock:
            self.jobs[job["id"]] = job
            save_json(self.home / "jobs.json", self.jobs)
        return job

    def run_job(self, job):
        prefix = "auto-" + job["id"] + "-"
        archive = PurePosixPath(job["output"]) / (prefix + identifier() + ".sbackup")
        message = "失败"
        try:
            status = self.backup(job, archive)
            entries = self.cloud.operation("space", {"path": job["output"]})["entries"]
            names = sorted((item["name"] for item in entries if not item["folder"] and
                            item["name"].startswith(prefix)), reverse=True)
            if names[job["keep"]:]:
                self.cloud.operation("space-trash", {"path": job["output"], "names": names[job["keep"]:]})
            message = "成功：" + archive.name
            return status
        except Exception as error:
            message = "失败：" + str(error)
            raise
        finally:
            with self.lock:
                if job["id"] in self.jobs:
                    job["status"] = message
                    save_json(self.home / "jobs.json", self.jobs)

    def upload_dropped(self, paths, target, options=None, archive_name=None):
        check(isinstance(paths, list) and 1 <= len(paths) <= 100, "每次可上传 1～100 项")
        if archive_name:
            check(len(paths) == 1 and PurePosixPath(archive_name).name == archive_name and
                  "\\" not in archive_name and archive_name.lower().endswith(".sbackup"), "归档文件名无效")
        options = options or {}
        target = self.cloud.operation("space", {"path": target})["path"]
        good, errors = [], []
        for path in paths:
            source = Path(path)
            try:
                check(source.is_absolute() and not source.is_symlink() and source.exists(), "找不到源项目")
                name = (source.name if source.is_dir() else source.stem).strip(" .") or "文件"
                archive = PurePosixPath(target) / (archive_name or name[:65] + "-" + identifier() + ".sbackup")
                if source.is_dir():
                    self.backup({**options, "source": source}, archive)
                else:
                    check(source.is_file(), "不支持特殊文件")
                    with tempfile.TemporaryDirectory(prefix="backup-cloud-file-") as temp:
                        wrapper = Path(temp) / (name[:65] + "-文件")
                        wrapper.mkdir()
                        shutil.copy2(source, wrapper / source.name)
                        self.backup({**options, "source": wrapper}, archive)
                good.append(archive.name)
            except (OSError, ValueError) as error:
                errors.append(f"{source.name}：{error}")
        return "\n".join([f"上传完成：{len(good)} 项成功，{len(errors)} 项失败。", *good, *errors])


class ClientApi(HTTP):
    def handle_request(self):
        check(self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}", "仅允许本机客户端访问")
        if self.headers.get("X-Backup-Console") != "1":
            raise PermissionError("请求缺少客户端标识")
        state = self.server.state
        if self.command == "GET" and self.path == "/api/state":
            self.reply(200, state.public())
            return
        check(self.command == "POST" and self.path.startswith("/api/"), "接口不存在")
        check(not self.headers.get("Origin"), "不允许网页调用桌面接口")
        data = json.loads(self.body(65536))
        action = self.path[5:]
        if action in ("register", "email-code"):
            self.reply(201 if action == "register" else 200, state.cloud.authenticate(action, data))
            return
        if action == "login":
            state.login(data)
            self.reply(200, {"username": state.username})
            return
        if action == "logout":
            state.logout()
            self.reply(200, {"ok": True})
            return
        if not state.username or state.expires <= time.time():
            raise PermissionError("请先登录")
        if action == "backup":
            state.launch(f"本地打包并上传到{state.server_label}", lambda: state.backup(data, data["archive"]))
        elif action == "drop-upload":
            state.launch("上传拖入的项目", lambda: state.upload_dropped(
                data["paths"], data["directory"], data.get("options"), data.get("archive_name")))
        elif action in ("restore", "inspect"):
            check(data.get("archive"), "请先选择要下载的备份归档")
            if not data.get("password"):
                check(not state.cloud.archive_info(data["archive"])["encrypted"], "该备份需要密码，请先填写归档密码。")
            label = f"从{state.server_label}下载并还原" if action == "restore" else "下载并检查归档"
            state.launch(label, lambda: state.restore(data, action))
        elif action == "job":
            self.reply(201, state.add_job(data))
            return
        elif action == "remove":
            with state.lock:
                state.jobs.pop(data["id"], None)
                state.watch.pop(data["id"], None)
                save_json(state.home / "jobs.json", state.jobs)
        elif action in ("archive-catalog", "quota", "space", "space-folder", "space-rename", "space-trash", "trash-list",
                        "trash-restore", "trash-empty", "trash-delete"):
            self.reply(200, state.cloud.operation(action, data))
            return
        else:
            raise ValueError("接口不存在")
        self.reply(200, {"ok": True})


def connect(home):
    certificate = home / "server.crt"
    certificate.write_bytes(subprocess.check_output(
        SSH + ["TencentCloud", "cat " + SERVER_HOME + "/tls.crt"], creationflags=FLAGS, timeout=15))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    tunnel = subprocess.Popen(
        SSH + ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=20",
               "-L", f"127.0.0.1:{port}:127.0.0.1:9443", "TencentCloud"],
        stdin=subprocess.DEVNULL, creationflags=FLAGS)
    try:
        for _ in range(50):
            check(tunnel.poll() is None, "腾讯云 SSH 隧道无法启动")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.2):
                    break
            except OSError:
                time.sleep(.2)
        storage = CloudStorage({"url": f"https://127.0.0.1:{port}", "ca": str(certificate)})
        storage.call("/auth/health")
        return storage, tunnel
    except Exception:
        tunnel.terminate()
        tunnel.wait()
        raise


def connect_wsl(home):
    certificate = home / "server.crt"
    certificate.write_bytes(subprocess.check_output(WSL + ["certificate"], cwd=ROOT, creationflags=FLAGS, timeout=30))
    config = {"url": f"https://127.0.0.1:{WSL_REPOSITORY_PORT}", "ca": str(certificate)}
    storage = CloudStorage(config)
    try:
        storage.call("/auth/health")
        return storage
    except OSError:
        server = subprocess.Popen(WSL + ["serve"], cwd=ROOT, stdin=subprocess.DEVNULL, creationflags=FLAGS)
    try:
        for _ in range(60):
            try:
                storage.call("/auth/health")
                return storage
            except OSError:
                check(server.poll() is None, "WSL 备份服务启动失败")
                time.sleep(.25)
        raise ValueError("无法连接 WSL HTTPS 备份服务")
    except Exception:
        if server.poll() is None:
            server.terminate()
        raise


def main():
    import sys
    local = sys.argv[1:] == ["--wsl"]
    label = "WSL" if local else "腾讯云"
    home = Path(os.environ["LOCALAPPDATA"]) / ("BackupAssistantWSL" if local else "BackupAssistantCloud")
    home.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", WSL_CLIENT_PORT if local else PORT), ClientApi)
    tunnel = None
    try:
        if local:
            storage = connect_wsl(home)
        else:
            storage, tunnel = connect(home)
        state = ClientState(home, storage, label)
        server.state = state

        def scheduler():
            while True:
                if tunnel is not None and tunnel.poll() is not None:
                    server.shutdown()
                    return
                try:
                    if not state.username and time.monotonic() >= state.next_auth_config_check:
                        state.next_auth_config_check = time.monotonic() + 15
                        state.email_verification = bool(storage.call("/auth/health").get("email_verification"))
                    if state.username and state.expires > time.time():
                        state.tick()
                except (OSError, ValueError) as error:
                    state.status = "自动任务错误：" + str(error)
                time.sleep(1)

        threading.Thread(target=scheduler, daemon=True).start()
        server.serve_forever()
    finally:
        server.server_close()
        if tunnel and tunnel.poll() is None:
            tunnel.terminate()
            tunnel.wait()


if __name__ == "__main__":
    main()
