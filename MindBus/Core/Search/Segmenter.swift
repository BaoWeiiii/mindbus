import Foundation

/// 会话切段：段是检索的基本单位。
///
/// 为什么要切：会话级检索实测 R@1 只有 5.2%（558 条评测集），因为一条 257 轮的长会话
/// 被当成一个文档，命中词被整场对话的其他内容淹没。切成段后 R@1 到 21.7%。
///
/// 为什么在结构事件处切、而不是固定每 N 轮：实测两者检索质量**打平**（21.7% vs 21.0%，
/// 在噪声范围内），结构切的唯一优势是段数少 3.6 倍（1699 vs 6084）——索引更小、
/// 返回结果更集中。这是工程效率选择，不是质量创新。
public enum Segmenter {

    /// 单段轮数上限。不封顶的话最长 257 轮的会话会切出巨段，段级排序退化回会话级。
    public static let maxTurnsPerSegment = 8
    /// 单段字数上限。单条巨长消息（粘贴的大段日志）同样会让段膨胀。
    /// 这是软顶：判断发生在「把当前消息加进去之后」，不保证单个 segment 的
    /// text 严格 ≤4000——单条巨长消息会让该段远超这个数字，调用方不能假设硬上限。
    public static let maxCharsPerSegment = 4000
    /// 单段文字硬上限。`maxCharsPerSegment` 是软顶（判断发生在把整条消息加进去之后），
    /// 单条粘贴的大段日志能让一个段远超它。而 FTS5 trigram 对超长文本建索引时内存会飙升
    /// ——改造前 `ConversationIndex.searchTextCap = 1_000_000` 就是防这个的 spec 预案，
    /// 换成段级后这条防线不能丢。截断只影响该段尾部的可搜性，前 20 万字符仍可搜。
    public static let hardTextCap = 200_000

    public struct Segment: Equatable {
        public let firstMessageIndex: Int
        public let lastMessageIndex: Int
        public let text: String
    }

    public static func segments(of messages: [Message]) -> [Segment] {
        var out: [Segment] = []
        var start = 0
        var texts: [String] = []
        var chars = 0
        var turns = 0

        func flush(endingAt end: Int) {
            let joined = texts.joined(separator: "\n")
            if !joined.isEmpty {
                out.append(Segment(firstMessageIndex: start, lastMessageIndex: end,
                                    text: String(joined.prefix(hardTextCap))))
            } else if let last = out.popLast() {
                // 没有文字可成段（纯图片消息、或封顶刚 flush 完紧跟一条空文字消息）：
                // 把这些下标并进上一段的范围。不这么做的话 start 照样前移，
                // 这几条消息就不属于任何段——将来「从搜索结果跳到这条消息」无从可跳。
                out.append(Segment(firstMessageIndex: last.firstMessageIndex,
                                   lastMessageIndex: end,
                                   text: last.text))
            }
            start = end + 1
            texts = []
            chars = 0
            turns = 0
        }

        for (i, m) in messages.enumerated() {
            let t = plainTextForSearch(of: m)
            // 结构事件：上一条是 assistant 的长回复、这一条是 user 的短消息
            // ——「长回复建立了预期、短否定违反了它」，这一轮是本次尝试的终点，
            // 所以切点落在**这一条之后**，而不是之前。
            //
            // 已知限制：如果长回复自己就把字数顶穿了 maxCharsPerSegment（处理那条
            // 长回复消息时已经因封顶 flush 过一次），紧跟着的短否定会被孤立成自己的
            // 单条段，而不是像设计意图那样留在前一段末尾——它离开了赋予它语境的长回复，
            // 变成几乎没有检索信号的孤段。彻底修需要在 flush 前「前瞻」判断下一条是否会
            // 构成结构事件，超出当前实现范围（SegmenterTests 里有测试锁定这个现状）。
            //
            // 加 !t.isEmpty：一条纯图片消息（无文字）不构成「短否定」，把它当结构事件
            // 触发 flush 只会产出一个空段（texts 里没有它的文字可拼），白白触发一次
            // 注定无字可成段的 flush——遇到这种情况得靠下面 flush 里的兜底分支
            // 把下标塞回上一段，不如从源头不把它算作结构事件。
            let isStructuralEnd = i > 0 && !t.isEmpty
                && m.role == .user && t.count <= 60
                && messages[i - 1].role == .assistant && plainTextForSearch(of: messages[i - 1]).count >= 400

            if !t.isEmpty {
                texts.append(t)
                chars += t.count
                turns += 1
            }

            if isStructuralEnd || turns >= maxTurnsPerSegment || chars >= maxCharsPerSegment {
                flush(endingAt: i)
            }
        }
        if start < messages.count { flush(endingAt: messages.count - 1) }
        return out
    }

    /// 取消息的可搜文字：除图片外全要。`Conversation.searchableText` 复用这份实现
    /// （而不是各自手工复刻一遍口径）——两处若各写一份，将来改一个不会带动另一个，
    /// 口径会在无人察觉的情况下悄悄分叉。internal（非 private）就是为了让
    /// `Conversation.swift`（同一 target）能调用它。
    ///
    /// 为什么不只取 `.text`：代码块（`.code`）与工具输出（`.toolResult`，报错原文就在这里）
    /// 一直都是可搜的，本次改造只该换索引结构、不该顺带改「什么内容能被搜到」——
    /// 收窄口径是需要单独测量后再拍板的产品决策，不能混在结构改造里悄悄发生。
    public static func plainTextForSearch(of message: Message) -> String {
        message.blocks.compactMap { block -> String? in
            if case .image = block { return nil }   // 图片 base64 不入检索
            return block.plainText
        }.joined(separator: "\n")
    }

