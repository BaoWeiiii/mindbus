import Foundation
import MindBusCore

/// L3 原文，按窗口给。
///
/// 为什么不给全文：本机真实语料里有超过一千条消息的会话，全量吐出会直接打爆宿主的
/// 上下文窗口——而"省 token"正是这套渐进式披露存在的理由。窗口 + 明确的翻页句柄，
/// 让模型自己决定要读多深。
public enum MemoryOpenTool {

    public static let defaultRadius = 6
    public static let maxRadius = 30
    /// 单条消息的字符上限。
    public static let perMessageCap = 2_000
    /// 整个窗口的字符上限——半径 30 × 每条 2000 仍可能上万字。
    ///
    /// 不变式：`perMessageCap` ≤ `totalCap`。`render` 里"预算首条就不够"那条分支
    /// 依赖这个关系才安全（见该函数内注释）——若未来把 `perMessageCap` 调得比 `totalCap`
    /// 还大，需要一并重新检视那条分支。
    public static let totalCap = 20_000

    /// 引用回流记账钩子（spec §7 第5步）：`loadFull` 成功读到原文后调用一次，
    /// 参数是那条会话真正的 `lite.id`。生产走默认实现——写真实
    /// `MCPRefLog.defaultLogURL`；测试替换成断言用的闭包，断言"被调/未被调"后
    /// 必须在 `addTeardownBlock` 里还原——这是进程级共享的 static var，没有
    /// 实例作用域，不还原会让后续测试带着替身闭包运行。
    internal static var refLogger: (String) -> Void = { MCPRefLog.append(conversationID: $0) }

