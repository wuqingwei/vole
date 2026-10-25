#!/usr/bin/env bash
# clean-baidunetdisk.sh - 清理 Windows 上百度网盘的无用缓存与死重文件。
# 在 Git Bash / MSYS2 下运行。vole 主程序仅支持 Linux，此脚本独立使用：
#   bash scripts/clean-baidunetdisk.sh          # 执行清理
#   bash scripts/clean-baidunetdisk.sh -n       # 仅预览(dry-run)
#
# 清理内容：
#   1. P2P 加速缓存 BaiduYunKernel/.accelerate（常达数十 GB，非用户文件本体）
#   2. 安装目录死重：*.old* 播放器备份、kernel_o.dll 旧内核、
#      Msixbundle/Appx 安装包残留、pepflashplayer.dll(Flash)、
#      netdisk-chrome-ext.crx、日志、0 字节 cmd.exe
#
# 不动：主程序、BrowserEngine(app.asar/core.asar)、账号数据 users/。

set -u

DRY_RUN=0
[[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY_RUN=1

BAIDU_DIR="${APPDATA:-$HOME/AppData/Roaming}/baidu"
NETDISK="$BAIDU_DIR/BaiduNetdisk"
KERNEL="$BAIDU_DIR/BaiduYunKernel"

say() { printf '%s\n' "$*"; }
run() {
    if (( DRY_RUN )); then say "  [dry-run] $*"; else "$@"; fi
}

# Git Bash 会把 /IM 当路径转换，经 cmd 调用 taskkill
kill_proc() {
    local exe="$1"
    if tasklist 2>/dev/null | grep -qi "^$exe "; then
        say "· 结束进程 $exe"
        run cmd //c "taskkill /IM $exe /F" >/dev/null 2>&1
    fi
}

[[ -d "$NETDISK" ]] || { say "未找到百度网盘安装目录: $NETDISK"; exit 1; }

say "==> 退出百度网盘进程"
kill_proc BaiduNetdisk.exe
kill_proc BaiduNetdiskUnite.exe
kill_proc baidunetdiskhost.exe
kill_proc BaiduNetdiskRender.exe
kill_proc YunDetectService.exe

say "==> [1/2] 清理 P2P 加速缓存 ($KERNEL/.accelerate)"
if [[ -d "$KERNEL/.accelerate" ]]; then
    run rm -rf "$KERNEL/.accelerate"
    say "  已清理"
else
    say "  无缓存，跳过"
fi

say "==> [2/2] 清理安装目录死重文件"
deadweight=(
    "$NETDISK/module/BrowserEngine"/*.old*
    "$NETDISK/kernel_o.dll"
    "$NETDISK/BaiduNetdiskService.Msixbundle"
    "$NETDISK"/Microsoft.*.Appx
    "$NETDISK/pepflashplayer.dll"
    "$NETDISK/netdisk-chrome-ext.crx"
    "$NETDISK/debug.log"
    "$NETDISK/install.log"
    "$NETDISK/cmd.exe"
    "$NETDISK/YunShellExtV164.dll.old"
)
found=0
for f in "${deadweight[@]}"; do
    [[ -e "$f" ]] || continue
    found=1
    run rm -f "$f"
    say "  已删 ${f#$NETDISK/}"
done
(( found )) || say "  无死重文件，跳过"

say "==> 完成"
