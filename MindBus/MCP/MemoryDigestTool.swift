import Foundation
import MindBusCore

/// 一场旧对话的精华包："答案贬值、语境增值"的落地（LLM 增值层）。
///
/// 与 `memory_open` 的窗口分页不同，这里不是给更多原文，而是给**更少但更挑过**的原文
/// 碎片——机械抽出任务、辨识度实体、收尾结论、同项目相邻会话，让宿主模型用今天的知识
/// 重新判断，而不是把当年的结论原样当答案抄。MindBus 自己一行 LLM 不调、一次网络不发：
/// 纯文本渲染 + 只读查询，"重新解释"这件事完全留给读输出的那个模型。
public enum MemoryDigestTool {

    /// DISTINCTIVE ENTITIES 最多列几个。
    static let entityLimit = 8
    /// TASK 段的字符上限。
    static let taskCap = 300
    /// CLOSING 每条消息的字符上限。
    static let closingCap = 400
    /// CLOSING 里最多带几条尾部 assistant 消息（跟在最后一条 user 后面）。
    static let maxClosingAssistants = 2
    /// 找同项目相邻会话时的候选池大小——同 `MemoryBrowseTool` 系的量级，不追求"全项目
    /// 精确排序"，只要候选池够大、几乎不可能漏掉紧邻的那一条即可。
    static let neighbourScanLimit = 200
    /// NEIGHBOURS 里标题/预览的单行宽度，与 `MemoryBrowseTool.titleWidth`/
    /// `MemorySearchTool.titleWidth` 同一量级（各工具独立定义，不共享常量——同
    /// 该文件其余工具的既有做法）。
    static let titleWidth = 100

    /// 引用回流记账钩子，与 `MemoryOpenTool.refLogger` 同款：`loadFull` 成功读到原文后
    /// 调用一次。生产走默认实现——写真实 `MCPRefLog.defaultLogURL`；测试替换成断言用的
    /// 闭包，断言"被调/未被调"后必须在 `addTeardownBlock` 里还原——这是进程级共享的
    /// static var，没有实例作用域，不还原会让后续测试带着替身闭包运行。
    internal static var refLogger: (String) -> Void = { MCPRefLog.append(conversationID: $0) }

