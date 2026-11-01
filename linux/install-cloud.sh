#!/usr/bin/env bash
set -euo pipefail
umask 077

release="$(cd -- "$(dirname -- "$0")/.." && pwd)"
state="$HOME/.local/share/backup-assistant-cloud"
unit="backup-assistant-cloud.service"
port=9443

mkdir -p -- "$state"
python3 -B - "$release/linux" "$state" "$port" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from service import provision
provision(Path(sys.argv[2]), int(sys.argv[3]))
PY

sudo -n tee "/etc/systemd/system/$unit" >/dev/null <<EOF
[Unit]
Description=Backup Assistant authenticated HTTPS repository
After=network.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=$release
ExecStart=/usr/bin/python3 -B $release/linux/service.py server --home $state --bind 127.0.0.1 --repository-port $port
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$state
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo -n systemctl daemon-reload
sudo -n systemctl enable "$unit"
sudo -n systemctl restart "$unit"
sudo -n systemctl is-active "$unit"
