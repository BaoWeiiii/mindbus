import Foundation

public enum ClaudeCodeLoader {

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

    /// 非用户对话、应从扫描中排除的目录标记。
    /// claude-mem 的观察者 agent 把日志写进
    /// `~/.claude/projects/...--claude-mem-observer-sessions/`，那不是用户对话，
    /// 是观察 bot 的内部元日志（系统提示 + `<observed_from_primary_session>` 包装），整目录排除。
    static let excludedPathMarkers = ["claude-mem-observer-sessions"]

    static func isExcludedPath(_ path: String) -> Bool {
        if excludedPathMarkers.contains(where: { path.contains($0) }) { return true }
        // 用户级排除（~/.mindbus/ignore）：定时任务/无头自动化目录的会话不进库
        return IgnoreRules.matches(path: path)
    }

    public static func parseLine(_ line: String) -> Message? {
        guard !line.isEmpty, line.first == "{" else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseObject(obj)
    }

    /// 已解析 JSON 对象 → Message。loadConversation 每行只做一次 JSONSerialization，
    /// 元数据 / sidechain / 消息三处复用同一 obj（此前元数据扫描与 parseLine 重复解析）。
    /// 时间戳解析口径(全量 parseObject 与 lean 流式解码共用)。
    static func parseTimestamp(_ tsStr: String) -> Date? {
        iso8601.date(from: tsStr) ?? iso8601NoFraction.date(from: tsStr)
    }

    static func parseObject(_ obj: [String: Any]) -> Message? {
        guard let typeStr = obj["type"] as? String,
              let role: MessageRole = {
                  switch typeStr {
                  case "user": return .user
                  case "assistant": return .assistant
                  default:
                      // 白名单外的新类型会被遥测汇总上报——上游出新格式时显式可见
                      FormatTelemetry.shared.note(source: "claudeCode", type: typeStr)
                      return nil
                  }
              }() else {
            return nil
        }

        guard let uuid = obj["uuid"] as? String,
              let tsStr = obj["timestamp"] as? String,
              let ts = iso8601.date(from: tsStr) ?? iso8601NoFraction.date(from: tsStr) else {
            return nil
        }

        guard let message = obj["message"] as? [String: Any] else { return nil }

        var blocks = ContentBlockParser.parse(message["content"])

        // 用户消息：滤掉工具输出与注入脚手架，只留有价值的对话内容。
        if role == .user {
            blocks = blocks.compactMap { block -> ContentBlock? in
                switch block {
                case .toolResult:
                    return nil   // 工具输出（command/文件/搜索结果），非用户对话
                case .text(let t):
                    if isInjectedUserText(t) { return nil }   // task-notification / 技能脚手架 / slash 命令 / caveat / 中断
                    let s = stripSystemReminders(t)           // 剥离附加的 <system-reminder> 注入
                    return s.isEmpty ? nil : .text(s)
                default:
                    return block   // 保留 image（用户贴图）等
                }
            }
            guard !blocks.isEmpty else { return nil }
        }

        return Message(id: uuid, role: role, timestamp: ts, blocks: blocks)
    }

