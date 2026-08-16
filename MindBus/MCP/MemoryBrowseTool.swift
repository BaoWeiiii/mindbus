import Foundation
import MindBusCore

/// L0 地图与 L1 切面页。关键词检索之外的另一条路：不知道该搜什么词的时候顺着结构找。
public enum MemoryBrowseTool {

    static let maxLimit = 100
    static let defaultLimit = 20
    /// 地图上每一节列几行。列全了没意义（模型只需要够它挑一个下钻方向）。
    static let mapRowsPerSection = 10
    static let mapEntityRows = 15
    /// 单行标题/预览的长度上限。
    static let titleWidth = 100

    /// `ConversationIndex.MapOverview.byProject` 的文档写明"取前 20"——地图数据本身
    /// 已经在 Core 侧被截过一次（见该属性注释）。若这里拿到的列表长度恰好撞上这个数，
    /// 真实项目总数完全可能更多，但从这份返回值本身已经无法知道具体是多少；
    /// `renderMap` 据此把 "of M" 印成 "of 20+" 而不是断言一个可能错误的总数。
    static let projectCapInCore = 20

    /// `mapOverview().topEntities` 是同一类问题：Core 侧对 `topEntities(limit: 20)`
    /// 同样硬顶 20——命中这个数时真实实体总数可能更多，地图页据此把 "of M" 印成
    /// "of 20+" 而不是断言一个可能错误的总数。
    static let entityCapInCore = 20

