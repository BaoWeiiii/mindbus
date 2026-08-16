#!/bin/bash
set -uo pipefail

# ============================================================
# MindBus 索引数据质量哨兵
#
# 把 2026-08-02 数据链路专项审查的全部判据固化为可重复断言。
# 用途：发版前必跑；改动任何 loader / 索引逻辑后跑；
#       用户报告「重复/丢失/怪数据」时第一时间跑。
# 退出码：0 全绿；1 有断言失败（输出 ✗ 行）。
# 只读，不修改索引。
# ============================================================

DB="${1:-$HOME/Library/Application Support/MindBus/index.sqlite}"
if [ ! -f "$DB" ]; then
    echo "✗ 索引不存在: $DB"
    exit 1
fi

Q() { sqlite3 -readonly "$DB" "$1"; }
FAIL=0
pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; FAIL=1; }
assert_zero() {  # assert_zero <描述> <SQL(应返回 0)>
    local n; n=$(Q "$2")
    if [ "$n" = "0" ]; then pass "$1"; else fail "$1 —— 命中 $n 条"; fi
}

# 政策版本先取一次，供下面「新表是否存在」的分支判断复用——v13（第三路词表检索）
# 新增 segments_fts_lex/lexicon/lexicon_meta/mcp_refs 四张表，跑在还没升级到 v13
# 的真实索引上时查这些表会直接报 "no such table"（sqlite3 把错误打到 stderr，
# $() 只捕获 stdout，变量会拿到空串又继续往下比对，输出一堆脏行、误判成 fail）。
VERSION=$(Q "PRAGMA user_version;")

echo "== MindBus 索引哨兵 · $(date '+%F %T') =="
echo "库: ${DB}（$(Q 'SELECT COUNT(*) FROM conversations') 条，政策 v${VERSION}）"
if [ "${VERSION}" -lt 13 ]; then
    echo "⚠ 政策版本旧（v${VERSION} < v13）——先启动 App 完成迁移，本轮跳过第三路新表检查（segments_fts_lex/lexicon/lexicon_meta/mcp_refs）"
fi
echo

# ── 残骸与壳会话（v4/v5 政策的持续性验证）──
assert_zero "无 API Error 连接残骸（≤2 条且以失败占位开头）" \
    "SELECT COUNT(*) FROM conversations WHERE message_count<=2 AND preview LIKE 'API Error: Unable to connect%';"
assert_zero "无「单 user 无回复」壳会话（>10 分钟前）" \
    "SELECT COUNT(*) FROM conversations WHERE message_count<=1 AND source IN ('claudeCode','claudeAgent') AND end_at < strftime('%s','now')-600;"

# ── 重复维度 ──
assert_zero "无同 id 多行" \
    "SELECT COUNT(*) FROM (SELECT id FROM conversations GROUP BY id HAVING COUNT(*)>1);"
DUP=$(Q "SELECT COUNT(*) FROM (SELECT cwd, substr(preview,1,40) p, COUNT(*) c FROM conversations WHERE source='codex' GROUP BY cwd, p HAVING c>1);")
if [ "${DUP}" = "0" ]; then pass "Codex 无同 cwd+preview 疑似线程组"; else
    # 启发式警告不置 FAIL：同类任务多次独立运行 preview 相同是合法的（如反复评审）；
    # 若某组的 forked_from 指向同根才是收敛失效——人工看一眼下面清单即可判断
    echo "⚠ Codex 同 cwd+preview 组 ${DUP} 个（人工确认是否独立会话）："
    Q "SELECT '  ' || substr(cwd,-24) || ' | ' || substr(preview,1,32) || ' ×' || COUNT(*) FROM conversations WHERE source='codex' GROUP BY cwd, substr(preview,1,40) HAVING COUNT(*)>1 LIMIT 5;"
fi

# ── 时间正确性 ──
assert_zero "无 start_at > end_at" \
    "SELECT COUNT(*) FROM conversations WHERE start_at > end_at;"
