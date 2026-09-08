#!/bin/bash
set -euo pipefail

# MindBus — 构建并安装到 /Applications
# Usage: ./scripts/install.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="MindBus"
INSTALL_PATH="/Applications/$APP_NAME.app"

cd "$PROJECT_DIR"

# 精确匹配整条命令行（pgrep -fx）取 PID 再逐个 kill，不用 pkill -f 子串匹配——
# 后者会把命令行里恰好带这段路径的 tail / 编辑器 / 终端一起杀掉。
stop_running_app() {
    local pids pid
    pids="$(pgrep -fx "$INSTALL_PATH/Contents/MacOS/$APP_NAME" || true)"
    [ -n "$pids" ] || return 0
    echo "▸ 关闭正在运行的 ${APP_NAME}（PID: $(echo "$pids" | tr '\n' ' ')）..."
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    sleep 1
}

# ── 1. 覆盖前先看清楚装的是什么 ──
# Releases 下载的 Developer ID 签名版被本地 ad-hoc 构建覆盖后，Sparkle 无法再自动更新
# （签名身份不匹配）；想回到自动更新只能重新从 Releases 安装。问清楚再编译，省得白等。
# codesign 要 -dvv（两个 v）才打印 Authority= 证书链；单 -v 只有 TeamIdentifier，匹配不到
if [ -d "$INSTALL_PATH" ]; then
    EXISTING_SIG="$(codesign -dvv "$INSTALL_PATH" 2>&1 || true)"
    if [[ "$EXISTING_SIG" == *"Authority=Developer ID Application"* ]]; then
        echo "⚠ $INSTALL_PATH 是 Releases 下载的 Developer ID 签名版。"
        echo "  用本地构建覆盖后 Sparkle 将无法自动更新；想恢复需重新从 Releases 安装。"
        read -r -p "  仍要覆盖？[y/N] " answer || answer=""
        case "$answer" in
            y|Y|yes|YES) ;;
            *) echo "已取消，$INSTALL_PATH 未改动"; exit 1 ;;
        esac
    fi
fi

# 注：杀旧进程放在「拷贝前一刻」（第 5 步），不在这里——
# 曾经在编译前杀，编译的几秒窗口里系统把旧版拉活，open 只激活了旧进程，
# 表现为「装了新版界面还是旧的」。

# ── 2. 编译 release ──
echo "▸ 编译 release..."
swift build -c release 2>&1

BINARY=".build/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "✗ 编译失败"
    exit 1
fi
echo "✓ 编译完成 ($(du -h "$BINARY" | cut -f1))"

MCP_BINARY=".build/release/mindbus-mcp"
if [ ! -f "$MCP_BINARY" ]; then
    echo "✗ mindbus-mcp 未编出——检查 Package.swift 的 targets"
    exit 1
fi
echo "✓ mindbus-mcp ($(du -h "$MCP_BINARY" | cut -f1))"

# ── 3. 组装 .app bundle ──
echo "▸ 组装 .app bundle..."
STAGE="$PROJECT_DIR/.build/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
mkdir -p "$STAGE/Contents/Resources"

cp "$BINARY" "$STAGE/Contents/MacOS/$APP_NAME"
# MCP server 与 App 同 bundle 发布：装了 App 就有了 server，且 Sparkle 更新会一并换掉，
# 二进制与索引结构版本因此天然同步（版本不同步时 server 会拒绝服务）。
cp "$MCP_BINARY" "$STAGE/Contents/MacOS/mindbus-mcp"
cp "$PROJECT_DIR/Info.plist" "$STAGE/Contents/"
echo -n "APPL????" > "$STAGE/Contents/PkgInfo"

# SPM resource bundle（.build/release 是 SPM 指向原生架构目录的符号链接，
# 硬编码 arm64-apple-macosx 会让 Intel 构建装出来缺资源）。
# 放 Contents/Resources/ 而不是 .app 根，与 build-release.sh 一致：根目录多任何东西都会让
# codesign 报 "unsealed contents present in the bundle root"，公证过不去。
# 注意 SwiftPM 生成的 Bundle.module **不会**在这里找（只认 .app 根目录旁与编译机的绝对
# 构建路径）——App 侧由 AppResources 按 Bundle.main.resourceURL 定位（issue #3）。
RESOURCE_BUNDLE="$PROJECT_DIR/.build/release/MindBus_MindBus.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "✗ 资源包不存在: $RESOURCE_BUNDLE"
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$STAGE/Contents/Resources/"

# Copy Sparkle.framework（SPM 拉的是 xcframework，已是 universal）——
# 不拷进 bundle，dyld 找不到 @rpath/Sparkle 会直接闪退
SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    mkdir -p "$STAGE/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$STAGE/Contents/Frameworks/"
    echo "✓ Sparkle.framework bundled"
else
    echo "✗ Sparkle.framework not found — run 'swift build' first"
    exit 1
fi
install_name_tool -add_rpath "@executable_path/../Frameworks" "$STAGE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# 资源自检（issue #3）：要求资源包从 .app 内部解析到、关键资源齐全，否则不装。
# 本机 .build 存在时 Bundle.module 的兜底路径也能蒙混过关，自检不认兜底。
echo "▸ 资源自检..."
"$STAGE/Contents/MacOS/$APP_NAME" --check-resources

# App icon
ICONSET_DIR="$PROJECT_DIR/MindBus/Assets.xcassets/AppIcon.appiconset"
SOURCE_ICON="$ICONSET_DIR/icon_1024x1024.png"
if [ -f "$SOURCE_ICON" ]; then
    ICON_WORK="$PROJECT_DIR/.build/AppIcon.iconset"
    rm -rf "$ICON_WORK"
    mkdir -p "$ICON_WORK"
    for size in 16 32 128 256 512; do
        size2=$((size * 2))
        sips -z $size $size "$SOURCE_ICON" --out "$ICON_WORK/icon_${size}x${size}.png" -s format png > /dev/null 2>&1
        sips -z $size2 $size2 "$SOURCE_ICON" --out "$ICON_WORK/icon_${size}x${size}@2x.png" -s format png > /dev/null 2>&1
    done
    iconutil -c icns "$ICON_WORK" -o "$STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICON_WORK"
fi

# ── 4. Ad-hoc 签名（稳定身份，Keychain 不再反复弹窗）──
echo "▸ 签名..."
codesign --force --deep --sign - "$STAGE" 2>/dev/null || true

# ── 5. 安装到 /Applications ──
# 拷贝前一刻才杀旧进程：窗口最短，旧版没机会被系统拉活
stop_running_app
echo "▸ 安装到 $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$STAGE" "$INSTALL_PATH"
rm -rf "$STAGE"

echo "✓ 安装完成: $INSTALL_PATH"

# ── 6. 启动（并验证跑的确实是新二进制）──
echo "▸ 启动 $APP_NAME..."
# 兜底：若这一秒内又有旧进程复活（登录项等），杀掉再启
stop_running_app
sleep 0.5
open "$INSTALL_PATH"

echo ""
echo "═══════════════════════════════════════"
echo "  $APP_NAME 已安装到「应用程序」"
echo "═══════════════════════════════════════"
