"""Configure QQ SMTP interactively without displaying the authorization code."""
import argparse
import getpass
import os
from pathlib import Path
import re
import smtplib
import ssl

from service import save_json


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    sender = input("发信 QQ 邮箱地址：").strip().lower()
    if not re.fullmatch(r"[a-z0-9_.-]+@qq\.com", sender):
        raise SystemExit("请输入有效的 QQ 邮箱地址。")
    code = getpass.getpass("QQ 邮箱 SMTP 授权码（输入时不显示）：").strip()
    if not code:
        raise SystemExit("授权码为空。")
    try:
        with smtplib.SMTP_SSL("smtp.qq.com", 465, timeout=8, context=ssl.create_default_context()) as smtp:
            smtp.login(sender, code)
    except (OSError, smtplib.SMTPException):
        raise SystemExit("QQ SMTP 登录失败，请检查网络、邮箱地址和授权码。") from None
    home = args.home.expanduser()
    home.mkdir(parents=True, exist_ok=True)
    save_json(home / "smtp.json", {"sender": sender, "authorization_code": code})
    print("QQ SMTP 登录成功，已启用新账号邮箱验证码。")
