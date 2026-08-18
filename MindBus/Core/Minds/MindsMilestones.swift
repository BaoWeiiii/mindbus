import Foundation

/// 「你点头的时刻」——从对话里机械地找出被用户认可过的阶段成果。
///
/// # 这一层为什么存在
///
/// Minds 此前所有的维度都是「词 / 短语 / 统计」，没有一个能回答「发生过什么」。
/// 事件不在用户的话里——用户的话是短指令（「继续」说了 238 遍，本身零信息）；
/// 事件在 AI 的汇报里，而**用户的短反馈恰好是那份汇报的标注**：
///
///     [assistant] 风声扩展 P1 落地完毕(0a1b2c3)：表 + 闸门 + 真实种子全链路跑通
///     [user]      继续                          ← 这一声就是「我认可了」
///
/// 所以信号 = 用户的认可词，内容 = 它前面那条 AI 消息的首句。
/// 这样拿到的里程碑是**被用户点过头的**，不是 AI 自吹的。
///
/// # 定阈依据（2026-08-18，真机 150 场 / 3240 条 user 消息）
///
/// - 认可信号 271 处（继续 238 · 确认 19 · 好 9 · 好的 2 · 可以 2 · 对 1）
/// - 提取出 233 条里程碑，抽样看约八成是真事件
/// - 被认可的 AI 消息平均 1342 字，其余 264 字（5.1×）
///
/// 试过并否掉的：按「含代码块 / 列表 / 小标题 / 建议」等形式特征找偏好——
/// 控制长度之后这些差异全部消失（列表 2.58× → 1.02× → 0.84×），
/// 它们只是长消息的副产品。**唯一稳健的信号是长度本身**，
/// 也就是「一个实质工作块做完了」，这正是里程碑的定义。
public enum MindsMilestones {

    public struct Milestone: Equatable, Sendable {
        /// AI 汇报的首句（已去掉 markdown 标记）
        public let headline: String
        /// 用户当时说的那句认可
        public let approval: String
        public let at: Date
        public init(headline: String, approval: String, at: Date) {
            self.headline = headline; self.approval = approval; self.at = at
        }
    }

    /// 认可词。整条消息必须**只有**这一句才算——
    /// 「继续，另外把 X 改一下」是新指令不是认可，混进来会把里程碑变成噪声。
    static let approvals = ["继续", "好", "好的", "可以", "行", "对", "是的", "同意",
                            "没问题", "ok", "就这样", "不错", "确认", "通过", "采纳",
                            "听你的", "你决定"]

    /// 认可词最长多少字。超过就当它带了新内容。
    static let maxApprovalLength = 12

    /// AI 消息至少多长才算「一个工作块」。真机上被认可的平均 1342 字，
    /// 其余 264 字；200 是保守下界，宁可漏掉短汇报，不要把闲聊当里程碑。
    static let minReportLength = 200

    /// 首句至少多长才算一条里程碑。
    static let minHeadlineLength = 10

    public static func isApproval(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= maxApprovalLength else { return false }
        // 去掉句末标点后必须**整句**等于某个认可词
        let core = t.trimmingCharacters(in: CharacterSet(charactersIn: "。，！？!?,.~、 　"))
        return approvals.contains { $0.caseInsensitiveCompare(core) == .orderedSame }
    }

    /// 取一段汇报的首句：第一行有实质内容的文字，截到第一个句末标点。
    /// 去掉 markdown 的标题号与强调符——那是排版不是内容。
    public static func headline(of report: String) -> String? {
        for rawLine in report.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            line.removeAll { "*`_>".contains($0) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.count >= minHeadlineLength else { continue }
            let sentence = line.split(whereSeparator: { "。！？；!?;".contains($0) }).first
                .map(String.init) ?? line
            let picked = sentence.count >= minHeadlineLength ? sentence : line
            return String(picked.prefix(80))
        }
        return nil
    }

    /// 从一场对话里抽出所有里程碑。
    ///
    /// `text(of:)` 由调用方给——Core 里 `Message` 的正文提取有好几种口径
    /// （检索用 / 展示用），这一层不替调用方决定用哪种。
    public static func extract(messages: [Message],
                               text: (Message) -> String) -> [Milestone] {
        var out: [Milestone] = []
        for (i, m) in messages.enumerated() {
            guard m.role == .user else { continue }
            let said = text(m)
            guard isApproval(said) else { continue }
            // 往回找最近的一条「够长的」AI 消息
            guard let report = messages[..<i].reversed().first(where: {
                $0.role == .assistant && text($0).count >= minReportLength
            }) else { continue }
            guard let h = headline(of: text(report)) else { continue }
            out.append(Milestone(headline: h,
                                 approval: said.trimmingCharacters(in: .whitespacesAndNewlines),
                                 at: m.timestamp))
        }
        return out
    }
}
