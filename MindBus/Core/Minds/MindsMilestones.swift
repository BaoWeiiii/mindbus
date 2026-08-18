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

    /// 认可词的长度上限。
    ///
    /// 12 个字符对中英文都落在「一句短应答」的量级：
    /// 继续(2) · 确认(2) · ok(2) · yes(3) · lgtm(4) · ship it(7) ·
    /// continue(8) · go ahead(8) · looks good(10) · sounds good(11)。
    /// 超过它就当这条消息带了新内容，不是纯粹的应答。
    static let maxApprovalLength = 12

    /// 学认可词时，一个候选至少要出现这么多次。
    static let approvalMinOccurrences = 5
    /// 候选出现处有多大比例紧跟在一段长汇报之后。
    static let approvalMinAfterReportRatio = 0.7

    /// **学出**这个人的认可词，而不是预先写死一张中文表。
    ///
    /// 判据三条，全部与语言无关：
    /// ① **短**——不超过 `maxApprovalLength`
    /// ② **反复出现**——至少 `approvalMinOccurrences` 次
    /// ③ **位置**——绝大多数出现在一段够长的 AI 汇报之后
    ///
    /// 真机验证（2026-08-18，150 场）自动学出：继续(242 次/84%) · 确认(19/100%) ·
    /// push · 全部优化 · 做 · a。用学出的表提取里程碑得到 287 条，
    /// 与人工写死那张表的 233 条质量相当——学出来的「噪声词」其实无害，
    /// 它们前面同样是实质汇报。换个说英文的人，学到的会是
    /// continue / yes / ok / go ahead，代码一行不用改。
    ///
    /// 试过并否掉的四条判据（都想把「认可」和「短指令」分开，都不成立）：
    /// 跨项目数（会误伤只在少数项目里说的「确认」）、
    /// 前后 AI 消息的话题延续度（继续 0.095 vs 全部优化 0.061，区分度不够）、
    /// 独立成句率（确认只有 5%，反被误杀）、
    /// 完全不用词表只看「长汇报 + 短回应」（484 条，混进大量讨论中间态）。
    /// 结论：词表是必需的，但它必须是学出来的。
    public static func learnApprovals(conversations: [[Message]],
                                      text: (Message) -> String) -> Set<String> {
        var seen: [String: Int] = [:]
        var afterReport: [String: Int] = [:]
        for messages in conversations {
            for (i, m) in messages.enumerated() where m.role == .user {
                let core = normalizedApproval(text(m))
                guard !core.isEmpty, core.count <= maxApprovalLength else { continue }
                seen[core, default: 0] += 1
                let prev = messages[..<i].last { $0.role == .assistant }
                if let prev, text(prev).count >= minReportLength {
                    afterReport[core, default: 0] += 1
                }
            }
        }
        return Set(seen.compactMap { word, n -> String? in
            guard n >= approvalMinOccurrences else { return nil }
            let ratio = Double(afterReport[word] ?? 0) / Double(n)
            return ratio >= approvalMinAfterReportRatio ? word : nil
        })
    }

    /// 归一化成比对用的形态：去首尾空白、去句末标点、小写。
    /// 标点集合含中英两套，是**书写系统**的差异，不是某种语言的词汇表。
    static func normalizedApproval(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。，！？!?,.~、;；ï¼ 　"))
            .lowercased()
    }

    /// AI 消息至少多长才算「一个工作块」。真机上被认可的平均 1342 字，
    /// 其余 264 字；200 是保守下界，宁可漏掉短汇报，不要把闲聊当里程碑。
    static let minReportLength = 200

    /// 首句至少多长才算一条里程碑。
    static let minHeadlineLength = 10

    /// 整条消息必须**只有**这一句认可才算——「继续，另外把 X 改一下」是新指令。
    public static func isApproval(_ text: String, approvals: Set<String>) -> Bool {
        let core = normalizedApproval(text)
        guard !core.isEmpty, core.count <= maxApprovalLength else { return false }
        return approvals.contains(core)
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
                               approvals: Set<String>,
                               text: (Message) -> String) -> [Milestone] {
        var out: [Milestone] = []
        for (i, m) in messages.enumerated() {
            guard m.role == .user else { continue }
            let said = text(m)
            guard isApproval(said, approvals: approvals) else { continue }
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

    /// 征询之后多少条消息内的回应算数。隔太远就不是对这次征询的回答了。
    static let decisionLookahead = 2
    static let minSolicitationLength = 150
    static let decisionRange = 4...120

    /// 问号。中英两套写法都列上——那是**书写系统**的差别，
    /// 不是「中文词汇表」；任何用这两个符号的语言都被覆盖。
    static let questionMarks: Set<Character> = ["?", "？"]

    /// AI 在向你征询意见：一段够长的话，并且**以问号收尾**。
    ///
    /// 原先这里是一张中文模式表（方案 A/B、两个选择、你倾向哪种…），
    /// 换个语言的模型说话就全部失效。改成「以问号收尾」之后判据与语言无关，
    /// 而且更准——真机实测「结尾是问句」在被认可组里富集 4.17×/2.64×，
    /// 本来就是这批消息最稳的特征。
    static func isSolicitation(_ report: String) -> Bool {
        guard report.count >= minSolicitationLength else { return false }
        let tail = report.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = tail.last else { return false }
        return questionMarks.contains(last)
    }

    /// 疑问句不是拍板——你在追问，不是在定。
    ///
    /// 只看问号，不列疑问词：疑问词表是语言相关的（中文「什么/为什么」、
    /// 英文 what/why/how），而问号是书写系统级的。代价是漏掉不带问号的
    /// 疑问句，宁可漏一条也不要把整套判据绑死在一种语言上。
    static func isQuestion(_ text: String) -> Bool {
        text.contains { questionMarks.contains($0) }
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