assert_zero "无未来时间戳（>now+1h，时钟漂移余量）" \
    "SELECT COUNT(*) FROM conversations WHERE end_at > strftime('%s','now')+3600;"

# ── 表间对账（段级）──
# 注意：不能断言 conversations 行数 == DISTINCT conv_rowid 数——纯图片会话
# 合法地产出 0 段。段级对账改成段表互相核对行数，外加孤儿段检查。
SEG=$(Q "SELECT COUNT(*) FROM segments;")
F1=$(Q "SELECT COUNT(*) FROM segments_fts;")
F2=$(Q "SELECT COUNT(*) FROM segments_fts_uni;")
if [ "${VERSION}" -ge 13 ]; then
    F3=$(Q "SELECT COUNT(*) FROM segments_fts_lex;")
    if [ "$SEG" = "$F1" ] && [ "$SEG" = "$F2" ] && [ "$SEG" = "$F3" ]; then
        pass "段级四表行数对账一致（segments=$SEG = fts = fts_uni = fts_lex）"
    else
        fail "段级表行数不一致：segments=$SEG fts=$F1 fts_uni=$F2 fts_lex=$F3 —— 某条写入/删除路径漏同步"
    fi
else
    if [ "$SEG" = "$F1" ] && [ "$SEG" = "$F2" ]; then pass "段级三表行数对账一致（segments=$SEG = fts = fts_uni）"; else
        fail "段级表行数不一致：segments=$SEG fts=$F1 fts_uni=$F2 —— 某条写入/删除路径漏同步"
    fi
fi
assert_zero "无孤儿段（conv_rowid 指向已不存在的会话）" \
    "SELECT COUNT(*) FROM segments WHERE conv_rowid NOT IN (SELECT rowid FROM conversations);"
# 行数相等排除不了集合错位：segments 删了 3 行、segments_fts 删了另外 3 行时
# 上面的行数对账照样一致，但 fts 里会留着指向已不存在 segments 行的倒排——
# 检索时这些行仍能被 MATCH 命中，JOIN segments 却查不到，就是「幽灵命中」。
assert_zero "无孤儿 segments_fts 行" \
    "SELECT COUNT(*) FROM segments_fts WHERE rowid NOT IN (SELECT rowid FROM segments);"
assert_zero "无孤儿 segments_fts_uni 行" \
    "SELECT COUNT(*) FROM segments_fts_uni WHERE rowid NOT IN (SELECT rowid FROM segments);"
if [ "${VERSION}" -ge 13 ]; then
    assert_zero "无孤儿 segments_fts_lex 行" \
        "SELECT COUNT(*) FROM segments_fts_lex WHERE rowid NOT IN (SELECT rowid FROM segments);"
fi
assert_zero "无孤儿实体关联（指向不存在的会话）" \
    "SELECT COUNT(*) FROM conversation_entities WHERE conv_rowid NOT IN (SELECT rowid FROM conversations);"
assert_zero "无孤儿实体关联（指向不存在的实体）" \
    "SELECT COUNT(*) FROM conversation_entities WHERE entity_rowid NOT IN (SELECT rowid FROM entities);"

# ── MCP 引用回流（v13+，Task 5）──
# mcp_refs 的 conv_id 允许指向已被清理/prune 的会话——日志是 append-only 的历史
# 记录，App 侧只保证 ingest 时会话还在；会话之后被删（源文件清理、政策收紧），
# 这条引用行不会跟着消失，这不是孤儿缺陷，是「历史上真的引用过」这件事本身。
# 所以这里不做外键式对账（不 JOIN conversations 检查存在性），只查两个能算
# 真缺陷的不变量：计数与时间戳都不该是非正数——那样只可能是 ingestRefLog 的
# 聚合逻辑本身写错了，与「会话是否还在」无关。
if [ "${VERSION}" -ge 13 ]; then
    assert_zero "无 mcp_refs 非正计数/非法时间戳（聚合逻辑不变量，与会话是否还在无关）" \
        "SELECT COUNT(*) FROM mcp_refs WHERE ref_count <= 0 OR last_ref <= 0;"
    MCPREFS=$(Q "SELECT COUNT(*) FROM mcp_refs;")
    pass "mcp_refs ${MCPREFS} 行（引用计数为历史记录，允许指向已清理会话）"
