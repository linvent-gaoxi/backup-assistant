#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ ! -x build/linux/backup_cli ]]; then bash linux/build.sh; fi
exec python3 linux/service.py demo "$@"
