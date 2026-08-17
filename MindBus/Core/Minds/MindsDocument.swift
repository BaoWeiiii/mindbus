import Foundation

/// `minds.md` 机械层的**读端**。
///
/// 存在理由：写端是同目录的 `MindsBuilder.renderDocument`。两端隔着一个 App target
/// 各写各的时候，格式一改就是「Builder 绿、界面空白」——而界面里的解析散在
/// 十几个 View 的 `private func` 里，既测不到也没人能一眼看全。把读端搬到写端旁边，
/// 一处改格式两处一起炸，回归测试也能直接跑 render → parse 往返。
///
/// 这一层是纯的：不碰 SwiftUI、不碰 L10n、不读时钟（需要「今天」的一律由调用方传）。
/// 文案化（把 `54 conversations` 说成「54 场对话」）留在界面层，那是展示不是解析。
public struct MindsDocument: Sendable {

    public let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    // MARK: - 分节

    /// 取某节的所有非空行（不含 `## 节名` 那行本身）。
    public func lines(_ section: String) -> [String] {
        guard let start = markdown.range(of: "## \(section)\n") else { return [] }
        let rest = markdown[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// 只取 `- ` 开头的数据行。节里的第一行是说明句，不是数据。
    public func bullets(_ section: String) -> [String] {
        lines(section).filter { $0.hasPrefix("- ") }
    }

    /// 这些节里有没有任何一节能渲出内容——决定分组标题出不出。
    public func hasAny(_ sections: [String]) -> Bool {
        sections.contains { !bullets($0).isEmpty }
    }

    // MARK: - 通用行形态

    /// 「名字 — 详情」。沉睡项目 / 不再说的词 / 项目杠杆都是这个形态。
    public func namedDetail(_ line: String) -> (name: String, detail: String)? {
        guard line.hasPrefix("- ") else { return nil }
        let body = String(line.dropFirst(2))
        guard let dash = body.range(of: " — ") else { return nil }
        return (String(body[..<dash.lowerBound]), String(body[dash.upperBound...]))
    }

    /// 「标题 — 详情 (id: x)」。马拉松对话这类可点行。
    /// `id` 在行尾，先摘掉它再从**右边**找分隔符——标题里本身可能含 " — "。
    public func identified(_ line: String) -> (id: String, label: String, meta: String)? {
        guard line.hasPrefix("- ") else { return nil }
        let body = String(line.dropFirst(2))
        guard let idRange = body.range(of: #"\(id: [^)]+\)$"#, options: .regularExpression)
        else { return nil }
        let id = String(body[idRange].dropFirst(5).dropLast(1))
        let front = body[..<idRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let dash = front.range(of: " — ", options: .backwards) else { return nil }
        return (id, String(front[..<dash.lowerBound]), String(front[dash.upperBound...]))
    }

    // MARK: - 项目节奏

    public struct ProjectRow: Equatable, Sendable {
        public let path: String
        /// 路径末段——界面上显示的项目名
        public let name: String
        /// 会话场数
        public let count: Int
        /// 消息总数。条形按它画——场数不代表投入（54 场 6027 条 vs 4 场 7914 条）。
        /// 旧文档没有这一段时为 0，调用方回退到场数。
        public let messages: Int
        public let activeStart: Date?
        public let activeEnd: Date?
        /// 「最近活跃」列用它。md 里一直有，只是以前解析时被丢了。
        public let lastTouched: Date?

        /// 近 `window` 天有动静。判「活跃中」徽标用，时钟由调用方给。
        public func isActive(now: Date, window: TimeInterval = 14 * 86_400) -> Bool {
            guard let activeEnd else { return false }
            return now.timeIntervalSince(activeEnd) < window && now >= activeEnd
        }
    }

    /// "- /path — 54 conversations, 6027 messages, active 2026-05-15 → 2026-08-10, last touched 2026-08-12"
    public func project(_ line: String) -> ProjectRow? {
        guard let (path, rest) = namedDetail(line) else { return nil }
        let count = Int(rest.split(separator: " ").first ?? "") ?? 0
        // `N messages` 是 2026-08-18 才加的段；旧文档缺它时给 0，读端不报错
        let messages = Self.captures(rest, #"(\d+) messages"#).first.flatMap { Int($0) } ?? 0
        let dates = Self.isoDates(in: rest)
        // `active A → B` 与 `last touched C` 分开取:三者都可能缺，
        // 按位置猜会在缺一个的时候把日期串位。
        let active = Self.captures(rest, #"active (\d{4}-\d{2}-\d{2}) → (\d{4}-\d{2}-\d{2})"#)
        let touched = Self.captures(rest, #"last touched (\d{4}-\d{2}-\d{2})"#)
        return ProjectRow(
            path: path,
            name: (path as NSString).lastPathComponent,
            count: count,
            messages: messages,
            activeStart: active.count >= 2 ? Self.day(from: active[0]) : dates.first.flatMap(Self.day(from:)),
            activeEnd: active.count >= 2 ? Self.day(from: active[1]) : nil,
            lastTouched: touched.first.flatMap(Self.day(from:)) ?? dates.last.flatMap(Self.day(from:)))
    }

    public func projects() -> [ProjectRow] {
        bullets("PROJECT RHYTHM").compactMap(project)
    }

    // MARK: - 委托动词 / 提问形状

    public struct DelegationVerb: Equatable, Sendable {
        public let verb: String
        public let count: Int
        public let conversations: Int
    }

    /// "- 优化 118×/27c · 设计 106×/21c · …"
    /// 同节里还有一条 `- research destination …`，那条不是动词行。
    public func delegationVerbs() -> [DelegationVerb] {
        guard let line = bullets("DELEGATION").first(where: { !$0.hasPrefix("- research") })
        else { return [] }
        var out: [DelegationVerb] = []
        for part in line.dropFirst(2).split(separator: "·") {
            let t = part.trimmingCharacters(in: .whitespaces)
            // 动词可能含空格，所以从最后一个空格切，右边才是 `118×/27c`
            guard let sp = t.lastIndex(of: " ") else { continue }
            let nums = t[t.index(after: sp)...].split(separator: "×")
            guard nums.count == 2, let n = Int(nums[0]),
                  let c = Int(nums[1].dropFirst().dropLast()) else { continue }
            out.append(DelegationVerb(verb: String(t[..<sp]), count: n, conversations: c))
        }
        return out
    }

    /// "- research destination #1: github (19 of your 调研 orders; …"
    public func researchDestination() -> (destination: String, count: Int)? {
        guard let line = bullets("DELEGATION").first(where: { $0.hasPrefix("- research destination") })
        else { return nil }
        let g = Self.captures(line, #"#1: (\S+) \((\d+)"#)
        guard g.count >= 2, let n = Int(g[1]) else { return nil }
        return (g[0], n)
    }

    /// "- should-we 286 · how-to 206 · why 94 · what-is 89"
    /// md 里是固定类别序；按数值降序返回——条形图要读成「排行」。
    public func questionShape() -> [(kind: String, count: Int)] {
        guard let line = bullets("QUESTION SHAPE").first else { return [] }
        return line.dropFirst(2).split(separator: "·").compactMap { part -> (String, Int)? in
            let t = part.trimmingCharacters(in: .whitespaces)
            guard let sp = t.lastIndex(of: " "), let n = Int(t[t.index(after: sp)...]) else { return nil }
            return (String(t[..<sp]), n)
        }.sorted { $0.1 > $1.1 }
    }

    // MARK: - 词条

    public struct Chip: Equatable, Sendable {
        public let word: String
        /// 括号里的原始 meta（`115×/15p` 或 `87`），文案化留给界面层
        public let meta: String
    }

    /// "架构 (115×/15p) · 复用 (31×/9p)" → 词条数组
    public func chips(from flat: String) -> [Chip] {
        flat.split(separator: "·").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let parts = t.split(separator: "(", maxSplits: 1)
            let word = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? t
            let meta = parts.count > 1
                ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ") ")) : ""
            return Chip(word: word, meta: meta)
        }
    }

    /// 常用词 / 反复说的话共用一个形态，都在各自节的第一条 bullet 里
    public func chipRow(_ section: String) -> [Chip] {
        bullets(section).first.map { chips(from: String($0.dropFirst(2))) } ?? []
    }

    /// 口头禅是「继续 ×251 · push ×33」——分隔符是 `×` 不是括号
    public func catchphrases() -> [(phrase: String, count: Int)] {
        guard let line = bullets("CATCHPHRASES").first(where: { !$0.contains("politeness") })
        else { return [] }
        return line.dropFirst(2).split(separator: "·").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: "×", maxSplits: 1)
            guard parts.count == 2,
                  let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return (parts[0].trimmingCharacters(in: .whitespaces), n)
        }
    }

    /// "- politeness & delegation: 帮我 ×30 · please ×12"
    public func politenessLine() -> String? {
        bullets("CATCHPHRASES").first(where: { $0.contains("politeness") })
            .map {
                String($0.dropFirst(2))
                    .replacingOccurrences(of: "politeness & delegation: ", with: "")
                    .replacingOccurrences(of: " ×", with: " ")
                    .replacingOccurrences(of: " · ", with: "、")
            }
    }

    // MARK: - 详情行的结构化抽取
    //
    // 界面要把这些英文机械行说成中文。抽取放在这里、文案留在界面层——
    // 抽取的正则必须与写端逐字对齐，对不上时界面会静默显示英文原文
    // （不报错、不空白，最难发现的一种），所以它必须被测试盯着。

    /// "12 conversations, last touched 2026-07-18"
    public func dormantDetail(_ detail: String) -> (conversations: Int, lastTouched: String)? {
        let g = Self.captures(detail, #"(\d+) conversations, last touched (.+)"#)
        guard g.count >= 2, let n = Int(g[0]) else { return nil }
        return (n, g[1])
    }

    /// "said 92 times, silent 96 days"
    public func fadedDetail(_ detail: String) -> (said: Int, silentDays: Int)? {
        let g = Self.captures(detail, #"said (\d+) times, silent (\d+) days"#)
        guard g.count >= 2, let a = Int(g[0]), let b = Int(g[1]) else { return nil }
        return (a, b)
    }

    public enum MarathonSpan: Equatable, Sendable {
        case days(Int)
        case hours(Int)
    }

    /// "5497 messages over 64 days, Atlas" / "… over 5 h, X"
    public func marathonDetail(_ detail: String) -> (messages: Int, span: MarathonSpan, project: String)? {
        let d = Self.captures(detail, #"(\d+) messages over (\d+) days, (.+)"#)
        if d.count >= 3, let m = Int(d[0]), let n = Int(d[1]) {
            return (m, .days(n), d[2])
        }
        let h = Self.captures(detail, #"(\d+) messages over (\d+) h, (.+)"#)
        if h.count >= 3, let m = Int(h[0]), let n = Int(h[1]) {
            return (m, .hours(n), h[2])
        }
        return nil
    }

    public enum ChipMeta: Equatable, Sendable {
        /// "475×/13p" —— 次数 + 覆盖项目数
        case timesAndProjects(times: Int, projects: Int)
        /// "87" —— 只有次数
        case times(Int)
        /// 认不出来，原样显示
        case raw(String)
    }

    public static func chipMeta(_ meta: String) -> ChipMeta {
        let g = captures(meta, #"^(\d+)×/(\d+)p$"#)
        if g.count >= 2, let t = Int(g[0]), let p = Int(g[1]) {
            return .timesAndProjects(times: t, projects: p)
        }
        if let n = Int(meta) { return .times(n) }
        return .raw(meta)
    }

    // MARK: - 数值抽取

    /// 「说过 92 次，沉默 96 天」这类：从详情里按前缀取第一个整数。
    /// 前缀为空时取行内第一个整数。
    public static func firstInt(after prefix: String, in text: String) -> Int? {
        guard let r = text.range(of: prefix.isEmpty ? #"\d+"# : "\(NSRegularExpression.escapedPattern(for: prefix))\\d+",
                                 options: .regularExpression) else { return nil }
        return Int(text[r].drop(while: { !$0.isNumber }))
    }

    /// 行内出现的所有 ISO 日期，按出现顺序。
    public static func isoDates(in text: String) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while let r = text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression,
                                 range: cursor..<text.endIndex) {
            out.append(String(text[r]))
            cursor = r.upperBound
        }
        return out
    }

    /// 取第一处匹配的全部捕获组（按组号顺序）。匹配不上返回空数组。
    public static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return [] }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - 日期

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func day(from iso: String) -> Date? { isoFormatter.date(from: iso) }
    public static func dayString(_ d: Date) -> String { isoFormatter.string(from: d) }

    /// 「今天 / N 天前」的 N。负数（未来日期）夹到 0。
    public static func daysAgo(_ date: Date, now: Date, calendar: Calendar = .current) -> Int {
        let d = calendar.dateComponents([.day],
                                        from: calendar.startOfDay(for: date),
                                        to: calendar.startOfDay(for: now)).day ?? 0
        return max(0, d)
    }
}
