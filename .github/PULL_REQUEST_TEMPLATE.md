## 改动说明 / What changed

<!-- 一句话说清改了什么、为什么；关联 Issue 用 Fixes #123 / One line on what and why; link issues with Fixes #123 -->

## 自查清单 / Checklist

- [ ] `swift test` 本地全绿 / all green locally
- [ ] 新增或改动的用户可见文案已进 `MindBus/Config/L10n.swift` 的 `Strings` 双语表，中英都有 / new UI strings live in the bilingual `Strings` table
- [ ] 不含个人路径、真实对话、真实项目名（`scripts/setup-hooks.sh` 装好的 guard 已通过）/ no personal paths or real data (guard hook passes)
- [ ] 改了解析器（`Core/Loaders/`）或索引口径的，已附对应测试与脱敏夹具 / parser or index changes come with tests and redacted fixtures
- [ ] 未引入新的外部依赖 / no new external dependency
