<div align="center">

<img src="assets/logo.png" alt="MindBus" width="112" />

# MindBus

**把散落在各个 AI 工具里的对话，收进一台机器。**

模型是租的，对话是你的。

[![License](https://img.shields.io/badge/license-MIT-1a1a1a?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13.0+-1a1a1a?style=flat-square)](#安装)
[![Swift](https://img.shields.io/badge/Swift-5.9-1a1a1a?style=flat-square)](Package.swift)
[![Release](https://img.shields.io/github/v/release/BaoWeiiii/mindbus?style=flat-square&color=1a1a1a)](https://github.com/BaoWeiiii/mindbus/releases/latest)

语言：[English](README.en.md) | 简体中文

[这是什么](#1这是什么) · [我为什么创建它](#2我为什么创建它) · [它能做什么](#3它能做什么) · [快速使用](#4快速使用)

</div>

---

## 1、这是什么？

**你的 AI 工具记忆收纳箱。**

MindBus 是一个 macOS 应用，把你在 Claude Code、Claude 桌面版、ChatGPT 客户端里的对话收进同一个窗口：随时翻阅、收藏、搜索，选中一段就能一键接力到新对话；你的 AI 也能通过 MCP 随时调用这份历史。所有数据都留在你自己的电脑上。

<p align="center"><img width="1672" height="941" alt="home" src="https://github.com/user-attachments/assets/9c866743-008c-44d9-8da7-343d44b8194c" /></p>

## 2、我为什么创建它？

我每天在好几个 AI 工具里聊很多东西。用得越多，下面这些事越让我难受：

<p align="center"><img width="1672" height="941" alt="problem" src="https://github.com/user-attachments/assets/8985af0f-fe12-4271-89ff-dd2aa47bcc54" /></p>

1. **我不敢关窗口，也不敢开新对话。**

   这场会话攒了一下午的上下文，关了怕找不回；开新的，又得把背景从头交代一遍——于是一个窗口越挂越久，越久越不敢动。

2. **AI 挂了、没额度了，我想找聊天记录却没地儿找。**

   服务一抖、额度一到，正聊着的东西就被锁在那个打不开的窗口里。

3. **明明聊过，内容就是找不到。**

   三个工具、三种格式、三个藏在 `~/` 深处的目录，想找回上周那个决定，只能一个个翻。

4. **用着用着，记录悄悄没了。**

   有的工具会定期清理本地记录，等我想起来去找，早就没了，也没有任何提示。

5. **每开一场新会话，AI 都像初次见面。**

   做过的决定、踩过的坑、约定好的偏好全部归零，我只能重新解释一遍。

6. **同一句话我交代了无数遍，自己却没察觉。**

   我有自己的口头禅，交代 AI 的要求也在反复出现，这些模式自己看不见。

于是我做了 MindBus：把这些对话收进一台机器，我自己随时翻，我的 AI 随时查。

## 3、它能做什么？

<p align="center"><img width="1536" height="1024" alt="feature" src="https://github.com/user-attachments/assets/f476db46-c069-4ead-be2d-9a0b162b1ef1" /></p>

| 功能<img width="150" height="1" alt=""> | 说明 |
| --- | --- |
| **永久保存**<br><sub><em>全部存本地</em></sub> | 每一场对话都会在你的电脑上留一份副本，完全丢不了。即使 AI 工具自己清理了记录，你在 MindBus 里依然找得到，被救回的对话会专门标出来。 |
| **统一浏览**<br><sub><em>全部可视化</em></sub> | 三个工具的对话都在同一个窗口里，按工具、项目或时间筛选，就像翻微信聊天记录一样，随便翻找。 |
| **全文搜索**<br><sub><em>直达那条消息</em></sub> | 输入中文或英文关键词，直接定位到那一条消息。搜索会学习你常用的说法，越用越准。 |
| **收藏与接力**<br><sub><em>一键继续干</em></sub> | 把重要的消息标星收藏。选中一段对话，一键复制成可直接粘贴的内容，带到任何新对话里接着聊——AI 挂了、换 AI 都没事，上下文跟人走，不跟窗口走。 |
| **Minds 画像**<br><sub><em>全部数得清</em></sub> | 从你的对话中统计出你常交给 AI 的事、常说的话、反复交代的要求和各个项目的节奏。每一条都能点回原始对话，不是 AI 编写的。那句总在说的话，该沉淀成模板了。 |
| **支持 AI 调用**<br><sub><em>全部可调用</em></sub> | 内置只读的 MCP 服务。接入后，任何 AI 助手都可以自行搜索这份历史、读你的画像——接着上次聊，而不是每次自我介绍。 |
| **完全本地**<br><sub><em>不上传、无账号</em></sub> | 不收集数据，所有内容都留在你的电脑上。唯一的联网是检查更新，可以在设置里关闭。 |

## 4、快速使用

### 支持的 AI 工具
Claude Code、Claude 桌面版、ChatGPT 客户端

### 安装

从 [Releases](https://github.com/BaoWeiiii/mindbus/releases/latest) 下载安装包（Apple Silicon 与 Intel 通用，需要 macOS 13.0 或更高）：

### 打开即用

| 动作 | 怎么做 |
| --- | --- |
| **搜索** | `⌘K` 聚焦搜索框，中英文关键词都行，点击命中直达消息位置。 |
| **翻阅** | 侧栏按工具切换，列表按项目、时间筛选。 |
| **收藏** | 悬停消息点书签图标（或右键）收藏，侧栏「收藏」里集中查看。 |
| **接力** | 选中消息后点「复制接力」，粘贴到任何新对话里继续。 |
| **Minds** | 侧栏点「Minds」，看你自己的画像。 |

### 让 AI 调用

MindBus 自带一个 MCP 服务（`mindbus-mcp`）。把它接到你的 AI 工具上，AI 就能自己翻你的对话历史，不用你每次手动复制粘贴。凡是支持 MCP 的工具都能接，比如 Claude Code、Codex、Cursor。

**第 1 步：接入。** 打开 MindBus 的设置 → 「AI 接入」，点「接入 Claude Code」或「接入 Codex」，MindBus 会把 mindbus 写进该工具的 MCP 配置（Claude Code 是 `~/.claude.json`，Codex 是 `~/.codex/config.toml`），重启该工具后生效。首次启动右侧的欢迎页上也有这个按钮。

其他支持 MCP 的工具，把下面这句话发给它，它会自己完成配置；或在它的 MCP 设置里手动添加一项：名称 `mindbus`，命令 `/Applications/MindBus.app/Contents/MacOS/mindbus-mcp`。

> 把 `/Applications/MindBus.app/Contents/MacOS/mindbus-mcp` 注册成名为 mindbus 的 MCP server

**第 2 步：让AI自动调用（可选）。** 在 AI 工具的说明文件里（Claude Code 是 `CLAUDE.md`，Codex 是 `AGENTS.md`）加上一句，AI 就会主动先查历史再干活：

> 涉及过往决定、项目历史或「之前 / 上次」时，先用 mindbus 的 memory_search 查原始对话；新任务开始前用 minds_read 了解我的偏好。

**接入后 AI 能做什么：**

| 工具 | 作用 |
| --- | --- |
| `memory_search` | 按关键词搜索历史对话 |
| `memory_browse` | 按项目、时间、工具浏览对话清单 |
| `memory_open` | 读取某场对话的原文 |
| `memory_digest` | 拿到某场对话的要点：做了什么、涉及什么、结论是什么 |
| `minds_read` | 读取你的 Minds 画像：偏好、常用词、活跃项目 |

**安全边界：** 这五个工具全部只读，AI 只能看、不能改。MindBus 只会在自己的目录里记一份使用日志（哪场对话在什么时候被哪个 AI 读过），不含对话内容。接入的 AI 能看到你整个对话库的项目名和高频词，这是它能查得准的前提，接入前请知晓。

## 5、许可证

[MIT](LICENSE)
