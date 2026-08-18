import XCTest
@testable import MindBusCore

/// `minds.md` 读端的契约测试。
///
/// 这些用例的价值在于：界面上「某一节忽然空了」的故障，过去只能靠肉眼看渲染图
/// 发现，而根因几乎总是格式与解析对不上。把每种行形态钉在这里，Builder 一改格式
/// 就会红。
final class MindsDocumentTests: XCTestCase {

    // MARK: - 分节

    private let sample = """
    # Minds — mechanical self-description
    > counted, not generated. (policy v17, rebuilt 2026-08-17)

    ## SANCTUARY
    What this library holds for you. (mechanical)
    - 150 conversations · 150 archived copies (341 MB) · day 115 of your library

    ## DORMANT PROJECTS
    Heavy investments untouched for 30+ days. (mechanical, 1 projects)
    - StrategyGame — 54 conversations, last touched 2026-07-18

    ## QUESTION SHAPE
    Openers, counted. (mechanical)
    - should-we 148 · how-to 195 · why 79 · what-is 100

    ## DELEGATION
    What you ask AI to do. (mechanical, 3 verbs)
    - 优化 118×/27c · 设计 106×/21c · 开发 60×/21c
    - research destination #1: github (19 of your 调研 orders; then 产品 16)

    ## CATCHPHRASES
    Short messages you send again and again. (mechanical, 3 phrases)
    - 继续 ×251 · push ×33 · 全量 P0 做 ×7
    - politeness & delegation: 帮我 ×30 · please ×12

    ## MARATHONS
    Longest conversations. (mechanical)
    - 继续 — 5497 messages over 64 days, Atlas (id: conv-1)
    - 检查 — 5145 messages over 6 h, Beacon (id: conv-2)

    ## PROJECT RHYTHM
    Top projects. (mechanical, 2 projects)
    - /Users/me/dev/mindbus — 12 conversations, active 2026-08-01 → 2026-08-15, last touched 2026-08-15
    - /Users/me/dev/Codex — 7 conversations, active 2026-05-08 → 2026-06-09, last touched 2026-06-09

    ## VOCABULARY
    Words you keep saying. (mechanical, 3 terms)
    - 选择 (475×/13p) · 节点 (444×/10p) · 仓库 (353×/14p)

    ## FADED WORDS
    Words you used to say a lot. (mechanical, 1 words)
    - 诊断 — said 92 times, silent 96 days
    """

    private var doc: MindsDocument { MindsDocument(markdown: sample) }

    func testSectionLinesExcludeHeadingAndKeepProse() {
        let lines = doc.lines("DORMANT PROJECTS")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Heavy investments"))
        XCTAssertTrue(lines[1].hasPrefix("- StrategyGame"))
    }

    func testBulletsDropProseLine() {
        XCTAssertEqual(doc.bullets("DORMANT PROJECTS").count, 1)
    }

    func testMissingSectionIsEmptyNotCrash() {
        XCTAssertTrue(doc.lines("NO SUCH SECTION").isEmpty)
        XCTAssertTrue(doc.bullets("NO SUCH SECTION").isEmpty)
    }

    /// 节名是前缀关系时不能串台（`PROJECT RHYTHM` 不该被 `PROJECT` 命中）
    func testSectionLookupIsExact() {
        XCTAssertTrue(doc.lines("PROJECT").isEmpty)
        XCTAssertFalse(doc.lines("PROJECT RHYTHM").isEmpty)
    }

    func testLastSectionReadsToEndOfFile() {
        XCTAssertEqual(doc.bullets("FADED WORDS").count, 1)
    }

    func testHasAny() {
        XCTAssertTrue(doc.hasAny(["NOPE", "VOCABULARY"]))
        XCTAssertFalse(doc.hasAny(["NOPE", "ALSO NOPE"]))
    }

    // MARK: - 行形态

    func testNamedDetail() {
        let r = doc.namedDetail("- 诊断 — said 92 times, silent 96 days")
        XCTAssertEqual(r?.name, "诊断")
        XCTAssertEqual(r?.detail, "said 92 times, silent 96 days")
    }

