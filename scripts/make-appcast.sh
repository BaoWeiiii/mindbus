#!/bin/bash
set -euo pipefail

# ============================================================
# 生成 Sparkle appcast.xml（单条目：只含最新版）
#
# 用法: make-appcast.sh <short-version> <build-number> <zip-file> <signature-attrs>
#   signature-attrs 是 sign_update 的原样输出，形如：
#   sparkle:edSignature="base64..." length="12345678"
#
# 设计：appcast 永远只描述最新版本——任何旧版用户都直接升到最新，
# 无需维护历史条目。CI 发版时生成并提交回 main（SUFeedURL 指向
# raw.githubusercontent.com 的 main 分支路径）。
# ============================================================

usage() {
    cat >&2 << 'USAGE'
用法: make-appcast.sh <short-version> <build-number> <zip-file> <signature-attrs>
  short-version    形如 1.4.1（CFBundleShortVersionString）
  build-number     纯数字，形如 6（CFBundleVersion，Sparkle 用它比大小）
  zip-file         更新包路径；只取文件名拼进 Releases 下载 URL
  signature-attrs  sign_update 的原样输出：sparkle:edSignature="..." length="..."
输出写到 stdout，重定向到 appcast.xml。
USAGE
    exit 2
}

case "${1:-}" in -h|--help) usage ;; esac
[ "$#" -eq 4 ] || { echo "✗ 需要 4 个参数，收到 $#" >&2; usage; }
[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ short-version 应为 x.y.z，收到: $1" >&2; usage; }
[[ "$2" =~ ^[0-9]+$ ]] || { echo "✗ build-number 应为纯数字，收到: $2" >&2; usage; }
[ -n "$3" ] || { echo "✗ zip-file 为空" >&2; usage; }
[[ "$4" == *sparkle:edSignature=* && "$4" == *length=* ]] || { echo "✗ signature-attrs 缺少 sparkle:edSignature / length（应直接传 sign_update 的输出）" >&2; usage; }

VERSION="$1"
BUILD="$2"
ZIP_NAME="$(basename "$3")"
SIG_ATTRS="$4"

cat << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MindBus</title>
    <link>https://github.com/BaoWeiiii/mindbus</link>
    <item>
      <title>MindBus ${VERSION}</title>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/BaoWeiiii/mindbus/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/BaoWeiiii/mindbus/releases/download/v${VERSION}/${ZIP_NAME}"
        ${SIG_ATTRS}
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
