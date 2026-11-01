"""Ubuntu browser console and TLS backup repository."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import smtplib
import ssl
import stat
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from email.message import EmailMessage
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home() / ".local/share/backup-assistant"
BLOCK = 1024 * 1024
HEX = re.compile(r"[0-9a-f]{64}")
USER = re.compile(r"[a-zA-Z0-9_-]{1,40}")
EMAIL = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
IDENT = re.compile(r"[0-9]{8}T[0-9]{6}-[0-9a-f]{16}")
TRASH_RETENTION_SECONDS = 7 * 24 * 60 * 60


ACCOUNT_QUOTA = 5_000_000_000

def check(condition, message):
    if not condition:
        raise ValueError(message)


def hash_bytes(data):
    return hashlib.sha256(data).hexdigest()


def atomic(path, data):
    temp = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
            temp = Path(out.name)
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)


def save_json(path, value):
    atomic(path, json.dumps(value, ensure_ascii=False).encode())


def load_json(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def archive_family(name):
    return name.rsplit("-", 2)[0]


def archive_catalog(path, offset, limit):
    with path.open("rb") as archive:
        end = os.fstat(archive.fileno()).st_size - 32

        def read(count):
            check(archive.tell() + count <= end, "归档索引数据截断")
            data = archive.read(count)
            check(len(data) == count, "归档索引数据截断")
            return data

        def integer(count):
            return int.from_bytes(read(count), "little")

        def string():
            size = integer(4)
            check(size <= 65536, "归档索引名称超出限制")
            return read(size).decode("utf-8")

        magic = archive.read(8)
        if magic == b"SBKENC01":
            return {"encrypted": True, "entries": [], "total": 0}
        check(magic in (b"SBKRAW01", b"SBKRAW02"), "归档格式无效")
        mode = integer(1)
        root = string()
        total = integer(4)
        check(mode <= 1 and 0 < total <= 1_000_000, "归档索引头无效")
        entries = []
        for index in range(min(total, offset + limit)):
            kind = integer(1)
            name = string()
            modified, attributes, size = integer(8), integer(4), integer(8)
            check(kind <= (4 if magic == b"SBKRAW02" else 1), "归档索引类型无效")
            item = {"name": name, "kind": kind, "bytes": size, "modified": modified / 1e7 - 11644473600,
                    "readonly": bool(attributes & 1)}
            if magic == b"SBKRAW02":
                item.update(mode=integer(4), uid=integer(4), gid=integer(4))
                if kind in (2, 4):
                    item["link"] = string()
            remaining = size if kind == 0 else 0
            while remaining:
                raw, stored = integer(4), integer(4)
                integer(4)
                check(0 < raw <= min(remaining, BLOCK) and 0 < stored <= BLOCK + 1025
                      and archive.tell() + stored <= end, "归档索引数据块无效")
                archive.seek(stored, os.SEEK_CUR)
                remaining -= raw
            if index >= offset:
                entries.append(item)
        return {"encrypted": False, "root": root, "entries": entries, "total": total}


def identifier():
    return time.strftime("%Y%m%dT%H%M%S", time.gmtime()) + "-" + secrets.token_hex(8)


def validate_space_name(name):
    check(isinstance(name, str) and name and name == name.strip() and
          not name.startswith(".") and not any(c in name for c in '/\\:\0') and
          len(name.encode()) <= 200, "请输入有效的项目名称")


def invoke(command, *args, password=""):
    executable = "bin/backup_cli.exe" if os.name == "nt" else "build/linux/backup_cli"
    argv = [str(ROOT / executable), command, *map(str, args)]
    if password:
        argv.append("--password-stdin")
    result = subprocess.run(argv, input=password + "\n", capture_output=True, encoding="utf-8", errors="replace",
                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    if result.returncode:
        raise ValueError(result.stderr.strip().removeprefix("失败：") or "备份核心返回错误")
    return result.stdout


class HTTP(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, content="application/json; charset=utf-8"):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def body(self, limit):
        size = int(self.headers.get("Content-Length", "0"))
        check(0 <= size <= limit, "请求超出大小限制")
        data = self.rfile.read(size)
        check(len(data) == size, "请求内容不完整")
        return data

    def dispatch(self):
        try:
            self.handle_request()
        except PermissionError as error:
            self.reply(403, {"error": str(error)})
        except FileNotFoundError:
            self.reply(404, {"error": "找不到文件或版本"})
        except (ValueError, OSError, RuntimeError, KeyError, TypeError, AttributeError) as error:
            self.reply(400, {"error": str(error)})

    do_GET = do_POST = do_PUT = dispatch


class Repository(HTTP):
    def handle_request(self):
        if self.path == "/auth/health" and self.command == "GET":
            self.reply(200, {"ok": True, "email_verification": self.server.smtp_config.is_file()})
            return
        if self.path == "/auth/email-code" and self.command == "POST":
            self.send_email_code()
            return
        if self.command == "POST" and self.path in ("/auth/register", "/auth/login"):
            self.handle_login(self.path.endswith("/register"))
            return
        user = self.headers.get("X-Backup-User", "")
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        base = self.server.storage
        account = load_json(base / "accounts.json", {}).get(user) if USER.fullmatch(user) else None
        token_hash = hash_bytes(token.encode()) if token else ""
        with self.server.auth_lock:
            session = self.server.sessions.get(token_hash)
            signed_in = session and session[0] == user and session[1] > time.time()
            if not signed_in and not (account and token and hmac.compare_digest(account, token_hash)):
                raise PermissionError("账号或会话无效，请重新登录")
            if self.command == "POST" and self.path == "/auth/logout":
                self.server.sessions.pop(token_hash, None)
                self.reply(200, {"ok": True})
                return
        if self.path.startswith("/managed/"):
            self.handle_managed(user)
            return
        chunks = base / user / "chunks"
        versions = base / user / "versions"
        chunks.mkdir(parents=True, exist_ok=True)
        versions.mkdir(exist_ok=True)
        route = self.path.split("/")
        if self.command == "GET" and self.path == "/versions":
            self.reply(200, [json.loads(p.read_text()) for p in sorted(versions.glob("*.json"), reverse=True)])
        elif len(route) == 3 and route[1] == "chunk" and HEX.fullmatch(route[2]):
            path = chunks / route[2]
            if self.command == "GET":
                self.reply(200, path.read_bytes(), "application/octet-stream")
            elif self.command == "PUT":
                data = self.body(BLOCK)
                check(hash_bytes(data) == route[2], "数据块校验失败")
                atomic(path, data)
                self.reply(200, {})
            else:
                self.reply(405, {"error": "不支持此操作"})
        elif self.command == "POST" and self.path == "/missing":
            hashes = json.loads(self.body(BLOCK))
            check(isinstance(hashes, list) and all(isinstance(x, str) and HEX.fullmatch(x) for x in hashes), "数据块清单无效")
            self.reply(200, [x for x in set(hashes) if not (chunks / x).is_file()])
        elif self.command == "POST" and self.path == "/versions":
            manifest = json.loads(self.body(BLOCK))
            hashes = manifest.get("chunks", [])
            check(isinstance(hashes, list) and hashes and len(hashes) <= 4096 and
                  all(isinstance(x, str) and HEX.fullmatch(x) and (chunks / x).is_file() for x in hashes), "版本包含缺失的数据块")
            check(isinstance(manifest.get("sha256"), str) and HEX.fullmatch(manifest["sha256"]), "归档摘要无效")
            name = manifest.get("name", "")
            check(isinstance(name, str) and 0 < len(name) <= 255 and Path(name).name == name, "归档名称无效")
            version = identifier()
            record = {"id": version, "name": name, "chunks": hashes, "sha256": manifest["sha256"],
                      "bytes": sum((chunks / x).stat().st_size for x in hashes), "created": time.time()}
            save_json(versions / (version + ".json"), record)
            self.reply(201, record)
        elif self.command == "GET" and len(route) == 3 and route[1] == "versions" and IDENT.fullmatch(route[2]):
            self.reply(200, json.loads((versions / (route[2] + ".json")).read_text()))
        elif self.command == "POST" and self.path == "/rename":
            data = json.loads(self.body(65536))
            version, name = data["id"], data["name"]
            check(isinstance(version, str) and IDENT.fullmatch(version), "版本编号无效")
            validate_space_name(name)
            check(name.lower().endswith(".sbackup"), "归档名称必须以 .sbackup 结尾")
            path = versions / (version + ".json")
            with self.server.rename_lock:
                record = json.loads(path.read_text())
                if record["name"] != name:
                    check(not any(p != path and json.loads(p.read_text())["name"] == name
                                  for p in versions.glob("*.json")), "已有同名远端归档")
                    record["name"] = name
                    save_json(path, record)
            self.reply(200, record)
        else:
            self.reply(404, {"error": "接口不存在"})

    def handle_login(self, register):
        data = json.loads(self.body(4096))
        username = data.get("username")
        password = data.get("password")
        check(isinstance(username, str) and USER.fullmatch(username), "账号须为 1～40 个字母、数字、下划线或连字符")
        check(isinstance(password, str) and 8 <= len(password) <= 128, "密码须为 8～128 个字符")
        username = username.lower()
        path = self.server.storage / "users.json"
        with self.server.auth_lock:
            users = load_json(path, {})
            if register:
                legacy = load_json(self.server.storage / "accounts.json", {})
                check(username not in users and all(username != user.lower() for user in legacy), "该账号已存在")
                email = None
                if self.server.smtp_config.is_file():
                    email = self.email_address(data.get("email"))
                    check(not any(user.get("email") == email for user in users.values()), "该邮箱已注册")
                    challenge = self.server.email_codes.get(email)
                    check(challenge and challenge["username"] == username and challenge["expires"] > time.time(),
                          "请先获取有效的邮箱验证码")
                    code = data.get("code", "")
                    check(isinstance(code, str) and re.fullmatch(r"[0-9]{6}", code), "请输入 6 位邮箱验证码")
                    if not hmac.compare_digest(challenge["digest"], hash_bytes(code.encode())):
                        challenge["attempts"] += 1
                        if challenge["attempts"] >= 5:
                            self.server.email_codes.pop(email, None)
                        raise ValueError("邮箱验证码不正确")
                salt = secrets.token_bytes(16)
                verifier = hashlib.scrypt(password.encode(), salt=salt, n=32768, r=8, p=1, maxmem=64*1024**2)
                users[username] = {"salt": salt.hex(), "verifier": verifier.hex()}
                if email:
                    users[username]["email"] = email
                save_json(path, users)
                if email:
                    self.server.email_codes.pop(email, None)
                self.reply(201, {"username": username})
                return
            account = users.get(username)
            if not account:
                raise PermissionError("账号或密码不正确")
            verifier = hashlib.scrypt(password.encode(), salt=bytes.fromhex(account["salt"]),
                                      n=32768, r=8, p=1, maxmem=64*1024**2)
            if not hmac.compare_digest(verifier.hex(), account["verifier"]):
                raise PermissionError("账号或密码不正确")
            now = time.time()
            expires = now + 24 * 3600
            self.server.sessions = {key: session for key, session in self.server.sessions.items() if session[1] > now}
            token = secrets.token_urlsafe(32)
            self.server.sessions[hash_bytes(token.encode())] = (username, expires)
            self.reply(200, {"username": username, "token": token, "expires": expires})

    @staticmethod
    def email_address(value):
        check(isinstance(value, str) and len(value) <= 254 and EMAIL.fullmatch(value),
              "请输入有效的邮箱地址")
        return value.lower()

    def send_email_code(self):
        check(self.server.smtp_config.is_file(), "服务器尚未配置发信邮箱")
        data = json.loads(self.body(4096))
        username = data.get("username")
        check(isinstance(username, str) and USER.fullmatch(username), "请先填写有效的账号")
        username = username.lower()
        email = self.email_address(data.get("email"))
        with self.server.auth_lock:
            now = time.time()
            users = load_json(self.server.storage / "users.json", {})
            legacy = load_json(self.server.storage / "accounts.json", {})
            check(username not in users and all(username != user.lower() for user in legacy), "该账号已存在")
            check(not any(user.get("email") == email for user in users.values()), "该邮箱已注册")
            self.server.email_codes = {k: v for k, v in self.server.email_codes.items() if v["expires"] > now}
            self.server.email_sent = {k: v for k, v in self.server.email_sent.items() if now - v < 3600}
            check(now - self.server.email_sent.get(email, 0) >= 60, "请等待 60 秒后重新获取")
            self.server.email_requests = [when for when in self.server.email_requests if now - when < 3600]
            check(len(self.server.email_requests) < 30, "发信次数过多，请稍后再试")
            self.server.email_requests.append(now)
            self.server.email_sent[email] = now
            code = f"{secrets.randbelow(1000000):06d}"
            challenge = {"username": username, "digest": hash_bytes(code.encode()), "expires": now + 300, "attempts": 0}
        try:
            config = load_json(self.server.smtp_config, {})
            self.server.deliver_code(config, email, code)
        except (OSError, ValueError, KeyError, smtplib.SMTPException):
            raise ValueError("验证码发送失败，请检查服务器的 QQ 邮箱 SMTP 配置") from None
        with self.server.auth_lock:
            if self.server.email_sent.get(email) == now:
                self.server.email_codes[email] = challenge
        self.reply(200, {"ok": True, "expires_in": 300})

    def handle_managed(self, user):
        state = self.server.managed_state(user)
        route = urlsplit(self.path)
        action = route.path.removeprefix("/managed/")
        if action == "quota" and self.command == "POST":
            self.body(65536)
            with state.lock:
                state.purge_expired_trash(time.time())
                self.reply(200, {"limit": ACCOUNT_QUOTA, "used": state.used_space()})
            return
        if action == "archive-catalog" and self.command == "POST":
            data = json.loads(self.body(65536))
            path = state.space_path(data["path"], directory=False)
            offset, limit = int(data.get("offset", 0)), int(data.get("limit", 200))
            check(0 <= offset <= 1_000_000 and 1 <= limit <= 200, "索引分页参数无效")
            catalog = archive_catalog(path, offset, limit)
            siblings = state.list_space(str(path.parent))["entries"]
            catalog["versions"] = sorted(
                (entry for entry in siblings if not entry["folder"] and
                 archive_family(entry["name"]) == archive_family(path.name)),
                key=lambda entry: entry["modified"], reverse=True)[:100]
            self.reply(200, catalog)
            return
        if action == "archive-blocks" and self.command == "GET":
            base = state.space_path(parse_qs(route.query)["path"][0], directory=False)
            with state.lock:
                with base.open("rb") as source:
                    hashes = [hash_bytes(block) for block in iter(lambda: source.read(BLOCK), b"")]
            self.reply(200, {"hashes": hashes})
            return
        if action == "archive-delta" and self.command == "PUT":
            query = parse_qs(route.query)
            path = state.space_path(query["path"][0], directory=False)
            base = state.space_path(query["base"][0], directory=False)
            size = int(self.headers.get("X-Archive-Size", "0"))
            manifest_size = int(self.headers.get("X-Manifest-Size", "0"))
            length = int(self.headers.get("Content-Length", "0"))
            digest = self.headers.get("X-Archive-SHA256", "")
            check(0 < size <= ACCOUNT_QUOTA and 0 < manifest_size <= 512 * 1024
                  and manifest_size <= length <= manifest_size + size and HEX.fullmatch(digest), "增量归档参数无效")
            manifest = json.loads(self.rfile.read(manifest_size))
            check(isinstance(manifest, list) and len(manifest) == (size + BLOCK - 1) // BLOCK, "增量清单长度无效")
            with state.lock:
                state.purge_expired_trash(time.time())
                check(state.used_space() + size <= ACCOUNT_QUOTA, "账号备份空间不足（5 GB）")
                previous = base.open("rb")
            with previous, tempfile.NamedTemporaryFile(dir=path.parent, prefix=".incoming-", delete=False) as out:
                temp = Path(out.name)
                try:
                    offsets = {}
                    for index, block in enumerate(iter(lambda: previous.read(BLOCK), b"")):
                        offsets[hash_bytes(block)] = index * BLOCK
                    consumed = manifest_size
                    actual = hashlib.sha256()
                    reused = 0
                    for index, entry in enumerate(manifest):
                        check(isinstance(entry, list) and len(entry) == 2, "增量清单条目无效")
                        key, reuse = entry
                        check(isinstance(key, str) and HEX.fullmatch(key) and isinstance(reuse, bool), "增量校验值无效")
                        count = min(BLOCK, size - index * BLOCK)
                        if reuse:
                            check(key in offsets, "增量基准已变化，请刷新后重试")
                            previous.seek(offsets[key])
                            block = previous.read(count)
                            reused += count
                        else:
                            check(consumed + count <= length, "增量数据长度无效")
                            block = self.rfile.read(count)
                            consumed += count
                        check(len(block) == count and hash_bytes(block) == key, "增量数据块校验失败")
                        out.write(block)
                        actual.update(block)
                    check(consumed == length and actual.hexdigest() == digest, "增量归档完整性校验失败")
                    out.flush()
                    os.fsync(out.fileno())
                    with state.lock:
                        check(state.used_space() + size <= ACCOUNT_QUOTA, "账号备份空间不足（5 GB）")
                        os.link(temp, path)
                finally:
                    temp.unlink(missing_ok=True)
            self.reply(201, {"bytes": size, "uploaded": length, "reused": reused})
            return
        if action == "archive-info" and self.command == "GET":
            path = state.space_path(parse_qs(route.query)["path"][0], directory=False)
            with state.lock:
                check(path.is_file() and not path.is_symlink(), "归档不存在")
                with path.open("rb") as archive:
                    magic = archive.read(8)
            check(magic in (b"SBKRAW01", b"SBKRAW02", b"SBKENC01"), "不是有效的备份归档")
            self.reply(200, {"encrypted": magic == b"SBKENC01"})
            return
        if action == "archive":
            path = state.space_path(parse_qs(route.query)["path"][0], directory=False)
            if self.command == "PUT":
                size = int(self.headers.get("Content-Length", "0"))
                digest = self.headers.get("X-Archive-SHA256", "")
                check(0 < size <= ACCOUNT_QUOTA and HEX.fullmatch(digest), "归档大小或校验值无效")
                with state.lock:
                    state.purge_expired_trash(time.time())
                    check(state.used_space() + size <= ACCOUNT_QUOTA, "账号备份空间不足（5 GB）")
                with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".incoming-", delete=False) as out:
                    temp = Path(out.name)
                    try:
                        remaining = size
                        actual = hashlib.sha256()
                        while remaining:
                            data = self.rfile.read(min(BLOCK, remaining))
                            check(data, "上传数据不完整")
                            out.write(data)
                            actual.update(data)
                            remaining -= len(data)
                        out.flush()
                        os.fsync(out.fileno())
                        check(actual.hexdigest() == digest, "上传归档校验失败")
                        with state.lock:
                            state.purge_expired_trash(time.time())
                            check(state.used_space() + size <= ACCOUNT_QUOTA, "账号备份空间不足（5 GB）")
                            os.link(temp, path)
                    finally:
                        temp.unlink(missing_ok=True)
                self.reply(201, {"bytes": size})
            elif self.command == "GET":
                with state.lock:
                    check(path.is_file() and not path.is_symlink(), "归档不存在")
                    source = path.open("rb")
                with source:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(os.fstat(source.fileno()).st_size))
                    self.end_headers()
                    shutil.copyfileobj(source, self.wfile, BLOCK)
            else:
                self.reply(405, {"error": "不支持此操作"})
            return
        check(self.command == "POST", "接口不存在")
        data = json.loads(self.body(65536))
        routes = {
            "space": lambda: state.list_space(data.get("path", ".")),
            "space-folder": lambda: state.make_space_folder(data["path"], data["name"]),
            "space-trash": lambda: state.trash_space(data["path"], data["names"]),
            "space-rename": lambda: state.rename_space(data["path"], data["old"], data["new"]),
            "trash-list": state.list_trash,
            "trash-restore": lambda: state.restore_trash(data["batch"], data["name"]),
            "trash-empty": state.empty_trash,
            "trash-delete": lambda: state.delete_trash_items(data["items"]),
        }
        with state.lock:
            state.purge_expired_trash(time.time())
            self.reply(200, routes[action]())


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Remote:
    def __init__(self, config):
        self.url = config["url"].rstrip("/")
        check(self.url.startswith("https://"), "网络备份必须使用 HTTPS")
        self.context = ssl.create_default_context(cafile=config.get("ca") or None)
        self.opener = build_opener(HTTPSHandler(context=self.context), NoRedirect())
        self.headers = ({"X-Backup-User": config["user"], "Authorization": "Bearer " + config["token"]}
                        if config.get("user") and config.get("token") else {})

    def call(self, path, method="GET", data=None):
        with self.opener.open(Request(self.url + path, data, self.headers, method=method), timeout=30) as response:
            limit = BLOCK if path.startswith("/chunk/") else 32 * BLOCK
            data = response.read(limit + 1)
            check(len(data) <= limit, "远端响应超出大小限制")
            return data if path.startswith("/chunk/") and method == "GET" else json.loads(data)

    def upload(self, archive):
        hashes = []
        digest = hashlib.sha256()
        with archive.open("rb") as src:
            while data := src.read(BLOCK):
                hashes.append(hash_bytes(data))
                digest.update(data)
        check(0 < len(hashes) <= 4096, "网络归档上限为 4 GiB")
        missing = set(self.call("/missing", "POST", json.dumps(hashes).encode()))
        sent = 0
        with archive.open("rb") as src:
            for expected in hashes:
                data = src.read(BLOCK)
                check(hash_bytes(data) == expected, "上传期间归档已变化")
                if expected in missing:
                    self.call("/chunk/" + expected, "PUT", data)
                    missing.remove(expected)
                    sent += len(data)
        result = self.call("/versions", "POST", json.dumps(
            {"name": archive.name, "chunks": hashes, "sha256": digest.hexdigest()}).encode())
        return {"id": result["id"], "bytes": result["bytes"], "uploaded": sent}

    def restore(self, version, destination, password):
        check(IDENT.fullmatch(version), "版本编号无效")
        manifest = self.call("/versions/" + version)
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "download.sbackup"
            digest = hashlib.sha256()
            with archive.open("wb") as out:
                for key in manifest["chunks"]:
                    data = self.call("/chunk/" + key)
                    check(hash_bytes(data) == key, "下载块校验失败")
                    out.write(data)
                    digest.update(data)
            check(digest.hexdigest() == manifest["sha256"], "下载归档校验失败")
            if destination is None:
                return invoke("inspect", "--archive", archive, password=password)
            return invoke("restore", "--archive", archive, "--destination", destination, password=password)


def fingerprint(source):
    digest = hashlib.sha256()
    for base, directories, files in os.walk(source, onerror=lambda error: (_ for _ in ()).throw(error)):
        directories.sort()
        for name in sorted(directories + files):
            path = Path(base) / name
            info = path.lstat()
            check(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), "源目录含链接或特殊文件")
            digest.update(os.fsencode(str(path.relative_to(source))) + b"\0")
            digest.update(f"{info.st_mode}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}\n".encode())
    return digest.hexdigest()


class ConsoleState:
    def __init__(self, home):
        self.home = home
        self.lock = threading.RLock()
        self.busy = False
        self.status = "就绪"
        self.jobs = load_json(home / "jobs.json", {})
        self.default_remote = load_json(home / "client.json", {})
        self.watch = {}
        self.next_trash_cleanup = 0
        self.space = home / "backups"
        self.space.mkdir(exist_ok=True)
        check(not self.space.is_symlink() and self.space.is_dir(), "备份空间必须是本机普通目录")
        (home / "restored").mkdir(exist_ok=True)

    def used_space(self):
        return sum(
            path.stat().st_size
            for path in self.space.rglob("*.sbackup")
            if path.is_file() and not path.is_symlink() and not path.name.startswith(".incoming-")
        )

    def space_path(self, value, *, directory):
        check(isinstance(value, str) and value and "\0" not in value, "备份空间路径无效")
        candidate = Path(value)
        check(".." not in candidate.parts, "保存位置必须在备份空间内")
        if not candidate.is_absolute():
            candidate = self.space / candidate
        check(candidate.is_relative_to(self.space), "保存位置必须在备份空间内")
        current = self.space
        for part in candidate.relative_to(self.space).parts:
            check(not part.startswith("."), "不能访问备份空间的内部目录")
            current /= part
            check(not current.is_symlink(), "备份空间不允许使用符号链接")
        check(candidate.resolve().is_relative_to(self.space), "保存位置必须在备份空间内")
        if directory:
            check(candidate.is_dir(), "备份空间中的文件夹不存在")
        else:
            check(candidate.suffix.lower() == ".sbackup" and candidate.parent.is_dir(),
                  "请选择备份空间中的文件夹，并使用 .sbackup 文件名")
        return candidate

    def list_space(self, path):
        directory = self.space_path(path or ".", directory=True)
        entries = []
        for item in directory.iterdir():
            if item.is_symlink() or item.name.startswith("."):
                continue
            folder = item.is_dir()
            if not folder and not (item.is_file() and item.suffix.lower() == ".sbackup"):
                continue
            info = item.stat()
            entries.append({"name": item.name, "path": str(item), "folder": folder,
                            "bytes": info.st_size if not folder else None, "modified": info.st_mtime})
        return {"root": str(self.space), "path": str(directory),
                "parent": str(directory.parent) if directory != self.space else "",
                "entries": sorted(entries, key=lambda entry: (not entry["folder"], entry["name"].casefold()))}

    def make_space_folder(self, path, name):
        check(isinstance(name, str) and name == name.strip() and name not in ("", ".", "..") and
              not name.startswith(".") and not any(c in name for c in '/\\:\0') and
              len(name.encode()) <= 200, "请输入有效的文件夹名称")
        folder = self.space_path(path or ".", directory=True) / name
        with self.lock:
            folder.mkdir()
        return self.list_space(str(folder.parent))

    def rename_space(self, path, old, new):
        directory = self.space_path(path, directory=True)
        validate_space_name(old)
        validate_space_name(new)
        with self.lock:
            check(not self.busy, "请等待当前备份或还原任务完成")
            source, target = directory / old, directory / new
            check(not source.is_symlink() and (source.is_dir() or
                  (source.is_file() and source.suffix.lower() == ".sbackup")), "选中的项目已变化")
            if source == target:
                return self.list_space(str(directory))
            check(not target.exists() and not target.is_symlink(), "已有同名项目")
            if source.is_file():
                check(target.suffix.lower() == ".sbackup", "归档名称必须以 .sbackup 结尾")
            check(not any(Path(job["output"]).is_relative_to(source) or
                          Path(job["source"]).is_relative_to(source) for job in self.jobs.values()),
                  "自动任务正在使用此文件夹，请先移除任务")
            source.rename(target)
        return self.list_space(str(directory))

    def trash_space(self, path, names):
        directory = self.space_path(path, directory=True)
        check(isinstance(names, list) and 1 <= len(names) <= 1000, "请选择 1～1000 个项目")
        check(all(isinstance(name, str) and name and not name.startswith(".") and
                  Path(name).name == name and "\0" not in name for name in names), "项目名称无效")
        check(len(set(names)) == len(names), "选择包含重复项目")
        with self.lock:
            check(not self.busy, "请等待当前备份或还原任务完成")
            items = []
            for name in names:
                item = directory / name
                check(not item.is_symlink() and (item.is_dir() or
                      (item.is_file() and item.suffix.lower() == ".sbackup")), "选中的项目已变化：" + name)
                check(not any(Path(job["output"]).is_relative_to(item) or
                              Path(job["source"]).is_relative_to(item) for job in self.jobs.values()),
                      "自动任务正在使用此文件夹，请先移除任务：" + name)
                items.append(item)
            trash = self.space / ".trash"
            trash.mkdir(exist_ok=True)
            check(not trash.is_symlink() and trash.is_dir(), "回收站路径无效")
            batch = trash / identifier()
            batch.mkdir()
            save_json(batch / ".origin.json", {"directory": str(directory), "names": names, "deleted_at": time.time()})
            moved = []
            try:
                for item in items:
                    item.rename(batch / item.name)
                    moved.append(item)
            except OSError as error:
                for item in reversed(moved):
                    if not item.exists() and not item.is_symlink():
                        (batch / item.name).rename(item)
                raise ValueError("删除未完成，请检查备份空间和回收站") from error
        return {"count": len(moved), "trash": str(batch)}

    def purge_expired_trash(self, now):
        trash = self.space / ".trash"
        if trash.is_symlink() or not trash.is_dir():
            return
        for batch in trash.iterdir():
            marker = batch / ".origin.json"
            if not IDENT.fullmatch(batch.name) or batch.is_symlink() or not batch.is_dir():
                continue
            if marker.is_symlink() or not marker.is_file():
                continue
            try:
                record = load_json(marker, {})
                deleted_at = record.get("deleted_at", marker.stat().st_mtime)
                if not isinstance(deleted_at, (int, float)) or not 0 < deleted_at <= now:
                    continue
                if now - deleted_at >= TRASH_RETENTION_SECONDS:
                    shutil.rmtree(batch)
            except (ValueError, AttributeError, FileNotFoundError):
                continue

    def trash_batches(self):
        trash = self.space / ".trash"
        if trash.is_symlink() or not trash.is_dir():
            return
        for batch in trash.iterdir():
            marker = batch / ".origin.json"
            if not IDENT.fullmatch(batch.name) or batch.is_symlink() or not batch.is_dir():
                continue
            if marker.is_symlink() or not marker.is_file():
                continue
            try:
                record = load_json(marker, {})
                origin = Path(record["directory"])
                if not origin.is_relative_to(self.space) or ".." in origin.parts:
                    continue
                deleted = record.get("deleted_at", marker.stat().st_mtime)
                names = record["names"]
                if not isinstance(names, list) or not isinstance(deleted, (int, float)):
                    continue
                yield batch, origin, deleted, names
            except (ValueError, KeyError, TypeError, FileNotFoundError):
                continue

    def list_trash(self):
        with self.lock:
            items = []
            for batch, origin, deleted, names in self.trash_batches():
                for name in names:
                    if not isinstance(name, str) or not name or Path(name).name != name or name.startswith("."):
                        continue
                    item = batch / name
                    if item.is_symlink() or not item.exists():
                        continue
                    items.append({"batch": batch.name, "name": name, "folder": item.is_dir(),
                                  "origin": origin.relative_to(self.space).as_posix(), "deleted": deleted})
            return sorted(items, key=lambda item: item["deleted"], reverse=True)

    def restore_trash(self, batch_id, name):
        with self.lock:
            check(not self.busy, "请等待当前备份或还原任务完成")
            item = next((item for item in self.list_trash() if item["batch"] == batch_id and item["name"] == name), None)
            check(item is not None, "回收站项目已不存在")
            original = self.space_path(item["origin"], directory=True)
            target = original / name
            check(not target.exists() and not target.is_symlink(), "原位置有同名项目，请先处理同名项目")
            batch = self.space / ".trash" / batch_id
            (batch / name).rename(target)
            if all(child.name == ".origin.json" for child in batch.iterdir()):
                (batch / ".origin.json").unlink()
                batch.rmdir()
            return {"name": name}

    def empty_trash(self):
        with self.lock:
            check(not self.busy, "请等待当前备份或还原任务完成")
            count = len(self.list_trash())
            for batch, _, _, _ in self.trash_batches():
                shutil.rmtree(batch)
            return {"count": count}

    def delete_trash_items(self, selections):
        check(isinstance(selections, list) and 1 <= len(selections) <= 1000, "请选择 1～1000 个项目")
        with self.lock:
            check(not self.busy, "请等待当前备份或还原任务完成")
            available = {(item["batch"], item["name"]): item for item in self.list_trash()}
            selected = []
            for entry in selections:
                key = (entry["batch"], entry["name"])
                check(key in available and key not in selected, "回收站项目已变化")
                selected.append(key)
            for batch_id, name in selected:
                batch = self.space / ".trash" / batch_id
                item = batch / name
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
                if all(child.name == ".origin.json" for child in batch.iterdir()):
                    (batch / ".origin.json").unlink()
                    batch.rmdir()
            return {"count": len(selected)}

    def public(self):
        with self.lock:
            return {"busy": self.busy, "status": self.status, "jobs": list(self.jobs.values()),
                    "remote": {key: self.default_remote.get(key, "") for key in ("url", "user", "ca")},
                    "example": {"source": str(ROOT / "examples/示例资料"),
                                "output": str(self.home / "backups"),
                                "destination": str(self.home / "restored")}}

    def launch(self, label, action):
        with self.lock:
            check(not self.busy, "有任务正在执行")
            self.busy = True
            self.status = label + "…"

        def work():
            try:
                status = str(action())
            except Exception as error:
                status = "失败：" + str(error)
            with self.lock:
                self.status = status
                self.busy = False

        threading.Thread(target=work, daemon=True).start()

    def backup(self, data, archive):
        archive = self.space_path(str(archive), directory=False)
        return self.pack(data, archive)

    def pack(self, data, archive):
        args = ["--source", data["source"], "--output", archive]
        for name in ("name", "path", "extensions", "min-size", "max-size", "after", "before"):
            if data.get(name):
                args.extend(["--" + name, data[name]])
        if not data.get("compression", True):
            args.append("--no-compress")
        return invoke("backup", *args, password=data.get("password", ""))

    def upload_dropped(self, paths, target):
        directory = self.space_path(target, directory=True)
        check(isinstance(paths, list) and 1 <= len(paths) <= 100, "每次可上传 1～100 个项目")
        sources = []
        for path in paths:
            check(isinstance(path, str), "源路径无效")
            source = Path(path)
            check(source.is_absolute() and not source.is_symlink() and
                  (source.is_dir() or source.is_file()), "找不到文件或文件夹：" + path)
            check(not source.resolve().is_relative_to(self.space), "请从备份空间之外拖入文件")
            sources.append(source)
        output = []
        errors = []
        for source in sources:
            label = source.name if source.is_dir() else source.stem
            label = label.strip(" .") or "文件"
            archive = directory / (label[:80] + "-" + identifier() + ".sbackup")
            try:
                if source.is_dir():
                    self.backup({"source": source}, archive)
                else:
                    with tempfile.TemporaryDirectory(prefix="backup-drop-") as staging:
                        wrapper = Path(staging) / (label[:80] + "-文件")
                        wrapper.mkdir()
                        shutil.copy2(source, wrapper / source.name)
                        self.backup({"source": wrapper}, archive)
                output.append(archive.name)
            except (ValueError, OSError) as error:
                errors.append(f"{source.name}：{error}")
        lines = [f"上传完成：{len(output)} 项成功，{len(errors)} 项失败。", *output]
        if errors:
            lines.extend(["失败详情：", *errors])
        return "\n".join(lines)

    def upload_backup(self, archive):
        archive = self.space_path(str(archive), directory=False)
        result = Remote(self.default_remote).upload(archive)
        return (f"网络备份成功\n版本：{result['id']}\n"
                f"实际上传 {result['uploaded']} / {result['bytes']} 字节")

    def backup_and_upload(self, data, archive):
        local = self.backup(data, archive)
        try:
            return self.upload_backup(archive) + "\n\n" + local
        except (ValueError, OSError, KeyError) as error:
            raise ValueError(f"上传失败，归档已保存在备份空间，可选中后重新上传。\n{error}") from error

    def configure_remote(self, data):
        config = {key: str(data.get(key, "")).strip() for key in ("url", "user", "token", "ca")}
        if not config["token"] and all(config[key] == self.default_remote.get(key, "") for key in ("url", "user")):
            config["token"] = self.default_remote.get("token", "")
        check(config["url"] and USER.fullmatch(config["user"]) and config["token"], "请填写仓库地址、账号和令牌")
        versions = Remote(config).call("/versions")
        with self.lock:
            save_json(self.home / "client.json", config)
            self.default_remote = config
        return f"连接成功，设置已保存。远端共有 {len(versions)} 份备份。"

    def add_job(self, data):
        source = Path(data["source"]).resolve()
        output = self.space_path(data["output"], directory=True)
        check(source.is_dir() and output.is_dir() and output != source and source not in output.parents,
              "请选择已有源目录与源目录之外的保存目录")
        mode = data["mode"]
        period, keep = int(data["period"]), int(data["keep"])
        check(mode in ("schedule", "watch") and 5 <= period <= 604800 and 1 <= keep <= 100,
              "间隔须为 5～604800 秒，保留数量须为 1～100")
        key = identifier()
        job = {"id": key, "source": str(source), "output": str(output), "mode": mode,
               "period": period, "keep": keep, "next": time.time() + period, "status": "等待"}
        if mode == "watch":
            job["last_snapshot"] = fingerprint(source)
        with self.lock:
            self.jobs[key] = job
            save_json(self.home / "jobs.json", self.jobs)
        return job

    def run_job(self, job):
        prefix = "auto-" + job["id"] + "-"
        destination = Path(job["output"]) / (prefix + identifier() + ".sbackup")
        try:
            result = self.backup(job, destination)
            versions = sorted(Path(job["output"]).glob(prefix + "*.sbackup"), reverse=True)
            for old in versions[job["keep"]:]:
                if old.is_file() and not old.is_symlink():
                    old.unlink()
            message = "成功：" + destination.name
            return result
        except Exception as error:
            message = "失败：" + str(error)
            raise
        finally:
            with self.lock:
                if job["id"] in self.jobs:
                    job["status"] = message
                    save_json(self.home / "jobs.json", self.jobs)

    def tick(self):
        with self.lock:
            now = time.time()
            if now >= self.next_trash_cleanup:
                self.purge_expired_trash(now)
                self.next_trash_cleanup = now + 3600
            jobs = list(self.jobs.values())
        for job in jobs:
            with self.lock:
                if self.busy or job["id"] not in self.jobs:
                    continue
                now = time.time()
                if job["mode"] == "watch":
                    try:
                        current = fingerprint(Path(job["source"]))
                    except (ValueError, OSError) as error:
                        job["status"] = str(error)
                        continue
                    previous, changed_at = self.watch.get(job["id"], (current, now))
                    if previous != current:
                        changed_at = now
                    self.watch[job["id"]] = (current, changed_at)
                    if current == job.get("last_snapshot") or now - changed_at < job["period"]:
                        continue
                elif now < job["next"]:
                    continue
                job["next"] = now + job["period"]
                save_json(self.home / "jobs.json", self.jobs)

                def action(job=job, stamp=current if job["mode"] == "watch" else None):
                    try:
                        result = self.run_job(job)
                    finally:
                        if stamp:
                            with self.lock:
                                if job["id"] in self.jobs:
                                    self.watch[job["id"]] = (stamp, time.time())
                    if stamp:
                        with self.lock:
                            if job["id"] in self.jobs:
                                job["last_snapshot"] = stamp
                                save_json(self.home / "jobs.json", self.jobs)
                    return result

                self.launch("自动备份", action)


class Console(HTTP):
    def handle_request(self):
        host = self.headers.get("Host", "")
        check(host in {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"},
              "仅允许本机浏览器访问")
        state = self.server.state
        if self.command == "GET" and self.path == "/":
            self.reply(200, (Path(__file__).with_name("index.html")).read_bytes(), "text/html; charset=utf-8")
            return
        if self.headers.get("X-Backup-Console") != "1":
            raise PermissionError("请求缺少控制台标识")
        if self.command == "GET" and self.path == "/api/state":
            self.reply(200, state.public())
            return
        check(self.command == "POST" and self.path.startswith("/api/"), "接口不存在")
        origin = self.headers.get("Origin")
        check(origin is None or origin == "http://" + host, "请求来源不匹配")
        data = json.loads(self.body(65536))
        action = self.path[5:]
        if action == "backup":
            state.space_path(data["archive"], directory=False)
            state.launch("保存到 WSL 服务器", lambda: state.backup(data, data["archive"]))
        elif action == "drop-upload":
            state.space_path(data["directory"], directory=True)
            state.launch("上传拖入的文件", lambda: state.upload_dropped(data["paths"], data["directory"]))
        elif action == "remote-settings":
            state.launch("检查仓库连接", lambda: state.configure_remote(data))
        elif action == "retry-upload":
            state.launch("重新上传归档", lambda: state.upload_backup(data["archive"]))
        elif action == "space":
            self.reply(200, state.list_space(data.get("path", ".")))
            return
        elif action == "space-folder":
            self.reply(201, state.make_space_folder(data.get("path", "."), data["name"]))
            return
        elif action == "space-trash":
            self.reply(200, state.trash_space(data["path"], data["names"]))
            return
        elif action == "trash-list":
            self.reply(200, state.list_trash())
            return
        elif action == "trash-restore":
            self.reply(200, state.restore_trash(data["batch"], data["name"]))
            return
        elif action == "trash-empty":
            self.reply(200, state.empty_trash())
            return
        elif action == "trash-delete":
            self.reply(200, state.delete_trash_items(data["items"]))
            return
        elif action == "space-rename":
            self.reply(200, state.rename_space(data["path"], data["old"], data["new"]))
            return
        elif action == "remote-rename":
            result = Remote(state.default_remote).call("/rename", "POST",
                json.dumps({"id": data["id"], "name": data["name"]}).encode())
            self.reply(200, {"name": result["name"]})
            return
        elif action in ("restore", "inspect"):
            args = ["--archive", data["archive"]]
            if action == "restore":
                destination = Path(data["destination"])
                check(destination.is_absolute() and destination.is_dir(),
                      "请选择 WSL 能访问的已有还原文件夹")
                args.extend(["--destination", destination])
            state.launch("处理归档", lambda: invoke(action, *args, password=data.get("password", "")))
        elif action == "job":
            self.reply(201, state.add_job(data))
            return
        elif action == "remove":
            with state.lock:
                state.jobs.pop(data["id"], None)
                state.watch.pop(data["id"], None)
                save_json(state.home / "jobs.json", state.jobs)
        elif action in ("upload", "versions", "download", "remote-inspect"):
            config = {**state.default_remote, **{k: v for k, v in data.items() if v and k in ("url", "user", "token", "ca")}}
            if any(config.get(k) != state.default_remote.get(k) for k in ("url", "user", "ca")):
                check(data.get("token"), "连接其他仓库时请输入该仓库的访问令牌")
            remote = Remote(config)
            if action == "versions":
                self.reply(200, [{k: v for k, v in item.items() if k != "chunks"} for item in remote.call("/versions")])
                return
            if action == "upload":
                state.launch("上传备份", lambda: json.dumps(remote.upload(Path(data["archive"])), ensure_ascii=False))
            else:
                destination = data["destination"] if action == "download" else None
                state.launch("网络还原" if destination is not None else "检查远端归档",
                             lambda: remote.restore(data["version"], destination, data.get("password", "")))
        else:
            raise ValueError("接口不存在")
        self.reply(200, {"ok": True})


def deliver_email_code(config, recipient, code):
    sender = config["sender"]
    message = EmailMessage()
    message["From"] = sender
    message["To"] = recipient
    message["Subject"] = "文件备份助手 · 注册验证码"
    message.set_content(f"你的注册验证码是 {code}，5 分钟内有效。若未请求验证码，可忽略此邮件。")
    with smtplib.SMTP_SSL("smtp.qq.com", 465, timeout=8, context=ssl.create_default_context()) as smtp:
        smtp.login(sender, config["authorization_code"])
        smtp.send_message(message)


def repository(home, bind, port):
    server = ThreadingHTTPServer((bind, port), Repository)
    server.rename_lock = threading.Lock()
    server.auth_lock = threading.Lock()
    server.sessions = {}
    server.smtp_config = home / "smtp.json"
    server.email_codes = {}
    server.email_sent = {}
    server.email_requests = []
    server.deliver_code = deliver_email_code
    server.managed_lock = threading.Lock()
    server.managed = {}
    server.storage = home / "repository"
    server.storage.mkdir(exist_ok=True)

    def managed_state(user):
        with server.managed_lock:
            if user not in server.managed:
                managed_home = server.storage / user / "managed"
                managed_home.mkdir(parents=True, exist_ok=True)
                server.managed[user] = ConsoleState(managed_home)
            return server.managed[user]

    next_cleanup = 0

    def cleanup_managed_trash():
        nonlocal next_cleanup
        now = time.time()
        if now < next_cleanup:
            return
        next_cleanup = now + 3600
        try:
            accounts = load_json(server.storage / "accounts.json", {})
            accounts.update(load_json(server.storage / "users.json", {}))
            for user in accounts:
                if not USER.fullmatch(user) or not (server.storage / user / "managed").is_dir():
                    continue
                state = managed_state(user)
                with state.lock:
                    state.purge_expired_trash(now)
        except (OSError, ValueError) as error:
            print("回收站清理失败：" + str(error), flush=True)

    server.managed_state = managed_state
    server.service_actions = cleanup_managed_trash
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(home / "tls.crt", home / "tls.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    return server


def provision(home, repo_port):
    if not (home / "tls.crt").exists():
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "365",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                        "-keyout", str(home / "tls.key"), "-out", str(home / "tls.crt")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    repo = home / "repository"
    repo.mkdir(exist_ok=True)
    accounts = load_json(repo / "accounts.json", {})
    if not (home / "client.json").exists():
        token = secrets.token_urlsafe(32)
        accounts["demo"] = hash_bytes(token.encode())
        save_json(repo / "accounts.json", accounts)
        save_json(home / "client.json", {"user": "demo", "token": token,
                  "ca": str(home / "tls.crt"), "url": f"https://127.0.0.1:{repo_port}"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["demo", "console", "server", "account"])
    parser.add_argument("--home", type=Path, default=HOME)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--repository-port", type=int, default=9443)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--user")
    args = parser.parse_args()
    os.umask(0o077)
    home = args.home.resolve()
    home.mkdir(parents=True, exist_ok=True)
    if args.mode == "account":
        check(args.user and USER.fullmatch(args.user), "账号只允许字母、数字、下划线和连字符")
        repo = home / "repository"
        repo.mkdir(exist_ok=True)
        accounts = load_json(repo / "accounts.json", {})
        check(args.user not in accounts, "账号已存在")
        token = secrets.token_urlsafe(32)
        accounts[args.user] = hash_bytes(token.encode())
        save_json(repo / "accounts.json", accounts)
        print(token)
        return
    if args.mode == "server":
        repository(home, args.bind, args.repository_port).serve_forever()
        return
    if args.mode == "demo":
        provision(home, args.repository_port)
        remote = repository(home, "127.0.0.1", args.repository_port)
        threading.Thread(target=remote.serve_forever, daemon=True).start()
    state = ConsoleState(home)
    console = ThreadingHTTPServer(("127.0.0.1", args.port), Console)
    console.state = state

    def scheduler():
        while True:
            try:
                state.tick()
            except (OSError, ValueError) as error:
                with state.lock:
                    state.status = "自动任务错误：" + str(error)
            time.sleep(1)

    threading.Thread(target=scheduler, daemon=True).start()
    print(f"中文控制台：http://localhost:{args.port}", flush=True)
    console.serve_forever()


if __name__ == "__main__":
    main()
