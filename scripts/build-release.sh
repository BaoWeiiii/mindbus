#!/bin/bash
set -euo pipefail

# ============================================================
# MindBus macOS App — Build & Package Script
# Usage:
#   ./scripts/build-release.sh              # Build only (no signing)
#   ./scripts/build-release.sh --sign       # Build + sign + notarize
#   ./scripts/build-release.sh --sign --dmg # Build + sign + notarize + DMG
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="MindBus"
BUNDLE_ID="ai.mindbus.app"

# 版本号单一真相源：Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/Info.plist")"

# Output paths
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# Signing config (override via environment)
DEVELOPER_ID="${DEVELOPER_ID:-}"
TEAM_ID="${TEAM_ID:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_PASSWORD="${APPLE_PASSWORD:-}"  # App-specific password
NOTARY_PROFILE="${NOTARY_PROFILE:-}"  # notarytool keychain profile(优先于 APPLE_ID/PASSWORD,密码不进环境)
# App Store Connect API key 三件套(CI 用:无 keychain、无 Apple ID 密码,凭据可撤销)
NOTARY_KEY_FILE="${NOTARY_KEY_FILE:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"

SIGN=false
DMG=false

for arg in "$@"; do
    case $arg in
        --sign) SIGN=true ;;
        --dmg) DMG=true ;;
    esac
done

# ── Step 1: Build universal binary（arm64 + x86_64） ───────
echo "▸ Building universal binary (arm64 + x86_64)..."
cd "$PROJECT_DIR"

# 跑两次架构 build。在 Apple Silicon Mac 上交叉编译 x86_64 需要 macOS 自带的 x86_64 stdlib（默认有）
swift build -c release --arch arm64 2>&1
swift build -c release --arch x86_64 2>&1

ARM64_BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
X86_BINARY="$PROJECT_DIR/.build/x86_64-apple-macosx/release/$APP_NAME"

if [ ! -f "$ARM64_BINARY" ] || [ ! -f "$X86_BINARY" ]; then
    echo "✗ Build failed: one or both architecture binaries missing"
    echo "  arm64:  $ARM64_BINARY ($([ -f "$ARM64_BINARY" ] && echo present || echo missing))"
    echo "  x86_64: $X86_BINARY ($([ -f "$X86_BINARY" ] && echo present || echo missing))"
    exit 1
fi

ARM64_MCP="$PROJECT_DIR/.build/arm64-apple-macosx/release/mindbus-mcp"
X86_MCP="$PROJECT_DIR/.build/x86_64-apple-macosx/release/mindbus-mcp"
if [ ! -f "$ARM64_MCP" ] || [ ! -f "$X86_MCP" ]; then
    echo "✗ mindbus-mcp 双架构未齐"
    echo "  arm64:  $ARM64_MCP ($([ -f "$ARM64_MCP" ] && echo present || echo missing))"
    echo "  x86_64: $X86_MCP ($([ -f "$X86_MCP" ] && echo present || echo missing))"
    exit 1
fi
UNIVERSAL_MCP="$PROJECT_DIR/.build/universal-mindbus-mcp"
rm -f "$UNIVERSAL_MCP"
lipo -create "$ARM64_MCP" "$X86_MCP" -output "$UNIVERSAL_MCP"
echo "✓ mindbus-mcp universal: archs=$(lipo -archs "$UNIVERSAL_MCP")"

# lipo 合并成 universal
UNIVERSAL_BINARY="$PROJECT_DIR/.build/universal-$APP_NAME"
rm -f "$UNIVERSAL_BINARY"
lipo -create "$ARM64_BINARY" "$X86_BINARY" -output "$UNIVERSAL_BINARY"
echo "✓ Universal binary: $(du -h "$UNIVERSAL_BINARY" | cut -f1), archs=$(lipo -archs "$UNIVERSAL_BINARY")"

# ── Step 2: Create .app bundle ────────────────────────────
echo "▸ Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy universal binary
cp "$UNIVERSAL_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$UNIVERSAL_MCP" "$APP_BUNDLE/Contents/MacOS/mindbus-mcp"

# Copy Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Copy SPM resource bundle。Bundle.module 的查找候选含 Bundle.main.resourceURL
# (Contents/Resources)——必须放这里而不是 .app 根:根目录多任何东西都会让
# codesign 报 "unsealed contents present in the bundle root",公证过不去。
# 两个架构内容一样，复制 arm64 的即可
RESOURCE_BUNDLE="$PROJECT_DIR/.build/arm64-apple-macosx/release/MindBus_MindBus.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "✓ Resource bundle copied"
fi

