import SwiftUI
import MindBusCore

/// 三个页面共用的取数上下文。
///
/// 页面组件只吃这一个值，不各自持有 `MindsStore`，也不各自解析 md——
/// `minds.md` 的格式是 `MindsBuilder` 单一真相，解析口子必须只有一处，
/// 否则 Builder 一改格式要满仓找调用点。
@MainActor
struct MindsContext {
    let store: ConversationStore
    /// 机械层 markdown（已剔除 WEAK SPOTS 之后的部分）
    let md: String
    let viz: MindsViz

    private var l10n: Strings { L10n.shared.s }
    var isZh: Bool { L10n.shared.isZh }

    // MARK: - 分节取行

    func lines(_ section: String) -> [String] {
        guard let start = md.range(of: "## \(section)\n") else { return [] }
        let rest = md[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func bullets(_ section: String) -> [String] {
        lines(section).filter { $0.hasPrefix("- ") }
    }

    func hasAny(_ names: String...) -> Bool {
        names.contains { !bullets($0).isEmpty }
    }

    // MARK: - 行解析

    /// 「名字 — 详情」同构行
    func parseRecurring(_ line: String) -> (word: String, detail: String)? {
        let body = String(line.dropFirst(2))
        guard let dash = body.range(of: " — ") else { return nil }
        return (String(body[..<dash.lowerBound]), String(body[dash.upperBound...]))
    }

    /// 「标题 — 详情 (id: x)」可点行
    func parseWithID(_ line: String) -> (id: String, label: String, meta: String)? {
        let body = String(line.dropFirst(2))
        guard let idRange = body.range(of: #"\(id: [^)]+\)$"#, options: .regularExpression)
        else { return nil }
        let id = String(body[idRange].dropFirst(5).dropLast(1))
        let front = body[..<idRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let dash = front.range(of: " — ", options: .backwards) else { return nil }
        return (id, String(front[..<dash.lowerBound]), String(front[dash.upperBound...]))
    }

    /// "- /path — 54 conversations, active A → B, last touched C"
    func parseProject(_ line: String) -> ProjectRow? {
        let body = String(line.dropFirst(2))
        guard let dash = body.range(of: " — ") else { return nil }
        let path = String(body[..<dash.lowerBound])
        let rest = String(body[dash.upperBound...])
        let count = Int(rest.split(separator: " ").first ?? "") ?? 0
        let dates = isoDates(in: rest)
        let span = dates.count >= 2
            ? "\(dates[0].dropFirst(5)) 至 \(dates[1].dropFirst(5))"
            : ""
        // 「last touched」在 md 里就有，之前被丢掉了；「最近活跃」列要用它
        let touched = firstGroup(rest, #"last touched (\d{4}-\d{2}-\d{2})"#) ?? dates.last
        return ProjectRow(path: path, name: (path as NSString).lastPathComponent,
                          count: count, span: span, lastTouched: touched.flatMap(Self.day(from:)),
                          active: dates.last.map { isRecent(iso: $0) } ?? false)
    }

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

    /// 「今天 / 3 天前」——最近活跃列。
    func relativeDay(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: date),
            to: Calendar.current.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return l10n.mRelToday }
        return l10n.mRelDaysAgo(days)
    }

    // MARK: - 文案化（md 里是英文机械行，GUI 单语显示）

    func dormantMeta(_ d: String) -> String {
        guard let m = twoGroups(d, #"(\d+) conversations, last touched (.+)"#) else { return d }
        return l10n.mDormantMeta(Int(m.0) ?? 0, m.1)
    }

    func fadedMeta(_ d: String) -> String {
        guard let m = twoGroups(d, #"said (\d+) times, silent (\d+) days"#) else { return d }
        return l10n.mFadedMeta(Int(m.0) ?? 0, Int(m.1) ?? 0)
    }

    /// 「5497 条消息 · 跨 64 天 · Atlas」
    func marathonMeta(_ d: String) -> String {
        if let m = threeGroups(d, #"(\d+) messages over (\d+) days, (.+)"#) {
            return l10n.mMarathonMeta(Int(m.0) ?? 0, l10n.mSpanDays(Int(m.1) ?? 0), m.2)
        }
        if let m = threeGroups(d, #"(\d+) messages over (\d+) h, (.+)"#) {
            return l10n.mMarathonMeta(Int(m.0) ?? 0, l10n.mSpanHours(Int(m.1) ?? 0), m.2)
        }
        return d
    }

    func vocabMeta(_ meta: String) -> String {
        if let m = twoGroups(meta, #"(\d+)×/(\d+)p"#) {
            return l10n.mVocabMindMeta(Int(m.0) ?? 0, Int(m.1) ?? 0)
        }
        if let n = Int(meta) { return l10n.mVocabWorkMeta(n) }
        return meta
    }

    func sourceName(_ raw: String) -> String {
        ConversationSource(rawValue: raw)?.displayName(isZh: isZh) ?? raw
    }

    /// "架构 (115×/15p) · 复用 (31×/9p)" → [(词, meta)]
    func chips(from flat: String) -> [(word: String, meta: String)] {
        flat.split(separator: "·").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let parts = t.split(separator: "(", maxSplits: 1)
            let word = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? t
            let meta = parts.count > 1
                ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ") ")) : ""
            return (word, meta)
        }
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

    // MARK: - 正则小工具

    func firstGroup(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    func twoGroups(_ text: String, _ pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text) else { return nil }
        return (String(text[r1]), String(text[r2]))
    }

    func threeGroups(_ text: String, _ pattern: String) -> (String, String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 4,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let r3 = Range(m.range(at: 3), in: text) else { return nil }
        return (String(text[r1]), String(text[r2]), String(text[r3]))
    }

    func firstInt(after prefix: String, in text: String) -> Int? {
        guard let r = text.range(of: prefix.isEmpty ? #"\d+"# : "\(prefix)\\d+",
                                 options: .regularExpression) else { return nil }
        return Int(text[r].drop(while: { !$0.isNumber }))
    }

    func isoDates(in text: String) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while let r = text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression,
                                 range: cursor..<text.endIndex) {
            out.append(String(text[r]))
            cursor = r.upperBound
        }
        return out
    }

    private func isRecent(iso: String) -> Bool {
        guard let d = Self.day(from: iso) else { return false }
        return abs(d.timeIntervalSinceNow) < 14 * 86_400
    }

    static func day(from iso: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
