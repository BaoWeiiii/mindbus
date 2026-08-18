import Foundation

/// Codex Desktop / CLI session log parser.
///
/// File layout: `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`
/// Codex Desktop and Codex CLI share the same directory; `originator`
/// distinguishes them ("Codex Desktop" vs CLI variants).
///
/// Per-line shape: `{type, payload, timestamp}` where `type` is one of
/// `session_meta` | `response_item` | `event_msg` | `turn_context`.
/// Only `response_item` with `payload.type == "message"` carries chat text.
///
/// Filtering rules:
/// - Drop `developer` role (system prompts).
/// - Drop user messages whose first text block is auto-injected context
///   (`<environment_context>`, `<permissions ...>`, `<app-context>`,
///    `<turn_aborted>`, `<user_instructions>` etc).
/// - `input_text` and `output_text` map to `.text` blocks.
/// - `reasoning` items are encrypted (no readable summary today) → skipped.
public enum CodexLoader {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 时间戳解析口径(全量 parseLine 与 lean 流式解码共用)。
    static func parseTimestamp(_ tsStr: String) -> Date? {
        iso8601.date(from: tsStr) ?? iso8601NoFraction.date(from: tsStr)
    }

    /// 单行字节上限（默认）。Codex 上下文压缩写的 `compacted` 行内嵌整会话累积的 base64
    /// 截图，单行可达 155MB；这些行整行 buffer+解析瞬时约 600MB 后又因 `type≠response_item`
    /// 被丢弃，是首次建库内存峰值主因。30MB 能干净分离 compaction 巨行（49/155MB）与正常行
    /// （≤22MB）及用户主动贴图（实测 ≤15MB），在读取层（JSONLReader）流式跳过、不解码不解析。
    public static let defaultMaxLineBytes = 30 * 1024 * 1024

    /// Returns true when the user message is Codex's own context injection,
    /// not actual human input.
    public static func isAutoInjectedUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "<environment_context>",
            "<permissions",
            "<app-context>",
            "<turn_aborted>",
            "<user_instructions>",
            "<system-",
            "<goal_context>",             // goal 模式的「继续朝目标推进」注入
            "<subagent_notification>",    // 子 agent 通知注入
            "<recommended_plugins>",      // 插件推荐清单（顶着 user 名头注入）
            "<multi_agent_mode>",         // 多 agent 模式声明注入
            // 浏览器状态注入的第三种形态(另两种:「# In app browser:」头在语料层
            // 剥、截图在图片过滤里丢)。它整块都是客户端写的环境描述。
            "<in-app-browser-context",
            "# AGENTS.md instructions",   // Codex 把 AGENTS.md 作为前言注入
            "AGENTS.md instructions for",
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    /// 解析 data URI（data:image/<type>;base64,<DATA>）为 .image block；非此格式返回 nil。
    static func parseDataURIImage(_ s: String) -> ContentBlock? {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
        let header = s[s.index(s.startIndex, offsetBy: 5)..<comma]   // image/png;base64
        guard let semi = header.firstIndex(of: ";") else { return nil }
        let mediaType = String(header[..<semi])                       // image/png
        guard mediaType.hasPrefix("image/") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard !b64.isEmpty else { return nil }
        return .image(mediaType: mediaType, source: .base64(b64))
    }