# Copy Sparkle.framework（SPM 拉的是 xcframework，已是 universal）——
# 不拷进 bundle，dyld 找不到 @rpath/Sparkle 会直接闪退
SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo "✓ Sparkle.framework bundled"
else
    echo "✗ Sparkle.framework not found — run 'swift build' first"
    exit 1
fi
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Write PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Process app icon if exists
ICONSET_DIR="$PROJECT_DIR/MindBus/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET_DIR" ]; then
    echo "▸ Processing app icon..."
    ICON_WORK="$DIST_DIR/AppIcon.iconset"
    rm -rf "$ICON_WORK"
    mkdir -p "$ICON_WORK"

    # iconutil requires specific naming: icon_NxN.png and icon_NxN@2x.png
    SOURCE_ICON="$ICONSET_DIR/icon_1024x1024.png"
    if [ -f "$SOURCE_ICON" ]; then
        for size in 16 32 128 256 512; do
            size2=$((size * 2))
            sips -z $size $size "$SOURCE_ICON" --out "$ICON_WORK/icon_${size}x${size}.png" -s format png > /dev/null 2>&1
            sips -z $size2 $size2 "$SOURCE_ICON" --out "$ICON_WORK/icon_${size}x${size}@2x.png" -s format png > /dev/null 2>&1
        done
        iconutil -c icns "$ICON_WORK" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || \
            echo "⚠ iconutil failed — app will use default icon"
    fi
    rm -rf "$ICON_WORK"
fi

echo "✓ App bundle created: $APP_BUNDLE"

# ── Step 3: Code signing ──────────────────────────────────
if [ "$SIGN" = true ]; then
    if [ -z "$DEVELOPER_ID" ]; then
        # Auto-detect Developer ID Application certificate
        DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    fi

    if [ -z "$DEVELOPER_ID" ]; then
        echo "✗ No 'Developer ID Application' certificate found."
        echo "  Create one at: https://developer.apple.com/account/resources/certificates/list"
        echo "  Then double-click the .cer to import into Keychain."
        exit 1
    fi

    echo "▸ Signing with: $DEVELOPER_ID"

    # 公证要求 bundle 内所有 Mach-O 都带 Developer ID + hardened runtime + 时间戳。
    # SwiftPM 构建的 Sparkle 是 adhoc 签名(公证实测 Invalid),必须由内到外用
    # 我们的证书深度重签(顺序照 Sparkle 官方文档:XPC → Autoupdate → Updater.app
    # → framework 本体),然后 mindbus-mcp,最后外层 bundle。
    SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE" ]; then
        for xpc in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
            [ -e "$xpc" ] && codesign --force --options runtime --timestamp \
                --sign "$DEVELOPER_ID" "$xpc"
        done
        [ -f "$SPARKLE/Versions/B/Autoupdate" ] && codesign --force --options runtime --timestamp \
            --sign "$DEVELOPER_ID" "$SPARKLE/Versions/B/Autoupdate"
        [ -d "$SPARKLE/Versions/B/Updater.app" ] && codesign --force --options runtime --timestamp \
            --sign "$DEVELOPER_ID" "$SPARKLE/Versions/B/Updater.app"
        codesign --force --options runtime --timestamp \
            --sign "$DEVELOPER_ID" "$SPARKLE"
    fi

    if [ -f "$APP_BUNDLE/Contents/MacOS/mindbus-mcp" ]; then
        codesign --force --options runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            "$APP_BUNDLE/Contents/MacOS/mindbus-mcp"
    fi

    codesign --force --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/MindBus.entitlements" \
        --sign "$DEVELOPER_ID" \
        "$APP_BUNDLE"

    echo "✓ Code signed"

    # Verify signature
    codesign --verify --deep --strict "$APP_BUNDLE"
    echo "✓ Signature verified"

    # ── Step 4: Notarization ──────────────────────────────
    if [ -n "$NOTARY_PROFILE" ] || [ -n "$NOTARY_KEY_FILE" ] || { [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ]; }; then
        echo "▸ Submitting for notarization..."

        # Create zip for notarization
        NOTARIZE_ZIP="$DIST_DIR/$APP_NAME-notarize.zip"
        ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

        if [ -n "$NOTARY_PROFILE" ]; then
            xcrun notarytool submit "$NOTARIZE_ZIP" \
                --keychain-profile "$NOTARY_PROFILE" \
                --wait
        elif [ -n "$NOTARY_KEY_FILE" ]; then
            xcrun notarytool submit "$NOTARIZE_ZIP" \
                --key "$NOTARY_KEY_FILE" \
                --key-id "$NOTARY_KEY_ID" \
                --issuer "$NOTARY_ISSUER_ID" \
                --wait
        else
            xcrun notarytool submit "$NOTARIZE_ZIP" \
                --apple-id "$APPLE_ID" \
                --password "$APPLE_PASSWORD" \
                ${TEAM_ID:+--team-id "$TEAM_ID"} \
                --wait
        fi

        # Staple the notarization ticket
        xcrun stapler staple "$APP_BUNDLE"
        echo "✓ Notarized and stapled"

        rm -f "$NOTARIZE_ZIP"
    else
        echo "⚠ Skipping notarization (set NOTARY_PROFILE / NOTARY_KEY_FILE 三件套 / APPLE_ID + APPLE_PASSWORD)"
    fi
