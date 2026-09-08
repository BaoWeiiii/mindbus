#!/bin/bash
# 决定性检验（个人词表 ↔ 检索一致性）：
# 从个人词表随机抽词，逐词经 mindbus-mcp 的 memory_search 检索——
# 词表词本来就从语料统计而来，整词检索理应几乎全中；
# 不中的词就是「索引/查询两侧切分不一致」的直接证据，这正是本脚本要抓的回归。
#
# ⚠ 输出含你的个人词表 / 对话片段，勿直接贴进 Issue。
#
# 用法: scripts/lexicon-spotcheck.sh
#   环境变量覆盖（源码构建的贡献者用它指到 .build 里的二进制）：
#   DB=/path/to/index.sqlite MCP=.build/release/mindbus-mcp scripts/lexicon-spotcheck.sh
set -euo pipefail
DB="${DB:-$HOME/Library/Application Support/MindBus/index.sqlite}"
MCP="${MCP:-/Applications/MindBus.app/Contents/MacOS/mindbus-mcp}"

[ -f "$DB" ] || { echo "✗ 索引不存在: ${DB}（用 DB= 指定）" >&2; exit 1; }
[ -x "$MCP" ] || { echo "✗ mindbus-mcp 不可执行: ${MCP}（源码构建请 MCP=.build/release/mindbus-mcp）" >&2; exit 1; }

echo "== 词表规模 =="
sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM lexicon;"
echo ""
echo "== 随机 30 个 3-4 字词（人工看噪声比例）=="
sqlite3 -readonly "$DB" "SELECT word FROM lexicon WHERE length(word) >= 3 ORDER BY random() LIMIT 30;" | tr '\n' '　'
echo ""
echo ""
echo "== 抽 20 个 3-4 字词跑真检索 =="
HIT=0; TOTAL=0
while IFS= read -r w; do
    TOTAL=$((TOTAL+1))
    OUT=$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"%s"}}}\n' "$w" | "$MCP" 2>/dev/null || true)
    if echo "$OUT" | grep -q "conversations matched"; then
        HIT=$((HIT+1))
    else
        echo "  miss: ${w}"
    fi
done < <(sqlite3 -readonly "$DB" "SELECT word FROM lexicon WHERE length(word) >= 3 ORDER BY random() LIMIT 20;")
echo "命中 ${HIT} / ${TOTAL}"
if [ "$TOTAL" -gt 0 ] && [ $((HIT * 100 / TOTAL)) -ge 90 ]; then
    echo "✓ 通过（≥90%）"
else
    echo "✗ 未达 90% —— 查索引/查询两侧切分是否一致"
    exit 1
fi