    /// Parses a single JSONL line; returns nil when it isn't a chat message
    /// or shouldn't be shown. `lineIndex` participates in the message id —
    /// timestamp+role alone collides when Codex writes several messages in
    /// the same millisecond.
    public static func parseLine(_ line: String, lineIndex: Int? = nil) -> Message? {
        guard !line.isEmpty, line.first == "{" else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard (obj["type"] as? String) == "response_item",
              let payload = obj["payload"] as? [String: Any]
        else { return nil }
        guard (payload["type"] as? String) == "message" else {
            // 白名单外的新 payload 类型遥测上报（对话内容的风险面集中在 response_item 演化）
            FormatTelemetry.shared.note(source: "codex", type: (payload["type"] as? String) ?? "?")
            return nil
        }

        guard let roleStr = payload["role"] as? String else { return nil }
        let role: MessageRole
        switch roleStr {
        case "user": role = .user
        case "assistant": role = .assistant
        // developer = system prompt; never surface
        default: return nil
        }

        let content = payload["content"] as? [[String: Any]] ?? []
        var texts: [String] = []
        for c in content {
            let cType = c["type"] as? String ?? ""
            // input_text / output_text → user/assistant text block.
            // input_image / output_image are ignored for V1 (no binary support).
            if cType == "input_text" || cType == "output_text" || cType == "summary_text" {
                if let t = c["text"] as? String, !t.isEmpty {
                    texts.append(t)
                }
            }
        }
        // 用户消息：逐块剔除 Codex 注入的脚手架（AGENTS.md / environment_context / user_instructions 等），
        // 只保留真实文字；若整条全是注入则丢弃。逐块（而非整条 merge 后判断）可保住「注入块+真问题」混排时的真问题。
        if role == .user {
            texts = texts.filter { !isAutoInjectedUserText($0) }
        }
        guard !texts.isEmpty else { return nil }
        let merged = texts.joined(separator: "\n")

        var blocks: [ContentBlock] = [.text(merged)]
        // 仅保留用户主动附件（# Files mentioned by the user:）的图；
        // browser-use 注入截图（# In app browser:）等只留文字。
        if role == .user && merged.contains("# Files mentioned by the user:") {
            for c in content where (c["type"] as? String) == "input_image" {
                if let urlStr = c["image_url"] as? String,
                   let img = Self.parseDataURIImage(urlStr) {
                    blocks.append(img)
                }
            }
        }

        // timestamp 解析不出就丢弃该行：兜底 Date()（=解析那一刻）会把这条消息
        // 排到会话末尾、endAt 被顶成「现在」，污染整条排序，不如不要。
        let tsStr = (obj["timestamp"] as? String) ?? ""
        guard let ts = iso8601.date(from: tsStr) ?? iso8601NoFraction.date(from: tsStr) else {
            return nil
        }

        // Codex doesn't emit a stable per-message id; build one from timestamp +
        // role + 行序号 so it's deterministic for caches——同毫秒多条消息不再撞 id
        //（撞 id 曾让 SwiftUI ForEach 视图错乱 / 缓存去重误判）。
        let id = lineIndex.map { "\(tsStr)-\(roleStr)-\($0)" } ?? "\(tsStr)-\(roleStr)"
        return Message(id: id, role: role, timestamp: ts, blocks: blocks)
    }

    /// 字节级预筛：只有含 "response_item" 的行可能是消息。
    /// event_msg / token_count / function_call 等占了九成以上，解析完必被丢弃 ——
    /// 在构造 String 之前用 memmem 拦掉，省下的是整行解码（大行内嵌 base64 可达数 MB）。
    /// type 总在行首附近，扫前 256 字节即可。
    /// session_meta 也要放行：它在文件开头、带着 cwd，且不含 response_item。
    /// 只有一行，成本可忽略。
    static let messageLineFilter: (UnsafeRawBufferPointer) -> Bool = { buf in
        guard let base = buf.baseAddress else { return false }
        let n = min(buf.count, 256)
        let hitItem = "response_item".withCString { memmem(base, n, $0, 13) != nil }
        if hitItem {
            // 只放行 message 型 payload(2026-08-14 首建峰值最后一刀):parse 侧只消费
            // payload.type=="message",而 reasoning/function_call(_output) 占巨型
            // rollout 的 99% 体量(真机 720MB 文件 response_item 275MB、message 型
            // 仅 ~3MB)——在字节层挡下,不再为丢弃的行做全行 JSON 建树。
            // 匹配裸 `"type":"message"` 子串而非带 payload 前缀:真机 serde 固定
            // 字段序,但字节层不赌顺序——多放行无害(parse 层照常判定),漏放行才丢消息。
            // 顶层 type 已是 response_item,此子串只可能来自 payload.type(或极罕见的
            // 消息文本前缀,同样无害)。带空格变体一并容忍。
            let hitMsg = "\"type\":\"message\"".withCString { memmem(base, n, $0, strlen($0)) != nil }
            return hitMsg || "\"type\": \"message\"".withCString { memmem(base, n, $0, strlen($0)) != nil }
        }
        return "session_meta".withCString { memmem(base, n, $0, 12) != nil }
    }

    /// 多 agent 子会话（session_meta 带 parent_thread_id）：主会话派出的并行
    /// 子 agent 工作日志。内容 = 注入脚手架 + 从父线程继承的上下文片段，
    /// 用户视角是「同名重复会话、点开全是垃圾」——整文件跳过不入库。
    /// （compact/fork 延续没有 parent_thread_id，正常保留。）
    private struct SubagentRunSkip: Error {}

