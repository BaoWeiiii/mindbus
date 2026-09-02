#!/bin/sh
# 内容防护共享逻辑 —— 被 pre-commit 与 pre-push 调用。
#
# 设计原则：确定性规则，不依赖人工或模型每次识别。
#   1. 路径规则：文件名/目录命中即拦（私有文档、数据库、对话原始数据、调研产物）
#   2. 内容规则：正则扫描待提交的差异文本（密钥、令牌、私钥、本机绝对路径）
#   3. 体积规则：异常大文件需显式确认
#
# 绕过方式（应当罕见，且请在 commit message 里说明原因）：
#   git commit --no-verify   /   git push --no-verify

RED=''; YEL=''; NC=''
if [ -t 2 ]; then RED='\033[31m'; YEL='\033[33m'; NC='\033[0m'; fi

# ── 路径 deny-list（扩展正则，匹配仓库相对路径）────────────────
# 私有规格与内部文档：私有规格不进开源仓
DENY_PATH='(^|/)\.env($|\.|/)
(^|/)\.envrc$
\.(pem|key|p12|pfx|cer|mobileprovision|keystore|jks)$
\.(sqlite|sqlite3|db)(-wal|-shm)?$
\.jsonl$
(^|/)(corpus|eval|evalset)\.json$
(^|/)CLAUDE\.md$
(^|/)MEMORY\.md$
(^|/)docs/specs/
(^|/)[A-Z0-9_-]*SPEC\.md$
(^|/)(ROADMAP|DEVPLAN|AUDIT)[A-Z0-9_-]*\.md$
(^|/)\.claude/
(^|/)(scratchpad|research|private|_local)/
(^|/)\.DS_Store$'

# ── 内容正则（每行一条：描述|正则）────────────────────────────
DENY_CONTENT='Anthropic API key|sk-ant-[A-Za-z0-9_-]{16,}
OpenAI API key|sk-(proj-)?[A-Za-z0-9]{32,}
GitHub token|(ghp|gho|ghs|ghr)_[A-Za-z0-9]{30,}
GitHub fine-grained PAT|github_pat_[A-Za-z0-9_]{40,}
AWS access key|AKIA[0-9A-Z]{16}
Slack token|xox[baprs]-[A-Za-z0-9-]{10,}
私钥文件内容|-----BEGIN [A-Z ]*PRIVATE KEY-----
Sentry DSN（含真实 key）|https://[0-9a-f]{16,}@[A-Za-z0-9.-]*sentry\.io
JWT / Supabase key|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.
Supabase service_role|service_role[^A-Za-z]{0,4}(key|secret)
本机绝对路径（泄漏用户名）|/Users/'"$(whoami)"

# 本机私有规则（不入仓）：与 _guard.sh 同目录的 local-deny.txt，每行「描述|正则」。
# 作者身份词、私人邮箱这类规则本身就是敏感信息，只能放在 gitignore 掉的文件里。
_LOCAL_DENY="${HOOK_DIR:-$(dirname "$0")}/local-deny.txt"
if [ -f "$_LOCAL_DENY" ]; then
  DENY_CONTENT="$DENY_CONTENT
$(grep -v '^#' "$_LOCAL_DENY" | grep -v '^[[:space:]]*$')"
fi

MAX_BYTES=5242880   # 5MB

_hit=0

guard_paths() {   # $* = 待检查路径列表
  for f in "$@"; do
    [ -z "$f" ] && continue
    echo "$DENY_PATH" | while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      if printf '%s' "$f" | grep -Eq "$pat"; then
        printf "${RED}✗ 路径被拦截${NC} %s\n    命中规则: %s\n" "$f" "$pat" >&2
        echo "HIT" >> "$GUARD_FLAG"
      fi
    done
  done
}

guard_content() {  # stdin = 差异文本
  _diff=$(cat)
  [ -z "$_diff" ] && return 0
  echo "$DENY_CONTENT" | while IFS='|' read -r desc pat; do
    [ -z "$pat" ] && continue
    _m=$(printf '%s' "$_diff" | grep -aEn "^\+.*$pat" | head -3)
    if [ -n "$_m" ]; then
      printf "${RED}✗ 内容被拦截${NC} [%s]\n" "$desc" >&2
      printf '%s\n' "$_m" | sed 's/^/    /' | cut -c1-160 >&2
      echo "HIT" >> "$GUARD_FLAG"
    fi
  done
}

guard_size() {    # $* = 待检查路径列表
  for f in "$@"; do
    [ -f "$f" ] || continue
    _sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    [ -z "$_sz" ] && continue
    if [ "$_sz" -gt "$MAX_BYTES" ]; then
      printf "${YEL}✗ 文件过大${NC} %s (%s bytes > %s)\n" "$f" "$_sz" "$MAX_BYTES" >&2
      echo "HIT" >> "$GUARD_FLAG"
    fi
  done
}

guard_report() {
  if [ -s "$GUARD_FLAG" ]; then
    printf "\n${RED}══ 已阻止：检测到不应进入公开仓库的内容 ══${NC}\n" >&2
    printf "  这是 mindbus 开源仓，私有规格 / 环境变量 / 密钥 / 对话数据 / 调研产物一律不得提交。\n" >&2
    printf "  · 若文件本就不该进仓：git rm --cached <file> 并加进 .gitignore\n" >&2
    printf "  · 若确属误报：git commit --no-verify（请在 message 说明原因）\n\n" >&2
    rm -f "$GUARD_FLAG"
    return 1
  fi
  rm -f "$GUARD_FLAG"
  return 0
}
