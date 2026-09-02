#!/bin/bash
set -euo pipefail

# ============================================================
# MindBus — 卸载脚本
#
# 逐条打印将要删除的路径，删之前要你确认；`~/.mindbus`（你的归档副本）
# 单独再问一次。不碰你的原始对话（~/.claude、~/.codex、Claude 桌面版目录）。
#
# 用法: ./scripts/uninstall.sh
#   不需要 sudo：所有路径都在你的用户目录与 /Applications 下。
#   rm -rf 的目标全部写死；家目录用 ${HOME:?} 展开——HOME 未设置或为空时直接中止，
#   不会退化成对根目录动手。
# ============================================================

APP_EXEC="/Applications/MindBus.app/Contents/MacOS/MindBus"

confirm() {   # confirm <提示> → 回答 y / yes 才返回 0
    local answer
    read -r -p "$1 [y/N] " answer || answer=""
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# ── 1. 退出 App ──
# 先 pgrep 再 osascript：App 没在跑时直接 tell … to quit 会把它先拉起来再退出
if pgrep -fx "$APP_EXEC" >/dev/null 2>&1; then
    echo "▸ 退出 MindBus..."
    osascript -e 'tell application "MindBus" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -fx "$APP_EXEC" >/dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -fx "$APP_EXEC" >/dev/null 2>&1; then
        echo "✗ MindBus 仍在运行，请手动退出后重试" >&2
        exit 1
    fi
fi

# ── 2. 列出并确认 ──
echo
echo "将删除以下位置（不存在的自动跳过）："
echo "  1. /Applications/MindBus.app"
echo "       App 本体（含 mindbus-mcp）"
echo "  2. ~/Library/Application Support/MindBus"
echo "       索引 index.sqlite 与 MCP 使用日志 mcp-refs.jsonl（索引可从源文件重建）"
echo "  3. ~/Library/Caches/ai.mindbus.app"
echo "       系统缓存"
echo "  4. ~/Library/Preferences/ai.mindbus.app.plist"
echo "       偏好与更新设置（用 defaults delete 清除）"
echo "  5. ~/Library/Application Support/<浏览器>/NativeMessagingHosts/com.mindbus.native.json"
echo "       旧版本（≤ 1.4.0）写入 Chrome / Arc / Edge / Brave / Opera / Chromium 的清单"
echo
echo "  ~/.mindbus（你的归档：全部对话压缩副本、Minds 画像、收藏/别名/删除记录）最后单独询问。"
echo "  你的原始对话记录（~/.claude、~/.codex 等）不会被碰。"
echo
confirm "继续删除上面 1–5 项？" || { echo "已取消，未做任何改动。"; exit 0; }

# ── 3. 删除 ──
rm -rf "/Applications/MindBus.app"
echo "  ✓ /Applications/MindBus.app"
rm -rf "${HOME:?}/Library/Application Support/MindBus"
echo "  ✓ ~/Library/Application Support/MindBus"
rm -rf "${HOME:?}/Library/Caches/ai.mindbus.app"
echo "  ✓ ~/Library/Caches/ai.mindbus.app"
defaults delete ai.mindbus.app >/dev/null 2>&1 || true
echo "  ✓ defaults delete ai.mindbus.app"

for browser in "Google/Chrome" "Arc/User Data" "Microsoft Edge" "BraveSoftware/Brave-Browser" "com.operasoftware.Opera" "Chromium"; do
    manifest="${HOME:?}/Library/Application Support/$browser/NativeMessagingHosts/com.mindbus.native.json"
    if [ -f "$manifest" ]; then
        rm -f "$manifest"
        echo "  ✓ 已清除 $browser 的 com.mindbus.native.json"
    fi
done

# ── 4. 登录项 ──
echo
echo "  登录项：App 已删除，开机自启随之失效；若「系统设置 → 通用 → 登录项」里仍显示 MindBus，请手动移除。"

# ── 5. ~/.mindbus 单独确认 ──
echo
if [ -d "${HOME:?}/.mindbus" ]; then
    size="$(du -sh "${HOME:?}/.mindbus" 2>/dev/null | cut -f1 || echo '?')"
    echo "最后一项：~/.mindbus（${size}）是你的归档——"
    echo "  全部对话的压缩副本（工具自己删掉的对话只在这里还有一份）、Minds 画像 minds.md、收藏/别名/删除记录。"
    echo "  删了就没有了；保留的话，重装 MindBus 后会原样接续。"
    if confirm "删除 ~/.mindbus？"; then
        if confirm "再确认一次：确定删除 ~/.mindbus 里的全部归档副本？"; then
            rm -rf "${HOME:?}/.mindbus"
            echo "  ✓ 已删除 ~/.mindbus"
        else
            echo "  已保留 ~/.mindbus"
        fi
    else
        echo "  已保留 ~/.mindbus"
    fi
else
    echo "  ~/.mindbus 不存在，跳过。"
fi

echo
echo "═══════════════════════════════════════"
echo "  MindBus 已卸载"
echo "═══════════════════════════════════════"
