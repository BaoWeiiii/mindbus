# 安全政策 / Security Policy

[中文](#中文) · [English](#english)

---

## 中文

### 支持的版本

只有最新的 0.1.x 版本接受安全修复。报告前请先升级到 [Releases](https://github.com/BaoWeiiii/mindbus/releases/latest) 的最新版，确认问题仍然存在。

| 版本 | 是否支持 |
| --- | --- |
| 0.1.x（最新） | 支持 |
| 更早的内测版 | 不支持，请升级 |

### 如何报告

请**不要**在公开 Issue 里报告安全问题。

使用 GitHub 的私密漏洞报告：仓库页 → **Security** 标签页 → **Report a vulnerability**（直达：<https://github.com/BaoWeiiii/mindbus/security/advisories/new>）。

报告里请包含：受影响的版本、复现步骤或最小 PoC、你判断的影响面。**不要附带你的真实对话数据**——需要样本时用脱敏后的结构示例。

### 处理时限

- **7 天内**给出首次响应：确认收到，给出初步判断。
- 确认为漏洞后，修复随下一个补丁版本发布（开启了更新检查的用户会由 Sparkle 自动收到），并在 Release notes 与 `CHANGELOG.md` 里致谢（除非你不愿具名）。
- 修复发布前请保密；发布后欢迎公开讨论。

### 威胁模型要点

知道 MindBus 的边界在哪，就知道什么算漏洞：

- **本地 App，没有服务端。** 没有账号、没有云端、没有遥测。数据只在你的机器上。
- **读取你的 AI 对话文件，只读。** App 只读三处：`~/.claude/projects`、Claude 桌面版的 `local-agent-mode-sessions`、`~/.codex/sessions`，从不写入。任何能让 App 写进这些源目录的路径（例如路径穿越）都算漏洞。
- **App 自己的落盘。** 索引在 `~/Library/Application Support/MindBus/`；对话归档副本、Minds 画像、收藏在 `~/.mindbus/`（目录 `700` / 文件 `600`）。削弱这些权限、或让对话内容落到同机其他账号可读的位置，算漏洞。
- **MCP 只读。** `mindbus-mcp` 以 `SQLITE_OPEN_READONLY` 打开索引，五个工具（memory_search / memory_browse / memory_open / memory_digest / minds_read）全部只读；唯一写入是追加式使用日志 `mcp-refs.jsonl`（会话 id、时间戳、宿主名，不含正文）。任何能通过 MCP 参数写索引、或读到索引之外文件的路径都算漏洞。注意：接入的 agent 不带参数调用 `memory_browse()` 拿到全库项目路径地图与高频实体，是设计使然，不算漏洞。
- **Sparkle 更新检查是唯一联网。** 本仓源码不含网络代码；更新检查默认开启，每 24 小时请求一次 GitHub 上的 appcast，更新包由 EdDSA 签名校验（公钥在 `Info.plist`），设置里可一键关闭。绕过签名校验、或让 App 从其他来源安装更新的路径，算漏洞。
- **对话正文是不可信输入。** 会话文件里的文本（助手回复、工具输出、粘贴进来的网页）可能来自任何人。渲染层只允许打开 `http` / `https` 链接。任何借正文内容执行代码、打开本地程序、或把数据发出去的路径，算漏洞。

不在范围内：需要物理接触已解锁的机器、或已能以同一用户身份执行任意代码才成立的问题；Claude Code / Codex 等第三方工具自身对话文件的安全。

---

## English

### Supported versions

Only the latest 0.1.x release receives security fixes. Before reporting, please update to the latest version on [Releases](https://github.com/BaoWeiiii/mindbus/releases/latest) and confirm the issue is still present.

| Version | Supported |
| --- | --- |
| 0.1.x (latest) | Yes |
| Earlier preview builds | No — please upgrade |

### How to report

Please **do not** report security issues in a public Issue.

Use GitHub's private vulnerability reporting: repository page → **Security** tab → **Report a vulnerability** (direct link: <https://github.com/BaoWeiiii/mindbus/security/advisories/new>).

Include: affected version(s), steps to reproduce or a minimal PoC, and your assessment of the impact. **Do not attach your real conversation data** — use redacted structural samples if a sample is needed.

### Response timeline

- **First response within 7 days**: acknowledgement plus an initial assessment.
- Once confirmed, the fix ships in the next patch release (users with update checks enabled receive it via Sparkle) and you are credited in the Release notes and `CHANGELOG.md` unless you prefer not to be named.
- Please keep the report private until the fix is released; public discussion is welcome afterwards.

### Threat model

Knowing where MindBus's boundaries are tells you what counts as a vulnerability:

- **Local app, no server.** No account, no cloud, no telemetry. Data stays on your machine.
- **Reads your AI conversation files, read-only.** The app reads exactly three locations — `~/.claude/projects`, Claude desktop's `local-agent-mode-sessions`, and `~/.codex/sessions` — and never writes to them. Any path that lets the app write into those source directories (e.g. path traversal) is a vulnerability.
- **The app's own files.** The index lives in `~/Library/Application Support/MindBus/`; archived conversation copies, the Minds profile, and stars live in `~/.mindbus/` (directories `700` / files `600`). Weakening those permissions, or leaking conversation content to a location readable by other accounts on the same Mac, is a vulnerability.
- **MCP is read-only.** `mindbus-mcp` opens the index with `SQLITE_OPEN_READONLY`; all five tools (memory_search / memory_browse / memory_open / memory_digest / minds_read) are read-only. The only write is an append-only usage log, `mcp-refs.jsonl` (conversation id, timestamp, host name — no message text). Any path that writes to the index or reads files outside it through MCP parameters is a vulnerability. Note: a connected agent calling `memory_browse()` with no arguments and receiving the whole library's project-path map and top entities is by design, not a vulnerability.
- **Sparkle's update check is the only network access.** This repository contains no networking code; the update check is on by default, fetches the appcast on GitHub once every 24 hours, and verifies update packages with an EdDSA signature (public key in `Info.plist`). It can be turned off with one click in Settings. Bypassing the signature check, or making the app install an update from another source, is a vulnerability.
- **Conversation text is untrusted input.** Text inside session files (assistant replies, tool output, pasted web pages) can come from anyone. The renderer only opens `http` / `https` links. Any path where conversation content executes code, launches a local program, or sends data out is a vulnerability.

Out of scope: issues that require physical access to an unlocked machine or arbitrary code execution as the same user; the security of third-party tools' own conversation files (Claude Code, Codex, etc.).
