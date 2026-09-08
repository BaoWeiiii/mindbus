import XCTest
@testable import MindBusCore

/// 思脉底座 · 机械层：`MindsBuilder` 从索引统计生成 `minds.md`。
///
/// 架构红线：全部用注入的临时路径，绝不碰真实 `~/.mindbus`——`setUpWithError` 把
/// `MINDBUS_MINDS_ROOT` 指向一个每次测试独立的临时目录，`tearDown` 清理干净。
final class MindsBuilderTests: XCTestCase {
    private var mindsRoot: String!
    private var refsLogURL: URL!

    override func setUpWithError() throws {
        mindsRoot = NSTemporaryDirectory() + "minds-builder-\(UUID().uuidString)"
        setenv("MINDBUS_MINDS_ROOT", mindsRoot, 1)
        refsLogURL = URL(fileURLWithPath: NSTemporaryDirectory() + "minds-builder-refs-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        unsetenv("MINDBUS_MINDS_ROOT")
        try? FileManager.default.removeItem(atPath: mindsRoot)
        try? FileManager.default.removeItem(at: refsLogURL)
    }

    /// 收藏文件隔离路径（不存在 → STARRED 空态）——build 不得读真实 ~/.mindbus。
    private let isolatedStarredURL = URL(fileURLWithPath:
        NSTemporaryDirectory() + "minds-starred-absent-\(UUID().uuidString).json")

    // MARK: - 构造助手

    private let gregorian = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
        return gregorian.date(from: c)!
    }

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "minds-builder-idx-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    /// 一次性造一条会话入库：lite + 单段 + entityText 三者共用同一份文字
    /// （同 `EntityIndexTests`/`LexRouteTests` 的省事写法——这些测试不关心实体/段的
    /// 口径差异，只关心 upsert 之后能查到什么）。
    @discardableResult
    private func upsertConversation(_ index: ConversationIndex, id: String, cwd: String,
                                    startAt: Date, endAt: Date? = nil,
                                    source: ConversationSource = .codex,
                                    text: String = "占位文字") throws -> ConversationLite {
        let lite = ConversationLite(id: id, source: source, startAt: startAt, endAt: endAt ?? startAt,
                                    cwd: cwd, gitBranch: nil, preview: "p", messageCount: 1,
                                    fileURL: URL(fileURLWithPath: "/tmp/minds-\(id).jsonl"))
        try index.upsert([(lite, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)],
                           1, text)])
        return lite
    }

    // MARK: - defaultMindsURL：根目录解析（MINDBUS_MINDS_ROOT 覆盖）

    func testDefaultMindsURLHonorsRootOverride() {
        let override = NSTemporaryDirectory() + "minds-url-override-\(UUID().uuidString)"
        setenv("MINDBUS_MINDS_ROOT", override, 1)
        XCTAssertEqual(MindsBuilder.defaultMindsURL.path, override + "/minds.md")
    }

    /// 纯空白 override 等同于未设置——回落到真实默认值。只做字符串比对，不触发任何
    /// 文件 I/O，所以不会碰到真实 `~/.mindbus`。
    func testDefaultMindsURLBlankOverrideFallsBackToRealDefaultPath() {
        setenv("MINDBUS_MINDS_ROOT", "   ", 1)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("minds", isDirectory: true)
            .appendingPathComponent("minds.md")
        XCTAssertEqual(MindsBuilder.defaultMindsURL.path, expected.path)
    }

    // MARK: - legacyWeakSpotsMarker：字面量钉住（读取方拿它截断旧文件遗留的增补节）

    func testLegacyWeakSpotsMarkerLiteralValue() {
        XCTAssertEqual(MindsBuilder.legacyWeakSpotsMarker, "<!-- weak-spots -->")
    }

    // MARK: - rankVocabulary：纯排序函数，≥3 字优先 + df 降序（变异反证核心）

    /// 长词优先于短词——即便短词 df 远高于长词。这是判别性最强的一条：如果实现退化成
    /// "整体按 df 排序、不分组"，2 字词会排到 3 字词前面，直接炸红。
    func testRankVocabularyPrefersLongWordsOverHigherDfShortWords() {
        let ranked = MindsBuilder.rankVocabulary(frequencies: ["短词": 100, "三字词": 5], limit: 20)
        XCTAssertEqual(ranked.map(\.word), ["三字词", "短词"], "≥3 字词必须排在 df 更高的 2 字词之前")
    }

    /// 组内按 df 降序——变异反证：把比较符从 `>` 改成 `<` 会让这条测试由绿转红
    /// （长词组内部顺序会整体反过来）。
    func testRankVocabularyDescendingWithinLongGroup() {
        let ranked = MindsBuilder.rankVocabulary(
            frequencies: ["低频三字词": 1, "高频三字词": 10, "中频三字词": 5], limit: 20)
        XCTAssertEqual(ranked.map(\.word), ["高频三字词", "中频三字词", "低频三字词"],
                       "长词组内部必须按 df 降序——改成升序这条测试必须变红")
    }

    /// 同一条反证也要在短词组内独立成立——两组各自排序，不是共用一次排序后偶然分组正确。
    func testRankVocabularyDescendingWithinShortGroup() {
        let ranked = MindsBuilder.rankVocabulary(frequencies: ["低频": 1, "高频": 10, "中频": 5], limit: 20)
        XCTAssertEqual(ranked.map(\.word), ["高频", "中频", "低频"],
                       "短词组内部也必须按 df 降序——改成升序这条测试必须变红")
    }

    /// 边界：恰好 3 字算"长"，不是 ">3"。2 字高 df 词仍必须排在 3 字低 df 词之后。
    /// 用字符数刻意可数的词（"二字"=2 字/"三字词"=3 字），不借助描述性前缀拼词——
    /// 早前一版把"高频"/"唯一"这类修饰语拼进词里，导致"看起来像 2 字词"的字符串
    /// 实际数出来是 4 字，本条测试的边界断言因此测的根本不是它自称要测的边界。
    func testRankVocabularyThreeCharBoundaryCountsAsLong() {
        XCTAssertEqual("二字".count, 2); XCTAssertEqual("三字词".count, 3)   // 前提自查，不能再数错一次
        let ranked = MindsBuilder.rankVocabulary(frequencies: ["二字": 50, "三字词": 1], limit: 20)
        XCTAssertEqual(ranked.map(\.word), ["三字词", "二字"], "恰好 3 字必须归入≥3字组，不是>3")
    }

    /// 长词不足 limit 时用短词按 df 降序补齐——不是"长词不够就整体放弃分组"。
    func testRankVocabularyFillsRemainderFromShortGroupWhenLongGroupInsufficient() {
        XCTAssertEqual("唯一词".count, 3); XCTAssertEqual("频高".count, 2); XCTAssertEqual("频低".count, 2)
        let ranked = MindsBuilder.rankVocabulary(
            frequencies: ["唯一词": 1, "频高": 9, "频低": 3], limit: 3)
        XCTAssertEqual(ranked.map(\.word), ["唯一词", "频高", "频低"])
    }

    /// limit 在两组拼接之后统一截断，不是"每组各截一半"。
    func testRankVocabularyLimitTruncatesAcrossBothGroups() {
        let freq = ["长词A": 5, "长词B": 4, "长词C": 3, "短A": 9, "短B": 8]
        let ranked = MindsBuilder.rankVocabulary(frequencies: freq, limit: 2)
        XCTAssertEqual(ranked.map(\.word), ["长词A", "长词B"], "只取长词组最前两个，不该混入短词")
    }

    /// 同组同 df 按词本身升序兜底，保证输出确定（字典遍历顺序不稳定）。
    func testRankVocabularyTiesBrokenByWordAscending() {
        let ranked = MindsBuilder.rankVocabulary(frequencies: ["丙三字词": 5, "甲三字词": 5, "乙三字词": 5],
                                                  limit: 20)
        XCTAssertEqual(ranked.map(\.word), ["丙三字词", "甲三字词", "乙三字词"].sorted())
    }

    /// `renderForInjection` 用 limit:10、`build` 用 limit:20——同一份 frequencies 下，
    /// 前者必须恰好是后者的前 10 个，不是另一套排序规则算出来的不同列表。
    func testRankVocabularyInjectionLimitIsPrefixOfDocumentLimit() {
        var freq: [String: Int] = [:]
        for i in 1...15 { freq["词条\(String(format: "%02d", i))"] = 100 - i }
        let top20 = MindsBuilder.rankVocabulary(frequencies: freq, limit: 20)
        let top10 = MindsBuilder.rankVocabulary(frequencies: freq, limit: 10)
        XCTAssertEqual(top10.map(\.word), Array(top20.prefix(10)).map(\.word))
    }

    // MARK: - ConversationIndex.lexiconWordFrequencies（新查询口）

    /// df = 出现该词的**段数**，不是出现次数——同一段里重复出现只算一次
    /// （`vocab_lex` 的 'row' 模式即"出现在几行/几段"，与 `topEntities` 的
    /// "出现在几个会话"是同一种"文档频率"哲学，但这里的"文档"是段不是会话）。
    /// 借"词表为空时退化成单字切分"这一已有行为（`PersonalLexicon.segment` 见其注释）
    /// 直接控制 `segments_fts_lex` 里出现哪些词元，不需要跑完整的词表构建启发式。
    func testLexiconWordFrequenciesCountsDistinctSegments() throws {
        let index = try makeIndex()
        try upsertConversation(index, id: "c1", cwd: "/p", startAt: date(2026, 5, 1), text: "见到甲")
        try upsertConversation(index, id: "c2", cwd: "/p", startAt: date(2026, 5, 2), text: "又见到甲甲甲")
        try upsertConversation(index, id: "c3", cwd: "/p", startAt: date(2026, 5, 3), text: "见到乙")

        let freqs = index.lexiconWordFrequencies(words: ["甲", "乙", "丙"])
        XCTAssertEqual(freqs["甲"], 2, "「甲」出现在 2 个不同段里（c2 里重复 3 次只算 1 段）")
        XCTAssertEqual(freqs["乙"], 1)
        XCTAssertNil(freqs["丙"], "从未出现的词不该出现在返回字典里")
    }

    /// 查询侧大小写不敏感：`vocab_lex` 的词元是 unicode61 casefold 后存的，
    /// 传入原始大小写的词也要能查到。
    func testLexiconWordFrequenciesIsCaseInsensitiveOnQuery() throws {
        let index = try makeIndex()
        try upsertConversation(index, id: "c1", cwd: "/p", startAt: date(2026, 5, 1),
                               text: "we shipped Widget today")
        let freqs = index.lexiconWordFrequencies(words: ["Widget"])
        XCTAssertEqual(freqs["Widget"], 1, "大小写不敏感查询失败——键仍应是原始传入的大小写")
    }

    func testLexiconWordFrequenciesEmptyWordListReturnsEmptyDict() throws {
        let index = try makeIndex()
        XCTAssertEqual(index.lexiconWordFrequencies(words: []), [:])
    }

    // MARK: - ConversationIndex.topReferenced（新查询口）

    func testTopReferencedOrdersByCountDescending() throws {
        let index = try makeIndex()
        for _ in 0..<3 { MCPRefLog.append(conversationID: "popular", to: refsLogURL) }
        MCPRefLog.append(conversationID: "rare", to: refsLogURL)
        index.ingestRefLog(from: refsLogURL)

        let top = index.topReferenced(limit: 10)
        XCTAssertEqual(top.map(\.id), ["popular", "rare"])
        XCTAssertEqual(top.first?.count, 3)
    }

    /// 同 `conversationIDs(for:limit:)` 的既有反证：MCP 层表达"不限"用 `Int.max`，
    /// 裸 `Int32(limit)` 转换会在这个值上运行时陷阱、整个进程 abort。
    func testTopReferencedWithIntMaxLimitDoesNotCrash() throws {
        let index = try makeIndex()
        MCPRefLog.append(conversationID: "a", to: refsLogURL)
        index.ingestRefLog(from: refsLogURL)
        XCTAssertEqual(index.topReferenced(limit: Int.max).map(\.id), ["a"])
    }

    func testTopReferencedEmptyWhenNoRefs() throws {
        let index = try makeIndex()
        XCTAssertEqual(index.topReferenced(limit: 10).count, 0)
    }

    // MARK: - MindsBuilder.projectRhythms：查询正确性

    /// 活跃期取首末 **startAt**；`lastTouched` 取最大 **endAt**——两者刻意不是同一个数字
    /// （见 `ProjectRhythm` 的文档注释）。这条测试专门构造"最后一场会话开始得早、
    /// 但聊到很晚"的场景，把两者的差异坐实。
    func testProjectRhythmsComputesActivePeriodAndLastTouched() throws {
        let index = try makeIndex()
        try upsertConversation(index, id: "c1", cwd: "/p/alpha",
                               startAt: date(2026, 5, 1, 10, 0), endAt: date(2026, 5, 1, 10, 30))
        try upsertConversation(index, id: "c2", cwd: "/p/alpha",
                               startAt: date(2026, 5, 10, 9, 0), endAt: date(2026, 5, 10, 11, 0))
        try upsertConversation(index, id: "c3", cwd: "/p/beta", startAt: date(2026, 6, 1, 8, 0))

        let rhythms = MindsBuilder.projectRhythms(index: index, projects: index.mapOverview().byProject)
        let alpha = try XCTUnwrap(rhythms.first { $0.cwd == "/p/alpha" })
        XCTAssertEqual(alpha.count, 2)
        XCTAssertEqual(alpha.activeStart, date(2026, 5, 1, 10, 0))
        XCTAssertEqual(alpha.activeEnd, date(2026, 5, 10, 9, 0), "活跃期末取最后一场的 startAt")
        XCTAssertEqual(alpha.lastTouched, date(2026, 5, 10, 11, 0), "last touched 取最大 endAt，不等于 activeEnd")

        let beta = try XCTUnwrap(rhythms.first { $0.cwd == "/p/beta" })
        XCTAssertEqual(beta.count, 1)
        XCTAssertEqual(beta.activeStart, beta.activeEnd)
        XCTAssertEqual(beta.lastTouched, date(2026, 6, 1, 8, 0))
    }

    // MARK: - renderDocument：纯渲染，六节顺序与格式（不碰索引/文件）

    private func emptyOverview(topEntities: [ConversationIndex.EntityStat] = []) -> ConversationIndex.MapOverview {
        ConversationIndex.MapOverview(conversationCount: 0, earliest: nil, latest: nil,
                                      bySource: [], byProject: [], byMonth: [], topEntities: topEntities)
    }

    func testRenderDocumentSectionsAppearInFixedOrder() {
        let overview = ConversationIndex.MapOverview(
            conversationCount: 3, earliest: date(2026, 5, 1), latest: date(2026, 6, 1),
            bySource: [.init(key: "codex", count: 2), .init(key: "claudeCode", count: 1)],
            byProject: [], byMonth: [],
            topEntities: [.init(text: "Foo", kind: "identifier", conversationCount: 2)])
        let text = MindsBuilder.renderDocument(overview: overview, projects: [], vocabulary: [], refs: [],
                                               builtAt: date(2026, 8, 10))

        let headings = ["## OVERVIEW", "## PROJECT RHYTHM", "## VOCABULARY"]
        let positions = try! headings.map { heading -> String.Index in
            try XCTUnwrap(text.range(of: heading)?.lowerBound)
        }
        XCTAssertEqual(positions, positions.sorted(), "统计区标题必须按固定顺序出现")
        XCTAssertFalse(text.contains("WEAK SPOTS"), "增补节已拆除，渲染里不得再出现")
    }

    func testRenderDocumentHeaderCarriesPolicyVersionAndBuildDate() {
        let text = MindsBuilder.renderDocument(overview: emptyOverview(), projects: [], vocabulary: [], refs: [],
                                               builtAt: date(2026, 8, 10))
        XCTAssertTrue(text.contains("# Minds — mechanical self-description"))
        XCTAssertTrue(text.contains("policy v\(ConversationIndex.dataPolicyVersion)"))
        XCTAssertTrue(text.contains("rebuilt 2026-08-10"))
    }

    func testRenderDocumentOverviewReflectsStats() {
        let overview = ConversationIndex.MapOverview(
            conversationCount: 141, earliest: date(2026, 4, 24), latest: date(2026, 8, 10),
            bySource: [.init(key: "codex", count: 100), .init(key: "claudeCode", count: 40),
                      .init(key: "claudeAgent", count: 1)],
            byProject: [], byMonth: [], topEntities: [])
        let text = MindsBuilder.renderDocument(overview: overview, projects: [], vocabulary: [], refs: [],
                                               builtAt: date(2026, 8, 10))
        XCTAssertTrue(text.contains("141 conversations across 3 tools, 2026-04-24 → 2026-08-10."))
        XCTAssertTrue(text.contains("(mechanical, 141 conversations)"))
        XCTAssertTrue(text.contains("codex 100 · claudeCode 40 · claudeAgent 1"))
    }

    /// 空库（0 会话）必须仍是合法、诚实的一句话——不崩、不印 "? → ?" 半截模板。
    func testRenderDocumentOverviewEmptyLibraryIsLegal() {
        let text = MindsBuilder.renderDocument(overview: emptyOverview(), projects: [], vocabulary: [], refs: [],
                                               builtAt: date(2026, 8, 10))
        XCTAssertTrue(text.contains("0 conversations across 0 tools. (mechanical, 0 conversations)"))
        XCTAssertFalse(text.contains("→"), "空库没有日期区间可言，不该印出箭头")
    }

    func testRenderDocumentProjectRhythmRendersEachProject() {
        let projects = [
            MindsBuilder.ProjectRhythm(cwd: "/p/alpha", count: 54, messages: 6027,
                                       activeStart: date(2026, 5, 2), activeEnd: date(2026, 8, 9),
                                       lastTouched: date(2026, 8, 10)),
        ]
        let text = MindsBuilder.renderDocument(overview: emptyOverview(), projects: projects, vocabulary: [],
                                               refs: [], builtAt: date(2026, 8, 10))
        XCTAssertTrue(text.contains(
            "- /p/alpha — 54 conversations, 6027 messages, active 2026-05-02 → 2026-08-09, last touched 2026-08-10"))
    }

    func testRenderDocumentProjectRhythmEmptyShowsPlaceholder() {
        let text = MindsBuilder.renderDocument(overview: emptyOverview(), projects: [], vocabulary: [], refs: [],
                                               builtAt: date(2026, 8, 10))
        XCTAssertTrue(text.contains("## PROJECT RHYTHM\nTop 0 projects by conversation count. (mechanical, 0 projects)\n(none yet)"))
    }


    /// VOCABULARY 带「词 (N)」计数（2026-08-12 反转旧骨架的「不带计数」决定）：
    /// 「counted, not generated」的可信度要落到每个词上——用户看到「第一性原理 (25)」
    /// 才知道这数字真是数出来的；N 从 v14 起是 user 语料里的**说过次数**（tf）。
    func testRenderDocumentVocabularyRendersWordsWithCounts() {
        let text = MindsBuilder.renderDocument(overview: emptyOverview(), projects: [],
                                               vocabulary: [("输入框", 12), ("智能体", 9)], refs: [],
                                               builtAt: date(2026, 8, 10))
        // 新口径带跨项目数(2026-08-16 一组化):"词 (次数×/项目数p)"
        XCTAssertTrue(text.contains("输入框 (12×/0p) · 智能体 (9×/0p)"), "词要带说过的次数")
    }

    /// 总次数覆盖全部引用（哪怕超过 5 条），但 Top 列表只列前 5——两个数字不该混淆。


    // MARK: - renderForInjection：CLAUDE.md 注入（机械紧凑版）

    /// 增补层拆除后注入文本必须是纯机械——不得再有 Confirmed 段或任何模型条目痕迹。
    func testRenderForInjectionIsPureMechanical() throws {
        let index = try makeIndex()
        let output = MindsBuilder.renderForInjection(index: index)
        XCTAssertFalse(output.contains("## Confirmed"))
        XCTAssertFalse(output.contains("spot:"))
    }

    func testRenderForInjectionIncludesOverviewOneLineAndCompactSections() throws {
        let index = try makeIndex()
        try upsertConversation(index, id: "c1", cwd: "/p", startAt: date(2026, 5, 1),
                               text: "AlphaWidget shipped")
        let output = MindsBuilder.renderForInjection(index: index)
        XCTAssertTrue(output.contains("1 conversations across 1 tools"))
        XCTAssertTrue(output.contains("(mechanical, 1 conversations)"))
        XCTAssertTrue(output.contains("## Top entities"))
        XCTAssertTrue(output.contains("AlphaWidget (1)"))
        XCTAssertTrue(output.contains("## Vocabulary"))
    }

    /// 前 10 而非前 20——从与 `build()` 同一份 `mapOverview().topEntities` 派生期望值，
    /// 不假设任何具体的并列 tie-break 顺序，只锁"恰好截到第 10 个"这件事本身。
    func testRenderForInjectionCapsEntitiesAtTenNotTwenty() throws {
        let index = try makeIndex()
        // 实体正则要求至少两个大写起首的驼峰段（`(?:[A-Z][a-z0-9]+)+` 至少重复一次）——
        // "Entity01" 这类"字母+数字"只算一段，压根不匹配；用第二个真正的单词段
        // （"ItemOne"/"ItemTwo"/…）才是合法的驼峰标识符。
        let words = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven"]
        for (i, word) in words.enumerated() {
            try upsertConversation(index, id: "c\(i)", cwd: "/p", startAt: date(2026, 5, i + 1),
                                   text: "Item\(word) mentioned here")
        }
        let allTop = index.mapOverview().topEntities
        XCTAssertEqual(allTop.count, 11, "前提：11 个候选实体全部入选（未被样板压制吃掉）")
        let included = Array(allTop.prefix(10)).map(\.text)
        let excluded = Array(allTop.dropFirst(10)).map(\.text)

        let output = MindsBuilder.renderForInjection(index: index)
        for text in included { XCTAssertTrue(output.contains(text), "\(text) 应在前 10 之内") }
        for text in excluded { XCTAssertFalse(output.contains(text), "\(text) 应被前 10 截断排除") }
    }

    // MARK: - build(from:to:)：端到端（真实索引 + 落盘）

    func testBuildProducesAllSixSectionsWithMatchingStatsAndAtomicWriteIsRereadable() throws {
        let index = try makeIndex()
        try upsertConversation(index, id: "c1", cwd: "/p/alpha",
                               startAt: date(2026, 5, 1, 10, 0), endAt: date(2026, 5, 1, 10, 30),
                               source: .codex, text: "AlphaWidget shipped")
        try upsertConversation(index, id: "c2", cwd: "/p/alpha",
                               startAt: date(2026, 5, 10, 9, 0), endAt: date(2026, 5, 10, 11, 0),
                               source: .codex, text: "AlphaWidget again")
        try upsertConversation(index, id: "c3", cwd: "/p/beta",
                               startAt: date(2026, 6, 1, 8, 0), endAt: date(2026, 6, 1, 8, 15),
                               source: .claudeCode, text: "BetaThing shipped")
        for _ in 0..<3 { MCPRefLog.append(conversationID: "c1", to: refsLogURL) }
        MCPRefLog.append(conversationID: "c3", to: refsLogURL)
        index.ingestRefLog(from: refsLogURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: MindsBuilder.defaultMindsURL.path),
                       "前提：build 之前文件不存在")
        MindsBuilder.build(from: index)
        let content = try String(contentsOf: MindsBuilder.defaultMindsURL, encoding: .utf8)

        // 统计区顺序(2026-08-16 收敛:TOP ENTITIES/AGENT USAGE 已砍;增补节 2026-09-01 拆除)
        let headings = ["## OVERVIEW", "## PROJECT RHYTHM", "## VOCABULARY"]
        let positions = try headings.map { try XCTUnwrap(content.range(of: $0)?.lowerBound) }
        XCTAssertEqual(positions, positions.sorted())

        // OVERVIEW
        XCTAssertTrue(content.contains("3 conversations across 2 tools, 2026-05-01 → 2026-06-01."))
        XCTAssertTrue(content.contains("codex 2 · claudeCode 1"))

        // PROJECT RHYTHM
        XCTAssertTrue(content.contains(
            "- /p/alpha — 2 conversations, 2 messages, active 2026-05-01 → 2026-05-10, last touched 2026-05-10"))
        XCTAssertTrue(content.contains(
            "- /p/beta — 1 conversations, 1 messages, active 2026-06-01 → 2026-06-01, last touched 2026-06-01"))

        // 增补节已拆除：全文不得再出现 WEAK SPOTS 或旧分隔标记
        XCTAssertFalse(content.contains("WEAK SPOTS"))
        XCTAssertFalse(content.contains(MindsBuilder.legacyWeakSpotsMarker))
    }

    /// 空库（0 会话）也要生成合法文件，不崩、各节落空态文案。
    func testBuildEmptyLibraryProducesLegalFile() throws {
        let index = try makeIndex()
        MindsBuilder.build(from: index)
        let content = try String(contentsOf: MindsBuilder.defaultMindsURL, encoding: .utf8)

        XCTAssertTrue(content.contains("0 conversations across 0 tools. (mechanical, 0 conversations)"))
        XCTAssertTrue(content.contains("Top 0 projects by conversation count."))
        XCTAssertTrue(content.contains("Your lexicon, counted in your own messages"))
        XCTAssertFalse(content.contains("WEAK SPOTS"))
    }

    func testBuildCreatesMissingDirectory() throws {
        let index = try makeIndex()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mindsRoot), "前提：根目录尚不存在")
        MindsBuilder.build(from: index)
        XCTAssertTrue(FileManager.default.fileExists(atPath: MindsBuilder.defaultMindsURL.path))
    }

    /// 原子写 = 整体替换，不是追加——重建后旧内容必须完全消失,不是新旧内容拼在一起。
    func testBuildOverwritesPreviousContentOnRebuild() throws {
        let index = try makeIndex()
        try upsertConversation(index, id: "c1", cwd: "/p", startAt: date(2026, 5, 1), text: "第一版")
        MindsBuilder.build(from: index)
        let first = try String(contentsOf: MindsBuilder.defaultMindsURL, encoding: .utf8)
        XCTAssertTrue(first.contains("1 conversations across 1 tools"))

        try upsertConversation(index, id: "c2", cwd: "/p", startAt: date(2026, 5, 2), text: "第二版")
        MindsBuilder.build(from: index)
        let second = try String(contentsOf: MindsBuilder.defaultMindsURL, encoding: .utf8)
        XCTAssertTrue(second.contains("2 conversations across 1 tools"))
        XCTAssertFalse(second.contains("1 conversations across 1 tools"),
                       "重建必须整体替换——旧的会话计数陈述不该继续留在文件里")
    }

    /// 增补层拆除后，build 不得读取 enriched.jsonl——即便磁盘上留有旧日志文件，
    /// 里面的模型条目也绝不能再进入 minds.md。
    func testBuildIgnoresLeftoverEnrichedLog() throws {
        let index = try makeIndex()
        try FileManager.default.createDirectory(atPath: mindsRoot, withIntermediateDirectories: true)
        let leftover = #"{"kind":"enrich","id":"e1","spot":"spot:goals","text":"MODEL-WRITTEN-LEFTOVER","sources":["c1"],"agent":"claude-code","ts":1700000000}"#
        try Data((leftover + "\n").utf8).write(to: URL(fileURLWithPath: mindsRoot + "/enriched.jsonl"))

        MindsBuilder.build(from: index)
        let content = try String(contentsOf: MindsBuilder.defaultMindsURL, encoding: .utf8)
        XCTAssertFalse(content.contains("MODEL-WRITTEN-LEFTOVER"))
    }

    /// PROJECT RHYTHM 截前 10——用 11 个并列（各 1 会话）的项目，期望值从 `build()`
    /// 内部同一条 `mapOverview().byProject` 查询派生，不依赖具体并列 tie-break 顺序。
    func testBuildCapsProjectRhythmAtTenProjects() throws {
        let index = try makeIndex()
        for i in 1...11 {
            try upsertConversation(index, id: "c\(i)", cwd: "/p/proj-\(String(format: "%02d", i))",
                                   startAt: date(2026, 5, i))
        }
        let allProjects = index.mapOverview().byProject
        XCTAssertEqual(allProjects.count, 11)
        let included = Array(allProjects.prefix(10)).map(\.key)
        let excluded = Array(allProjects.dropFirst(10)).map(\.key)

        MindsBuilder.build(from: index)
        let content = try String(contentsOf: MindsBuilder.defaultMindsURL, encoding: .utf8)
        for cwd in included { XCTAssertTrue(content.contains(cwd), "\(cwd) 应在前 10 之内") }
        for cwd in excluded { XCTAssertFalse(content.contains(cwd), "\(cwd) 应被前 10 截断排除") }
    }
}

