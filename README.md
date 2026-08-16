<div align="center">

<img src="assets/logo.png" alt="MindBus" width="112" />

# MindBus

**把散落在各个 AI 工具里的对话，收进一台机器。**

模型是租的，对话是你的。

无需联网 · 无需账号 · 源码可查

[![简体中文](https://img.shields.io/badge/简体中文-current-A68450?style=flat-square)](#)
[![English](https://img.shields.io/badge/English-switch-DDB992?style=flat-square&logo=googletranslate&logoColor=white)](README.en.md)

[这是什么](#这是什么) · [支持的 AI 工具](#支持的-ai-工具) · [技术概述](#技术概述) · [使用方式](#使用方式) · [安装](#安装)

</div>

---

## 这是什么

**你的 AI 工具记忆收纳箱。**

你可以随时翻阅，收藏；不同的 AI 工具也可以随时调用，低成本获取历史记忆。

<img src="assets/screenshots/browser.png" alt="对话浏览器" width="840" />

一只收纳箱，两头服务：**你**，和**你的 AI**。它治的都是具体的痛——

### 给你的

**①「不知不觉，就被删了。」**
Claude Code 默认 30 天静默清理全部历史，官方立场，改设置也有照删的报告。每个用满 30 天的人都会在某天发现记录没了，且无法挽回。
→ **永久留底**：每场对话在本地存一份压缩副本，工具删它的，你的还在。App 会告诉你有多少场对话「活过了那 30 天」、有多少场已经靠这份副本救了回来。

**②「明明聊过，就是找不到。」**
三个工具、三种格式、三个藏在 `~/` 深处的目录，想找回上周那个决定，只能一个个翻。
→ **一个窗口全收**：搜索中英文关键词直达那条消息，按工具、项目、时间随手筛。

**③「不敢关这个窗口，更不敢开新对话。」**
这场会话攒了一下午的上下文，关了怕找不回；开新的，又得把背景从头交代一遍——于是一个窗口越挂越久，越久越不敢动。
→ **放心关**：对话永远在收纳箱里，随时翻回；要带走的内容标星收藏，或选中后**一键接力**到新对话——上下文跟人走，不跟窗口走。

**④「同一句话，我说了多少遍自己都不知道。」**
你有自己的习惯用语——「第一性原理」「去 GitHub 调研一下」张口就来；对 AI 的交代也翻来覆去讲。这些模式自己是看不见的。
→ **Minds 帮你看见**：从你的对话里数出你派活的动词、你的口头禅、你反复交代过的原话（讲过几遍、跨几场，一清二楚）——常说的那句，该存成模板了。


### 给你的 AI 的

**⑤「每场都是初次见面。」**
每开一场新会话，AI 都从零开始：做过的决定、踩过的坑、约定的偏好全部归零，你只能重新解释一遍。
→ **内置只读 MCP**：任何接入的 AI 都能搜索这份完整历史、读你的画像——接着上次聊，而不是每次自我介绍。

**⑥「用一次历史，烧一堆 token。」**
想让 AI 用上历史，要么整场注入烧掉几十万 token，要么关键词检索赌运气，搜不到就白花。
→ **[记忆换乘协议](docs/MEMORY-TRANSIT.md)**：先递 1.5K token 的目录，AI 自己判断有没有、在哪里，逐层下钻到原文——全程约 4K token，任何一场对话三次换乘必达。不保证直达，保证到达。

以上全部发生在你的机器上——它**没有能力**把数据发到任何地方，不是「我们承诺不发」，是它根本连不了网。

## 支持的 AI 工具

App 只读取下面这三个目录，全部是只读访问，不修改原文件：

| 来源 | 读取路径 |
| --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Claude 桌面版（本地 Agent 模式） | `~/Library/Application Support/Claude/local-agent-mode-sessions/` |
| Codex | `~/.codex/sessions/**/*.jsonl` |

> 注意：你至少得用过其中一个工具——MindBus 收的是「你已经产生的对话」，没有历史数据时它是一间空收纳箱。

代码里还躺着 Cursor、OpenClaw、GitHub Copilot 的解析器，暂时没启用——还差足够多的真实样本来验证格式，验完就开放。

## 技术概述

收纳箱的三条技术底线，对应定位的三个词：

**「你的」——数据不出你的机器。** 这个 App 发不出任何网络请求。想验证？把仓库拉下来运行：

```bash
grep -rn "URLSession\|URLRequest" MindBus/
```

**没有任何输出。** 没有账号，没有崩溃上报，没有分析工具。解析和索引都在本地完成，索引是你磁盘上的一个 SQLite 文件。唯一的联网功能是更新检查（Sparkle → GitHub Releases，可一键关闭；联网能力在 Sparkle 框架内，不在本仓源码）。

**「随时翻阅」——检索是本地全文引擎。** BM25 双分词（中英文各司其职）+ 从你自己语料学出的个人词表 + 查询扩展 + 项目情境加权。Minds 画像全程零 LLM——每一行都可回查到具体的次数、日期、会话。

**「低成本调用」——[记忆换乘协议](docs/MEMORY-TRANSIT.md)。** 五段披露阶梯（线路图 → 选线 → 精查 → 速览 → 原文），token 账单全公开；结构路径三跳封顶、100% 可达，与检索运气无关。

## 使用方式

### 个人使用

打开 App 即自动扫描，几秒后列表可用。日常动作全在一个窗口里：

- **搜索**：中英文关键词，命中片段高亮，点击直达消息位置。
- **翻阅**：按工具 / 项目 / 时间筛选，列表带项目彩签，活跃会话有金色呼吸点。
- **收藏与接力**：标星重要消息；「接力复制」把选中内容一键带去任何新对话。
- **Minds 与报告**：看你的自画像；随时生成 1/3/12 个月的统计卡片，导出前可一键隐去私人内容。

### AI 调用

两句话完成接入。第一句发给你的 AI：

> 把 `/Applications/MindBus.app/Contents/MacOS/mindbus-mcp` 注册成名为 mindbus 的 MCP server

它自己会配好。第二句加进你的 `CLAUDE.md`（或 `AGENTS.md`），让 AI 养成先查历史的习惯：

> 涉及过往决定、项目历史或「之前 / 上次」时，先用 mindbus 的 memory_search 查原始对话；新任务开始前用 minds_read 了解我的偏好。

之后 AI 就能搜索、翻阅这份历史。除「补充画像」（每条都要注明来源、等你确认）外全部只读——索引以只读方式打开，不可能改动你的库。

## 安装

从 [Releases](https://github.com/BaoWeiiii/mindbus/releases/latest) 下载 `MindBus-x.y.z.dmg`（Apple Silicon 与 Intel 通用），拖进「应用程序」。DMG 已由 Apple Developer ID 签名并公证，双击即开。

或者从源码构建：

```bash
git clone https://github.com/BaoWeiiii/mindbus.git
cd mindbus
swift build -c release
./scripts/build-release.sh        # 打包成 MindBus.app（加 --dmg 可产出 DMG）
```

需要 Xcode 15+ / Swift 5.9+，macOS 13.0 或更高。

## 开发

```
MindBus/
├── Core/          # MindBusCore — 解析与索引，纯逻辑，可独立测试
│   ├── Loaders/   # 各工具的 JSONL 解析器
│   ├── DB/        # SQLite 增量索引
│   ├── Markdown/  # 正文分段与代码块识别
│   └── Models/    # Conversation / Message / ContentBlock
├── Views/         # SwiftUI 界面（菜单栏面板 / 对话浏览器 / 设置）
└── Config/        # 设计 token 与 Native Messaging（本地 IPC，非网络）
```

解析逻辑全部收在 `MindBusCore` 这个 library target 里，不依赖 SwiftUI，所以能脱离界面单独测试：

```bash
swift test          # 800+ 个测试,全绿是合并的底线
```

加一个新的对话来源，通常就是写一个 Loader + 一组测试，参考 [`CodexLoader.swift`](MindBus/Core/Loaders/CodexLoader.swift)。

## 常见问题

**打开后是空的?**
MindBus 收录的是「你已经产生的对话」。它不联网、没有云端,所以至少用过一次 Claude Code / Claude 桌面版 / Codex,收纳箱里才有东西。

**删除对话会影响原始文件吗?**
不会。删除只从 MindBus 里抹除(列表、搜索、Minds、归档副本),你工具目录里的原始记录**从未被碰过**——这是写进测试里的底线,每条删除用例都断言源文件仍在。

**Minds 里的内容是 AI 生成的吗?**
不是。每一行都是从你的对话里**数出来**的(次数、日期、会话数皆可回查),全程零 LLM。AI 只在一个地方出现:MCP 的 `minds_enrich` 允许宿主模型补充画像,但每条都强制溯源、默认待你确认。

**什么时候支持 Cursor / Copilot?**
解析器已经写好在仓库里,差的是足够多的真实格式样本做验证。欢迎在 Issue 里提供样本(脱敏后的结构示例即可)。

## 参与贡献

欢迎 Issue 与 PR,中文英文皆可。几条约定:

- **测试全绿是硬门槛**——`swift test` 通过再提 PR;改动解析器或索引口径的,请附上对应测试。
- **新增对话来源**是最受欢迎的贡献:写一个 Loader + 一组测试即可接入全部管线(搜索/Minds/归档),参考 [`CodexLoader.swift`](MindBus/Core/Loaders/CodexLoader.swift)。
- **零外部依赖**是项目底线(唯一例外 Sparkle)——引入新依赖的 PR 请先开 Issue 讨论。

## 卸载

数据主权也包括「干净地离开」。MindBus 在你磁盘上只有两处：

```bash
rm -rf /Applications/MindBus.app
rm -rf ~/Library/Application\ Support/MindBus     # 本地索引（可从源文件随时重建）
```

「登录项」里的开机自启随 App 删除自动失效。你的原始对话记录（`~/.claude` 等）从未被修改，卸载不影响它们。

## 许可证

[MIT](LICENSE)