    func testNamedDetailRejectsNonBullet() {
        XCTAssertNil(doc.namedDetail("诊断 — said 92 times"))
    }

    func testNamedDetailRejectsLineWithoutSeparator() {
        XCTAssertNil(doc.namedDetail("- 诊断 said 92 times"))
    }

    func testIdentifiedSplitsFromTheRight() {
        // 标题本身含 " — " 时，必须从右边切，否则标题会被腰斩
        let r = doc.identified("- A — B — 5497 messages over 64 days, Atlas (id: conv-1)")
        XCTAssertEqual(r?.id, "conv-1")
        XCTAssertEqual(r?.label, "A — B")
        XCTAssertEqual(r?.meta, "5497 messages over 64 days, Atlas")
    }

    func testIdentifiedRequiresTrailingID() {
        XCTAssertNil(doc.identified("- 继续 — 5497 messages (id: x) 还有别的"))
    }

    // MARK: - 项目行

    func testProjectRowParsesAllThreeDates() {
        let rows = doc.projects()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "mindbus")
        XCTAssertEqual(rows[0].path, "/Users/me/dev/mindbus")
        XCTAssertEqual(rows[0].count, 12)
        XCTAssertEqual(rows[0].activeStart, MindsDocument.day(from: "2026-08-01"))
        XCTAssertEqual(rows[0].activeEnd, MindsDocument.day(from: "2026-08-15"))
        XCTAssertEqual(rows[0].lastTouched, MindsDocument.day(from: "2026-08-15"))
    }

    /// 回归：`last touched` 一直写在 md 里，旧解析把它丢了，「最近活跃」列因此没数据
    func testProjectRowKeepsLastTouchedEvenWhenItDiffersFromActiveEnd() {
        let line = "- /x/y — 3 conversations, active 2026-01-01 → 2026-02-02, last touched 2026-03-03"
        let row = doc.project(line)
        XCTAssertEqual(row?.activeEnd, MindsDocument.day(from: "2026-02-02"))
        XCTAssertEqual(row?.lastTouched, MindsDocument.day(from: "2026-03-03"))
    }

    func testProjectActiveWithinWindow() {
        let now = MindsDocument.day(from: "2026-08-20")!
        let recent = doc.project("- /a — 1 conversations, active 2026-08-10 → 2026-08-18, last touched 2026-08-18")!
        let stale = doc.project("- /b — 1 conversations, active 2026-01-10 → 2026-01-18, last touched 2026-01-18")!
        XCTAssertTrue(recent.isActive(now: now))
        XCTAssertFalse(stale.isActive(now: now))
    }

    /// 边界：正好 14 天算不活跃（窗口是开区间），13 天算活跃
    func testProjectActiveBoundary() {
        let now = MindsDocument.day(from: "2026-08-20")!
        let at14 = doc.project("- /a — 1 conversations, active 2026-08-06 → 2026-08-06, last touched 2026-08-06")!
        let at13 = doc.project("- /b — 1 conversations, active 2026-08-07 → 2026-08-07, last touched 2026-08-07")!
        XCTAssertFalse(at14.isActive(now: now))
        XCTAssertTrue(at13.isActive(now: now))
    }

    // MARK: - 委托动词

    func testDelegationVerbs() {
        let verbs = doc.delegationVerbs()
        XCTAssertEqual(verbs.count, 3)
        XCTAssertEqual(verbs[0], MindsDocument.DelegationVerb(verb: "优化", count: 118, conversations: 27))
        XCTAssertEqual(verbs[2].verb, "开发")
    }

    /// research 行与动词行同节，不能被当成动词
    func testDelegationIgnoresResearchLine() {
        XCTAssertFalse(doc.delegationVerbs().contains { $0.verb.contains("research") })
    }

    func testDelegationOnlyResearchLineYieldsNoVerbs() {
        let only = MindsDocument(markdown: """
        ## DELEGATION
        prose
        - research destination #1: github (19 of your 调研 orders)
        """)
        XCTAssertTrue(only.delegationVerbs().isEmpty)
        XCTAssertEqual(only.researchDestination()?.destination, "github")
        XCTAssertEqual(only.researchDestination()?.count, 19)
    }

    func testResearchDestination() {
        let r = doc.researchDestination()
        XCTAssertEqual(r?.destination, "github")
        XCTAssertEqual(r?.count, 19)
    }

    // MARK: - 提问形状

    func testQuestionShapeSortsDescending() {
        let counts = doc.questionShape()
        XCTAssertEqual(counts.map(\.kind), ["how-to", "should-we", "what-is", "why"])
        XCTAssertEqual(counts.map(\.count), [195, 148, 100, 79])
    }

    // MARK: - 词条

    func testVocabularyChips() {
        let chips = doc.chipRow("VOCABULARY")
        XCTAssertEqual(chips.count, 3)
        XCTAssertEqual(chips[0], MindsDocument.Chip(word: "选择", meta: "475×/13p"))
    }

    func testChipWithoutMeta() {
        XCTAssertEqual(doc.chips(from: "架构 · 复用"),
                       [MindsDocument.Chip(word: "架构", meta: ""),
                        MindsDocument.Chip(word: "复用", meta: "")])
    }

    func testCatchphrasesSplitOnMultiplicationSign() {
        let ps = doc.catchphrases()
        XCTAssertEqual(ps.count, 3)
        XCTAssertEqual(ps[0].phrase, "继续")
        XCTAssertEqual(ps[0].count, 251)
        // 词里带空格也要完整保住
        XCTAssertEqual(ps[2].phrase, "全量 P0 做")
        XCTAssertEqual(ps[2].count, 7)
    }

    func testCatchphrasesIgnorePolitenessLine() {
        XCTAssertFalse(doc.catchphrases().contains { $0.phrase.contains("politeness") })
    }

    func testPolitenessLineIsHumanized() {
        XCTAssertEqual(doc.politenessLine(), "帮我 30、please 12")
    }

    // MARK: - 数值抽取

    func testFirstIntAfterPrefix() {
        XCTAssertEqual(MindsDocument.firstInt(after: "silent ", in: "said 92 times, silent 96 days"), 96)
        XCTAssertEqual(MindsDocument.firstInt(after: "", in: "said 92 times"), 92)
        XCTAssertNil(MindsDocument.firstInt(after: "nope ", in: "said 92 times"))
    }

    func testIsoDatesInOrder() {
        XCTAssertEqual(MindsDocument.isoDates(in: "active 2026-05-08 → 2026-06-09, last touched 2026-06-30"),
                       ["2026-05-08", "2026-06-09", "2026-06-30"])
        XCTAssertTrue(MindsDocument.isoDates(in: "no dates here").isEmpty)
    }

    func testCaptures() {
        XCTAssertEqual(MindsDocument.captures("a 12 b 34", #"(\d+) b (\d+)"#), ["12", "34"])
        XCTAssertTrue(MindsDocument.captures("nothing", #"(\d+)"#).isEmpty)
    }

    func testDaysAgoClampsFutureToZero() {
        let now = MindsDocument.day(from: "2026-08-20")!
        XCTAssertEqual(MindsDocument.daysAgo(MindsDocument.day(from: "2026-08-20")!, now: now), 0)
        XCTAssertEqual(MindsDocument.daysAgo(MindsDocument.day(from: "2026-08-17")!, now: now), 3)
        XCTAssertEqual(MindsDocument.daysAgo(MindsDocument.day(from: "2026-09-01")!, now: now), 0)
    }

    func testDayRoundTrip() {
        let iso = "2026-08-17"
        XCTAssertEqual(MindsDocument.day(from: iso).map(MindsDocument.dayString), iso)
        XCTAssertNil(MindsDocument.day(from: "not-a-date"))
    }

    // MARK: - 空文档

    func testEmptyDocumentReturnsEmptyEverywhere() {
        let empty = MindsDocument(markdown: "")
        XCTAssertTrue(empty.projects().isEmpty)
        XCTAssertTrue(empty.delegationVerbs().isEmpty)
        XCTAssertTrue(empty.questionShape().isEmpty)
        XCTAssertTrue(empty.catchphrases().isEmpty)
        XCTAssertTrue(empty.chipRow("VOCABULARY").isEmpty)
        XCTAssertNil(empty.researchDestination())
        XCTAssertNil(empty.politenessLine())
    }

    /// 空态文案（`(none yet)` 这类）不是 `- ` 开头，不能被当成数据行
    func testEmptyStateProseIsNotABullet() {
        let d = MindsDocument(markdown: """
        ## DORMANT PROJECTS
        Heavy investments. (mechanical, 0 projects)
        (none — everything heavy is still warm)
        """)
        XCTAssertTrue(d.bullets("DORMANT PROJECTS").isEmpty)
        XCTAssertFalse(d.hasAny(["DORMANT PROJECTS"]))
    }
}

// MARK: - 2026-08-18 修的四项

/// 这一组对着「Minds 发现的内容符不符合预期」那轮审计写的。
/// 四项各自有具体的真机证据，注释里记了，别当成假想用例删掉。
extension MindsDocumentTests {

    /// 条形要按消息数画：真机上 Atlas 54 场共 6027 条，Beacon 4 场却有 7914 条，
    /// 只按场数排会让条长与实际投入成反比。
    func testProjectRowCarriesMessageCount() {
        let line = "- /x/Atlas — 54 conversations, 6027 messages, "
            + "active 2026-05-15 → 2026-05-15, last touched 2026-07-18"
        let row = MindsDocument(markdown: "").project(line)
        XCTAssertEqual(row?.count, 54)
        XCTAssertEqual(row?.messages, 6027)
    }

    /// 旧文档没有 `N messages` 那一段，读端给 0，界面据此回退到场数——不能崩也不能乱。
    func testProjectRowMessagesIsZeroOnLegacyLine() {
        let legacy = "- /x/a — 12 conversations, active 2026-08-01 → 2026-08-15, "
            + "last touched 2026-08-15"
        let row = MindsDocument(markdown: "").project(legacy)
        XCTAssertEqual(row?.count, 12)
        XCTAssertEqual(row?.messages, 0)
    }

    /// 「conversations」和「messages」两个数字都在行里，不能互相串位
    func testProjectRowDoesNotConfuseCountWithMessages() {
        let line = "- /x/a — 3 conversations, 999 messages, "
            + "active 2026-08-01 → 2026-08-02, last touched 2026-08-02"
        let row = MindsDocument(markdown: "").project(line)
        XCTAssertEqual(row?.count, 3)
        XCTAssertEqual(row?.messages, 999)
    }
}

// MARK: - 你点头的时刻

extension MindsDocumentTests {

    /// 段落渲染 + 读端解析：一条里程碑 = 日期 + 你说的那句认可 + AI 汇报的首句。
    func testMilestonesSectionRoundTrip() {
        let stones = [
            MindsMilestones.Milestone(headline: "风声扩展 P1 落地完毕：表 + 闸门全链路跑通",
                                      approval: "继续",
                                      at: Date(timeIntervalSince1970: 1_754_000_000)),
            MindsMilestones.Milestone(headline: "上架合规全套上线", approval: "确认",
                                      at: Date(timeIntervalSince1970: 1_754_100_000)),
        ]
        let md = MindsBuilder.renderMilestones(stones, total: 307)
        XCTAssertTrue(md.contains("## MILESTONES"), md)
        XCTAssertTrue(md.contains("307"), "总数要如实写出来: \(md)")

        let doc = MindsDocument(markdown: md)
        let parsed = doc.milestones
        XCTAssertEqual(parsed.count, 2)
        // 最近的排在最前
        XCTAssertEqual(parsed.first?.approval, "确认")
        XCTAssertEqual(parsed.last?.headline, "风声扩展 P1 落地完毕：表 + 闸门全链路跑通")
    }

    /// 没有素材时不能装作有——空段落要明说
    func testMilestonesEmptyStatesSoHonestly() {
        let md = MindsBuilder.renderMilestones([], total: 0)
        XCTAssertTrue(md.contains("(none yet)"), md)
        XCTAssertTrue(MindsDocument(markdown: md).milestones.isEmpty)
    }
}

// MARK: - 项目的产出量（不是活动量）

extension MindsDocumentTests {

    /// `N conversations, M messages` 量的是你花了多少时间；
    /// 「放行了几件」量的是这段时间产出了什么。后者才是你想知道的。
    func testProjectRowCarriesSignedOffCount() {
        let md = """
        ## PROJECT RHYTHM
        Top 2 projects. (mechanical, 2 projects)
        - /w/alpha — 12 conversations, 900 messages, 7 signed off, active 2026-05-01 → 2026-08-01, last touched 2026-08-01
        - /w/beta — 30 conversations, 4000 messages, active 2026-06-01 → 2026-07-01, last touched 2026-07-01
        """
        let rows = MindsDocument(markdown: md).projects()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].signedOff, 7)
        // 旧文档没有这一段：给 0，读端不报错（同 `N messages` 当初的处理）
        XCTAssertEqual(rows[1].signedOff, 0)
        XCTAssertEqual(rows[1].messages, 4000, "缺 signed off 不能串位到别的数字")
    }

    /// 放行数为 0 的项目不写这一段——写「0 signed off」等于在说它没产出，
    /// 而真相可能只是这个项目的推进方式不产生这个信号（真机覆盖率 16%）。
    func testZeroSignedOffIsOmittedNotPrinted() {
        let p = MindsBuilder.ProjectRhythm(
            cwd: "/w/x", count: 3, messages: 90, signedOff: 0,
            activeStart: Date(timeIntervalSince1970: 1_754_000_000),
            activeEnd: Date(timeIntervalSince1970: 1_754_100_000),
            lastTouched: Date(timeIntervalSince1970: 1_754_100_000))
        XCTAssertFalse(MindsBuilder.renderProjectRhythmForTest([p]).contains("signed off"))
        let q = MindsBuilder.ProjectRhythm(
            cwd: "/w/y", count: 3, messages: 90, signedOff: 4,
            activeStart: Date(timeIntervalSince1970: 1_754_000_000),
            activeEnd: Date(timeIntervalSince1970: 1_754_100_000),
            lastTouched: Date(timeIntervalSince1970: 1_754_100_000))
        XCTAssertTrue(MindsBuilder.renderProjectRhythmForTest([q]).contains("4 signed off"))
    }
}

// MARK: - 悬着的事

extension MindsDocumentTests {

    func testOpenLoopsRoundTrip() {
        let items = [
            ConversationIndex.UnfinishedThread(
                id: "c1", title: "构建本地 AI 记忆系统的设计方案",
                preview: "要我开始吗？", cwd: "/w/mindbus",
                endAt: Date(timeIntervalSince1970: 1_754_000_000)),
            ConversationIndex.UnfinishedThread(
                id: "c2", title: nil, preview: "要我把它归档提交、还是继续调形态？",
                cwd: "/w/ResourceLoop", endAt: Date(timeIntervalSince1970: 1_753_000_000)),
        ]
        let md = MindsBuilder.renderOpenLoops(items)
        XCTAssertTrue(md.contains("## OPEN LOOPS"), md)
        let rows = MindsDocument(markdown: md).openLoops
        XCTAssertEqual(rows.count, 2)
        // 问题本身要在，光有标题等于没说清楚悬的是什么
        XCTAssertEqual(rows[0].question, "要我开始吗？")
        XCTAssertEqual(rows[0].context, "构建本地 AI 记忆系统的设计方案")
        // 没标题时退回项目名——总得让人知道这是哪儿的事
        XCTAssertEqual(rows[1].context, "ResourceLoop")
    }

    func testOpenLoopsEmptyIsHonest() {
        XCTAssertTrue(MindsBuilder.renderOpenLoops([]).contains("(none yet)"))
        XCTAssertTrue(MindsDocument(markdown: MindsBuilder.renderOpenLoops([])).openLoops.isEmpty)
    }
}