    /// 供**实体抽取**用的文本：排除图片，**也排除 `.toolUse`**。
    ///
    /// 与检索口径（`plainTextForSearch`，除图片外全要）的区别是刻意的：`.toolUse` 的文本形态是
    /// `[tool: 名字] {JSON 参数}`，JSON 的 key 是 snake_case，会被抽成 `file_path`/
    /// `old_string`/`new_string` 这类「实体」——真实语料 Top-30 里约 12 条是它们，
    /// 而它们跨会话复现率虚高纯粹是日志格式所致，作为导航线索价值为零。
    /// 但 `.toolResult`（工具**输出**）要留：里面的真实文件路径与报错原文是好线索。
    /// 检索侧不做这个排除——搜 `old_string` 是合理的查询，只是它不该出现在「值得点的实体」里。
    static func entityText(of messages: [Message]) -> String {
        messages.map(entityTextOfSingle).joined(separator: "\n")
    }

    /// 单条消息的实体抽取口径(全量版与流式管线共用,防口径分叉)。
    static func entityTextOfSingle(_ message: Message) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case .image, .toolUse: return nil
            default: return block.plainText
            }
        }.joined(separator: "\n")
    }

    /// 供**用户语料**（user_corpus 表）用的文本：只取 user 角色消息，口径同检索
    /// （除图片外全要）。「你的高频词」必须从你说的话里数——全语料以 AI 输出为主，
    /// 按它数出来的词表是 AI 的语言习惯，不是你的（Minds 概念地图的数频次口径）。
    /// 系统注入剔除（2026-08-13 真机审查）：hook 反馈/会话续传/任务通知等以 user
    /// 角色进场，但不是「你亲手表达的」——0.6% 的污染却会占据展示位
    /// （UNFINISHED 曾把 Stop hook 文本当成你的断点）。
    /// 消息内部换行压平成空格(2026-08-13,policy v16):下游六个消费者
    /// (口头禅/礼貌语/提问形状/委托动词/反复交代/创世句)全按「\n=消息边界」拆行,
    /// 多行消息不压平的话,粘贴代码/计划模板的每一行都会伪装成一条独立短消息——
    /// 口头禅真机现场:Run: ×21 / import ×21 / echo ×9 / fi ×7,全是粘贴行不是你的话。
    /// 词表分词不受影响(空格与换行等价)。
    public static func userText(of messages: [Message]) -> String {
        messages.compactMap(userTextOfSingle).joined(separator: "\n")
    }

    /// 单条消息的用户语料口径(全量版 `userText` 与流式管线共用同一份——两处各写
    /// 一遍的话口径会悄悄分叉)。nil = 该条不产出(非 user / 系统注入 / 纯文件清单)。
    public static func userTextOfSingle(_ message: Message) -> String? {
        guard message.role == .user, !isSystemInjected(message) else { return nil }
        var t = plainTextForSearch(of: message).replacingOccurrences(of: "\n", with: " ")
        // Codex 客户端拼在 user 消息**前面**的注入头。后随「## My request for
        // Codex:」标记时,标记之后才是你的话(真机: Codex 项目创世句曾被这个头
        // 顶成 markdown 标题、遭噪声正则整条误杀);无标记=整条都是注入,丢弃。
        // 两个条件绑定,不误伤恰好写出这句话的人——只有出现在开头才算。
        if codexInjectedHeaders.contains(where: {
            t.trimmingCharacters(in: .whitespaces).hasPrefix($0)
        }) {
            guard let r = t.range(of: "## My request for Codex:") else { return nil }
            t = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // Claude Code 把粘贴的图片写成「[Image: source: <本地路径>]」。那是客户端
        // 写进正文的路径,不是你打的字,而且路径里带着家目录用户名(policy v18)。
        t = t.replacingOccurrences(of: #"\[Image: source:[^\]]*\]"#, with: "",
                                   options: .regularExpression)
        // Codex 的同类标记是 XML 形态:<image name=… path="/var/folders/…"> </image>
        t = t.replacingOccurrences(of: #"</?image[^>]*>"#, with: "",
                                   options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Codex 客户端拼在 user 消息前面的注入头。两种形态同构——头在前、
    /// 你的话在「## My request for Codex:」之后。
    static let codexInjectedHeaders = [
        "# Files mentioned by the user:",   // 文件引用头(policy v17)
        // 浏览器状态注入(policy v18)。真机 336 个 block 带着它,是短语榜上
        // app browser 532 次、Current URL 257 次、家目录路径 306 次的来源。
        "# In app browser:",
    ]

    /// 以 user 角色进场的系统产物：整条消息以已知系统模式开头，或全文由注入标记主导。
    /// 判定保守（前缀级）——宁放过存疑的，不误杀你的真话。
    public static func isSystemInjected(_ message: Message) -> Bool {
        let text = plainTextForSearch(of: message).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Stop hook feedback:", "This session is being continued",
                        "[Request interrupted", "Caveat: The messages below",
                        "<system-reminder>", "<task-notification>", "<command-name>",
                        "<local-command-stdout>"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    /// 「断点」信号用的收尾角色：最后一条**非系统注入**消息的角色——
    /// hook 反馈以 user 收尾会伪造「你问了没人答」。
    public static func lastMeaningfulRole(of messages: [Message]) -> String {
        messages.last { !isSystemInjected($0) }?.role.rawValue ?? ""
    }
}
