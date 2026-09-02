# Changelog

本文件记录 MindBus 每个版本面向用户的变化。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。
This file tracks user-facing changes per release, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format with [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.4.1] - 2026-09-02

### Removed / 移除
- Chrome Native Messaging 链路（浏览器扩展桥）整体删除：不再向 Chrome / Arc / Edge / Brave / Opera / Chromium 写 `com.mindbus.native.json`，1.4.1 首次启动自动清除旧版写入的清单。App 现在只读取三个本地目录。
  Removed the Chrome Native Messaging bridge entirely; no more manifests written into six browsers, and leftovers from older versions are cleaned up on first launch. The app now reads exactly three local directories.
- `mindbus://` URL scheme 移除（未曾有处理器，只会被网页凭空拉起 App）。
  Removed the unused `mindbus://` URL scheme.

### Security / 安全
- 对话正文里的链接只允许 `http` / `https`，`file://` 等其他 scheme 点击不再打开。
  Links inside conversation text only open for `http` / `https`; other schemes are discarded.
- `~/.mindbus/` 权限收紧（目录 `700` / 文件 `600`），与工具自身的源目录同级。
  Tightened `~/.mindbus/` permissions (directories `700` / files `600`), matching the source directories.
- 内置样本、测试夹具与注释全部脱敏，不再含真实对话、项目名、路径、会话 UUID；`.githooks` 内容防护支持本机私有规则文件（`local-deny.txt`，不入仓）。
  Built-in samples, test fixtures, and comments fully redacted; the commit guard now reads an optional local, untracked rule file.
- 索引文本绑定改为显式 UTF-8 长度：含 U+0000 的消息不再在 NUL 处被静默截断而对搜索「隐身」。
  Text bindings now pass explicit UTF-8 lengths, so messages containing U+0000 are no longer silently truncated and hidden from search.
- `MindsInjection`（可改写 `~/.claude/CLAUDE.md` 的无入口代码）连同文案一并删除；`--render-preview` 设计校验脚手架只编进 DEBUG 构建；评测管线 `Bench` 从 `MindBusCore` 挪进独立库，主 App 与 `mindbus-mcp` 不再链接会起 `git` 子进程的代码。
  Removed the unreachable `MindsInjection` (could rewrite `~/.claude/CLAUDE.md`); the `--render-preview` scaffold is DEBUG-only now; the bench pipeline moved out of `MindBusCore` so the app and `mindbus-mcp` no longer link code that spawns `git`.
- 日志不再带完整源文件路径；`minds.md` 的悬而未决 / 反复交代行统一压平并截断。
  Logs no longer include full source paths; free text in `minds.md` OPEN LOOPS / PHRASES is flattened and capped.

### Added / 新增
- 设置页新增「登录项」开关，开机自启可关。
  Login-item toggle in Settings.
- `scripts/uninstall.sh`：逐项确认的卸载脚本，`~/.mindbus` 单独二次确认。
  `scripts/uninstall.sh`: an uninstaller that confirms each item, with a separate second confirmation for `~/.mindbus`.

### Fixed / 修复
- 向导扫描页的计数轮询任务在向导完成后不再永远跑下去（此前每 400ms 在主线程跑一次 SQL 直到退出）。
  The setup wizard's live-count poller now stops when scanning finishes (it used to run a main-thread query every 400 ms for the life of the process).
- Minds 画像重建：索引无变化时整轮跳过；「它教你的词」按会话缓存，只重解析变过的会话（此前每轮扫描都把全库会话完整重解析并同时驻留内存）。
  Minds rebuilds are skipped when the index is unchanged, and vocabulary-contagion analysis is cached per conversation instead of re-parsing the whole library into memory on every scan.
- `<system-reminder>` 剥离改为线性扫描，大量未闭合标签不再卡顿；损坏索引件只保留最近一份。
  Stripping `<system-reminder>` blocks is linear now (no more stalls on many unclosed tags); only the latest corrupt-index backup is kept.
