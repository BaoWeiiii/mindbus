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

    // MARK: - 你拍板的时刻

    /// 一次拍板：AI 摆出选项 / 征询意见之后，你给出的那句实质回应。
    public struct Decision: Equatable, Sendable {
        /// 你说的那句话（原话，不做加工）
        public let statement: String
        public let at: Date
        public init(statement: String, at: Date) {
            self.statement = statement; self.at = at
        }
    }

    /// AI 侧的「征询」标记。
    ///
    /// 注意这些模式匹配的是 **AI 的话**，不是你的话——它只用来定位「这里是个
    /// 决策点」，不对你说的内容做任何价值判断。真机上 AI 摆出选项 65 次。
    ///
    /// 为什么不去判「你选了 A 还是 B」：真机实测你几乎不用编号选择（用
    /// 「A」「第二个」这类说法的只有 2 处），你的做法是**用自己的话重述**，
    /// 所以配对到具体选项做不到，也不必要——你那句回应本身就是决定。
    static let solicitationMarkers = [
        "方案 A", "方案 B", "方案一", "方案二", "选项 A", "选项 B",
        "两个选择", "两个方案", "两个做法", "两个思路",
        "三个选择", "三个方案", "三个做法", "三个思路",
        "哪一种", "哪种", "你倾向", "你想要哪",
    ]

    /// 征询之后多少条消息内的回应算数。隔太远就不是对这次征询的回答了。
    static let decisionLookahead = 2
    static let minSolicitationLength = 150
    static let decisionRange = 4...120

    static func isSolicitation(_ report: String) -> Bool {
        guard report.count >= minSolicitationLength else { return false }
        if solicitationMarkers.contains(where: { report.contains($0) }) { return true }
        // 「要么…要么…」是同一个语用形态，只是没法写成固定串
        guard let first = report.range(of: "要么") else { return false }
        return report[first.upperBound...].contains("要么")
    }

    /// 疑问句不是拍板——你在追问，不是在定。
    /// 真机上剔掉的是「测试和验收呢？」「什么是语义地图渲染管线？」这类。
    static func isQuestion(_ text: String) -> Bool {
        if text.contains("？") || text.contains("?") { return true }
        let openers = ["什么", "为什么", "怎么", "如何", "是不是", "能不能",
                       "有没有", "哪些", "哪个", "多少", "在哪"]
        return openers.contains { text.hasPrefix($0) }
    }

    public static func extractDecisions(messages: [Message],
                                        text: (Message) -> String) -> [Decision] {
        var out: [Decision] = []
        for (i, m) in messages.enumerated() where m.role == .assistant {
            guard isSolicitation(text(m)) else { continue }
            let upper = min(i + 1 + decisionLookahead, messages.count)
            guard i + 1 < upper else { continue }
            guard let answer = messages[(i + 1)..<upper].first(where: { $0.role == .user })
            else { continue }
            let said = text(answer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard decisionRange.contains(said.count), !isQuestion(said) else { continue }
            out.append(Decision(statement: said, at: answer.timestamp))
        }
        return out
    }
}
