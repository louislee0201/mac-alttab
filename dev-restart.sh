#!/bin/bash
# 重新编译 + 全部重置 + 重启
set -e

echo "编译..."
cd "$(dirname "$0")"
unset CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS
go build -o mac-alttab .

echo "更新 app..."
pkill -f mac-alttab 2>/dev/null; sleep 0.3
cp mac-alttab "/Applications/Mac AltTab.app/Contents/MacOS/mac-alttab"

echo "重置权限和缓存..."
tccutil reset Accessibility com.local.mac-alttab 2>/dev/null
tccutil reset ScreenCapture com.local.mac-alttab 2>/dev/null
rm -rf ~/Library/Caches/mac-alttab 2>/dev/null
defaults delete com.local.mac-alttab 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.local.mac-alttab.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.local.mac-alttab.plist 2>/dev/null

echo "启动..."
open "/Applications/Mac AltTab.app"
echo "✅ 完成"