fi

# ── 用户语料（v14）──
# user_corpus 行数守恒：每条 conversations 恒有一行（空串也占行，见 upsertOne），
# 少行 = 某条写入路径漏了 user_corpus；多行/孤儿 = 某条删除路径漏了。
if [ "${VERSION}" -ge 14 ]; then
    assert_zero "user_corpus 行数守恒（与 conversations 1:1）" \
        "SELECT ABS((SELECT COUNT(*) FROM user_corpus) - (SELECT COUNT(*) FROM conversations));"
    assert_zero "无孤儿 user_corpus（指向不存在的会话）" \
        "SELECT COUNT(*) FROM user_corpus WHERE conv_rowid NOT IN (SELECT rowid FROM conversations);"
    UCNONEMPTY=$(Q "SELECT COUNT(*) FROM user_corpus WHERE text != '';")
    pass "user_corpus 非空 ${UCNONEMPTY} 行（Minds 概念地图按这份数频次）"
fi

# ── 悬挂与伪路径 ──
# vault 归档上线后「源盘没有」分两种：有归档 = 产品在兑现「工具删了、你的还在」
# （pruneMissing 有意保留这些行，详情回退归档读取，2026-08-10 真实抓到 3 条被
# Claude Code 30 天清理删掉而归档保住的会话）；无归档才是 prune/归档链路的真缺陷。
MISSING=$(Q "SELECT COUNT(*) FROM conversations WHERE file_path LIKE '/%';" )
GONE=0; RESCUED=0
VAULT="$HOME/.mindbus/vault"
while IFS= read -r p; do
    [ -f "$p" ] && continue
    HASH=$(printf '%s' "$p" | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)
    if [ -f "$VAULT/${HASH:0:2}/${HASH}.jsonl.lzma" ]; then RESCUED=$((RESCUED+1)); else GONE=$((GONE+1)); fi
done < <(Q "SELECT file_path FROM conversations WHERE file_path LIKE '/%';")
ONDISK=$((MISSING-RESCUED))
if [ "$GONE" = "0" ]; then
    pass "无真悬挂行（${MISSING} 个绝对路径：在盘 ${ONDISK}，源被清理但归档保住 ${RESCUED}）"
else
    fail "真悬挂行 $GONE 条（索引有、源盘没有、归档也没有）—— prune 或归档链路失效"
fi
BROWSER_ABS=$(Q "SELECT COUNT(*) FROM conversations WHERE source='browser' AND file_path LIKE '/%';")
BROWSER_ALL=$(Q "SELECT COUNT(*) FROM conversations WHERE source='browser';")
pass "browser 行 $BROWSER_ALL 条（其中绝对路径 ${BROWSER_ABS}——伪路径行依赖 prune 的 hasPrefix('/') 守卫）"

# ── preview 质量 ──
assert_zero "无空 preview" \
    "SELECT COUNT(*) FROM conversations WHERE preview IS NULL OR preview = '';"
assert_zero "无注入文本泄漏进 preview" \
    "SELECT COUNT(*) FROM conversations WHERE preview LIKE '<recommended_plugins>%' OR preview LIKE '<environment_context>%' OR preview LIKE '# AGENTS.md instructions%' OR preview LIKE '<multi_agent_mode>%';"

echo
if [ "$FAIL" = "0" ]; then
    echo "== 全绿 =="
else
    echo "== 有断言失败——先跑 App 全量重扫（bump 数据政策或删索引），复现则查对应 loader =="
fi
exit $FAIL
