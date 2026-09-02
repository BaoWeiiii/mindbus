import Foundation
import MindBusCore

/// L2 检索结果。排序完全交给索引层（段级 BM25 双分词 RRF 融合），这里只负责渲染
/// 与过滤——渲染层一旦自己重排，实测出来的相关度收益就白丢了。
public enum MemorySearchTool {

    static let defaultLimit = 10
    static let maxLimit = 50
    /// 过滤时最多按相关度往下扫多少条命中。
    ///
    /// 过滤要逐条查元数据，全量扫一个几千条命中的查询代价太高；而过了这个深度的
    /// 命中本来也没人会看。**上限一旦真的吃掉了结果就必须在输出里说出来**——
    /// 静默截断读起来是"筛完了，一条都没有"。
    public static let scanCap = 200
    static let titleWidth = 100
    static let snippetWidth = 220

    public static let spec = MCPToolSpec(
        name: "memory_search",
        description: """
        CALL THIS FIRST whenever the user references past work — "上次/之前/我们讨论过/当时为什么" \
        or any question whose answer may live in an earlier session, in any AI tool.

        Search the user's own past AI conversations (Claude Code, Claude desktop, ChatGPT \
        desktop, browser AI platforms) by keyword. Ranked by relevance (BM25 over both a \
        character-trigram and a word tokenizer, so Chinese and English both work). Each result \
        gives the conversation_id and the message index of the strongest hit.

        Pass words that would literally appear in the conversation — this is keyword search, not \
        semantic search, so a natural-language question works badly. If there are no hits, do NOT \
        conclude the archive has nothing: call memory_browse with no arguments to get the library \
        map and drill down by facet. Once a result looks right, call memory_open on its \
        conversation_id to read the original messages.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string",
                          "description": "Keywords that would literally appear in the conversation."],
                "source": ["type": "string",
                           "description": """
                           Optional. Restrict to one tool: claudeCode, claudeAgent, codex, \
                           browser, cursor, vscodeCopilot, openclaw.
                           """],
                "project": ["type": "string",
                            "description": "Optional. Absolute project path, exactly as printed by memory_browse."],
                "since": ["type": "string",
                          "description": "Optional. YYYY-MM-DD; only conversations that ended on or after that day."],
                "limit": ["type": "integer",
                          "description": "Max results to list. Default 10, max 50."],
                "context_path": ["type": "string",
                                 "description": """
                                 Optional but recommended: your current working directory. \
                                 Conversations from the same repository get ranked higher \
                                 (soft boost — nothing is filtered out).
                                 """],
            ],
            "required": ["query"],
        ],
        run: { arguments, index in run(arguments, index) })

    private struct Filters {
        var source: ConversationSource?
        var project: String?
        var since: Date?
        var isActive: Bool { source != nil || project != nil || since != nil }

        func accepts(_ lite: ConversationLite) -> Bool {
            if let source, lite.source != source { return false }
            if let project, lite.cwd != project { return false }
            if let since, lite.endAt < since { return false }
            return true
        }
    }

    /// `raw` 来自 JSON-RPC 参数，可能是 `Int`、`Double`（JSON 数字经 `JSONSerialization`
    /// 解析后二者都可能出现），也可能干脆缺失或类型不对。
    ///
    /// 不能用 `Int(someDouble)`：JSON 数字的指数可以大到解析成 `Double.infinity`
    /// （如 `1e400`），普通但超大的有限 Double（如 `1e300`）同样装不进 `Int` 的位宽——
    /// 两种情况 `Int(Double)` 都会直接 trap，拖死整个 `mindbus-mcp` 进程。与
    /// `MemoryBrowseTool.clampLimit` 同一类问题，必须是同一个写法：`Int(exactly:)`
    /// 不满足就回落默认值，绝不 trap。
    static func clampLimit(_ raw: Any?) -> Int {
        let requested = (raw as? Int) ?? (raw as? Double).flatMap { Int(exactly: $0) } ?? defaultLimit
        return min(maxLimit, max(1, requested))
    }

    private static func run(_ arguments: [String: Any], _ index: ConversationIndex) -> MCPToolOutput {
        guard let rawQuery = arguments["query"] as? String,
              !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPToolOutput("memory_search needs a non-empty 'query' string.", isError: true)
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        var filters = Filters()
        if let raw = arguments["source"] as? String, !raw.isEmpty {
            guard let source = ConversationSource(rawValue: raw) else {
                return MCPToolOutput("""
                Unknown source "\(raw)". Valid values: \
                \(ConversationSource.allCases.map(\.rawValue).joined(separator: ", ")).
                """, isError: true)
            }
            filters.source = source
        }
        if let raw = arguments["project"] as? String, !raw.isEmpty { filters.project = raw }
        if let raw = arguments["since"] as? String, !raw.isEmpty {
            // 非法日期不能静默忽略：模型会以为自己筛过时间，实际看到的是全库
            guard let date = parseSinceDay(raw) else {
                return MCPToolOutput(#"Could not read since="\#(raw)". Use YYYY-MM-DD."#, isError: true)
            }
            filters.since = date
        }
        let limit = clampLimit(arguments["limit"])
        var contextPath: String?
        if let raw = arguments["context_path"] as? String, !raw.isEmpty { contextPath = raw }

        // .always：宿主模型自己会滤掉扩展带来的噪声，MCP 场景要的是召回——
        // 与 GUI 的 .adaptive 不同，这里不看命中量，恒做 RM3 扩展补词汇鸿沟。
        // contextPath（情境先验）：模型自己知道调用方 cwd，schema 描述引导它
        // 传；软加权，不过滤——不接的话不影响结果集合，只是同仓库的会话排不到前面。
        let allHits = index.searchWithHits(query, expansion: .always, contextPath: contextPath)
        // 保持索引给出的相关度顺序：先按名次截断，再补元数据，再过滤，绝不重排
        let scanned = filters.isActive ? Array(allHits.prefix(scanCap)) : Array(allHits.prefix(limit))
        let metadata = Dictionary(uniqueKeysWithValues:
            index.metadata(forIDs: scanned.map(\.id)).map { ($0.id, $0) })
        let kept = scanned.compactMap { hit -> (ConversationIndex.SegmentHit, ConversationLite)? in
            guard let lite = metadata[hit.id], filters.accepts(lite) else { return nil }
            return (hit, lite)
        }

        guard !kept.isEmpty else {
            return MCPToolOutput(rescue(query: query, index: index,
                                        filtered: filters.isActive, totalHits: allHits.count))
        }

        var lines: [String] = []
        let total = filters.isActive ? kept.count : allHits.count
        lines.append("QUERY \"\(query)\" — \(total) conversations matched"
                     + (kept.count < total || kept.count > limit ? " (showing \(min(kept.count, limit)))" : ""))
        if filters.isActive && allHits.count > scanCap {
            lines.append("(filters were applied to the top \(scanCap) of \(allHits.count) "
                         + "matches by relevance — deeper matches were not examined)")
        }
        lines.append("")
        for (i, pair) in kept.prefix(limit).enumerated() {
            let (hit, lite) = pair
            // %2d 够用的前提是 maxLimit ≤ 99（现为 50）——若将来上调超过两位数，
            // 第 100 行起会静默错位，需改成 renderFacet 那样按行数动态定宽。
            // browser 会话的 cwd 是空串/伪路径——空时印 (no project)，别留双空格
            let project = lite.cwd.isEmpty ? "(no project)" : lite.cwd
            lines.append("\(String(format: "%2d", i + 1)). \(MCPText.minute(lite.startAt))  "
                         + "\(lite.source.rawValue)  \(project)  "
                         + "(\(lite.messageCount) msgs, \(hit.segmentHitCount) hits)")
            // 官方标题缺失且 preview 本身也是空白（纯空格/空字符串）时，`oneLine` 会把
            // 两者都折成空字符串，印出一行看不出内容的四空格——回落占位文案
            // （与 MemoryBrowseTool L1 页同一条规则）。
            let titleLine = MCPText.oneLine(lite.title ?? lite.preview, max: titleWidth)
            lines.append("    " + (titleLine.isEmpty ? "(no title)" : titleLine))
            lines.append("    hit: " + MCPText.snippet(hit.bestSegmentText, around: query, max: snippetWidth))
            if let at = hit.bestSegmentFirstMessageIndex {
                lines.append("    memory_open(conversation_id=\"\(lite.id)\", message=\(at))")
            } else {
                lines.append("    memory_open(conversation_id=\"\(lite.id)\")")
            }
        }
        lines.append("")
        // 借宿主改写：低命中时结果照给，但附一句改写建议——机械 RM3 只能
        // 桥「在语料里共现过」的词，同义改写这种语义跨越正是宿主模型的本行。
        // 本渲染层只服务 MCP（GUI 走 ConversationStore.runSearch，不经过这里），
        // 给模型看的指令不会泄漏进 GUI。
        if kept.count <= 3 {
            lines.append("Only \(kept.count) conversation(s) matched. If none of them is what "
                         + "you are looking for, rewrite the query (synonyms / EN-CN counterpart / "
                         + "concrete tool names) and search again — keyword search only finds "
                         + "literal wording.")
            lines.append("")
        }
        lines.append("NEXT: memory_open(<handle printed above>) reads the original messages around that index.")
        return MCPToolOutput(lines.joined(separator: "\n"))
    }

    /// 空结果救援（§1「空结果不返回空」+ §3.5）。给三样能直接照抄的东西：
    /// 库存总量、高频实体（可当下一次查询词）、工具与最近月份（可当切面）。
    private static func rescue(query: String, index: ConversationIndex,
                               filtered: Bool, totalHits: Int) -> String {
        let map = index.mapOverview()
        guard map.conversationCount > 0 else {
            return """
            QUERY "\(query)" — no hits: the index holds 0 conversations.

            Open the MindBus app and let it scan your AI tools once, then retry.
            """
        }
        var lines: [String] = []
        if filtered && totalHits > 0 {
            lines.append("QUERY \"\(query)\" — \(totalHits) matches, but none passed the filters.")
            // 这条 "none passed" 本身可能是 scanCap 造成的假象：真正通过过滤的会话可能
            // 就藏在没扫到的那部分里。不说清楚就是"筛完了，一条都没有"——模型会把
            // 这个查询词判死刑，而真相是它压根没被扫到。措辞与下面"有结果"分支的同一句
            // 提示保持一致（那句在 `run(_:_:)` 里）。
            if totalHits > scanCap {
                lines.append("(filters were applied to the top \(scanCap) of \(totalHits) "
                             + "matches by relevance — deeper matches were not examined)")
            }
            lines.append("")
            lines.append("Retry without the filters, or widen them.")
        } else {
            lines.append("QUERY \"\(query)\" — no hits.")
            lines.append("")
            lines.append("Do not stop here — this is keyword search, so it matches literal text, "
                         + "not concepts.")
        }
        let span = [map.earliest, map.latest].compactMap { $0 }.map(MCPText.day)
        lines.append("The archive holds \(map.conversationCount) conversations"
                     + (span.count == 2 ? " (\(span[0]) → \(span[1]))" : "") + ".")

        func row(_ label: String, _ pairs: [(String, Int)]) {
            guard !pairs.isEmpty else { return }
            lines.append("\(label): " + pairs.map { "\($0.0) (\($0.1))" }.joined(separator: " · "))
        }
        row("Most frequent entities", map.topEntities.prefix(8).map { ($0.text, $0.conversationCount) })
        row("Tools", map.bySource.prefix(6).map { ($0.key, $0.count) })
        row("Recent months", map.byMonth.reversed().prefix(4).map { ($0.key, $0.count) })

        lines.append("")
        // 借宿主改写：零命中说明机械扩展（RM3 共现词）也没救回来——
        // 语义改写让宿主自己生成。明说「别重复原词」，共现方向已经试过了。
        if !filtered {
            lines.append("REWRITE — the mechanical expansion already tried co-occurring terms "
                         + "from this archive. You are a language model: generate 2-3 semantically "
                         + "different rewrites the user might have actually typed back then "
                         + "(synonyms, the English/Chinese counterpart, the concrete tool or "
                         + "library name instead of the generic concept), then call memory_search "
                         + "once per rewrite. Do not repeat the original wording.")
            lines.append("")
        }
        lines.append("NEXT: memory_browse() for the full map, or retry memory_search with a term "
                     + "from the entity list above.")
        return lines.joined(separator: "\n")
    }

    /// 严格 YYYY-MM-DD。`DateFormatter` 单靠 `isLenient = false` 挡不住这件事——
    /// 实测哪怕 `isLenient = false`、哪怕把 `dateFormat` 里的分隔符用单引号转成字面量
    /// （`"yyyy'-'MM'-'dd"`），`"2026/07/01"`、`"2026.07.01"`、`"2026 07 01"` 依然全部
    /// 解析成功——`isLenient` 管的是数值范围（月份 13、日期 32、2 月 30 号这类确实会被
    /// 正确拒绝），完全管不到分隔符本身，ICU 在字段之间把非字母数字字符当通配符处理。
    /// 因此必须先手工校验形状（4 数字 - 2 数字 - 2 数字，与 `MemoryBrowseTool.parseFacet`
    /// 的 "month" 分支同一手法），形状过了之后交给 `dayParser` 做真正的日期换算——
    /// 此时字符串里除了两个 "-" 不会再有别的候选分隔符，`dayParser` 的宽容不再有可乘
    /// 之机，同时借它现成的月/日范围校验，不必自己重新实现一遍闰年这类规则。
    private static func parseSinceDay(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return dayParser.date(from: raw)
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
}
