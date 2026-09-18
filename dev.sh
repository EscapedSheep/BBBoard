#!/bin/bash
# 开发快速迭代：debug 增量构建（秒级，release 要全量优化很慢）→ 替换
# ~/Applications/BBBoard.app 内二进制 → 重启。app 身份/TCC 权限/菜单与
# install.sh 装的完全一致。首次使用请先跑一次 ./install.sh。
# 用法：./dev.sh
set -euo pipefail
cd "$(dirname "$0")"

# 同 install.sh：防御性指定 Xcode 工具链（已非必需，仅为保险）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

APP="$HOME/Applications/BBBoard.app"
BIN="$APP/Contents/MacOS/BBBoard"

if [ ! -f "$BIN" ]; then
    echo "▸ 尚未安装过 $APP，先走完整安装…"
    ./install.sh
    exit 0
fi

echo "▸ 构建 debug…"
swift build 2>&1 | tail -1

echo "▸ 退出正在运行的旧版…"
osascript -e 'quit app "BBBoard"' 2>/dev/null || true
for _ in $(seq 1 20); do
    pgrep -x BBBoard >/dev/null || break
    sleep 0.25
done
pgrep -x BBBoard >/dev/null && pkill -x BBBoard || true

echo "▸ 替换二进制并重启"
cp .build/debug/BoardApp "$BIN"
codesign --force --sign - "$APP"
open "$APP"

echo "▸ 安装 CLI → ~/.local/bin/bbboard"
mkdir -p "$HOME/.local/bin"
cp .build/debug/BoardCLI "$HOME/.local/bin/bbboard"
codesign --force --sign - "$HOME/.local/bin/bbboard" 2>/dev/null || true

echo "✓ 已更新并重启"
