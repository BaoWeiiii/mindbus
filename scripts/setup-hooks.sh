#!/bin/sh
# 启用仓库自带的提交防护 hook。
# 新 clone 后需要跑一次——core.hooksPath 是本地配置，不随 clone 传递。
set -e
cd "$(dirname "$0")/.."
chmod +x .githooks/pre-commit .githooks/pre-push .githooks/_guard.sh
git config core.hooksPath .githooks
echo "✓ 已启用 .githooks（pre-commit + pre-push 内容防护）"
