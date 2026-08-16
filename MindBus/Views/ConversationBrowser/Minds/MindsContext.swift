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
    /// 机械层 markdown（已剔除 WEAK SPOTS 之后的部分）
    let doc: MindsDocument

    init(store: ConversationStore, md: String, viz: MindsViz) {
        self.store = store
        self.viz = viz
        self.doc = MindsDocument(markdown: md)
    }

    private var l10n: Strings { L10n.shared.s }
    var isZh: Bool { L10n.shared.isZh }

    // MARK: - 取数（转发到 Core）

    func bullets(_ section: String) -> [String] { doc.bullets(section) }
    func hasAny(_ names: String...) -> Bool { doc.hasAny(names) }
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
                          span: span, lastTouched: row.lastTouched,
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

    func search(_ query: String) {
        store.searchQuery = query
        store.mindsSelected = false
    }

    static func dayString(_ d: Date) -> String { MindsDocument.dayString(d) }
    static func day(from iso: String) -> Date? { MindsDocument.day(from: iso) }
}