    public static let spec = MCPToolSpec(
        name: "memory_digest",
        description: """
        Extract the mechanically-derived essence of one past conversation in the archive: its \
        opening task, the entities that make it identifiable, its closing exchange, and its \
        neighbouring conversations in the same project. Nothing here is generated — every line is \
        copied or counted from the original.

        Call this instead of memory_open when an old conversation's conclusion matters to the \
        current task and you want to re-evaluate it with what you know today, rather than re-read \
        hundreds of turns. Call memory_open afterwards if you still need the full original text.

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
            ],
            "required": ["conversation_id"],
        ],
        run: { arguments, index in run(arguments, index) })

    private static func run(_ arguments: [String: Any], _ index: ConversationIndex) -> MCPToolOutput {
        guard let id = arguments["conversation_id"] as? String, !id.isEmpty else {
            return MCPToolOutput("memory_digest needs a 'conversation_id' string.", isError: true)
        }
        guard let lite = index.metadata(forID: id) else {
            return MCPToolOutput("""
            No conversation with id "\(id)" in the archive. Ids must come from memory_search or \
            memory_browse — call one of those first and copy the id verbatim.
            """, isError: true)
        }
        // 源文件还在不在，决定输出里要不要挂"从归档里救回来的"那句话——必须在 loadFull
        // 之前问，同 `MemoryOpenTool` 的理由：那个函数成功之后就分不清走的是哪条腿了。
        let sourceFileMissing = !FileManager.default.fileExists(atPath: lite.fileURL.path)
        guard let conversation = ConversationStore.loadFull(id: lite.id, fileURL: lite.fileURL,
                                                           source: lite.source) else {
            return MCPToolOutput("""
            Conversation "\(id)" is indexed but could not be read: the source file \
            \(lite.fileURL.path) is gone and there is no MindBus archive copy of it either. \
            Metadata is all that survives — the search snippet from memory_search is the most \
            you can get.
            """, isError: true)
        }
        // 真读到原文——记一笔引用（与 memory_open 同一条约束：找不到 id / 读不出原文
        // 都提前 return 了，走到这里必然是「真的产出了 digest」）。
        refLogger(lite.id)
        return render(lite: lite, conversation: conversation, sourceFileMissing: sourceFileMissing,
                     index: index)
    }

    /// 渲染独立可测：不需要真 jsonl，直接手造 `ConversationLite`/`Conversation`，配一个
    /// 临时 `ConversationIndex`（`upsert` 灌合成数据）即可覆盖全部分支——同
    /// `EntityIndexTests`/`MemoryOpenToolTests` 的既有测试模式，不必起 loader 集成测试。
    public static func render(lite: ConversationLite, conversation: Conversation,
                              sourceFileMissing: Bool, index: ConversationIndex) -> MCPToolOutput {
        let messages = conversation.messages
        // browser 会话 cwd 为空串——空时印 (no project)，别让 header 出现 ", ,"
        // （同 MemoryOpenTool.render 的既有惯例）。
        let project = lite.cwd.isEmpty ? "(no project)" : lite.cwd
        var lines = ["DIGEST \(lite.id) — \(lite.source.rawValue), \(project), "
                    + "\(MCPText.day(conversation.startAt)) → \(MCPText.day(conversation.endAt)), "
                    + "\(messages.count) messages"]
        if sourceFileMissing {
            // 与 memory_open 同一个真相、不同的措辞：digest 是"重新提炼"出来的，不是
            // "原样窗口"，用词照抄简报给定的那句，不自己改写。
            lines.append("[the tool deleted its own copy — this digest was built from your "
                        + "MindBus archive]")
        }
        lines.append("")

        lines.append("TASK (first user message)")
        if let firstUser = messages.first(where: { $0.role == .user }) {
            lines.append(truncate(plainText(of: firstUser), cap: taskCap))
        } else {
            lines.append("(no user message)")
        }
        lines.append("")

        lines.append("DISTINCTIVE ENTITIES (rarest first)")
        let entities = index.entities(forConversationID: lite.id, limit: entityLimit)
        lines.append(entities.isEmpty ? "(none extracted)" : entities.map(\.text).joined(separator: " · "))
        lines.append("")

        let closing = closingMessages(messages)
        if !closing.isEmpty {
            lines.append("CLOSING (last exchange)")
            for message in closing {
                lines.append("--- \(message.role.rawValue)")
                lines.append(truncateWithMarker(plainText(of: message), cap: closingCap))
            }
            lines.append("")
        }

        // cwd 为空（browser 会话）连查询都不必发起——一个没有项目概念的会话不可能有
        // "同项目相邻会话"。
        if !lite.cwd.isEmpty {
            let (before, after) = neighbours(of: lite, index: index)
            if before != nil || after != nil {
                lines.append("NEIGHBOURS (same project)")
                if let before {
                    lines.append("before: conversation_id=\"\(before.id)\"  "
                                + "\(MCPText.day(before.startAt))  \(neighbourTitle(before))")
                }
                if let after {
                    lines.append("after:  conversation_id=\"\(after.id)\"  "
                                + "\(MCPText.day(after.startAt))  \(neighbourTitle(after))")
                }
                lines.append("")
            }
        }

        // 引用计数独立成行，不嵌在 NEIGHBOURS 里——「这场对话被 agent 用过 N 次」是
        // 关于会话本身的信号，与它有没有同项目邻居无关；嵌进去的话 browser 会话或
        // 无邻居会话的引用历史就永远不露面了。
        if let ref = index.refCount(forID: lite.id), ref.count > 0 {
            lines.append("(referenced \(ref.count) times by agents before)")
            lines.append("")
        }

        // REINTERPRET 的措辞逐字照简报给定的那句——"答案贬值、语境增值"是产品对外话术，
        // 不是这里现造的说法，不自己扩写。句柄是真 id，能原样喂回 memory_open。
        lines.append("""
        REINTERPRET — this is raw material, not the answer. The conclusions above were made by \
        an older model with the knowledge of that time; answers depreciate, context does not. \
        Re-evaluate against what you know today: is the approach still right? Is there a better \
        way now? Use memory_open(conversation_id="\(lite.id)") to read the full original if needed.
        """)
        return MCPToolOutput(lines.joined(separator: "\n"))
    }

    /// 块渲染一律走 `ContentBlock.plainText`（单一真相）：图片在那里已经变成
    /// `[image: <mediaType>]`，base64 不会漏出来——同 `MemoryOpenTool.renderMessage` 的
    /// 既有惯例，digest 摘的是原文碎片，同样不能泄漏。
    private static func plainText(of message: Message) -> String {
        let text = message.blocks.map(\.plainText).joined(separator: "\n")
        return text.isEmpty ? "(no content)" : text
    }

    /// TASK 用：静默截断，只留省略号——TASK 是给宿主"认出是哪件事"的一句话线索，
    /// 不需要 `memory_open` 那种"还能继续读"的提示（那是窗口分页的概念，digest 没有
    /// 下一页）。
    private static func truncate(_ text: String, cap: Int) -> String {
        guard text.count > cap else { return text }
        return String(text.prefix(cap)) + "…"
    }

    /// CLOSING 用：截断要说出来——与 `MemoryOpenTool.renderMessage` 同一措辞，宿主模型
    /// 若已经见过 memory_open 的截断提示，这里是同一种语言。
    private static func truncateWithMarker(_ text: String, cap: Int) -> String {
        guard text.count > cap else { return text }
        let dropped = text.count - cap
        return String(text.prefix(cap)) + "\n…[truncated, \(dropped) more characters]"
    }

    /// 最后一条 user 消息 + 其后最多 `maxClosingAssistants` 条 assistant 消息；若尾部
    /// 就是那条 user（后面没有 assistant 了），CLOSING 只有它自己。全 assistant 的怪
    /// 会话（找不到任何 user 消息，与 TASK 的"(no user message)"同一种会话）退化成
    /// 直接取最后两条消息，不管角色。
    static func closingMessages(_ messages: [Message]) -> [Message] {
        guard !messages.isEmpty else { return [] }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return Array(messages.suffix(2))
        }
        let trailingAssistants = messages[(lastUserIndex + 1)...].prefix(maxClosingAssistants)
        return [messages[lastUserIndex]] + Array(trailingAssistants)
    }

    /// 同项目里时间上紧邻的前一条与后一条——不要求当前会话本身出现在候选池里
    /// （`limit` 封顶的候选池可能恰好把它挤出去），直接拿 `lite.startAt` 跟每个候选比,
    /// 比"先排序再找自己那个下标"更抗边界情况。
    private static func neighbours(of lite: ConversationLite, index: ConversationIndex)
        -> (before: ConversationLite?, after: ConversationLite?) {
        let ids = index.conversationIDs(for: .project(lite.cwd), limit: neighbourScanLimit)
        let candidates = index.metadata(forIDs: ids).filter { $0.id != lite.id }
        let before = candidates.filter { $0.startAt < lite.startAt }.max { $0.startAt < $1.startAt }
        let after = candidates.filter { $0.startAt > lite.startAt }.min { $0.startAt < $1.startAt }
        return (before, after)
    }

    private static func neighbourTitle(_ lite: ConversationLite) -> String {
        let line = MCPText.oneLine(lite.title ?? lite.preview, max: titleWidth)
        return line.isEmpty ? "(no title)" : line
    }
}
