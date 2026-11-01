#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p build/linux
g++ -std=c++17 -O2 -Wno-stringop-overread src/{codec,crypto,archive,cli}.cpp -lcrypto -o build/linux/backup_cli
echo "Ubuntu 构建完成：build/linux/backup_cli"
