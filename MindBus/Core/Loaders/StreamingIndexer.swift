import Foundation

/// 流式索引管线(2026-08-15):消息级消费,产出索引路径需要的全部轻量产物。
///
/// 存在理由:旧形态「整场 Conversation 对象树在内存 → 才开始切段/抽取」的峰值
/// = O(最大会话) × 并发 × 建树膨胀——多 Agent 支持下数据量 ×N,这个形态不可持续。
/// 流式后消息**消费完即弃**,驻留 = 段窗口(~KB)+ 轻量产物(段文本/语料,≈会话
/// 可搜文本量,远小于对象树)。
///
/// 等价性是硬约束:所有口径函数与全量路径共享同一份单条实现
/// (`Segmenter.userTextOfSingle` / `entityTextOfSingle` / `Conversation.cleanPreview`
/// / `StreamingSegmenter`),`StreamingIndexerTests` 锁死产物等价。
///
/// 会话级判定(壳会话/残骸)需要文件读完才能定——所以产物先攒在这里,由调用方
/// (loader)在文件结束时依据 `Product` 的判定素材决定 upsert 或丢弃;攒的是
/// 文本级产物,不是消息对象。
public struct StreamingIndexer {

    public struct Product {
        public let segments: [Segmenter.Segment]
        public let preview: String
        public let messageCount: Int
        public let startAt: Date?
        public let endAt: Date?
        public let entityText: String
        public let userText: String
        public let lastMeaningfulRole: String
        /// 残骸/壳会话判定素材(判定本身在 loader:壳会话还要看文件 mtime)
        public let assistantCount: Int
        public let allAssistantsAPIError: Bool
        /// 「你点头的时刻」「你拍板的时刻」的原始素材(与全量路径共用同一个累加器)
        public let harvest: MindsMilestones.Harvest
    }

    private var segmenter = StreamingSegmenter()
    private var count = 0
    private var startAt: Date?
    private var endAt: Date?
    private var previewSource: String?
    private var entityParts: [String] = []
    private var userParts: [String] = []
    private var lastRole = ""
    private var assistantCount = 0
    private var allAssistantsAPIError = true
    private var milestones = MindsMilestones.CandidateAccumulator()

    public init() {}

    /// 64 行早退判定用:还没消费到任何消息。
    public var isEmpty: Bool { count == 0 }

    public mutating func consume(_ m: Message) {
        segmenter.consume(m)
        count += 1
        // 全量路径 startAt/endAt 取排序后首末 = min/max;累加器口径恒等
        if startAt.map({ m.timestamp < $0 }) ?? true { startAt = m.timestamp }
        if endAt.map({ m.timestamp > $0 }) ?? true { endAt = m.timestamp }
        if let t = m.firstTextBlock { previewSource = t }
        entityParts.append(Segmenter.entityTextOfSingle(m))
        if let u = Segmenter.userTextOfSingle(m) { userParts.append(u) }
        if !Segmenter.isSystemInjected(m) { lastRole = m.role.rawValue }
        milestones.consume(m, text: Segmenter.textBlocksOnly)
        if m.role == .assistant {
            assistantCount += 1
            let firstBlockText = m.blocks.first?.plainText ?? ""
            if !firstBlockText.hasPrefix("API Error:") { allAssistantsAPIError = false }
        }
    }

    public mutating func finish() -> Product {
        Product(segments: segmenter.finish(messageCount: count),
                preview: Conversation.cleanPreview(previewSource),
                messageCount: count,
                startAt: startAt, endAt: endAt,
                entityText: entityParts.joined(separator: "\n"),
                userText: userParts.joined(separator: "\n"),
                lastMeaningfulRole: lastRole,
                assistantCount: assistantCount,
                allAssistantsAPIError: allAssistantsAPIError,
                harvest: milestones.finish())
    }
}

/// 索引路径的统一产物:全量路径(小文件,`from(conv)`)与流式路径(大文件,
/// loader 的 streamIndexRow)都产它——LoaderRuntime 只认这个形状,不再关心
/// 上游是对象树还是流。多 Agent 扩展点:新 loader 产出 IndexRow 即接入全管线。
public struct IndexRow {
    public let lite: ConversationLite
    public let segments: [Segmenter.Segment]
    public let entityText: String
    public let userText: String
    public let lastRole: String
    /// 「你点头的时刻」「你拍板的时刻」的原始素材。扫描时提取一次,
    /// 判据全留在 Minds 构建层。
    public let harvest: MindsMilestones.Harvest

    public init(lite: ConversationLite, segments: [Segmenter.Segment],
                entityText: String, userText: String, lastRole: String,
                harvest: MindsMilestones.Harvest = .init()) {
        self.lite = lite
        self.segments = segments
        self.entityText = entityText
        self.userText = userText
        self.lastRole = lastRole
        self.harvest = harvest
    }

    public static func from(_ conv: Conversation, fileURL: URL) -> IndexRow {
        IndexRow(lite: ConversationLite.from(conv, fileURL: fileURL),
                 segments: Segmenter.segments(of: conv.messages),
                 entityText: Segmenter.entityText(of: conv.messages),
                 userText: Segmenter.userText(of: conv.messages),
                 lastRole: Segmenter.lastMeaningfulRole(of: conv.messages),
                 harvest: MindsMilestones.harvest(messages: conv.messages,
                                                  text: Segmenter.textBlocksOnly))
    }
}