    /// 索引产物入口:≥8MB 走流式(峰值 O(窗口)),<8MB 走旧全量路径。
    static func indexRow(fileURL: URL) -> IndexRow? {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size >= ClaudeCodeLoader.streamingThresholdBytes {
            return try? streamIndexRow(fileURL: fileURL)
        }
        return (try? loadConversation(fileURL: fileURL, forIndexing: true))
            .flatMap { $0 }.map { IndexRow.from($0, fileURL: fileURL) }
    }

    /// 流式索引:行处理与 `loadConversation` 同步义务(预筛/子代理跳过/减重同款),
    /// 消息进 `StreamingIndexer` 即消费即弃。段按文件行序切(Codex rollout 追加写,
    /// 天然有序)。
    static func streamIndexRow(fileURL: URL) throws -> IndexRow? {
        var indexer = StreamingIndexer()
        var sessionId: String? = nil
        var cwd = ""
        var lineNo = 0
        var textBudget = LoaderRuntime.indexingSessionBudget
        do {
            try JSONLReader.forEachLine(fileURL: fileURL, maxLineBytes: defaultMaxLineBytes,
                                        lineFilter: messageLineFilter) { line in
                lineNo += 1
                guard !line.isEmpty, line.first == "{" else { return }
                // lean 解码:不建 NSDictionary 树(malloc 池根治,与 Claude 侧同款)
                guard let l = LeanLineParser.decodeCXLine(line) else { return }
                if l.type == "session_meta", let payload = l.payload {
                    if let parent = payload.parent_thread_id, !parent.isEmpty {
                        throw SubagentRunSkip()
                    }
                    if sessionId == nil, let s = payload.id { sessionId = s }
                    if cwd.isEmpty, let c = payload.cwd { cwd = c }
                    return
                }
                if let msg = LeanLineParser.cxMessage(from: l, lineIndex: lineNo) {
                    let capped = msg.cappedForIndexing(
                        blockCap: LoaderRuntime.indexingBlockCap, textStripped: textBudget <= 0)
                    textBudget -= capped.indexingTextCount
                    indexer.consume(capped)
                }
            }
        } catch is SubagentRunSkip {
            return nil
        }
        let p = indexer.finish()
        guard p.messageCount > 0, let startAt = p.startAt, let endAt = p.endAt else { return nil }
        let id = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
        let lite = ConversationLite(id: id, source: .codex, startAt: startAt, endAt: endAt,
                                    cwd: cwd, gitBranch: nil, title: nil,
                                    preview: p.preview, messageCount: p.messageCount,
                                    fileURL: fileURL)
        return IndexRow(lite: lite, segments: p.segments, entityText: p.entityText,
                        userText: p.userText, lastRole: p.lastMeaningfulRole,
                        milestones: p.milestones)
    }

    public static func loadConversation(fileURL: URL,
                                        maxLineBytes: Int = CodexLoader.defaultMaxLineBytes,
                                        forIndexing: Bool = false) throws -> Conversation? {
        var messages: [Message] = []
        var sessionId: String? = nil
        var cwd = ""
        var lineNo = 0
        var textBudget = LoaderRuntime.indexingSessionBudget

        do {
            try JSONLReader.forEachLine(fileURL: fileURL, maxLineBytes: maxLineBytes,
                                        lineFilter: messageLineFilter) { line in
                lineNo += 1
                guard !line.isEmpty, line.first == "{" else { return }
                // session_meta on the first line carries id/cwd.
                if sessionId == nil || cwd.isEmpty {
                    if let data = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       (obj["type"] as? String) == "session_meta",
                       let payload = obj["payload"] as? [String: Any] {
                        if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty {
                            throw SubagentRunSkip()
                        }
                        if sessionId == nil, let s = payload["id"] as? String { sessionId = s }
                        if cwd.isEmpty, let c = payload["cwd"] as? String { cwd = c }
                        return
                    }
                }
                if let msg = parseLine(line, lineIndex: lineNo) {
                    if forIndexing {
                        let capped = msg.cappedForIndexing(
                            blockCap: LoaderRuntime.indexingBlockCap, textStripped: textBudget <= 0)
                        textBudget -= capped.indexingTextCount
                        messages.append(capped)
                    } else {
                        messages.append(msg)
                    }
                }
            }
        } catch is SubagentRunSkip {
            return nil
        }

        guard !messages.isEmpty else { return nil }
        // 稳定排序：sort 键 = (timestamp, 文件行序)。Codex 同毫秒常落多条，
        // Swift sort 不稳定，纯按 timestamp 排会随机互换同刻消息的顺序。
        // messages 按行序追加，枚举下标即行序。
        messages = messages.enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)

