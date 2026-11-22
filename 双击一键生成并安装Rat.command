#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

echo "======================================================"
echo "        🐭 Rat for macOS 一键生成与自动安装工具"
echo "======================================================"
echo ""

# 检查 Apple 命令行编译器（Swift）
if ! command -v swift >/dev/null 2>&1; then
    echo "⚠️  检测到你的 Mac 尚未安装 Apple 命令行工具 (Command Line Tools)。"
    echo "👉 正在为你唤起系统安装弹窗，请点击“安装”，等待安装完成后再次双击本文件即可！"
    xcode-select --install || true
    echo ""
    read -n 1 -s -r -p "按任意键关闭窗口..."
    exit 1
fi

echo "1) 正在调用 Apple Swift 编译器原生构建 Rat.app（首次编译约需 10~20 秒）..."
chmod +x ./build_app.sh
./build_app.sh

echo ""
echo "2) 正在安装 Rat.app 到 /Applications 目录..."
pkill -x Rat >/dev/null 2>&1 || true
sleep 0.5

if [ -d "/Applications/Rat.app" ]; then
    rm -rf "/Applications/Rat.app"
fi
cp -R "dist/Rat.app" "/Applications/Rat.app"
xattr -dr com.apple.quarantine "/Applications/Rat.app" >/dev/null 2>&1 || true

echo "3) 正在启动 Rat..."
open "/Applications/Rat.app"

echo ""
echo "🎉 全部完成！Rat 已安装到「应用程序」并在顶部菜单栏启动。"
echo "📌 首次使用请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 Rat。"
echo "📌 如使用罗技高分辨率滚轮，请在「隐私与安全性 → 输入监控」中也勾选 Rat。"
echo ""
read -n 1 -s -r -p "按任意键关闭此窗口..."
