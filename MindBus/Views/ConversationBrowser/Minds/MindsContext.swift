import SwiftUI
import MindBusCore

/// 三个页面共用的取数上下文。
///
/// 解析一律走 `MindsCore.MindsDocument`（与写 md 的 `MindsBuilder` 同住 Core，
/// 格式改动两端一起炸，且能被测试直接覆盖）。这一层只负责三件事：
/// 把 `MindsStore` 读到的 markdown 包起来、把机械英文行文案化成中文、给导航动作。
@MainActor
struct MindsContext {
    let store: ConversationStore
    let viz: MindsViz
    /// 图表数据还在后台查。加载中与「数据不够」必须分开——
    /// 混成一个状态时，刚打开 Minds 会被告知「还没有足够数据」，那是假话。
    let isLoading: Bool
    /// 机械层 markdown（已剔除 WEAK SPOTS 之后的部分）
    let doc: MindsDocument

    init(store: ConversationStore, md: String, viz: MindsViz, isLoading: Bool) {
        self.store = store
        self.viz = viz
        self.isLoading = isLoading
        self.doc = MindsDocument(markdown: md)
    }

    private var l10n: Strings { L10n.shared.s }
    var isZh: Bool { L10n.shared.isZh }

    // MARK: - 取数（转发到 Core）

    func bullets(_ section: String) -> [String] { doc.bullets(section) }
    func hasAny(_ names: String...) -> Bool { doc.hasAny(names) }
    /// 传染的案发现场（词 / it 或 you / 那句原话）
    var taughtQuotes: [(word: String, role: String, text: String)] { doc.taughtQuotes }
    /// 它先说、你后来接过来的词
    var wordsItTaughtYou: [(word: String, gapDays: Int, projects: Int)] { doc.wordsItTaughtYou }
    /// 悬着的事（日期 / 上下文 / 那个没被回答的问题）
    var openLoops: [(day: String, context: String, question: String)] { doc.openLoops }
    func parseRecurring(_ line: String) -> (word: String, detail: String)? {
        doc.namedDetail(line).map { (word: $0.name, detail: $0.detail) }
    }
    func parseWithID(_ line: String) -> (id: String, label: String, meta: String)? {
        doc.identified(line)
    }
    func chips(from flat: String) -> [(word: String, meta: String)] {
        doc.chips(from: flat).map { (word: $0.word, meta: $0.meta) }
    }
    func firstInt(after prefix: String, in text: String) -> Int? {
        MindsDocument.firstInt(after: prefix, in: text)
    }
    func twoGroups(_ text: String, _ pattern: String) -> (String, String)? {
        let g = MindsDocument.captures(text, pattern)
        return g.count >= 2 ? (g[0], g[1]) : nil
    }

    // MARK: - 项目行（含展示用的活跃期文案）

    struct ProjectRow {
        let path: String
        let name: String
        let count: Int
        /// 消息总数（条形按它画）；旧文档缺这一段时回退成场数
        let messages: Int
        /// 这个项目里你放行过几件事（产出量，区别于条形画的投入量）
        let signedOff: Int
        /// 「05-15 至 08-10」
        let span: String
        let lastTouched: Date?
        /// 近 14 天有动静
        let active: Bool
    }

    func parseProject(_ line: String) -> ProjectRow? {
        guard let row = doc.project(line) else { return nil }
        let now = Date()
        var span = ""
        if let s = row.activeStart, let e = row.activeEnd {
            span = "\(MindsDocument.dayString(s).dropFirst(5)) \(l10n.mSpanTo) \(MindsDocument.dayString(e).dropFirst(5))"
        }
        return ProjectRow(path: row.path, name: row.name, count: row.count,
                          messages: row.messages > 0 ? row.messages : row.count,
                          signedOff: row.signedOff, span: span, lastTouched: row.lastTouched,
                          active: row.isActive(now: now))
    }

    /// 「今天 / 3 天前」——最近活跃列。
    func relativeDay(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = MindsDocument.daysAgo(date, now: Date())
        return days <= 0 ? l10n.mRelToday : l10n.mRelDaysAgo(days)
    }

    // MARK: - 文案化（抽取在 Core，这里只负责说成中文）

    func dormantMeta(_ d: String) -> String {
        guard let r = doc.dormantDetail(d) else { return d }
        return l10n.mDormantMeta(r.conversations, r.lastTouched)
    }

    func fadedMeta(_ d: String) -> String {
        guard let r = doc.fadedDetail(d) else { return d }
        return l10n.mFadedMeta(r.said, r.silentDays)
    }

    /// 「5497 条消息 · 跨 64 天 · Atlas」
    func marathonMeta(_ d: String) -> String {
        guard let r = doc.marathonDetail(d) else { return d }
        let span: String
        switch r.span {
        case .days(let n): span = l10n.mSpanDays(n)
        case .hours(let n): span = l10n.mSpanHours(n)
        }
        return l10n.mMarathonMeta(r.messages, span, r.project)
    }

    func vocabMeta(_ meta: String) -> String {
        switch MindsDocument.chipMeta(meta) {
        case .timesAndProjects(let t, let p): return l10n.mVocabMindMeta(t, p)
        case .times(let n): return l10n.mVocabWorkMeta(n)
        case .raw(let s): return s
        }
    }

    func sourceName(_ raw: String) -> String {
        ConversationSource(rawValue: raw)?.displayName(isZh: isZh) ?? raw
    }

    // MARK: - 导航

    func open(conversation id: String) {
        store.mindsSelected = false
        store.selectedConversationId = id
    }

    /// 跳回那一刻:打开对话并滚到那条消息。
    /// 「你点头 / 拍板的时刻」是**入口**不是展示——看完就完了的话，
    /// 这一层就只是好看的文字，没法用来找回当时的完整上下文。
    func open(conversation id: String, locate messageID: String) {
        if !messageID.isEmpty { store.pendingLocateMessageID = messageID }
        open(conversation: id)
    }

    func search(_ query: String) {
        store.searchQuery = query
        store.mindsSelected = false
    }

    static func dayString(_ d: Date) -> String { MindsDocument.dayString(d) }
    static func day(from iso: String) -> Date? { MindsDocument.day(from: iso) }
}