    public static let spec = MCPToolSpec(
        name: "memory_open",
        description: """
        Read the original messages of one conversation from the user's archive. Returns a window \
        of messages, not the whole conversation — pass `message` to move the window \
        (memory_search tells you which index the strongest hit is at). Every window prints the \
        handles for the next and previous window.

        Get a conversation_id from memory_search or memory_browse first; this tool only accepts \
        ids those two produced.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "conversation_id": [
                    "type": "string",
                    "description": "Exactly as returned by memory_search or memory_browse.",
                ],
                "message": [
                    "type": "integer",
                    "description": """
                    Optional 0-based message index to centre the window on. Omit to start at the \
                    beginning. Out-of-range values are clamped, not rejected.
                    """,
                ],
                "radius": [
                    "type": "integer",
                    "description": "Optional messages to include either side of `message`. Default 6, max 30.",
                ],
            ],
            "required": ["conversation_id"],
        ],
        run: { arguments, index in run(arguments, index) })

    private static func run(_ arguments: [String: Any], _ index: ConversationIndex) -> MCPToolOutput {
        guard let id = arguments["conversation_id"] as? String, !id.isEmpty else {
            return MCPToolOutput("memory_open needs a 'conversation_id' string.", isError: true)
        }
        guard let lite = index.metadata(forID: id) else {
            return MCPToolOutput("""
            No conversation with id "\(id)" in the archive. Ids must come from memory_search or \
            memory_browse — call one of those first and copy the id verbatim.
            """, isError: true)
        }
        // 源文件还在不在，决定输出里要不要挂"从归档里救回来的"那句话。
        // 必须在 loadFull 之前问：那个函数成功之后就分不清走的是哪条腿了
        // （源文件读成功 vs. 源文件没了但 vault 里有副本，两条路径的返回值长得一样）。
        let sourceFileMissing = !FileManager.default.fileExists(atPath: lite.fileURL.path)
        // vaultRoot 用默认值（用户真实归档目录）——只有测试会显式传别的根。这里没有
        // 显式传是有意的：`run` 的签名要跟 `MCPToolSpec.run` 与其余两个工具的
        // `(arguments, index) -> MCPToolOutput` 保持同一形状，不为了给单个工具开洞
        // 而把 vaultRoot 塞进这个公共签名。测试里 `testUnreadableConversationExplainsWhy`
        // 用的源路径是 `/tmp/definitely-missing-<uuid>.jsonl`——`VaultArchive.archiveURL`
        // 按源路径的 SHA256 定位归档文件，随机 UUID 的哈希实际上不可能撞上用户真实
        // 归档里的任何一个哈希目录；即便真撞上了，`loadFull`→`withRestoredCopy` 也只是
        // 读一个文件（`FileManager.default.contents(atPath:)`），不会写、删或改动
        // `~/.mindbus` 下的任何内容，所以这条路径对真实归档只读不动，测试是安全的。
        guard let conversation = ConversationStore.loadFull(id: lite.id, fileURL: lite.fileURL,
                                                           source: lite.source) else {
            return MCPToolOutput("""
            Conversation "\(id)" is indexed but could not be read: the source file \
            \(lite.fileURL.path) is gone and there is no MindBus archive copy of it either. \
            Metadata is all that survives — the search snippet from memory_search is the most \
            you can get.
            """, isError: true)
        }
        // 真读到原文——记一笔引用（spec §7 第5步）。只在这条成功分支记：上面两个
        // guard（id 查不到 / loadFull 失败）都提前 return 了，走不到这里，天然满足
        // 「找不到 id / 读不出原文都不记」的约束，不需要额外分支判断。
        refLogger(lite.id)
        let center = parseCenter(arguments["message"])
        let radius = parseRadius(arguments["radius"])
        return render(lite: lite, conversation: conversation, sourceFileMissing: sourceFileMissing,
                      center: center, radius: radius)
    }

    /// `arguments["message"]` 经 `JSONSerialization` 解析后可能是 `Int`、`Double`，也可能缺失
    /// 或类型不对。
    ///
    /// 不能用 `Int(someDouble)`：JSON 数字的指数可以大到解析成 `Double.infinity`
    /// （如 `1e400`），普通但超大的有限 Double（如 `1e300`）同样装不进 `Int` 的位宽——
    /// 两种情况 `Int(Double)` 都会直接 trap，拖死整个 `mindbus-mcp` 进程。与
    /// `MemoryBrowseTool.clampLimit`/`MemorySearchTool.clampLimit` 同一类问题，必须是
    /// 同一个写法：`Int(exactly:)` 不满足就回落 nil，绝不 trap。
    ///
    /// 越界（负数、超出当前消息数）不在这里 clamp——那是 `render` 的职责，且它的钳制
    /// 依据是"当前消息数"，这个函数拿不到那个上下文。这里只负责"解析安全"。
    static func parseCenter(_ raw: Any?) -> Int? {
        (raw as? Int) ?? (raw as? Double).flatMap { Int(exactly: $0) }
    }

    /// 同 `parseCenter`，多一层默认值——省略时用 `defaultRadius`。上限 `maxRadius` 同样
    /// 不在这里夹：`render` 已经用 `effectiveRadius = min(maxRadius, max(0, radius))` 夹过，
    /// 这里重复夹一遍只会让两处上限需要一起改、一处漏改就不一致。
    static func parseRadius(_ raw: Any?) -> Int {
        (raw as? Int) ?? (raw as? Double).flatMap { Int(exactly: $0) } ?? defaultRadius
    }

    /// 渲染独立可测：造一份真 jsonl 才能测窗口边界的话，测试会变成 loader 的集成测试。
    public static func render(lite: ConversationLite, conversation: Conversation,
                              sourceFileMissing: Bool, center: Int?, radius: Int) -> MCPToolOutput {
        let messages = conversation.messages
        // browser 会话 cwd 为空串——空时印 (no project)，别让 header 出现 ", ,"
        let project = lite.cwd.isEmpty ? "(no project)" : lite.cwd
        var header = "CONVERSATION \(lite.id) — \(lite.source.rawValue), \(project), "
            + "\(MCPText.minute(conversation.startAt)) → \(MCPText.minute(conversation.endAt)), "
            + "\(messages.count) messages"
        if let title = lite.title ?? conversation.title {
            header += "\n" + MCPText.oneLine(title, max: 120)
        }
        if sourceFileMissing {
            // 产品承诺兑现的那一刻——不说出来，用户与模型都不知道刚才发生了什么。
            header += "\n[the tool deleted its own copy of this session — restored from your "
                + "MindBus archive]"
        }
        guard !messages.isEmpty else {
            return MCPToolOutput(header + "\n\nThis conversation has no messages.")
        }

        let last = messages.count - 1
        let effectiveRadius = min(maxRadius, max(0, radius))
        // 入库时记的下标可能大于现在的消息数（源文件被重写变短），clamp 而不是越界。
        // center 为 nil 时把 focus 设成 effectiveRadius 而不是 0：这样 start 恰好夹到 0，
        // 同时 end 仍是 2*effectiveRadius，给出一整个满宽度窗口，而不是从 0 出发只有
        // 半径宽的半个窗口。
        let focus = min(max(0, center ?? effectiveRadius), last)
        let start = max(0, focus - effectiveRadius)
        var end = min(last, focus + effectiveRadius)

        var body: [String] = []
        var budget = totalCap
        var stoppedEarly = false
        for i in start...end {
            let rendered = renderMessage(messages[i], index: i)
            // `i > start` 保证窗口里至少有一条消息：即使首条消息单独的渲染结果就已经
            // 超过整个预算（在当前 perMessageCap(2000) ≤ totalCap(20000) 的关系下这条件
            // 实际不可达——单条消息最多被 renderMessage 截到 perMessageCap 附近，永远
            // 装得进 totalCap），也先塞进去再说，下一条消息才会真正触发提前收尾。
            // 这样不会出现"预算不够、一条都不给"的空窗口。
            if budget - rendered.count < 0 && i > start {
                end = i - 1
                stoppedEarly = true
                break
            }
            budget -= rendered.count
            body.append(rendered)
        }

        var lines = [header, "Showing messages \(start)–\(end) of \(messages.count)"]
        if stoppedEarly {
            lines.append("(stopped early at the output size limit — use `message` to read on)")
        }
        lines.append("")
        lines.append(contentsOf: body)
        lines.append("")

        // 下一窗 / 上一窗的句柄只指向"紧邻着当前窗口边界的下一条/上一条消息"
        // （`end + 1` / `start - 1`），不叠加 `effectiveRadius`：句柄文本里不会带上这次
        // 用的半径，模型翻页时如果没有照抄 `radius` 参数，下一次调用会用默认半径 6。
        // 若这里把半径也算进偏移量（例如 `end + 1 + effectiveRadius`），当这次半径是
        // 用户显式放大过的（比如 30）而下一次调用没带上它时，新窗口的起点会变成
        // `end + 1 + 30 - 6 = end + 25`——中间 24 条消息被**跳过**，永远不会被看到。
        // 用相邻下标做锚点，最坏情况只是下一窗口往回多看几条已经读过的消息（重复，
        // 不丢失），比跳过安全。
        // 每个句柄都带方向标签（next/previous）：两个裸句柄并排时，较弱的宿主模型
        // 得靠比较数字大小来猜哪个是往后翻——猜错就白烧一轮。
        var next: [String] = []
        if end < last {
            next.append("memory_open(conversation_id=\"\(lite.id)\", message=\(end + 1)) for the next window")
        }
        if start > 0 {
            next.append("memory_open(conversation_id=\"\(lite.id)\", message=\(start - 1)) for the previous window")
        }
        lines.append(next.isEmpty
                     ? "NEXT: that is the whole conversation."
                     : "NEXT: " + next.joined(separator: "  |  "))
        return MCPToolOutput(lines.joined(separator: "\n"))
    }

    /// 块渲染一律走 `ContentBlock.plainText`（单一真相）：图片在那里已经变成
    /// `[image: <mediaType>]`，base64 不会漏出来——一张截图的 base64 能顶掉整个上下文窗口。
    private static func renderMessage(_ message: Message, index: Int) -> String {
        let head = "--- #\(index) \(message.role.rawValue)  \(MCPText.minute(message.timestamp))"
        var text = message.blocks.map(\.plainText).joined(separator: "\n")
        if text.isEmpty {
            // 解析出零内容块的消息：留个占位，别让"表头+空行"看起来像渲染坏了
            text = "(no content)"
        }
        if text.count > perMessageCap {
            let dropped = text.count - perMessageCap
            text = String(text.prefix(perMessageCap)) + "\n…[truncated, \(dropped) more characters]"
        }
        return head + "\n" + text + "\n"
    }
}