    public static let spec = MCPToolSpec(
        name: "memory_browse",
        description: """
        Browse the user's conversation archive by structure instead of by keyword. With no \
        arguments it returns the library map: total conversations, time span, per-tool / \
        per-project / per-month counts, and the most frequent entities. Every line carries the \
        exact facet string to drill into. With a facet it returns that facet's conversation list.

        Call this when memory_search returned nothing, when you do not know which words to \
        search for, or when the user asks what the archive contains. Then take a facet string \
        from the output verbatim and call this tool again with it, and finally memory_open on a \
        conversation_id.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "facet": [
                    "type": "string",
                    "description": """
                    Omit for the library map. Otherwise one of: "source:<tool>" (claudeCode, \
                    claudeAgent, codex, browser, cursor, vscodeCopilot, openclaw), \
                    "project:<absolute path>", "month:YYYY-MM", "entity:<text>". Use the strings \
                    printed by this tool verbatim.
                    """,
                ],
                "limit": [
                    "type": "integer",
                    "description": "Max conversations to list on a facet page. Default 20, max 100.",
                ],
            ],
            "required": [] as [String],
        ],
        run: { arguments, index in
            let limit = clampLimit(arguments["limit"])
            guard let raw = arguments["facet"] as? String else {
                return render(facet: nil, limit: limit, index: index)
            }
            // 判空与喂给 parseFacet 的必须是同一份 trim 过的值——此前判空用 trim 过的
            // raw，喂给 parseFacet 的却是原始 raw，尾空格（如 "project:/p/one "）会被
            // parseFacet 当成一个字面上确实不存在的路径，查出 0 条，比报错更糟：
            // 该项目明明有会话，却被说成"这个切面是空的"。
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return render(facet: nil, limit: limit, index: index)
            }
            guard let facet = parseFacet(trimmed) else {
                return MCPToolOutput("""
                Unrecognised facet "\(raw)". A facet is "<kind>:<value>" — one of:
                  source:codex          (also claudeCode, claudeAgent, browser, cursor, vscodeCopilot, openclaw)
                  project:/absolute/path
                  month:2026-07         (YYYY-MM)
                  entity:SomeIdentifier

                Call memory_browse with no arguments to see the facets this archive actually has.
                """, isError: true)
            }
            return render(facet: facet, limit: limit, index: index)
        })

    /// `raw` 来自 JSON-RPC 参数，可能是 `Int`、`Double`（JSON 数字经 `JSONSerialization`
    /// 解析后二者都可能出现），也可能干脆缺失或类型不对。
    ///
    /// 不能用 `Int(someDouble)`：JSON 数字的指数可以大到解析成 `Double.infinity`
    /// （如 `1e400`），普通但超大的有限 Double（如 `1e300`）同样装不进 `Int` 的位宽——
    /// 两种情况 `Int(Double)` 都会直接 trap，拖死整个 `mindbus-mcp` 进程。
    /// `JSONRPC.RequestID.from` 已经因同一类问题改用 `Int(exactly:)`（不满足就返回 nil，
    /// 绝不 trap），这里必须是同一个写法，不能重蹈覆辙。
    static func clampLimit(_ raw: Any?) -> Int {
        let requested = (raw as? Int) ?? (raw as? Double).flatMap { Int(exactly: $0) } ?? defaultLimit
        return min(maxLimit, max(1, requested))
    }

    /// `"<kind>:<value>"`，只切**第一个**冒号——项目路径与 URL 实体本身含冒号。
    public static func parseFacet(_ raw: String) -> ConversationIndex.Facet? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let kind = String(raw[raw.startIndex..<colon])
        let value = String(raw[raw.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch kind {
        case "source":  return ConversationSource(rawValue: value).map { .source($0) }
        case "project": return .project(value)
        case "entity":  return .entity(value)
        case "month":
            // 严格 YYYY-MM：放过 "2026-7" 会静默返回 0 条，模型会当成"这个月没有对话"
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
                  parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  let month = Int(parts[1]), (1...12).contains(month) else { return nil }
            return .month(value)
        default: return nil
        }
    }

    /// 切面的规范写法——印出去的句柄由它生成，保证印出来的一定解析得回来。
    /// `renderMap`/`renderFacet` 里凡是要印 `facet="…"`，一律经过这个函数，不手写字符串
    /// 拼接：拼接出来的文本今天恰好和这里一致，但那是巧合，不是保证——一旦这里的格式
    /// 改了（比如未来要转义某个字符），手写的那份不会跟着变，round-trip 就悄悄碎了。
    static func handle(_ facet: ConversationIndex.Facet) -> String {
        switch facet {
        case .source(let s):   return "source:\(s.rawValue)"
        case .project(let p):  return "project:\(p)"
        case .month(let m):    return "month:\(m)"
        case .entity(let e):   return "entity:\(e)"
        }
    }

    /// 印之前的往返校验：任何要印成 `facet="…"` 的字符串必须①能被 `parseFacet` 解析
    /// 回同一个切面（挡住未知 source、空/畸形月份桶这类"语法上过得去但值本身是脏
    /// 数据"的情况）；②不含双引号或换行（挡住 cwd 里偶尔出现的这两种字符——即使
    /// `parseFacet` 认得这个值，印成 `facet="project:/p/one"junk"` 也会让引号配对从
    /// 中间断掉，真换行更是直接把一行拆成两行）。两条有一条不过就返回 nil，调用方
    /// 据此不给这一行印句柄（展示文本仍然照印，只是不给 `facet="…"` 这个可执行句柄——
    /// 给一个看着对、喂回去却报错或对不上的句柄，比不给更糟）。`renderMap`/
    /// `renderFacet` 里凡是要印 `facet="…"`，一律经这里，不直接调用 `handle(_:)`
    /// 手写拼接。
    static func safeHandle(_ facet: ConversationIndex.Facet) -> String? {
        let h = handle(facet)
        guard parseFacet(h) == facet, !h.contains(where: { $0 == "\"" || $0.isNewline }) else {
            return nil
        }
        return h
    }

    /// `"(top N of M)"` / `"(top N of M+)"` 表头算法。`section`（BY TOOL/PROJECT/MONTH）
    /// 与手写的 TOP ENTITIES 共用同一份实现，不各写一遍——"Core 侧的截断值被当成真
    /// 总数印出去"这类问题只要在一处改对，就不会有调用点漏改。
    static func sectionHeader(_ title: String, shownCount: Int, totalCount: Int,
                              coreCapAt: Int? = nil) -> String {
        if shownCount == totalCount {
            return title
        } else if let coreCap = coreCapAt, totalCount == coreCap {
            return "\(title) (top \(shownCount) of \(coreCap)+)"
        } else {
            return "\(title) (top \(shownCount) of \(totalCount))"
        }
    }

    /// 按 Swift 的 Character 计数对齐补空格，不用 `String.padding(toLength:)`——那是
    /// Foundation 桥接到 NSString 的方法，按 **UTF-16 code unit** 计长度，不是 Character
    /// 计数。代理对字符（emoji 等）在 Swift 里是 1 个 Character 但占 2 个 UTF-16 单元，
    /// 若拿 Character 计数算出的宽度去调用按 UTF-16 计长度的 `padding`，会把这个宽度
    /// 当成"不够 2 个单元"而截断，切出一个悬空代理项（实测转回 String 后变成 U+FFFD
    /// 替换字符）。这里全程只用 Character 计数，两头口径一致，不存在这个缺口。
    static func padded(_ s: String, to width: Int) -> String {
        let deficit = width - s.count
        return deficit > 0 ? s + String(repeating: " ", count: deficit) : s
    }

    public static func render(facet: ConversationIndex.Facet?, limit: Int,
                              index: ConversationIndex) -> MCPToolOutput {
        // 钳制挪到这里而不是只活在 spec.run 里——`render` 本身是 public API，任何绕过
        // spec.run 直接调用它的调用方（未来复用这份渲染逻辑的其他工具）都不该有机会
        // 把一个没夹过的 limit 直接送进 SQL LIMIT。spec.run 里那次因此变成幂等的重复
        // 钳制，留着无害。
        let limit = clampLimit(limit)
        guard let facet else { return MCPToolOutput(renderMap(index: index)) }
        return MCPToolOutput(renderFacet(facet, limit: limit, index: index))
    }

    // MARK: L0

    private static func renderMap(index: ConversationIndex) -> String {
        let map = index.mapOverview()
        guard map.conversationCount > 0 else {
            return """
            MindBus library — 0 conversations.

            The index is empty. Open the MindBus app and let it scan your AI tools once; it will \
            pick up Claude Code, Claude desktop and ChatGPT desktop sessions automatically.
            """
        }
        var lines: [String] = []
        // `day()` 对越界日期（strftime/Calendar 算不出年份的脏时间戳）返回空串而不是
        // nil 或崩溃——只判断"两个 Date 都非 nil"就直接拼 "→"，越界的一侧会拼出空
        // 字符串，首行变成 "— 1 conversations,  → 2026-07-15" 这种一眼假的输出。这里
        // 改判"两个都格式化得出非空串"，任一侧空了就整体不印时间跨度——宁可少一行
        // 信息，也不给一个自相矛盾的空洞。
        let spanDates = [map.earliest, map.latest].compactMap { $0 }.map(MCPText.day)
        let span = spanDates.allSatisfy { !$0.isEmpty } ? spanDates : []
        lines.append("MindBus library — \(map.conversationCount) conversations"
                     + (span.count == 2 ? ", \(span[0]) → \(span[1])" : ""))

        // `facetFor` 把这一行的原始 key 映射成候选切面；返回 nil（BY TOOL 遇到当前
        // 二进制不认识的 source 时）表示这一行没有安全句柄。候选切面还要再过
        // `safeHandle(_:)` 一次往返校验（该函数注释）——`facetFor` 负责"这个 key 能不能
        // 构造出一个切面"，`safeHandle` 负责"构造出来的这个切面印出来是否可信"，两层
        // 检查合起来才是完整的守卫，任何一层单独存在都会漏掉一类脏数据。
        // `coreCapAt`：这一路的 `rows` 是否可能已经被 Core 侧截断过——非 nil 且
        // `rows.count` 恰好等于它时，说明真总数未知，"of M" 要老实印成 "M+"（目前
        // BY PROJECT / TOP ENTITIES 两路命中：`bySource`/`byMonth` 在 Core 里都不带
        // LIMIT，`rows.count` 本身就是准确总数，不需要这个参数）。
        func section(_ title: String, _ rows: [ConversationIndex.FacetCount],
                     _ facetFor: (String) -> ConversationIndex.Facet?, cap: Int, coreCapAt: Int? = nil) {
            guard !rows.isEmpty else { return }
            let shown = Array(rows.prefix(cap))
            lines.append("")
            lines.append(sectionHeader(title, shownCount: shown.count, totalCount: rows.count,
                                       coreCapAt: coreCapAt))
            let width = shown.map(\.key.count).max() ?? 0
            for row in shown {
                let suffix = facetFor(row.key).flatMap(safeHandle).map { "  facet=\"\($0)\"" } ?? ""
                lines.append("  \(padded(row.key, to: width))  \(row.count)\(suffix)")
            }
        }

        // BY TOOL 的取值来自 DB 原始列，不保证是当前二进制认识的 source（新 App 写入
        // 新枚举值、宿主还在跑旧 mindbus-mcp 二进制）——先过 `ConversationSource
        // (rawValue:)`，与 `parseFacet` 的 "source" 分支同一条逻辑；解析不出就交给
        // `facetFor` 返回 nil，行照印、句柄由 safeHandle 挡掉。
        section("BY TOOL", map.bySource, { ConversationSource(rawValue: $0).map { .source($0) } },
                cap: mapRowsPerSection)
        section("BY PROJECT", map.byProject, { .project($0) }, cap: mapRowsPerSection,
                coreCapAt: projectCapInCore)
        // 月份倒序印：最近的月份对"上次是怎么弄的"这类问题最有用
        section("BY MONTH", map.byMonth.reversed(), { .month($0) }, cap: mapRowsPerSection)

        let entities = Array(map.topEntities.prefix(mapEntityRows))
        if !entities.isEmpty {
            lines.append("")
            lines.append(sectionHeader("TOP ENTITIES", shownCount: entities.count,
                                       totalCount: map.topEntities.count, coreCapAt: entityCapInCore))
            let width = entities.map(\.text.count).max() ?? 0
            for e in entities {
                let suffix = safeHandle(.entity(e.text)).map { "  facet=\"\($0)\"" } ?? ""
                lines.append("  \(padded(e.text, to: width))  \(e.conversationCount)\(suffix)")
            }
        }

        lines.append("")
        // 故意不写成 `facet="…"` / `query="…"`：那和上面每一行真实句柄的形状
        // （`facet="value"`）完全一样，模型很容易把这个占位符本身当成一个可以照抄的
        // 句柄去调用——`<value from above>` / `<your keywords>` 这种写法在语法上就和
        // 真句柄区分得开。
        lines.append("NEXT: memory_browse(facet=<value from above>) lists that facet's "
                     + "conversations; memory_search(query=<your keywords>) searches the text.")
        return lines.joined(separator: "\n")
    }

    // MARK: L1

    private static func renderFacet(_ facet: ConversationIndex.Facet, limit: Int,
                                    index: ConversationIndex) -> String {
        let key = handle(facet)
        let total = index.conversationCount(for: facet)
        guard total > 0 else {
            return """
            FACET \(key) — 0 conversations.

            This facet is empty. Call memory_browse with no arguments to see which facets do \
            have content.
            """
        }
        let ids = index.conversationIDs(for: facet, limit: limit)
        let rows = index.metadata(forIDs: ids)
        var lines = ["FACET \(key) — \(total) conversations"
                     + (rows.count < total ? " (showing \(rows.count))" : ""), ""]
        // 行号宽度按本页实际展示的行数动态定，不能写死 2 位——limit 上限是 100，
        // 恰好铺满 100 行时第 100 行需要 3 位数字，固定 2 位不会截断（"%2d" 是最小
        // 宽度不是最大宽度），但会让这一行单独多出一位、把整列对齐撑歪。
        let indexWidth = String(min(limit, rows.count)).count
        for (i, lite) in rows.enumerated() {
            let label = String(format: "%\(indexWidth)d", i + 1)
            // browser 等来源没有真实 cwd，落库时是空串；印成四个连续空格看不出是
            // "没有项目" 还是排版事故，回落成明确的占位文案。
            let cwdDisplay = lite.cwd.isEmpty ? "(no project)" : lite.cwd
            // 分桶轴与行内展示必须同一根时间轴：月份切面按 startAt 分桶（见
            // ConversationIndex.monthBucketSQL 注释），这里也用 startAt——用 endAt 的话
            // 跨月会话（7-31 深夜开始、8-1 凌晨结束）在 `month:2026-07` 页面里会印出
            // 8 月的日期，模型问 7 月却看到 8 月。列表页语义本就是"这场对话是什么时候
            // 的"，与"我几月在忙这个"的直觉一致的也是开始时间，不只是为了跟分桶对齐。
            lines.append("\(label). \(MCPText.minute(lite.startAt))  \(lite.source.rawValue)  "
                         + "\(cwdDisplay)  (\(lite.messageCount) msgs)")
            // 官方标题缺失且 preview 本身也是空白（纯空格/空字符串）时，`oneLine` 会把
            // 两者都折成空字符串，印出一行看不出内容的四空格——同理回落占位文案。
            let titleLine = MCPText.oneLine(lite.title ?? lite.preview, max: titleWidth)
            lines.append("    " + (titleLine.isEmpty ? "(no title)" : titleLine))
            lines.append("    conversation_id=\"\(lite.id)\"")
        }
        if case .entity(let text) = facet {
            let neighbours = index.coOccurring(with: text, limit: 10)
            if !neighbours.isEmpty {
                lines.append("")
                lines.append("CO-OCCURRING ENTITIES")
                let width = neighbours.map(\.text.count).max() ?? 0
                for n in neighbours {
                    let suffix = safeHandle(.entity(n.text)).map { "  facet=\"\($0)\"" } ?? ""
                    lines.append("  \(padded(n.text, to: width))  \(n.conversationCount)\(suffix)")
                }
            }
        }
        lines.append("")
        // 故意不写成 `conversation_id="…"`：与上面 L1 每一行的真句柄
        // （`conversation_id="conv-1"`）完全同形、同页、只隔几行，模型很容易照抄引号
        // 里的省略号本身。`<value from above>` 在语法上就和真句柄区分得开。
        lines.append("NEXT: memory_open(conversation_id=<value from above>) reads the original messages.")
        return lines.joined(separator: "\n")
    }
}
