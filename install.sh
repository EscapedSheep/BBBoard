#!/bin/bash
# 一键构建 release 并安装/更新本机 ~/Applications/BBBoard.app，然后重启。
# 用法：./install.sh
set -euo pipefail
cd "$(dirname "$0")"

# 防御：xcode-select 指向 CommandLineTools 时历史上有过插件缺失问题（HANDOVER §1），
# 现已无 FoundationModels 依赖，此行仅为保险
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

APP="$HOME/Applications/BBBoard.app"
BIN="$APP/Contents/MacOS/BBBoard"

echo "▸ 构建 release…"
swift build -c release 2>&1 | tail -1

echo "▸ 退出正在运行的旧版…"
osascript -e 'quit app "BBBoard"' 2>/dev/null || true
for _ in $(seq 1 20); do
    pgrep -x BBBoard >/dev/null || break
    sleep 0.25
done
pgrep -x BBBoard >/dev/null && pkill -x BBBoard || true

echo "▸ 更新 $APP"
mkdir -p "$APP/Contents/MacOS"
if [ ! -f "$APP/Contents/Info.plist" ]; then
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BBBoard</string>
	<key>CFBundleIdentifier</key><string>dev.bbboard.app</string>
	<key>CFBundleName</key><string>BBBoard</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.4.0</string>
	<key>CFBundleVersion</key><string>4</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
fi
cp .build/release/BoardApp "$BIN"
codesign --force --sign - "$APP"

echo "▸ 启动新版"
open "$APP"
echo "✓ 安装完成"