- 发布产物的 DMG 现在也经过公证与装订（`build-release.sh` 的 DMG 公证支持与 App 相同的三种凭据；此前 CI 产物只有 App 公证、DMG 仅签名）。
  The release DMG is now notarized and stapled too (DMG notarization accepts the same three credential forms as the app; CI builds previously shipped a notarized app inside a merely signed DMG).

### Changed / 变更
- README 两版事实修正：卸载路径逐条列全（含 `~/.mindbus` 归档）、联网说法改为「唯一联网是 Sparkle 更新检查」、MCP 五个只读工具、Codex 来源的 App 内显示名、测试数 900+。新增 `SECURITY.md`、`CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`、`THIRD_PARTY_NOTICES.md` 与 Issue / PR 模板。
  Documentation corrections in both READMEs (complete uninstall paths, accurate networking statement, five read-only MCP tools, Codex display name, 900+ tests), plus new `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `THIRD_PARTY_NOTICES.md`, and Issue / PR templates.
- `.githooks/pre-push` 不再限制推送目标，fork 贡献者可正常推送；内容防护保留。
  `pre-push` no longer restricts the remote; forks can push normally, content guarding stays.
- `scripts/install.sh` 精确匹配进程再 kill，覆盖 Releases 签名版前先询问；`audit-index.sh` 默认只打计数、`--verbose` 才输出对话片段；脚本路径可用 `DB=` / `MCP=` 覆盖。
  `install.sh` matches the exact process before killing and asks before overwriting a signed Releases build; `audit-index.sh` prints counts only unless `--verbose`; script paths can be overridden with `DB=` / `MCP=`.

## [1.4.0] - 2026-09-01

### Added / 新增
- CI 全自动 Developer ID 签名 + 公证：Releases 里的 DMG 双击即开，无需放行操作；Sparkle 更新包 EdDSA 签名。
  Fully automated Developer ID signing and notarization in CI; DMGs open with a double-click, Sparkle packages are EdDSA-signed.

### Removed / 移除
- Minds 增补层拆除：`minds_enrich` 工具、WEAK SPOTS 节与相关界面全部删除。Minds 回到 100% 机械统计，MCP 回到五个只读工具（memory_search / memory_browse / memory_open / memory_digest / minds_read）。
  Removed the Minds enrichment layer (`minds_enrich`, WEAK SPOTS, related UI). Minds is now 100% mechanical; MCP is back to five read-only tools.

### Fixed / 修复
- 右键菜单修复。
  Context menu fixes.

## [1.3.0] - 2026-08-15

开源首发。/ First open-source release.

### Added / 新增
- Minds（思脉）扩展到 26 节：委托光谱、提问的形状、每个项目的第一句话、口头禅纯净化。
  Minds expanded to 26 sections: delegation spectrum, question shapes, first sentence per project, cleaner catchphrases.
- 删除由你掌控：对话与单条消息删除、二次确认；从列表 / 搜索 / Minds / 归档副本彻底消失且重扫不复活；绝不碰工具目录里的原始文件。
  Deletion under your control: conversations and single messages, with confirmation; gone from list / search / Minds / archive and never resurrected on rescan; original files untouched.
- MCP 工具全链验证与引用回流徽章（你的历史真的在被 AI 用）。
  End-to-end verified MCP tools and reference-count badges.
- 列表活跃点改为金色呼吸。
  Gold breathing dot for active conversations.

### Changed / 变更
- 首装性能大修：流式索引管线、归档流式压缩、lean 行解码——全量首建半分钟级，稳态内存约 70MB。
  First-run performance overhaul: streaming index pipeline, streaming archive compression, lean line decoding — full first build in about half a minute, steady-state memory around 70MB.
- 数据政策 v17：用户语料剔除 Codex 文件引用头注入、消息内换行压平；归档格式与既有 vault 字节兼容。
  Data policy v17; archive format byte-compatible with existing vaults.

[Unreleased]: https://github.com/BaoWeiiii/mindbus/compare/v1.4.1...HEAD
[1.4.1]: https://github.com/BaoWeiiii/mindbus/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/BaoWeiiii/mindbus/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/BaoWeiiii/mindbus/releases/tag/v1.3.0