        let id = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
        return Conversation(
            id: id,
            source: .codex,
            startAt: messages.first!.timestamp,
            endAt: messages.last!.timestamp,
            cwd: cwd,
            gitBranch: nil,
            messages: messages
        )
    }

    public static func loadAll(sessionsDir: URL = CodexLoader.defaultSessionsDir) -> [Conversation] {
        let urls = enumerateJsonl(in: sessionsDir)
        var conversations: [Conversation] = []
        for url in urls {
            if let conv = try? loadConversation(fileURL: url) {
                conversations.append(conv)
            }
        }
        conversations.sort { $0.startAt > $1.startAt }
        return conversations
    }

    /// 写入索引（增量）。同一线程的多个 rollout 文件先收敛（见 collapseThreads），
    /// 被淘汰的快照残影从索引显式清除（prune 按路径删，与「磁盘消失」共用一条路径）。
    public static func loadAll(into index: ConversationIndex,
                               sessionsDir: URL = CodexLoader.defaultSessionsDir) {
        let (kept, superseded) = collapseThreads(enumerateJsonl(in: sessionsDir))
        if !superseded.isEmpty {
            index.prune(missingPaths: superseded.map(\.path))
        }
        LoaderRuntime.indexRows(urls: kept, into: index, source: .codex, makeRow: indexRow)
    }

    /// Codex 同一线程（session_id 相同）会写多个 rollout 文件：compact/fork 时把
    /// 历史拷贝进新文件生成「中间快照」——拷贝消息的时间戳被重写（实测 86 条挤在
    /// 4 分钟），且主文件的 endAt 反而更晚（compact 后仍在续写）。用户视角就是
    /// 「同名两条、内容九成一样」。同线程只保留 mtime 最新的文件（最后被写入 =
    /// 时间线最全），其余淘汰；子 agent（parent_thread_id）在此层一并跳过
    /// （loadConversation 的兜底判定仍保留）。
    static func collapseThreads(_ urls: [URL]) -> (kept: [URL], superseded: [URL]) {
        struct Entry { let url: URL; let mtime: Double }
        var groups: [String: [Entry]] = [:]
        var kept: [URL] = []
        var dropped: [URL] = []
        for url in urls {
            guard let head = readMetaHead(url) else {
                kept.append(url)   // 首行读不出 meta：交给完整解析兜底，不在此误杀
                continue
            }
            if head.isSubagent { dropped.append(url); continue }
            let m = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
                .timeIntervalSince1970 ?? 0
            groups[head.sessionId, default: []].append(Entry(url: url, mtime: m))
        }
        for (_, entries) in groups {
            let sorted = entries.sorted { $0.mtime > $1.mtime }
            if let newest = sorted.first { kept.append(newest.url) }
            dropped.append(contentsOf: sorted.dropFirst().map(\.url))
        }
        return (kept, dropped)
    }

    /// 只读文件首行的 session_meta（毫秒级）。
    ///
    /// 归线程的键是 **forked_from_id ?? session_id**：compact fork 文件的
    /// session_id 是它自己的新 id（实测），只有 forked_from_id 指回父线程——
    /// 用 session_id 归组会让父与 fork 各自成组、收敛失效。forked_from 只指
    /// 直接父（多级 fork 罕见，一层近似；真「分叉对话」两支都有价值的场景
    /// 目前按数据事实牺牲给快照收敛，出现实例再补链根解析）。
    /// parent_thread_id 认子 agent。meta 行可能带很长的 instructions，256KB 上限；
    /// 解析不出返回 nil（调用方保守放行）。
    static func readMetaHead(_ url: URL) -> (sessionId: String, isSubagent: Bool)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty,
              let nl = chunk.firstIndex(of: 0x0A) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: chunk[..<nl]) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        let forked = (payload["forked_from_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let own = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? url.path
        let isSub = ((payload["parent_thread_id"] as? String).map { !$0.isEmpty }) ?? false
        return (forked ?? own, isSub)
    }

    public static func enumerateJsonl(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator
            where url.pathExtension == "jsonl"
            && url.lastPathComponent.hasPrefix("rollout-")
        {
            urls.append(url)
        }
        return urls
    }

    /// `~/.codex/sessions`
    public static var defaultSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }
}