    /// 整块注入脚手架（非用户真实输入）：后台任务通知 / 技能脚手架 / slash 命令 / caveat / 中断标记。
    static func isInjectedUserText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let prefixes = [
            "<task-notification>",
            "Base directory for this skill:",
            "<command-name>",
            "<command-message>",
            "<local-command-stdout>",
            "<local-command-caveat>",
            "Caveat: The messages below were generated",
            "[Request interrupted by user]",
        ]
        return prefixes.contains { t.hasPrefix($0) }
    }

    /// 剥离附加在真实消息上的 `<system-reminder>…</system-reminder>` 注入块（CLAUDE.md/技能列表/上下文等）。
    static func stripSystemReminders(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<system-reminder>[\s\S]*?</system-reminder>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 增量解析：只读 `fromOffset` 之后的内容，把新消息接到 `baseMessages` 后面。
    ///
    /// 用于正在被 AI 工具追加写的活跃会话 —— 全量重解析的成本随对话长度线性上升
    /// （本机实测 14.3 MB / 1128 条 → 404 ms），而每次真正新增的往往只有几 KB。
    ///
    /// 元数据（cwd / sessionId / gitBranch）取自 `base`：它们只出现在文件头几行，
    /// 增量段里读不到。sidechain 也无需重判 —— 首次全量若判定为 sidechain 就压根
    /// 不会进缓存，能走到这里的都是正常会话。
    static func loadConversationIncremental(fileURL: URL,
                                            base: Conversation,
                                            baseMessages: [Message],
                                            fromOffset: UInt64) throws -> Conversation? {
        var fresh: [Message] = []
        var title = base.title
        // 增量只走索引路径(详情永远全量 parse),fresh 段与全量路径同口径减重。
        // 预算按 base 已占额扣减:超预算续写的尾部与全量路径同样只留结构。
        var textBudget = LoaderRuntime.indexingSessionBudget
            - baseMessages.reduce(0) { $0 + $1.indexingTextCount }
        try JSONLReader.forEachLine(fileURL: fileURL, fromOffset: fromOffset) { line in
            guard !line.isEmpty, line.first == "{" else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // ai-title 可能出现在增量段（标题在会话进行中生成/更新），与全量路径同步
            if (obj["type"] as? String) == "ai-title",
               let t = obj["aiTitle"] as? String, !t.isEmpty {
                title = t
                return
            }
            if let msg = parseObject(obj) {
                let capped = msg.cappedForIndexing(
                    blockCap: LoaderRuntime.indexingBlockCap, textStripped: textBudget <= 0)
                textBudget -= capped.indexingTextCount
                fresh.append(capped)
            }
        }
        guard !fresh.isEmpty || title != base.title else { return base }   // 无新内容，原样返回

        // 稳定排序（与全量路径同款）：base 已按 (ts, 行序) 有序，fresh 接在其后，
        // 枚举下标即全局行序——同 timestamp 消息合并后仍保持文件顺序。
        let merged = (baseMessages + fresh).enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)
        return Conversation(
            id: base.id, source: base.source,
            startAt: merged.first!.timestamp, endAt: merged.last!.timestamp,
            cwd: base.cwd, gitBranch: base.gitBranch, title: title, messages: merged
        )
    }

    /// 早退哨兵:结论已定(sidechain / 非会话文件),余下内容不必读。
    /// 真机现场:claude-mem observer 轨迹 6768 个 26GB,全量读完才判 barren,
    /// 删库首建峰值 1.8GB、耗时以十分钟计——判定信号其实都在前几行。
    private struct EarlyExit: Error {}

    /// 大文件流式分流阈值:≥8MB 走 streamIndexRow(消息级消费,峰值 O(窗口));
    /// <8MB 走旧全量路径(保增量 cache、全局排序、跳转下标语义)。
    /// 8MB 以下的对象树瞬时无害,以上才是峰值来源(真机 engine 目录 38MB 级一批)。
    public static let streamingThresholdBytes = 8 * 1024 * 1024

    /// 索引产物入口:按文件大小分流。LoaderRuntime.indexRows 的 makeRow。
    static func indexRow(fileURL: URL) -> IndexRow? {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size >= streamingThresholdBytes {
            return try? streamIndexRow(fileURL: fileURL)
        }
        return LoaderRuntime.parseWithIncrementalCache(url: fileURL) { base, baseMessages, offset in
            try? loadConversationIncremental(fileURL: fileURL, base: base,
                                             baseMessages: baseMessages, fromOffset: offset)
        } fullParse: {
            try? loadConversation(fileURL: fileURL, forIndexing: true)
        }.map { IndexRow.from($0, fileURL: fileURL) }
    }

    /// 流式索引:行处理逻辑与 `loadConversation` 同步义务(早退/元数据/减重/判定
    /// 全部同款),差别只在消息去向——不进数组,进 `StreamingIndexer` 即消费即弃。
    /// 已知口径差:段按文件行序切(全量版先全局排序再切)。jsonl 追加写基本有序,
    /// 乱序仅同毫秒级,对检索质量无感;跳转下标在乱序文件可能偏移(小文件不受影响)。
    static func streamIndexRow(fileURL: URL) throws -> IndexRow? {
        var indexer = StreamingIndexer()
        var cwd: String = ""
        var gitBranch: String? = nil
        var sessionId: String? = nil
        var title: String? = nil
        var isSidechain = false
        var lineCount = 0
        var textBudget = LoaderRuntime.indexingSessionBudget

        do {
            try JSONLReader.forEachLine(fileURL: fileURL) { line in
                lineCount += 1
                guard !line.isEmpty, line.first == "{" else { return }
                // lean 解码(Codable 值类型):不为行建 NSDictionary 树——大文件行级
                // 建树的 malloc 池水位是首建峰值根因,这里是它的手术台。
                guard let l = LeanLineParser.decodeCCLine(line) else { return }
                if !isSidechain, l.isSidechain == true {
                    isSidechain = true
                    throw EarlyExit()
                }
                if l.type == "ai-title", let t = l.aiTitle, !t.isEmpty {
                    title = t
                    return
                }
                if cwd.isEmpty || sessionId == nil {
                    if cwd.isEmpty, let c = l.cwd { cwd = c }
                    if gitBranch == nil, let g = l.gitBranch { gitBranch = g }
                    if sessionId == nil, let sid = l.sessionId { sessionId = sid }
                }
                if let msg = LeanLineParser.ccMessage(from: l) {
                    let capped = msg.cappedForIndexing(
                        blockCap: LoaderRuntime.indexingBlockCap, textStripped: textBudget <= 0)
                    textBudget -= capped.indexingTextCount
                    indexer.consume(capped)
                }
                if lineCount >= 64, indexer.isEmpty, title == nil { throw EarlyExit() }
            }
        } catch is EarlyExit {
            return nil
        }

        guard !isSidechain else { return nil }
        let p = indexer.finish()
        guard p.messageCount > 0, let startAt = p.startAt, let endAt = p.endAt else { return nil }

        // 残骸/壳会话判定与全量路径同款
        if p.messageCount <= 2, p.assistantCount > 0, p.allAssistantsAPIError { return nil }
        if p.assistantCount == 0, p.messageCount <= 1 {
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date)
                ?? .distantPast
            if Date().timeIntervalSince(mtime) > 600 { return nil }
        }

        let id = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
        let lite = ConversationLite(id: id, source: .claudeCode, startAt: startAt, endAt: endAt,
                                    cwd: cwd, gitBranch: gitBranch, title: title,
                                    preview: p.preview, messageCount: p.messageCount,
                                    fileURL: fileURL)
        return IndexRow(lite: lite, segments: p.segments, entityText: p.entityText,
                        userText: p.userText, lastRole: p.lastMeaningfulRole,
                        harvest: p.harvest)
    }

    public static func loadConversation(fileURL: URL,
                                        forIndexing: Bool = false) throws -> Conversation? {
        var messages: [Message] = []
        var cwd: String = ""
        var gitBranch: String? = nil
        var sessionId: String? = nil
        var title: String? = nil
        var isSidechain = false
        var lineCount = 0
        var textBudget = LoaderRuntime.indexingSessionBudget

        do {
        try JSONLReader.forEachLine(fileURL: fileURL) { line in
            lineCount += 1
            guard !line.isEmpty, line.first == "{" else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            // 子 agent（Task）会话标记。它们与父会话共享同一 sessionId——若入库会撞
            // conversations.id 唯一约束、连累整批 upsert 回滚，且本身是子任务噪音、非用户对话。
            // 判解析后的顶层字段，而非裸子串匹配——裸匹配会误杀「讨论 JSONL 格式本身」的
            // 正常对话（消息文本里出现 "isSidechain":true 字样即整个会话被丢，本项目自己的开发会话就中招）。
            // 标记在文件前几行,一见即停:sidechain 文件的余下全文不必解析。
            if !isSidechain, (obj["isSidechain"] as? Bool) == true {
                isSidechain = true
                throw EarlyExit()
            }

            // 官方会话标题行：{"type":"ai-title","aiTitle":"…"}。改标题会追加新行，
            // 取最后一条为准；该行不是消息，取完即返回。
            if (obj["type"] as? String) == "ai-title",
               let t = obj["aiTitle"] as? String, !t.isEmpty {
                title = t
                return
            }

            // 先扫元数据（只认第一行含字段的）
            if cwd.isEmpty || sessionId == nil {
                if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
                if gitBranch == nil, let g = obj["gitBranch"] as? String { gitBranch = g }
                if sessionId == nil, let s = obj["sessionId"] as? String { sessionId = s }
            }

            if let msg = parseObject(obj) {
                if forIndexing {
                    let capped = msg.cappedForIndexing(
                        blockCap: LoaderRuntime.indexingBlockCap, textStripped: textBudget <= 0)
                    textBudget -= capped.indexingTextCount
                    messages.append(capped)
                } else {
                    messages.append(msg)
                }
            }

            // 非会话文件早退:64 行内无一条消息、无标题=队列/观察者日志这类
            // 非对话产物(observer 文件前排全是 queue-operation/attachment 行),
            // 不必读完几 MB 才得出空结论。真会话的首条消息在最前几行;
            // 「壳会话」(单条 user)第 1 行就有消息,不受此判定影响。
            if lineCount >= 64, messages.isEmpty, title == nil { throw EarlyExit() }
        }
        } catch is EarlyExit {
            return nil
        }

        guard !isSidechain else { return nil }   // 跳过 sidechain 文件
        guard !messages.isEmpty else { return nil }

        // 连接失败残骸：≤2 条且 assistant 全部是「API Error:」开头的失败占位——
        // 用户一句、报错一条、会话夭折（真实库单个项目就攒了 7 条这种碎片）。
        // 判据收紧不误杀：多轮真会话（如 48 条、中途 Connection closed 的）不受影响。
        let assistants = messages.filter { $0.role == .assistant }
        if messages.count <= 2, !assistants.isEmpty,
           assistants.allSatisfy({ ($0.blocks.compactMap(\.plainText).first ?? "").hasPrefix("API Error:") }) {
            return nil
        }

        // 壳会话：单条 user、AI 从未回复（skill 跑批 / headless 调用起了会话、发了指令、
        // assistant 从未落盘——真实库 467 条里攒了 318 条这种壳，纯噪音）。
        // 源文件 mtime 距今 ≤10 分钟的放行：那可能是「刚发第一句、AI 还没答完」的
        // 活跃会话，该出现在列表里；AI 落盘后文件 mtime 变化，FSEvents 触发重扫自然转正。
        if assistants.isEmpty, messages.count <= 1 {
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date)
                ?? .distantPast   // 读不到属性按旧文件处理（文件刚被成功读过，stat 失败几乎不发生）
            if Date().timeIntervalSince(mtime) > 600 { return nil }
        }

        // 稳定排序：sort 键 = (timestamp, 文件行序)。Swift sort 不保证稳定，
        // 同一时间戳的多条消息（毫秒同刻落盘）纯按 timestamp 排会随机互换顺序。
        messages = messages.enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)

        let id = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
        return Conversation(
            id: id,
            source: .claudeCode,
            startAt: messages.first!.timestamp,
            endAt: messages.last!.timestamp,
            cwd: cwd,
            gitBranch: gitBranch,
            title: title,
            messages: messages
        )
    }

    public static func loadAll(projectsDir: URL) -> [Conversation] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDir.path) else { return [] }

        var conversations: [Conversation] = []
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl", !isExcludedPath(fileURL.path) else { continue }
            do {
                if let conv = try loadConversation(fileURL: fileURL) {
                    conversations.append(conv)
                }
            } catch {
                // 静默跳过读取失败的文件；V0 不做 error surfacing
                continue
            }
        }

        conversations.sort { $0.startAt > $1.startAt }
        return conversations
    }

    /// 写入索引（增量）。
    public static func loadAll(into index: ConversationIndex,
                               projectsDir: URL = ClaudeCodeLoader.defaultProjectsDir) {
        LoaderRuntime.indexRows(urls: enumerateJsonl(in: projectsDir), into: index,
                                source: .claudeCode, makeRow: indexRow)
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
            where url.pathExtension == "jsonl" && !isExcludedPath(url.path) {
            urls.append(url)
        }
        return urls
    }

    /// 默认的 Claude Code projects 目录：~/.claude/projects
    public static var defaultProjectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }
}
