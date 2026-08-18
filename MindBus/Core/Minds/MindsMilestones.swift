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
/// # 信号选择准则（2026-08-18，九次实测得出）
///
/// 这一层能成立、而别的挖掘尝试大多不成立，原因是可以说清楚的。
/// 准则一句话：
///
/// > **用户的显式动作可以被结构化识别；用户的隐式模式无法被统计发现。**
///
/// 成立的（都在这个文件里）——判据是「一个明确动作 + 确定的结构标记」：
/// - 认可：短消息 + 前面是一段够长的汇报 → 真机 286 条
/// - 拍板：以问号收尾的长消息 + 你的回应 → 真机 68 条
///
/// 试过并否掉的九条，全都是「想从统计规律里发现模式」。记在这里是为了
/// 不再重走——每条都附着当时的实测数字：
///
/// 1. **句式模板**（挖「不要 X」「有什么办法」这类带槽位的口令）
///    连试三次。最后一版用邻接变化度（右邻越发散 = 后面是槽位），
///    数据直接否掉：「然后」的右邻比「不要」更发散（60 种/5% vs 84 种/11%），
///    自动榜前 24 名混着 `**`、`//`、`##`、and、但是、而且。
///    根因：功能词与指令词在分布上本来就同构——都高频、都在句首、后面都能接万物。
///
/// 2. **扩散召回**（用被认可的消息当正样本，学特征去召回「同样有价值但你没点头」的）
///    控制长度之后，所有形式特征的区分度全部消失（列表 2.58× → 1.02× → 0.84×）。
///    唯一稳健的信号是长度本身——召回同类会退化成召回所有长消息。
///
/// 3. **重做/纠正**（AI 连着两次做同一件事 = 中间那句是纠正）
///    用 Jaccard 判「同一件事」，高相似组里大半是「继续」。
///    根因：AI 相邻两条消息天然用词相似，相似度量的是话题连续性，不是重做。
///
/// 4. **跨对话重复提问**（同一件事在不同对话里反复问 = 该沉淀）
///    加上「措辞不完全相同 + 时间跨度 ≥7 天」后只剩 1 个簇，还是条错误消息。
///    根因：人要么复制粘贴（一字不差），要么换个说法（相似度就低了），
///    中间地带只剩系统噪声。
///
/// 5. **重贴的上下文**（完全相同的长文本贴进多场对话 = 该存成模板）
///    330 条长文本里只有 9 条命中，且都是「3 场 / 跨 4 天」——同一段工作的延续。
///    真正该命中的那条（同一段背景贴了 5 次）反而漏了：每次都手动改了几个字。
///
/// 6. **打断**（`[Request interrupted by user]` 是系统记的显式动作，本该最可靠）
///    真机只有 2 次 / 141 场。判据没错，是这个动作本身太稀有。
///
/// 7. **会话价值排序**（聚合里程碑 + 拍板给对话排序）
///    信号只覆盖 16% 的会话（141 场里 23 场有里程碑），且排序结果与
///    「按消息数排序」大量重合——没有提供新信息。
///
/// 8. **高价值子语料二次挖掘**（在 286 条被认可的汇报上提概念）
///    出来的是「继续完成」16 次、「已完成并」4 次——AI 的套话。
///    根因：那 286 条是 **AI 写的**，措辞高度模板化。
///
/// 9. **最长的消息 = 最认真的表达**
///    部分成立（前几条确实是你写的需求文档），但混着粘贴的 skill 文档，
///    且分不开「自己写的」和「贴进来的」。
///
/// 附带一条参数教训：门槛与语料规模绑定。全语料标定的
/// 「≥6 次 / 跨 ≥3 项目」拿到 286 条的子语料上，一条都出不来。
public enum MindsMilestones {

