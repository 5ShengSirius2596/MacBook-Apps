#!/bin/bash
set -euo pipefail

APP_NAME="Rat"
BUNDLE_ID="com.local.rat"
APP_BUNDLE="dist/${APP_NAME}.app"
SIGN_IDENTITY="${CODESIGN_ID:--}"

echo "=================================================="
echo "  正在构建 ${APP_NAME} v1.3 (纯原生 AppKit / Apple Silicon arm64)"
echo "=================================================="

echo "[1/3] 准备 ${APP_BUNDLE} 目录结构..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "[2/3] 使用 xcrun swiftc 直接编译原生 arm64 可执行文件..."
xcrun swiftc -O \
    -target arm64-apple-macos14.0 \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework QuartzCore \
    -framework ServiceManagement \
    -framework IOKit \
    -framework UniformTypeIdentifiers \
    Sources/Rat/*.swift \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.1</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Rat 需要输入监控权限，以便通过 IOKit 与罗技 HID++ 鼠标通信并启用高分辨率滚轮功能。</string>
</dict>
</plist>
EOF

echo "[3/3] 签名应用 (Identity: ${SIGN_IDENTITY})..."
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

echo ""
echo "✅ 构建完成：${APP_BUNDLE}"
