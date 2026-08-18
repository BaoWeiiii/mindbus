import Foundation

/// 长对话的目录。
///
/// # 为什么需要它
///
/// 真机上最长的一场对话有 5495 条消息。想找回其中某个节点，现在只能滚。
/// 而这场对话里有 184 个被你点头放行的时刻——那本来就是 184 个章节标记，
/// 汇报的首句就是现成的章节标题。这一层不产生新信息，它把已经埋在
/// 消息序列里的结构取出来。
///
/// # 三种节点，覆盖率是这样叠上去的
///
/// 真机 30 场长对话（≥200 条消息）里，能凑够 3 个目录节点的：
/// - 只用里程碑：12 场（40%）
/// - 加上拍板：16 场（53%）
/// - 再加时间断点：20 场（67%）
///
/// 前两种有内容（章节有标题），第三种是纯结构——正因为它不依赖任何
/// 交互习惯（不管你说不说「继续」），才把覆盖率兜住。剩下 33% 多半是
/// 连续做完、中间既没停顿也没节点的对话，本来也不需要目录。
public enum ConversationOutline {

    public struct Node: Equatable, Sendable {
        public enum Kind: Sendable { case milestone, decision, gap }
        public let kind: Kind
        /// 跳转靶点。断点指向**恢复之后的第一条**——你要看的是回来以后说了什么。
        public let messageID: String
        /// 章节标题。断点没有标题（留空），文案由界面按间隔长短决定
        /// （「3 小时后」还是「隔天」是展示口径，不该在这里定死）。
        public let text: String
        public let at: Date
        /// 断点跨过的时长；非断点为 0
        public let gap: TimeInterval

        public init(kind: Kind, messageID: String, text: String, at: Date, gap: TimeInterval = 0) {
            self.kind = kind; self.messageID = messageID
            self.text = text; self.at = at; self.gap = gap
        }
    }

    /// 多久没说话算一次断点。
    ///
    /// 3 小时是从真机分布上取的：一问一答之间的停顿以分钟计，
    /// 而「吃完饭回来接着做」「第二天继续」这类真正的章节边界都在数小时以上。
    /// 取得太小的话，每次去开个会都会被切一章。
    public static let gapThreshold: TimeInterval = 3 * 3600

    /// 少于这么多节点就不算目录：一两个节点还不如不显示，
    /// 它只会让界面多一块内容、却帮不上导航。
    public static let minNodes = 3

    public static func isWorthShowing(_ nodes: [Node]) -> Bool { nodes.count >= minNodes }

    /// 把三种节点按**消息顺序**织成一条目录。
    ///
    /// 里程碑与拍板由调用方给（它们的判据在别处，这里不重复实现）；
    /// 时间断点现算——它只依赖消息本身的时间戳，不需要任何索引。
    public static func build(messages: [Message],
                             milestones: [(messageID: String, text: String)],
                             decisions: [(messageID: String, text: String)],
                             gapThreshold: TimeInterval = gapThreshold) -> [Node] {
        let stoneText = Dictionary(milestones.map { ($0.messageID, $0.text) }) { a, _ in a }
        let callText = Dictionary(decisions.map { ($0.messageID, $0.text) }) { a, _ in a }

        var out: [Node] = []
        for (i, m) in messages.enumerated() {
            // 有内容的节点优先：同一条消息既是里程碑又落在断点之后时，
            // 显示「这一块做完了」比显示「3 小时后」有用得多。
            if let t = stoneText[m.id] {
                out.append(Node(kind: .milestone, messageID: m.id, text: t, at: m.timestamp))
                continue
            }
            if let t = callText[m.id] {
                out.append(Node(kind: .decision, messageID: m.id, text: t, at: m.timestamp))
                continue
            }
            guard i > 0 else { continue }
            let gap = m.timestamp.timeIntervalSince(messages[i - 1].timestamp)
            if gap >= gapThreshold {
                out.append(Node(kind: .gap, messageID: m.id, text: "", at: m.timestamp, gap: gap))
            }
        }
        return out
    }
}
