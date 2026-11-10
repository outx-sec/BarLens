#!/bin/bash
#
# Build a distributable BarLens-<version>.dmg (and optional .zip when MAKE_ZIP=1).
#
# What this is: a release build of the app, signed the same way build.sh signs
# it, plus a symlink to /Applications so it can be dragged in.
#
# What this is NOT: notarized. `BarLens Dev` is a self-signed
# certificate, so on any other Mac Gatekeeper will refuse the app and say it is
# damaged or from an unidentified developer. That is expected and the README
# inside the image says how to get past it. Fixing it properly means a paid
# Developer ID certificate and `notarytool`, at which point the only change here
# is the identity and one extra submit step.
#
# The /Applications requirement is not a preference — see build.sh.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
STAGE=".build/dmg"
VOLNAME="BarLens"

VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
BUILD=$(plutil -extract CFBundleVersion raw Resources/Info.plist)
DMG="BarLens-${VERSION}.dmg"
ZIP="BarLens-${VERSION}.zip"

echo "==> building $CONFIG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# build.sh does the assembling and signing; INSTALL_DIR just redirects where it
# puts the finished bundle, so there is exactly one copy of that logic.
INSTALL_DIR="$PWD/$STAGE" CONFIG="$CONFIG" ./build.sh

if [ "${MAKE_ZIP:-0}" = "1" ]; then
    echo "==> creating $ZIP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$STAGE/BarLens.app" "$ZIP"
    echo "built $ZIP  ($(du -h "$ZIP" | cut -f1))"
fi

# Drag-to-install target.
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/INSTALL · 安装说明.txt" <<'README'
BarLens 1.0 — Installation Guide / 安装说明
===========================================

[English]

1. Drag BarLens.app into the Applications folder next to it.
   (BarLens MUST reside in /Applications so macOS 27's MenuBarAgent registers
   its status item under its bundle identifier.)

2. On first launch, if macOS Gatekeeper reports an unidentified developer:
   Run in Terminal:
      xattr -d com.apple.quarantine /Applications/BarLens.app
   or click "Open Anyway" in System Settings → Privacy & Security.

3. Grant Accessibility permission when prompted so BarLens can enumerate
   and trigger menu bar items.

4. Requires macOS 27.0 or later. Quitting BarLens immediately restores all
   hidden menu bar items.

---------------------------------------------------------------------------

[简体中文]

1. 把 BarLens.app 拖进旁边的 Applications（应用程序）文件夹。
   （必须放在 /Applications，macOS 27 的 MenuBarAgent 只对标准应用目录下的
   App 按 Bundle ID 记账状态栏图标。）

2. 首次打开若遇到 Gatekeeper 提示，可在终端执行：
      xattr -d com.apple.quarantine /Applications/BarLens.app
   或在「系统设置 → 隐私与安全性」中点击「仍要打开」。

3. 首次运行请按提示授予「辅助功能」权限。

4. 系统要求：macOS 27.0 及以上版本。退出 App 所有隐藏图标将立即恢复。
README

echo "==> creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "built $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "note: self-signed, not notarized. Recipients must right-click → Open once."
