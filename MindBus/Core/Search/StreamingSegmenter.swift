import Foundation

/// 消息级流式切段器(2026-08-15 流式索引管线核心)。
///
/// 与 `Segmenter.segments`(全量版)**逐字节等价**——`StreamingSegmenterTests` 用
/// 200 场随机会话锁死这一点。段口径连着检索质量(R@1 评测在段级),等价是硬约束。
///
/// 为什么存在:全量版要求整场 `[Message]` 在内存(720MB 级会话的对象树是首建峰值
/// 主因之一)。流式版逐条 `consume`,内部只保留「当前未 flush 的窗口」(≤8 轮/
/// ~4000 字)与前一条消息的 (role, 字数)——消息本体消费完即弃,峰值 O(窗口)。
/// 产出的段文本仍会累积在 `finish` 返回值里(那是索引产物,量级=会话可搜文本,
/// 远小于消息对象树)。
///
/// 全量版继续服务详情/增量路径,不删;两版共享 `plainTextForSearch` 口径。
public struct StreamingSegmenter {
    private var out: [Segmenter.Segment] = []
    private var start = 0
    private var texts: [String] = []
    private var chars = 0
    private var turns = 0
    private var index = -1
    private var prevRole: MessageRole?
    private var prevTextCount = 0

    public init() {}

    public mutating func consume(_ m: Message) {
        index += 1
        let t = Segmenter.plainTextForSearch(of: m)
        // 结构切点口径与全量版逐字对应:上一条是 assistant 的长回复(≥400)、
        // 这一条是 user 的短消息(≤60 且非空)——切点落在这一条之后。
        // 全量版对上一条重算 plainTextForSearch;这里用缓存的 prevTextCount,等价。
        let isStructuralEnd = index > 0 && !t.isEmpty
            && m.role == .user && t.count <= 60
            && prevRole == .assistant && prevTextCount >= 400

        if !t.isEmpty {
            texts.append(t)
            chars += t.count
            turns += 1
        }

        if isStructuralEnd || turns >= Segmenter.maxTurnsPerSegment
            || chars >= Segmenter.maxCharsPerSegment {
            flush(endingAt: index)
        }
        prevRole = m.role
        prevTextCount = t.count
    }

    /// 收尾:flush 残余窗口,返回全部段。`messageCount` 必须等于 consume 过的条数
    /// (全量版用 `messages.count`,这里由调用方保证一致)。
    public mutating func finish(messageCount: Int) -> [Segmenter.Segment] {
        if start < messageCount { flush(endingAt: messageCount - 1) }
        return out
    }

    private mutating func flush(endingAt end: Int) {
        let joined = texts.joined(separator: "\n")
        if !joined.isEmpty {
            out.append(Segmenter.Segment(firstMessageIndex: start, lastMessageIndex: end,
                                         text: String(joined.prefix(Segmenter.hardTextCap))))
        } else if let last = out.popLast() {
            // 空段兜底与全量版同款:无文字可成段的下标并进上一段,
            // 保证每条消息都属于某个段(搜索跳转依赖)。
            out.append(Segmenter.Segment(firstMessageIndex: last.firstMessageIndex,
                                         lastMessageIndex: end,
                                         text: last.text))
        }
        start = end + 1
        texts = []
        chars = 0
        turns = 0
    }
}