// MARK: - 「什么算项目」必须处处一致（2026-08-18）

extension MindsBuilderTests {

    /// 修「家目录被当成项目」时踩到的：项目节奏过滤了，项目杠杆与周末人格没过滤，
    /// 于是「项目榜里没有家目录、杠杆榜第一名却是 home」。
    /// 这一条锁住三处用同一个判据。
    func testProjectFilterAppliesToLeverageAndWeekendToo() throws {
        let index = try makeIndex()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // 项目杠杆要 join user_corpus，所以这里必须用带 userText 的那个重载——
        // `upsertConversation` 助手走的是 userText 为空的四元组版本，杠杆查不到东西
        func put(_ id: String, cwd: String, day: Int) throws {
            let at = date(2026, 8, day)
            let lite = ConversationLite(id: id, source: .codex, startAt: at, endAt: at,
                                       cwd: cwd, gitBranch: nil, preview: "p", messageCount: 2,
                                       fileURL: URL(fileURLWithPath: "/tmp/pf-\(id).jsonl"))
            let text = "这一场里用户说的话 \(id)"
            try index.upsert([(lite: lite,
                               segments: [Segmenter.Segment(firstMessageIndex: 0,
                                                            lastMessageIndex: 0, text: text)],
                               mtime: 1, entityText: text, userText: text, lastRole: "user")])
        }
        try put("h1", cwd: home, day: 3)
        try put("h2", cwd: home, day: 4)
        try put("c1", cwd: home + "/.claude/plugins/cache/x", day: 5)
        try put("c2", cwd: home + "/.claude/plugins/cache/x", day: 6)
        try put("p1", cwd: home + "/dev/mindbus", day: 7)
        try put("p2", cwd: home + "/dev/mindbus", day: 8)

        let leverage = index.projectLeverage(minConversations: 2, limit: 10).map(\.name)
        XCTAssertTrue(leverage.contains("mindbus"), "前提：真项目要能算出杠杆，\(leverage)")
        XCTAssertFalse(leverage.contains("home"), "家目录不该进项目杠杆榜：\(leverage)")
        XCTAssertFalse(leverage.contains("x"), "插件缓存不该进项目杠杆榜：\(leverage)")

        let split = index.weekendSplit(minCount: 1)
        let keys = (split.weekday + split.weekend).map(\.key)
        XCTAssertTrue(keys.contains("mindbus"), keys.description)
        XCTAssertFalse(keys.contains("home"), "家目录不该进周末人格：\(keys)")
        XCTAssertFalse(keys.contains("x"), "插件缓存不该进周末人格：\(keys)")
    }
}