    public struct Milestone: Equatable, Sendable {
        /// AI 汇报的首句（已去掉 markdown 标记）
        public let headline: String
        /// 用户当时说的那句认可
        public let approval: String
        public let at: Date
        public let messageID: String
        public init(headline: String, approval: String, at: Date, messageID: String = "") {
            self.headline = headline; self.approval = approval
            self.at = at; self.messageID = messageID
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

    /// 扫描时攒下的一条素材：一条**短** user 消息，配上它前面那条够长的
    /// AI 汇报的首句（前面没有汇报就是 nil）。
    ///
    /// 这一层刻意**不做任何判断**——是不是认可、算不算里程碑，全留给构建层。
    /// 两个理由：认可词表要看过全部对话才学得出来（单场对话里看不出「继续」
    /// 说了 242 次）；判据以后还会改，而改判据不该要求用户重建一次索引。
    public struct Candidate: Equatable, Sendable {
        public let approval: String
        public let headline: String?
        public let at: Date
        /// 汇报那条消息的 id。这一层是**特征**不是展示——不能指回原文的话，
        /// 它就只是一段好看的文字，没法拿来当入口、也没法给检索加权。
        public let messageID: String
        public init(approval: String, headline: String?, at: Date, messageID: String = "") {
            self.approval = approval; self.headline = headline
            self.at = at; self.messageID = messageID
        }
    }

    /// 候选素材的累加器。
    ///
    /// 全量路径（小文件，整场消息在手）与流式路径（大文件，逐条消费即弃）
    /// **共用这一份逻辑**——两处各写一遍的话口径会悄悄分叉，这是
    /// `Segmenter.userTextOfSingle` 已经交过的学费。
    ///
    /// 流式下只需记住「最近一条够长的汇报的首句」，一个变量就够：
    /// 全量路径里的「从当前位置往回找」找到的必然也是最近的那一条。
    public struct CandidateAccumulator {
        private var lastHeadline: String?
        private var lastReportID = ""
        private var harvest = Harvest()
        /// 距离上一次「AI 在征询意见」还剩几条消息内的回应算数。
        /// 流式下靠倒数实现全量路径的 `messages[(i+1)..<(i+1+lookahead)]`。
        private var solicitationWindow = 0
        public init() {}

        public mutating func consume(_ m: Message, text: (Message) -> String) {
            if solicitationWindow > 0 { solicitationWindow -= 1 }
            switch m.role {
            case .assistant:
                let t = text(m)
                if t.count >= minReportLength, let h = headline(of: t) {
                    lastHeadline = h
                    lastReportID = m.id
                }
                if isSolicitation(t) {
                    solicitationWindow = decisionLookahead
                    harvest.openQuestion = trailingQuestion(of: t)
                }
            case .user:
                let said = text(m).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !said.isEmpty else { return }
                // 你回话了，上一个问题就不算悬着
                harvest.openQuestion = nil
                if solicitationWindow > 0 {
                    harvest.decisions.append(DecisionCandidate(statement: said, at: m.timestamp,
                                                              messageID: m.id))
                    solicitationWindow = 0        // 一次征询只认第一个回应
                }
                guard normalizedApproval(said).count <= maxApprovalLength else { return }
                harvest.milestones.append(Candidate(approval: said, headline: lastHeadline,
                                                    at: m.timestamp, messageID: lastReportID))
            default:
                break
            }
        }

        public func finish() -> Harvest { harvest }
    }

    /// 一次征询之后你说的那句话（原话，不做加工）。
    /// 长度、是不是疑问句都留给构建层判——那两个阈值最容易改。
    public struct DecisionCandidate: Equatable, Sendable {
        public let statement: String
        public let at: Date
        /// 你说那句话的消息 id
        public let messageID: String
        public init(statement: String, at: Date, messageID: String = "") {
            self.statement = statement; self.at = at; self.messageID = messageID
        }
    }

    /// 一次遍历攒下的素材
    public struct Harvest: Equatable, Sendable {
        public var milestones: [Candidate] = []
        public var decisions: [DecisionCandidate] = []
        /// 悬而未决：它最后问了你一个问题，而你再没回过。
        ///
        /// 这一项对应「价值 = 遗忘度 × 相关性 × **未闭合度**」里的第三项：
        /// 已经做完的事提醒你没用，悬着没做完的事提醒才有价值。
        ///
        /// 试过并否掉的判据：`last_role = 'user'`（你问了没人答）——真机
        /// 141 场里只有 4 场，因为 AI 工具总会回复，对话几乎必然以它收尾。
        /// 反过来看「它问了你、你没回」才抓得住：真机 5 场，且条条可执行
        /// （「要我把它归档提交、还是继续调形态？」）。
        public var openQuestion: String?
        public init() {}
    }

    /// 从一段汇报里切出结尾那个问句。
    ///
    /// 待办清单上该写「要我把它归档提交吗」，而不是把 1800 字的汇报原样贴上去
    /// ——前面那一大段是它做完的事，不是需要你决定的事。
    public static func trailingQuestion(of text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last, questionMarks.contains(last) else { return nil }
        // 从末尾往前找上一个句末标点，中间那段就是问句本身
        let body = String(t.dropLast())
        if let cut = body.lastIndex(where: { "。！？!?\n；;".contains($0) }) {
            let q = String(t[t.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
            if !q.isEmpty { return q }
        }
        return t
    }

    /// 构建层筛选:太短/太长/疑问句都不是拍板。
    public static func decisions(candidates: [DecisionCandidate]) -> [Decision] {
        candidates.compactMap { c in
            guard decisionRange.contains(c.statement.count), !isQuestion(c.statement) else { return nil }
            return Decision(statement: c.statement, at: c.at, messageID: c.messageID)
        }
    }

    /// 从一场对话里取出全部候选素材。扫描时逐场调用。
    public static func candidates(messages: [Message], text: (Message) -> String) -> [Candidate] {
        harvest(messages: messages, text: text).milestones
    }

    /// 一次遍历取出两类素材。
    public static func harvest(messages: [Message], text: (Message) -> String) -> Harvest {
        var acc = CandidateAccumulator()
        for m in messages { acc.consume(m, text: text) }
        return acc.finish()
    }

    /// 这条短消息是不是一个**编号**。
    ///
    /// AI 摆出「方案 1 / 方案 2」时你打的「1」「a」，判据上完全符合认可词
    /// （短、反复出现、绝大多数跟在长汇报之后），但它是在**选择选项**，
    /// 不是在认可成果——它前面那条消息是选项列表，首句取出来是
    /// 「已使用内置 GPT Image 生成」这种没有信息的行（2026-08-18 真机现场）。
    ///
    /// 判据与语言无关：纯数字，或单个拉丁字母。说中文说英文的人
    /// 打的编号都长这样，而真正的短认可词（ok / yes / 好 / 确认 / lgtm）
    /// 一个都不符合。
    static func isEnumerationToken(_ s: String) -> Bool {
        let t = normalizedApproval(s)
        guard !t.isEmpty else { return false }
        if t.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        return t.count == 1 && (t.first?.isASCII ?? false) && (t.first?.isLetter ?? false)
    }

    /// 从候选素材里学出认可词表。判据与 `learnApprovals(conversations:text:)`
    /// 完全相同,只是输入换成了扫描时攒下的素材。
    public static func learnApprovals(candidates: [Candidate]) -> Set<String> {
        var seen: [String: Int] = [:], afterReport: [String: Int] = [:]
        for c in candidates {
            let core = normalizedApproval(c.approval)
            guard !core.isEmpty, !isEnumerationToken(core) else { continue }
            seen[core, default: 0] += 1
            if c.headline != nil { afterReport[core, default: 0] += 1 }
        }
        return Set(seen.compactMap { word, n -> String? in
            guard n >= approvalMinOccurrences else { return nil }
            return Double(afterReport[word] ?? 0) / Double(n) >= approvalMinAfterReportRatio ? word : nil
        })
    }

    /// 用学出的词表把候选筛成里程碑:既要是认可,前面又确实有过一段汇报。
    public static func milestones(candidates: [Candidate],
                                  approvals: Set<String>) -> [Milestone] {
        candidates.compactMap { c in
            guard let h = c.headline, isApproval(c.approval, approvals: approvals) else { return nil }
            return Milestone(headline: h, approval: c.approval, at: c.at, messageID: c.messageID)
        }
    }

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
        public let messageID: String
        public init(statement: String, at: Date, messageID: String = "") {
            self.statement = statement; self.at = at; self.messageID = messageID
        }
    }

    /// 征询之后多少条消息内的回应算数。隔太远就不是对这次征询的回答了。
    static let decisionLookahead = 2
    static let minSolicitationLength = 150
    public static let decisionRange = 4...120

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
    public static func isQuestion(_ text: String) -> Bool {
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
