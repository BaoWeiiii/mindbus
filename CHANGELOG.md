# Changelog

本文件记录 MindBus 每个版本面向用户的变化。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。
This file tracks user-facing changes per release, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format with [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-07

首个公开版本：本地 AI 对话库（Claude Code / Claude 客户端 / ChatGPT 客户端三源采集）、全文搜索、归档副本、Minds 画像、五个只读 MCP 工具、DMG 安装。
First public release: a local library of your AI conversations (Claude Code, Claude desktop, ChatGPT desktop), full-text search, archive copies, the Minds profile, five read-only MCP tools, DMG install.

### Changed / 变更
- 首次启动不再弹三页向导：打开就是对话库。列表标题在扫描时显示「正在收集 · 已找到 N 条对话」，对话随扫描逐条出现，侧栏各工具行显示正在读取 / 对话数；右侧空态首启时是欢迎页（只读三目录、数据留本机、一键接入），点开任意对话后恢复。所有开关移到设置页，默认值即合理值。
  No more three-page setup wizard on first launch: the app opens straight into the library. While scanning, the list title reads "Collecting · N found", conversations appear as they're found, and each sidebar tool shows a spinner / its count; the right pane is a welcome page on first launch (three read-only folders, everything local, one-click connect) until you open a conversation. All switches moved to Settings with sensible defaults.
- 扫描剩余时间：起点按通用参考速率算（不依赖本机测速），本段跑过三成后才按实际速度修正（旧默认速率差一两个数量级，首启第一眼「还需约 20 分钟」、一两分钟就扫完）；显示值像倒计时一样平滑，不再从 20 秒一闪跳到 10 秒。欢迎页的进度只在首次建库时出现，之后固定为「点开任意一条」，增量扫描只在侧栏底部露面；「接入 Claude Code」按钮改为「让 Claude Code 能查这些对话」，不再和左侧的对话来源混淆。对话计数单位统一为「条」。
  Remaining time starts from a universal reference rate (no per-machine guessing) and only follows the measured rate once 30% of the phase is done (the old default rates were off by an order of magnitude: "about 20 min left" for a scan that finished in a minute or two); the countdown is smoothed instead of jumping from 20s to 10s. The welcome page shows progress only during the first build, then settles on "pick any conversation" while incremental scans stay in the sidebar footer; the "Connect Claude Code" button became "Let Claude Code search these conversations" so it isn't mistaken for a source.
- 扫描状态行：倒计时只降不升（估算变大就原地停住等它回落），各来源清点完要读多少之前只显示阶段不报时间；阶段文案每 4 秒换一句（读取对话 / 整理标题 / 按项目归类 / 建立全文索引……），像 Claude Code 的状态那样一直在动。整库扫描的顺序读取不再占用系统文件缓存，减少首次建库时对其他 App 的挤压。
  Scan status: the countdown never goes up (it holds until the estimate comes back down) and no time is shown until every source has finished counting what to read; the phase message rotates every 4 seconds (reading conversations / titling / grouping by project / building the search index…) so the status keeps moving, Claude Code style. Bulk reads during a scan no longer occupy the system file cache, so a first build squeezes other apps less.

### Fixed / 修复
- 画像的单场中间结果落盘到索引库（`minds_contagion` 表）。此前只放在进程内存里，每次启动 App 第一轮扫描都要把全库源文件重新解析一遍算画像（18 GB 语料实测约 70 秒满一核、峰值内存 1.9 GB），用户的感受就是「一打开系统卡几秒」；现在只有源文件或词表变过的会话才重算。词表指纹改为跨进程稳定的哈希，大文件解析完立即归还内存池。
  The per-conversation intermediate results of the profile are now persisted in the index (`minds_contagion` table). They only lived in process memory before, so the first scan after every launch re-parsed every source file to rebuild the profile (about 70 s on one core and a 1.9 GB peak for an 18 GB corpus), which felt like the whole system stalling for a few seconds on open; now only conversations whose file or lexicon changed are recomputed. The lexicon fingerprint is a process-stable hash, and memory is returned to the system right after each large file.

- 画像的变更指纹不再计入十分钟内还在被写的会话。此前活跃会话每改一次，扫描一轮就整份重建画像（本机实测 19 秒满一核），每次启动也必来一回；现在会话凉下来才触发一次重建，启动后的后台工作从约 22 秒降到约 5 秒。每轮扫描把各阶段的字节数与秒数写到 `~/Library/Logs/MindBus/scan.log`（无路径、无内容）。
  The profile's change fingerprint now ignores conversations written to within the last ten minutes. Before, every change to an active conversation rebuilt the whole profile on the next scan (about 19 s on one core), including once on every launch; now a rebuild happens once a conversation goes quiet, and post-launch background work dropped from about 22 s to about 5 s. Each scan appends per-phase bytes and seconds to `~/Library/Logs/MindBus/scan.log` (no paths, no content).
### Added / 新增
- 一键接入：设置页「AI 接入」与首启欢迎页上的「接入 Claude Code / Codex」按钮，直接写入对应工具的 MCP 配置（`~/.claude.json` / `~/.codex/config.toml`），可随时移除；其他工具仍可复制接入指令。
  One-click connect: "Connect Claude Code / Codex" in Settings and on the welcome page writes mindbus into the tool's MCP config (`~/.claude.json` / `~/.codex/config.toml`), removable anytime; other tools can still copy the setup prompt.
- 设置页「对话来源」开关：每个工具可单独关掉，关掉的不再扫描、已入库的对话移出列表（归档副本保留）。
  Per-source switches in Settings: a switched-off tool is no longer scanned and its conversations leave the list (archive copies are kept).
- 设置页「登录项」开关（默认关）；接力按钮英文改为 "Copy Handoff"。
  Login-item switch in Settings (off by default); the relay button is now "Copy Handoff" in English.

[Unreleased]: https://github.com/BaoWeiiii/mindbus/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/BaoWeiiii/mindbus/releases/tag/v0.1.0