fi

# ── Step 5: Create DMG ────────────────────────────────────
if [ "$DMG" = true ]; then
    echo "▸ Creating DMG..."
    DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    rm -f "$DMG_PATH"

    if command -v create-dmg >/dev/null 2>&1; then
        # 定制安装窗：暖白噪点背景 + 金箭头引导 + 双语指引
        # 背景用矢量 PDF——Finder 按屏 backing scale 光栅化，文字 Retina 真清晰
        # （位图会被按像素=点渲成 1x，这是唯一绕开该约束的格式，实测 2026-08-03）
        # （资产由 scripts/dmg/render-background.swift 生成，token 与 App 一致；
        #   窗口/图标坐标必须与该脚本头部注释的布局保持同步）
        DMG_STAGE="$DIST_DIR/dmg-stage"
        rm -rf "$DMG_STAGE"
        mkdir -p "$DMG_STAGE"
        cp -R "$APP_BUNDLE" "$DMG_STAGE/"
        create-dmg \
            --volname "$APP_NAME" \
            --volicon "$SCRIPT_DIR/dmg/MindBus-volume.icns" \
            --background "$SCRIPT_DIR/dmg/background.pdf" \
            --window-pos 200 160 \
            --window-size 640 360 \
            --icon-size 128 \
            --text-size 12 \
            --icon "$APP_NAME.app" 180 140 \
            --app-drop-link 460 140 \
            --hide-extension "$APP_NAME.app" \
            --no-internet-enable \
            "$DMG_PATH" "$DMG_STAGE"
        rm -rf "$DMG_STAGE"
    else
        echo "⚠ create-dmg not found (brew install create-dmg) — falling back to plain DMG"
        DMG_TEMP="$DIST_DIR/dmg-temp"
        rm -rf "$DMG_TEMP"
        mkdir -p "$DMG_TEMP"
        cp -R "$APP_BUNDLE" "$DMG_TEMP/"
        ln -s /Applications "$DMG_TEMP/Applications"
        hdiutil create -volname "$APP_NAME" \
            -srcfolder "$DMG_TEMP" \
            -ov -format UDZO \
            "$DMG_PATH"
        rm -rf "$DMG_TEMP"
    fi

    # Sign the DMG if we have a cert
    if [ "$SIGN" = true ] && [ -n "$DEVELOPER_ID" ]; then
        codesign --force --sign "$DEVELOPER_ID" "$DMG_PATH"
        echo "✓ DMG signed"
    fi

    # DMG 也公证+装订:App 已 stapled 能跑,但未公证的 DMG 在部分系统上
    # 打开镜像时仍会弹一次提示——双层公证才是零弹窗。
    if [ "$SIGN" = true ] && [ -n "$NOTARY_PROFILE" ]; then
        echo "▸ Notarizing DMG..."
        xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG_PATH"
        echo "✓ DMG notarized and stapled"
    fi

    echo "✓ DMG created: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
fi

# ── Summary ───────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "  $APP_NAME v$VERSION build complete"
echo "═══════════════════════════════════════"
echo "  App:  $APP_BUNDLE"
[ "$DMG" = true ] && echo "  DMG:  $DMG_PATH"
echo ""
if [ "$SIGN" = false ]; then
    echo "  ⚠ Not signed. Run with --sign to sign for distribution."
fi
