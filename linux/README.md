# Ubuntu 版

在 Windows 双击项目根目录的「启动本地客户端.vbs」，可直接打开独立的 Windows 桌面窗口。客户端会连接已有的 Ubuntu 服务，服务未运行时尝试启动它。文件和文件夹可以通过 Windows 对话框选择，常规盘符路径会自动转换为 Ubuntu 路径。关闭客户端窗口后，Ubuntu 服务继续运行，已配置的自动备份仍会执行。

双击项目根目录的 `BackupAssistant-WSL.exe`，默认打开「备份空间」。桌面客户端通过 HTTP 调用 WSL 备份服务器，服务器直接将归档保存到 `~/.local/share/backup-assistant/backups`。手动、定时和实时任务使用同一个目录树，归档的创建、浏览、还原与回收站都从这里操作。左侧「设置」显示 WSL 服务器连接。还原位置仍可自由选择。

在 Windows 双击项目根目录的「启动Ubuntu版.cmd」，然后打开 <http://localhost:8765>。请保留启动窗口。服务会同时启动中文控制台和演示用 HTTPS 仓库。两者默认只监听 WSL 本机。

在 Ubuntu 项目目录运行同一入口：

```bash
bash linux/build.sh
bash linux/start.sh
```

依赖为 GCC 11 或更新版本、OpenSSL 开发库、OpenSSL 命令和 Python 3.10 或更新版本。此机已验证 Ubuntu 22.04 的现有环境。Windows 桌面版仍可用原入口启动。Linux 与 Windows 使用同一 C++17 归档、筛选和 Huffman 代码，Linux 以 OpenSSL 替代 BCrypt。浏览器界面、自动任务和仓库由 Python 标准库实现。

## 课堂演示

1. 「创建备份」已填入示例目录与新归档路径。点击「开始备份」，在底部查看文件数、字节数和归档路径。
2. 「还原与检查」会带入上一步的归档路径。还原会生成原目录名的子目录，重复演示请另选已有的空目录。
3. 「自动备份」新建一个定时任务，设 5 秒、保留 1 份。等两次执行后查看输出目录，只有最近的一份定时归档，手动归档保留。
4. 新建文件变化任务。源目录建议用一个单独的测试文件夹，填 5 秒稳定等待。修改或新增一个文件，等待自动生成归档。
5. 在 Windows 客户端创建备份后进入「备份空间」，刷新列表并双击归档，验证 WSL 服务器上的归档可以还原。

控制台里的路径使用 Ubuntu 格式。Windows C 盘对应 `/mnt/c`。演示的默认保存目录位于 Ubuntu 用户目录，避免 Windows 文件系统挂载限制。自动任务的保存目录须预先建立，并位于源目录之外。

实时备份每秒检查目录、文件大小、修改时间和状态时间，兼容 WSL 的 Windows 挂载路径。稳定等待用于合并连续修改。定时及实时任务重启后保留，WSL 或服务停止期间不会执行。自动任务生成本地完整归档，支持按数量淘汰该任务的旧归档。手动任务可设置归档密码，自动任务当前不保存密码。

## 可独立部署的 HTTPS 仓库

独立 HTTPS 接口的本机演示仓库为 `https://127.0.0.1:9443`。首次启动生成自签名证书、`demo` 账号和随机令牌，控制台通过证书验证连接。令牌存于 Ubuntu 用户目录下权限受限的配置文件。不同账号使用独立的版本清单和块目录。

桌面端默认流程直接使用 WSL 备份空间。独立 HTTPS 仓库接口用于分块传输实验。仓库将归档按 1 MiB 切块，以 SHA-256 标识内容，只接收缺失块。版本清单保存块序列、归档名、大小和摘要。下载后逐块校验并重建归档，由 C++ 核心还原。不同版本的相同块可以复用。重新创建的加密归档采用随机盐和 nonce，其密文块通常无法跨版本复用。未开启归档密码时，HTTPS 保护传输链路，仓库仍存放可读取的归档块。

独立部署时，在服务端为目标域名准备可信 TLS 证书和私钥，放到 `--home` 下的 `tls.crt` 和 `tls.key`。用 `account` 创建账号，把返回的令牌交给该客户端，启动 `server` 并选择监听地址。控制台用 `console` 独立启动，输入远端 HTTPS 地址、账号和令牌。内置演示证书只适用于 localhost。本次验收范围是 WSL 回环连接，跨主机防火墙和证书部署需按实际环境配置。

```bash
python3 linux/service.py account --home /path/to/store --user student
python3 linux/service.py server --home /path/to/store --bind 0.0.0.0 --repository-port 9443
python3 linux/service.py console
```

## 复验

```bash
bash linux/build.sh
python3 -B linux/check.py
```

用例覆盖加密和错误密码、中文路径、空目录、HTTPS 上传还原、错误令牌和账号隔离、增量数据块、周期触发与淘汰、文件变化触发及状态持久化。
