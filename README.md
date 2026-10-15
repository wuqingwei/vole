# Vole 🐾

<p align="center">
  <b>让你的 Linux 保持干净、轻快，像新装的一样。</b><br>
  深度清理 · 智能卸载 · 系统优化 · 磁盘分析 · 实时监控，一个终端命令搞定。
</p>

<p align="center">
  <a href="https://github.com/wuqingwei/vole/actions/workflows/ci.yml"><img src="https://github.com/wuqingwei/vole/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/wuqingwei/vole/releases"><img src="https://img.shields.io/github/v/release/wuqingwei/vole?style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-Linux-orange?style=flat-square" alt="Linux">
</p>

<p align="center">中文 · <a href="README_EN.md">English</a></p>

---

Vole（田鼠）是 [Mole](https://github.com/tw93/Mole)（鼹鼠）的 Linux 版本。命令、交互和输出风格都沿用 Mole，底层换成了 Linux 的东西：XDG 目录规范、apt / dnf / pacman / zypper、Flatpak、Snap、AppImage、systemd、`/proc` 和 `/sys`。

## 功能

- **一站式工具箱**：相当于 BleachBit + 应用卸载器 + ncdu/DaisyDisk + btop 合在一个命令里
- **深度清理**：用户缓存、缩略图、回收站、浏览器缓存、开发工具缓存、系统包缓存、journal 日志、崩溃转储、旧 Snap 版本、无用 Flatpak 运行时、已卸载应用的残留
- **智能卸载**：deb / rpm / pacman 包、Flatpak、Snap、AppImage、手动装在 `~/.local` 或 `/opt` 的应用，连同缓存一起删；个人配置默认保留
- **磁盘分析**：交互式 TUI，Vim 键导航、过滤、多选、移到回收站、大文件列表、JSON 输出
- **系统维护**：刷新 DNS、字体、图标、菜单、MIME 缓存，浏览器数据库 VACUUM，检查失败的 systemd 服务、TRIM、SMART
- **实时监控**：CPU、内存、磁盘 I/O、网络、电池、温度、风扇、进程、僵尸进程，带健康评分
- **开发者友好**：清理 `node_modules`、`target`、`build`、`.venv`，也认识 **CMake / Qt Creator 影子构建目录** 和 **Vivado 的 `.Xil`、`<proj>.cache`**

## 快速开始

**一行安装**（装到 `~/.local`，不需要 sudo）

```bash
curl -fsSL https://raw.githubusercontent.com/wuqingwei/vole/main/install.sh | bash
```

**或者从源码安装**

```bash
git clone https://github.com/wuqingwei/vole.git
cd vole && ./install.sh                    # 装到 ~/.local
./install.sh --prefix /usr/local           # 或装到系统目录
```

安装脚本会按顺序找 `analyze` / `status` 的二进制：本地 `bin/` 里已编译的文件 → [Releases](https://github.com/wuqingwei/vole/releases) 下载 → 用本机 Go 编译。都没有的话其他命令照常可用。

> 国内用户：GitHub 访问慢可以直接在 Releases 页下载 `vole-x.y.z-linux.tar.gz`，解压后运行 `./install.sh`，包里已带 amd64 和 arm64 静态二进制。自己编译时可以设 `GOPROXY=https://goproxy.cn`。

**运行**

```bash
vo                      # 交互菜单
vo clean                # 深度清理
vo uninstall            # 卸载应用及其残留
vo optimize             # 刷新缓存和服务
vo analyze              # 可视化磁盘浏览器（也可以写 vo analyse）
vo status               # 实时系统仪表盘
vo purge                # 清理项目构建产物
vo installer            # 查找并删除安装包

vo history              # 查看 Vole 删过什么
vo completion           # 安装 bash / zsh / fish 补全
vo update               # 更新
vo remove               # 卸载 Vole 本身
vo --help
vo --version
```

**先预览，再动手**

```bash
vo clean --dry-run
vo uninstall --dry-run
vo optimize --dry-run
vo purge --dry-run
vo installer --dry-run

vo clean --dry-run --debug   # 预览 + 详细日志
vo clean --whitelist         # 选择要保护的缓存
vo optimize --whitelist      # 排除某些优化项
vo purge --paths             # 设置项目扫描目录
vo analyze /mnt/data         # 分析指定目录
```

## 功能详解

> 以下是示例输出，实际条目、大小和跳过原因取决于你的系统。

### 清理 `vo clean`

```
$ vo clean

Clean Your Linux

⚙ Ubuntu 24.04 LTS | x86_64 | Free space: 86.2GB

➤ User essentials
  ✓ Thumbnail cache · 1204 items, 312.4MB
  ✓ Trash · emptied · 9 items, 1.1GB

➤ Browsers
  ✓ Chrome cache · 31 items, 1.2GB
  ◎ Firefox cache · skipped (firefox running)

➤ Developer tools
  ✓ npm cache · 842.0MB
  ✓ pip cache · 415.3MB
  ✓ Go build cache · 1.6GB
  ✓ Vivado logs & .Xil · 23 items, 96.1MB

➤ System
  ✓ APT package cache · 684.2MB
  ✓ Journal logs (older than 14d) · 1.3GB
  ✓ Old snap revisions · 4 items, 1.9GB

======================================================================
Cleanup complete
Tracked cleanup: 10.6GB | Items cleaned: 1312
Free space: 96.8GB (+10.6GB)
======================================================================
```

| 类别 | 内容 |
|---|---|
| 用户 | 缩略图、`~/.xsession-errors.old`、家目录下的 core dump、回收站（可白名单保留） |
| 浏览器 | Chrome、Chromium、Edge、Brave、Vivaldi、Opera、Firefox（含 Snap 版）缓存；GPU / Shader / Code Cache。浏览器运行时跳过 |
| 应用 | VS Code、Cursor、Slack、Discord、Spotify、Steam、Mesa / NVIDIA 着色器缓存、fontconfig、Qt shader cache；30 天没碰过的其他 `~/.cache` 子目录 |
| 开发工具 | npm、pnpm、Yarn、Bun、pip、uv、Go、Conda、Composer、ccache、Cargo、Gradle、node-gyp、Electron、Bazel、Vivado 日志和 `.Xil`；`--docker` 时清 Docker 构建缓存 |
| 残留 | 已卸载 Flatpak 的 `~/.var/app/*`、已卸载 Snap 的 `~/snap/*`、指向不存在程序的启动器和自启动项 |
| 系统（需要 sudo） | apt / dnf / yum / pacman（保留 2 个版本）/ zypper / apk 包缓存，journal 保留 14 天或 500M，14 天前的轮转日志，`/var/crash`，systemd coredump，旧 Snap 版本，无用 Flatpak 运行时 |

只想清理用户目录、不碰系统：`vo clean --user-only`。

白名单在 `~/.config/vole/whitelist`，一行一个路径或通配符，写 `trash` 表示不清空回收站。默认保护 Hugging Face、PyTorch、Playwright、JetBrains 这类重新下载很贵的缓存。

### 卸载 `vo uninstall`

```
$ vo uninstall

Select Apps to Remove  1/4 selected

➤ ● Visual Studio Code            412.6MB | apt      | 2mo ago
  ○ Telegram Desktop              198.3MB | flatpak  | 3d ago
  ○ Obsidian                      156.0MB | appimage | 2w ago
  ○ Postman                       320.1MB | snap     | 1y ago

Files to be removed:

✓ Visual Studio Code, 412.6MB  [apt code]
    ✓ ~/.cache/code

Personal data kept:
  ~/.config/Code

Enter remove · D toggle personal data · q cancel
```

- 来源：桌面菜单里的系统包（通过 `.desktop` 文件反查 dpkg / rpm / pacman）、Flatpak（用户和系统）、Snap、`~/Applications` 等目录里的 AppImage、手动安装的应用
- 缓存一起删除，**个人配置和数据默认保留**，按 `D` 才一起删
- 拒绝卸载桌面环境、systemd、包管理器、内核等核心包；apt 卸载会连带删除较多依赖时给出警告
- `vo uninstall --list` 只列出应用、大小和上次使用时间；`vo uninstall 关键字` 直接预选

### 优化 `vo optimize`

```
$ vo optimize

Optimize

⚙ System  9/31 GB RAM | 412/936 GB Disk | Uptime 6d

PERFORMANCE DIAGNOSIS
  ✓ No sustained high-CPU bottleneck detected (load 0.84, 16 cores)
  ✓ Memory OK (22140 MB available)

➤ DNS & Network
  → DNS cache flushed (systemd-resolved)

➤ Desktop Cache Refresh
  → Font cache rebuilt
  → Application menu database refreshed
  → Icon caches rebuilt (2 themes)

➤ Database Optimization
  ◎ Close these apps before database optimization: Firefox

➤ Services
  ✓ No failed services
  Boot: 4.2s (kernel) + 9.8s (userspace) = 14.0s

➤ Disk Health
  ✓ Periodic TRIM enabled (fstrim.timer)
  ◎ Disk verify skipped (set VOLE_ENABLE_DISK_VERIFY=1 with smartctl installed)

======================================================================
Optimization Complete
Applied 4 optimizations
3 unchanged | 2 skipped | 0 unavailable
======================================================================
```

### 磁盘分析 `vo analyze`

```
$ vo analyze

Analyze Disk  (86.2GB free)
Select a location to explore:

 ▶  1. ████████████████████████  52.1%  |  Home                       75.4GB
    2. ████████                  17.3%  |  Programs (/usr)            25.0GB
    3. █████                     11.0%  |  User cache                 15.9GB
    4. ███                        7.4%  |  Flatpak (system)           10.7GB
    5. ██                         4.9%  |  Old Downloads (90d+)        7.1GB  >3mo
```

| 按键 | 作用 |
|---|---|
| `↑↓` / `j k` | 移动 |
| `Enter` / `l` / `→` | 进入目录 |
| `←` / `h` / `Backspace` | 返回 |
| `/` | 过滤 |
| `Space` | 多选 |
| `d` | 移到回收站（确认后执行，遵守 freedesktop Trash 规范；跨分区时用 `gio trash`） |
| `f` | 最大文件列表 |
| `o` | 用文件管理器打开 |
| `r` | 重新扫描 |
| `q` | 退出 |

- 不跨文件系统，跳过 `/proc` `/sys` `/dev` `/run`；硬链接只计一次；按实际占用块计算，和 `du` 一致
- 大小后面带 `+` 表示部分目录没权限读，`unknown` 表示无法测量
- `vo analyze --json ~/Documents` 输出 JSON，每项带 `scan_status`（`complete` / `partial` / `unavailable`）

### 实时监控 `vo status`

```
Vole Status  Health ● 92  ThinkPad X1 · Intel Core i7-1260P · 31.0GB · Ubuntu 24.04 LTS

⚙ CPU                                       ▦ Memory
Total   ████████░░░░░░░░░░  45.2%           Used    ███████████░░░░░░░  58.4%
Load    0.82 / 1.05 / 1.23 (16 cores)       Total   18.1 / 31.0 GB
Core 1  ██████████████░░░░  78.3%           Avail   12.9 GB · cache 6.2 GB
Core 2  ███████████░░░░░░░  62.1%           Swap    ░░░░░░░░░░░░░░░░░░ 0.0/8.0 GB

▤ Disk                                      ⚡ Power
Used    ████████░░░░░░░░░░  44.0%           Level   ██████████████████ 100%
Free    524.0GB of 936.8GB                  Status  Full
Read    ▮▯▯▯▯  2.10 MB/s                    Health  91% · 212 cycles
Write   ▮▮▮▯▯  18.30 MB/s                   Temp    58°C · 2400 RPM

⇅ Network  wlp0s20f3                        ▶ Processes  412 total
Down    ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s         code           ▮▮▯▯▯  42.1%
Up      ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s         chrome         ▮▯▯▯▯  28.3%
Proxy   HTTP · 127.0.0.1:7890               vivado         ▮▯▯▯▯  21.0%
```

- 健康评分综合 CPU、负载、内存、swap、磁盘容量、温度、电池健康、磁盘 I/O 和开机时长
- 按 `c` 切换显示的核心数，`k` 切换吉祥物，`q` 退出；偏好保存在 `~/.config/vole/status.json`
- `vo status --json` 输出一次快照；输出被管道接走时自动切 JSON：`vo status | jq .health_score`
- `vo status --watch --interval 2s` 持续输出 NDJSON
- 进程 CPU 告警：`--proc-cpu-threshold 80 --proc-cpu-window 30s`，`--proc-cpu-alerts=false` 关闭

### 项目产物清理 `vo purge`

```
$ vo purge

Select Artifacts to Purge  3/5 selected

➤ ● ┌ ~/Projects/website              1.8GB | node_modules   | 28d
  ○ └ ~/Projects/website            186.0MB | dist           | <1d
  ● ─ ~/Projects/rust-app             2.2GB | target         | 2mo
  ● ┌ ~/fpga/sdi_tx                   3.4GB | sdi_tx.cache   | 12d
  ○ └ ~/fpga/sdi_tx                  96.0MB | .Xil           | <7d
```

| 产物 | 判定条件 |
|---|---|
| `node_modules` `.next` `.nuxt` `.turbo` `__pycache__` `.pytest_cache` `.mypy_cache` `.tox` `.gradle` `.dart_tool` `.zig-cache` `.Xil` … | 出现即算 |
| `target` | 旁边有 `Cargo.toml` / `pom.xml` |
| `build` | 旁边有 `package.json` / `CMakeLists.txt` / `build.gradle` / `pyproject.toml` / `meson.build` … |
| `dist` `out` `.venv` `venv` `_build` `obj` `bin` `.build` `.cxx` | 旁边有对应的构建文件 |
| `cmake-build-*` `build-*-Desktop_Qt_*` | 目录里有 `CMakeCache.txt` / `Makefile` / `build.ninja` / `.qmake.stash` |
| `<proj>.cache` `<proj>.ip_user_files` | 旁边有 `<proj>.xpr`（Vivado 工程） |

- 默认扫描 `~/Projects` `~/GitHub` `~/dev` `~/code` `~/src` `~/workspace` `~/work` 等，最深 6 层；`vo purge --paths` 自定义后只扫描你写的目录
- 含 git 跟踪文件、嵌套仓库或密钥文件的目录一律跳过
- 最近 7 天有改动的默认不勾选；非交互运行必须加 `--yes`

### 安装包清理 `vo installer`

查找 `下载` / `桌面`、Telegram、微信、yay / paru 缓存、Steam 下载目录里的 `.deb .rpm .iso .run .pkg.tar.zst .flatpakref .snap .apk .exe .msi .dmg` 等。3 天内下载的默认不勾选，删除前会再次校验文件大小。

## 安全设计

Vole 会删文件，所以它对删除非常保守：能证明安全才删，证明不了就跳过。

- **不要用 `sudo vo`**。Vole 只在需要时单独请求管理员权限
- **受保护路径永远拒绝**：`/`、`/usr`、`/etc`、`/var`、`$HOME`、`~/.config`、`~/.local/share`、`~/.ssh`、`~/.gnupg`、密钥环、密码库等
- 不跟随符号链接，`rm --one-file-system` 不跨分区
- 白名单文件读不了时，`clean`、`purge`、`optimize` 直接停止，不会在没有白名单的情况下继续
- 正在运行的浏览器、编辑器、Vivado 会被检测到，对应缓存跳过
- 所有删除都写进 `~/.local/state/vole/operations.log`，用 `vo history` 或 `vo history --json` 查看，`VOLE_NO_OPLOG=1` 关闭
- `vo analyze` 删除是移到回收站，可以恢复

## 配置

| 文件 | 作用 |
|---|---|
| `~/.config/vole/whitelist` | 清理时保护的路径或通配符，`trash` 表示保留回收站 |
| `~/.config/vole/optimize_whitelist` | 跳过的优化项 ID |
| `~/.config/vole/purge_paths` | 项目扫描目录 |
| `~/.config/vole/status.json` | 仪表盘显示偏好 |

| 环境变量 | 作用 |
|---|---|
| `VOLE_CLEAN_DOCKER=1`（或 `--docker`） | 同时清理 Docker 构建缓存 |
| `VOLE_ENABLE_TRIM=1` | fstrim.timer 没启用时手动 TRIM 一次 |
| `VOLE_ENABLE_DISK_VERIFY=1` | 用 smartctl 检查磁盘健康 |
| `VOLE_ENABLE_SWAP_REFRESH=1` | 内存充足时把 swap 挪回内存 |
| `VOLE_NO_OPLOG=1` | 不写操作日志 |
| `NO_COLOR=1` | 关闭颜色 |

## 系统要求

- Linux，bash 4+，coreutils，findutils
- 支持 Debian / Ubuntu / Mint、Fedora / RHEL、Arch / Manjaro、openSUSE、Alpine 等
- 可选：`sqlite3`（数据库优化）、`smartctl`（磁盘健康）、`gio`（跨分区回收站）、`fc-cache` / `update-desktop-database`（桌面缓存）
- `analyze` / `status` 预编译了 amd64 和 arm64，其他架构需要 Go 1.22+

## 开发

```bash
make build     # 编译本机 analyze / status
make release   # 交叉编译 amd64 / arm64 静态二进制
make test      # 在临时 HOME 里跑完整测试
make lint      # shellcheck + go vet
```

```
vole                 入口，命令分发和交互菜单
lib/core/common.sh   颜色、大小换算、安全检查、白名单、操作日志、safe_remove
lib/core/ui.sh       纯 Bash 多选菜单
lib/clean.sh  uninstall.sh  optimize.sh  purge.sh  installer.sh  history.sh  completion.sh
cmd/analyze/         磁盘分析 TUI（Go + Bubble Tea）
cmd/status/          系统监控 TUI（Go + Bubble Tea，直接读 /proc 和 /sys）
tests/run.sh         集成测试
```

发布：在 GitHub 上发布一个 Release，Actions 会自动编译二进制并上传 `vole-x.y.z-linux.tar.gz`、各架构二进制和 `SHA256SUMS`。

欢迎提 Issue 和 PR。加新的清理目标时，请同时在 `tests/run.sh` 里加测试。

## 致谢

Vole 的灵感、命令设计和交互方式都来自 [tw93](https://github.com/tw93) 的 [Mole](https://github.com/tw93/Mole)。按照 Mole 的要求，衍生项目使用了不同的名字并注明上游。

## 许可证

[GPL-3.0](LICENSE)
