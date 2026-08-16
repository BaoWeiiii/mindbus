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
