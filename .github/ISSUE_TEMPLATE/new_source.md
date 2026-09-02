---
name: 新来源采样 / New source sample
about: 提供一个新 AI 工具的会话格式样本，帮助接入解析器 / Provide a session-format sample for a new AI tool
title: "[source] "
labels: new-source
---

> 样本必须脱敏：消息正文换成占位文字（`lorem ipsum`），路径里的用户名换成 `<user>`，项目名换成 `ProjectA`，时间戳可保留。**保留结构，删掉内容。**
>
> Samples must be redacted: replace message bodies with placeholder text (`lorem ipsum`), usernames in paths with `<user>`, project names with `ProjectA`; timestamps can stay. **Keep the structure, drop the content.**

**工具名与版本 / Tool name & version**:

**会话文件路径 / Session file location**（例如 `~/.codex/sessions/**/*.jsonl`；说明一文件一会话还是一目录一会话 / e.g. one file per session or one directory per session）:

**文件格式 / File format**（JSONL / JSON / SQLite / 其他）:

**脱敏后的结构示例 / Redacted structural sample**（贴 5–10 行：用户消息、助手消息、工具调用各至少一条 / 5–10 lines: at least one user message, one assistant message, one tool call）

```jsonl
```

**字段说明 / Field notes**（哪个字段是角色、时间戳、会话 id、工作目录或项目 / which fields carry role, timestamp, session id, working directory or project）:

**已知坑 / Known quirks**（多行 JSON、续写文件、二进制内容、软删除标记…… / multi-line JSON, appended files, binary content, soft-delete markers…）:
