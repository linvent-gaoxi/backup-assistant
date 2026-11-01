"""Provision and run the local Ubuntu archive repository."""
import json
import os
import sys

from service import HOME, load_json, provision, repository

PORT = 19444

if __name__ == "__main__":
    os.umask(0o077)
    HOME.mkdir(parents=True, exist_ok=True)
    provision(HOME, PORT)
    if sys.argv[1:] == ["certificate"]:
        print((HOME / "tls.crt").read_text(), end="")
    elif sys.argv[1:] == ["credentials"]:
        config = load_json(HOME / "client.json", {})
        config["certificate"] = (HOME / "tls.crt").read_text()
        print(json.dumps(config))
    elif sys.argv[1:] == ["serve"]:
        repository(HOME, "127.0.0.1", PORT).serve_forever()
    else:
        raise SystemExit("usage: wsl-storage.py credentials|serve")
