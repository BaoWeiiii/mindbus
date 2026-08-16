import Foundation
import MindBusCore

/// 思脉底座 · 本产品第一个写工具：把宿主模型从对话史里读出的一条陈述记进
/// `enriched.jsonl`（design spec §3/§4）。顺序校验 spot → text → sources 存在性 →
/// 落盘，每一步失败都要把话说清——`sources` 这一步是反幻觉守卫的落地：`sources`
/// 里任何一个 conversation_id 在索引里查不到，整条陈述就不允许写入,并点名是哪个。
///
/// 只写 `enriched.jsonl` 这一个文件；`ConversationIndex` 连接照旧走
/// `SQLITE_OPEN_READONLY`（`MCPIndexAccess.opener`），这里唯一用到它的地方是
/// 只读查询 `conversationsExist(ids:)`——索引物理只读这条红线（design spec §6）
/// 在这个工具里同样成立，写入完全绕开索引连接，走独立的 append-only 文件。
public enum MindsEnrichTool {

    /// `text` 字段上限（design spec §4 / 任务简报："text（非空，≤2000 字）"）。
    static let maxTextLength = 2_000

    public static let spec = MCPToolSpec(
        name: "minds_enrich",
        description: """
        Record one statement into a WEAK SPOT of the user's Minds base — something the \
        mechanical layer cannot derive from counting alone: spot:preferences (working \
        preferences), spot:style (collaboration style), spot:goals (current goals), or \
        spot:stack (tech stack, self-reported).

        Call minds_read first to see which spots are thin or empty. Every statement must cite \
        the conversation_id(s) it was drawn from as `sources` — get them from memory_search, \
        memory_browse, or memory_digest and pass them verbatim; any id not already in the \
        archive causes the whole call to be rejected (no fabricated sources). New entries start \
        [unreviewed] — the user confirms or revokes them in the MindBus app. This tool only \
        ever appends to a separate enrichment log; it never touches the conversation archive \
        itself.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "spot": [
                    "type": "string",
                    "description": """
                    One of: spot:preferences (working preferences), spot:style (collaboration \
                    style), spot:goals (current goals), spot:stack (tech stack, self-reported).
                    """,
                ],
                "text": [
                    "type": "string",
                    "description": "The statement to record, trimmed non-empty, at most 2000 characters.",
                ],
                "sources": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": """
                    Non-empty list of conversation_id values that support this statement — \
                    exactly as returned by memory_search, memory_browse, or memory_digest. \
                    Every id must already exist in the archive or the call is rejected.
                    """,
                ],
            ],
            "required": ["spot", "text", "sources"],
        ],
        run: { arguments, index in run(arguments, index) })

    private static func run(_ arguments: [String: Any], _ index: ConversationIndex) -> MCPToolOutput {
        // 1. spot：必须是四个 rawValue 之一；非法时把全部合法值列出来。
        guard let spotRaw = arguments["spot"] as? String, let spot = MindsSpot(rawValue: spotRaw) else {
            let valid = MindsSpot.allCases.map(\.rawValue).joined(separator: ", ")
            if let raw = arguments["spot"] as? String, !raw.isEmpty {
                return MCPToolOutput(
                    "minds_enrich needs a 'spot' that is one of: \(valid). Got \"\(raw)\".",
                    isError: true)
            }
            return MCPToolOutput("minds_enrich needs a 'spot' that is one of: \(valid).", isError: true)
        }

        // 2. text：trim 后非空、≤2000 字。
        guard let rawText = arguments["text"] as? String else {
            return MCPToolOutput("minds_enrich needs a non-empty 'text' string.", isError: true)
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return MCPToolOutput("minds_enrich needs a non-empty 'text' string.", isError: true)
        }
        guard text.count <= maxTextLength else {
            return MCPToolOutput("""
            'text' is \(text.count) characters — minds_enrich accepts at most \(maxTextLength). \
            Shorten it and try again.
            """, isError: true)
        }

        // 3. sources：非空字符串数组，且每个 conversation_id 必须真实存在于索引——
        // 反幻觉守卫，缺一个就拒绝整条陈述，并点名是哪个（不是笼统地说"有问题"）。
        guard let sources = arguments["sources"] as? [String], !sources.isEmpty else {
            return MCPToolOutput("""
            minds_enrich needs a non-empty 'sources' array of conversation_id strings — every \
            statement in the Minds base must be traceable back to a real conversation.
            """, isError: true)
        }
        let existing = index.conversationsExist(ids: sources)
        // 保序去重:宿主重复给同一个 id 时不入库两遍(渲染会出现 sources: id, id)
        var seen = Set<String>()
        let dedupedSources = sources.filter { seen.insert($0).inserted }
        let missing = dedupedSources.filter { !existing.contains($0) }
        guard missing.isEmpty else {
            return MCPToolOutput("""
            These source conversation_id(s) do not exist in the archive: \
            \(missing.map { "\"\($0)\"" }.joined(separator: ", ")). Get ids from memory_search, memory_browse, or \
            memory_digest and pass them verbatim — minds_enrich refuses to record a statement \
            with a fabricated or stale source.
            """, isError: true)
        }

        // 4. 落盘：只写 enriched.jsonl；agent 取 initialize 握手时记下的宿主名
        // （`MCPRefLog.agentName`，design spec §3"模型戳"要求的最细粒度——MCP 协议
        // 本身拿不到具体模型名，宿主名是能拿到的最细粒度）。
        guard let id = MindsEnrichedLog.appendEnrich(spot: spot, text: text, sources: dedupedSources,
                                                     agent: MCPRefLog.agentName) else {
            return MCPToolOutput("""
            Could not write to the Minds enrichment log — this looks like a filesystem issue. \
            Check that ~/.mindbus is writable, then retry.
            """, isError: true)
        }

        // 5. 成功：带回新条目 id 与状态说明——这条陈述在用户确认之前不会进入
        // CLAUDE.md 注入闸门（design spec §5/§6"闸在 CLAUDE.md 出口"）。
        return MCPToolOutput("""
        Recorded as \(spot.rawValue) entry \(id), status [unreviewed]. The user will see it in \
        the MindBus app and can confirm or revoke it there.
        """)
    }
}
