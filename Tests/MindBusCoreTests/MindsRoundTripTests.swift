import XCTest
@testable import MindBusCore

/// 写端 → 读端往返。
///
/// 这是整套 Minds 测试里最值钱的一组：`MindsBuilder` 渲染 md、`MindsDocument` 解析它，
/// 两端各自的单元测试都绿、但格式一改就对不上——那种故障在界面上表现为
/// 「某一节忽然空白」，而 CI 全绿。这里用同一份数据走完整条链，
/// 断言解析出来的值等于喂进去的值。
final class MindsRoundTripTests: XCTestCase {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private func emptyOverview(count: Int = 0) -> ConversationIndex.MapOverview {
        ConversationIndex.MapOverview(conversationCount: count, earliest: nil, latest: nil,
                                      bySource: [], byProject: [], byMonth: [], topEntities: [])
    }

    /// 建一份「什么都有」的文档，往返一次
    private func render(_ mutate: (inout MindsBuilder.SurpriseData) -> Void = { _ in },
                        projects: [MindsBuilder.ProjectRhythm] = [],
                        vocab: [MindsBuilder.VocabWord] = []) -> MindsDocument {
        var s = MindsBuilder.SurpriseData()
        mutate(&s)
        let md = MindsBuilder.renderDocument(overview: emptyOverview(count: 150),
                                             projects: projects,
                                             vocabulary: [],
                                             vocabStats: vocab,
                                             refs: [],
                                             surprise: s,
                                             builtAt: date(2026, 8, 17))
        return MindsDocument(markdown: md)
    }

    // MARK: - 项目节奏

    func testProjectRhythmRoundTrip() {
        let projects = [
            MindsBuilder.ProjectRhythm(cwd: "/Users/me/dev/mindbus", count: 12, messages: 1200,
                                       activeStart: date(2026, 8, 1), activeEnd: date(2026, 8, 15),
                                       lastTouched: date(2026, 8, 15)),
            MindsBuilder.ProjectRhythm(cwd: "/Users/me/dev/Codex", count: 7, messages: 700,
                                       activeStart: date(2026, 5, 8), activeEnd: date(2026, 6, 9),
                                       lastTouched: date(2026, 6, 30)),
        ]
        let rows = render(projects: projects).projects()

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.name), ["mindbus", "Codex"])
        XCTAssertEqual(rows.map(\.count), [12, 7])
        XCTAssertEqual(rows[0].activeStart, MindsDocument.day(from: "2026-08-01"))
        XCTAssertEqual(rows[0].activeEnd, MindsDocument.day(from: "2026-08-15"))
        // 「最近活跃」列的数据源——lastTouched 与 activeEnd 不同也要各归各位
        XCTAssertEqual(rows[1].lastTouched, MindsDocument.day(from: "2026-06-30"))
        XCTAssertEqual(rows[1].activeEnd, MindsDocument.day(from: "2026-06-09"))
    }

    /// 路径里带空格 / 中文时不能把行切碎
    func testProjectPathWithSpacesAndCJK() {
        let projects = [MindsBuilder.ProjectRhythm(cwd: "/Users/me/我的 项目", count: 3, messages: 300,
                                                   activeStart: date(2026, 7, 1),
                                                   activeEnd: date(2026, 7, 2),
                                                   lastTouched: date(2026, 7, 2))]
        let rows = render(projects: projects).projects()
        XCTAssertEqual(rows.first?.path, "/Users/me/我的 项目")
        XCTAssertEqual(rows.first?.name, "我的 项目")
        XCTAssertEqual(rows.first?.count, 3)
    }

    // MARK: - 委托 / 提问

    func testDelegationRoundTrip() {
        let doc = render {
            $0.delegationVerbs = [("优化", 118, 27), ("设计", 106, 21), ("开发", 60, 21)]
            $0.researchDestinations = [(dest: "github", count: 19), (dest: "产品", count: 16)]
        }
        XCTAssertEqual(doc.delegationVerbs(),
                       [.init(verb: "优化", count: 118, conversations: 27),
                        .init(verb: "设计", count: 106, conversations: 21),
                        .init(verb: "开发", count: 60, conversations: 21)])
        XCTAssertEqual(doc.researchDestination()?.destination, "github")
        XCTAssertEqual(doc.researchDestination()?.count, 19)
    }

    func testQuestionShapeRoundTripSortsDescending() {
        let doc = render {
            $0.questionShape = [("should-we", 148), ("how-to", 195), ("why", 79), ("what-is", 100)]
        }
        XCTAssertEqual(doc.questionShape().map(\.kind), ["how-to", "should-we", "what-is", "why"])
        XCTAssertEqual(doc.questionShape().first?.count, 195)
    }

    // MARK: - 词条

    func testCatchphraseRoundTripKeepsSpacesInsidePhrase() {
        let doc = render {
            $0.catchphrases = [("继续", 251), ("全量 P0 做", 7)]
            $0.politeness = [("帮我", 30), ("please", 12)]
        }
        let ps = doc.catchphrases()
        XCTAssertEqual(ps.count, 2)
        XCTAssertEqual(ps[0].phrase, "继续")
        XCTAssertEqual(ps[0].count, 251)
        XCTAssertEqual(ps[1].phrase, "全量 P0 做")
        XCTAssertEqual(ps[1].count, 7)
        XCTAssertEqual(doc.politenessLine(), "帮我 30、please 12")
    }

    func testVocabularyRoundTrip() {
        let vocab = [MindsBuilder.VocabWord(word: "选择", tf: 475, projects: 13),
                     MindsBuilder.VocabWord(word: "节点", tf: 444, projects: 10)]
        let chips = render(vocab: vocab).chipRow("VOCABULARY")
        XCTAssertEqual(chips.first?.word, "选择")
        XCTAssertEqual(chips.first?.meta, "475×/13p")
        XCTAssertEqual(chips.count, 2)
    }

    func testPhrasesRoundTrip() {
        let doc = render { $0.phrases = [("第一性原理", 51, 13), ("AI 味", 61, 11)] }
        let chips = doc.chipRow("PHRASES YOU REPEAT")
        XCTAssertEqual(chips.map(\.word), ["第一性原理", "AI 味"])
        XCTAssertEqual(chips.first?.meta, "51×/13p")
    }

    // MARK: - 马拉松 / 沉睡 / 消退

    func testMarathonRoundTrip() {
        let doc = render {
            $0.marathons = [
                .init(id: "conv-1", title: "查看聊天记录中的开发需求和计划", preview: "",
                      cwd: "/x/Compass", messageCount: 5616, spanHours: 6 * 24),
                .init(id: "conv-2", title: nil, preview: "继续",
                      cwd: "/x/Atlas", messageCount: 5497, spanHours: 5),
            ]
        }
        let rows = doc.bullets("MARATHONS").compactMap(doc.identified)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "conv-1")
        XCTAssertEqual(rows[0].label, "查看聊天记录中的开发需求和计划")
        XCTAssertTrue(rows[0].meta.contains("5616 messages"))
        // 不足一天的用小时单位，解析同样要认得
        XCTAssertTrue(rows[1].meta.contains("h,"), rows[1].meta)
    }

    func testDormantRoundTrip() {
        let doc = render {
            $0.dormant = [MindsBuilder.ProjectRhythm(cwd: "/x/StrategyGame", count: 54, messages: 5400,
                                                     activeStart: date(2026, 5, 1),
                                                     activeEnd: date(2026, 5, 15),
                                                     lastTouched: date(2026, 7, 18))]
        }
        let rows = doc.bullets("DORMANT PROJECTS").compactMap(doc.namedDetail)
        XCTAssertEqual(rows.first?.name, "StrategyGame")
        XCTAssertEqual(MindsDocument.firstInt(after: "", in: rows[0].detail), 54)
        XCTAssertTrue(rows[0].detail.contains("2026-07-18"))
    }

    func testFadedWordsRoundTrip() {
        let doc = render {
            $0.fadedWords = [.init(word: "诊断", totalCount: 92, silentDays: 96)]
        }
        let rows = doc.bullets("FADED WORDS").compactMap(doc.namedDetail)
        XCTAssertEqual(rows.first?.name, "诊断")
        XCTAssertEqual(MindsDocument.firstInt(after: "said ", in: rows[0].detail), 92)
        XCTAssertEqual(MindsDocument.firstInt(after: "silent ", in: rows[0].detail), 96)
    }

    // MARK: - 空态

    /// 全空时每一节都渲了「诚实文案」而不是数据行——读端必须一条都解析不出来，
    /// 否则界面会把「(none yet)」当成一个项目画出来
    func testEmptyDocumentYieldsNoBulletsAnywhere() {
        let doc = render()
        for section in ["DORMANT PROJECTS", "FADED WORDS", "MARATHONS",
                        "PROJECT RHYTHM", "VOCABULARY", "PHRASES YOU REPEAT",
                        "CATCHPHRASES", "DELEGATION", "QUESTION SHAPE"] {
            XCTAssertTrue(doc.bullets(section).isEmpty, "\(section) 空态不该产出数据行")
        }
        XCTAssertTrue(doc.projects().isEmpty)
        XCTAssertTrue(doc.delegationVerbs().isEmpty)
        XCTAssertTrue(doc.catchphrases().isEmpty)
    }

    // MARK: - 分节完整性

    /// 界面按节名取数，节名漏一个就是一整块空白。这条锁住「界面用到的节都还在」。
    func testEverySectionTheUIReadsIsPresent() {
        let projects = [MindsBuilder.ProjectRhythm(cwd: "/x/a", count: 1, messages: 100,
                                                   activeStart: date(2026, 8, 1),
                                                   activeEnd: date(2026, 8, 2),
                                                   lastTouched: date(2026, 8, 2))]
        let doc = render({
            $0.questionShape = [("how-to", 20)]   // 低于 20 条时写端不渲数据行,见下面的阈值用例
            $0.delegationVerbs = [("优化", 1, 1)]
            $0.catchphrases = [("继续", 3)]
            $0.phrases = [("第一性原理", 5, 2)]
            $0.fadedWords = [.init(word: "诊断", totalCount: 92, silentDays: 96)]
            $0.marathons = [.init(id: "c", title: "t", preview: "", cwd: "/x", messageCount: 10, spanHours: 24)]
            $0.dormant = projects
        }, projects: projects, vocab: [MindsBuilder.VocabWord(word: "选择", tf: 1, projects: 1)])

        // 与三个页面实际读取的节名一一对应
        let sectionsUsedByUI = [
            "DORMANT PROJECTS", "FADED WORDS", "QUESTION SHAPE", "DELEGATION",
            "PHRASES YOU REPEAT", "CATCHPHRASES", "MARATHONS",
            "PROJECT RHYTHM", "VOCABULARY",
        ]
        for section in sectionsUsedByUI {
            XCTAssertFalse(doc.lines(section).isEmpty, "界面要读 \(section)，文档里必须有这一节")
            XCTAssertFalse(doc.bullets(section).isEmpty, "\(section) 给了数据却没渲出数据行")
        }
    }

    /// 提问形状有个 ≥20 条的阈值:样本太小时写端只渲一句诚实文案。
    /// 界面据此整节隐藏——这条锁住「阈值以下读端一条都读不出来」。
    func testQuestionShapeBelowThresholdYieldsNothingToRead() {
        let few = render { $0.questionShape = [("how-to", 9), ("why", 5)] }
        XCTAssertTrue(few.questionShape().isEmpty)
        XCTAssertTrue(few.bullets("QUESTION SHAPE").isEmpty)

        let enough = render { $0.questionShape = [("how-to", 15), ("why", 5)] }
        XCTAssertEqual(enough.questionShape().map(\.count), [15, 5])
    }

    /// WEAK SPOTS 是宿主模型写的增补层，绝不能混进机械层——
    /// 界面只渲机械层，混进来就等于把 LLM 文本当成「数出来的」展示
    func testMechanicalDocumentNeverContainsWeakSpots() {
        XCTAssertFalse(render().markdown.contains("WEAK SPOTS"))
    }
}

// MARK: - 详情行抽取的往返

/// 界面把英文机械行说成中文，靠的是一组正则。它们与写端对不上时，
/// 界面不会报错也不会空白——它会静默显示英文原文，是最难被发现的一种坏。
/// 所以每一条都用写端的真实输出验一次。
extension MindsRoundTripTests {

    func testDormantDetailExtraction() {
        let doc = render {
            $0.dormant = [MindsBuilder.ProjectRhythm(cwd: "/x/StrategyGame", count: 54, messages: 5400,
                                                     activeStart: date(2026, 5, 1),
                                                     activeEnd: date(2026, 5, 15),
                                                     lastTouched: date(2026, 7, 18))]
        }
        let detail = doc.bullets("DORMANT PROJECTS").compactMap(doc.namedDetail).first!.detail
        let r = doc.dormantDetail(detail)
        XCTAssertEqual(r?.conversations, 54)
        XCTAssertEqual(r?.lastTouched, "2026-07-18")
    }

    func testFadedDetailExtraction() {
        let doc = render { $0.fadedWords = [.init(word: "诊断", totalCount: 92, silentDays: 96)] }
        let detail = doc.bullets("FADED WORDS").compactMap(doc.namedDetail).first!.detail
        let r = doc.fadedDetail(detail)
        XCTAssertEqual(r?.said, 92)
        XCTAssertEqual(r?.silentDays, 96)
    }

    func testMarathonDetailExtractionBothUnits() {
        let doc = render {
            $0.marathons = [
                .init(id: "a", title: "长", preview: "", cwd: "/x/Atlas",
                      messageCount: 5497, spanHours: 64 * 24),
                .init(id: "b", title: "短", preview: "", cwd: "/x/Bench",
                      messageCount: 120, spanHours: 5),
            ]
        }
        let rows = doc.bullets("MARATHONS").compactMap(doc.identified)
        let long = doc.marathonDetail(rows[0].meta)
        XCTAssertEqual(long?.messages, 5497)
        XCTAssertEqual(long?.span, .days(64))
        XCTAssertEqual(long?.project, "Atlas")

        let short = doc.marathonDetail(rows[1].meta)
        XCTAssertEqual(short?.messages, 120)
        XCTAssertEqual(short?.span, .hours(5))
        XCTAssertEqual(short?.project, "Bench")
    }

    /// 认不出来的行必须原样返回 nil，让界面回退到显示原文——
    /// 绝不能返回一个「猜出来的」数字
    func testDetailExtractorsReturnNilOnUnknownShape() {
        let doc = render()
        XCTAssertNil(doc.dormantDetail("something else entirely"))
        XCTAssertNil(doc.fadedDetail("said a lot, silent forever"))
        XCTAssertNil(doc.marathonDetail("5497 messages, Atlas"))
    }

    func testChipMetaVariants() {
        XCTAssertEqual(MindsDocument.chipMeta("475×/13p"),
                       .timesAndProjects(times: 475, projects: 13))
        XCTAssertEqual(MindsDocument.chipMeta("87"), .times(87))
        XCTAssertEqual(MindsDocument.chipMeta(""), .raw(""))
        XCTAssertEqual(MindsDocument.chipMeta("weird"), .raw("weird"))
        // 只有形状完全吻合才算——半截的不能被当成 timesAndProjects
        XCTAssertEqual(MindsDocument.chipMeta("475×/13"), .raw("475×/13"))
    }

    /// 常用词与反复说的话都用 `N×/Mp`，写端一改这个格式两处一起坏
    func testChipMetaMatchesWriterFormat() {
        let doc = render({ $0.phrases = [("第一性原理", 51, 13)] },
                         vocab: [MindsBuilder.VocabWord(word: "选择", tf: 475, projects: 13)])
        for section in ["VOCABULARY", "PHRASES YOU REPEAT"] {
            let meta = doc.chipRow(section).first!.meta
            guard case .timesAndProjects = MindsDocument.chipMeta(meta) else {
                return XCTFail("\(section) 的 meta「\(meta)」没被 chipMeta 认出来")
            }
        }
    }
}

// MARK: - 2026-08-18 审计修的四项（写端 → 读端）

extension MindsRoundTripTests {

    /// ② 项目行必须带消息数，否则读端画不出按投入排的条形
    func testProjectRhythmRoundTripsMessageCount() {
        let projects = [
            MindsBuilder.ProjectRhythm(cwd: "/x/Atlas", count: 54, messages: 6027,
                                       activeStart: date(2026, 5, 15), activeEnd: date(2026, 5, 15),
                                       lastTouched: date(2026, 7, 18)),
            MindsBuilder.ProjectRhythm(cwd: "/x/Beacon", count: 4, messages: 7914,
                                       activeStart: date(2026, 7, 20), activeEnd: date(2026, 7, 30),
                                       lastTouched: date(2026, 7, 31)),
        ]
        let rows = render(projects: projects).projects()
        XCTAssertEqual(rows.map(\.count), [54, 4])
        XCTAssertEqual(rows.map(\.messages), [6027, 7914])
        // 这正是当初的现象：场数最多的项目投入最少
        XCTAssertTrue(rows[0].count > rows[1].count)
        XCTAssertTrue(rows[0].messages < rows[1].messages)
    }

    /// ③ 家目录与工具缓存目录不是项目
    func testHomeAndToolCachePathsAreNotProjects() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(MindsBuilder.isRealProject(home), "家目录本身不是项目")
        XCTAssertFalse(MindsBuilder.isRealProject(home + "/"), "末尾斜杠是同一个目录")
        XCTAssertFalse(MindsBuilder.isRealProject(
            home + "/.claude/plugins/cache/x/skills/skill-creator"), "插件缓存不是项目")
        XCTAssertFalse(MindsBuilder.isRealProject(home + "/.codex/sessions"))
        XCTAssertFalse(MindsBuilder.isRealProject(""))
        XCTAssertTrue(MindsBuilder.isRealProject(home + "/dev/mindbus"))
        XCTAssertTrue(MindsBuilder.isRealProject(home + "/Desktop/Project/Atlas"))
        // 家目录之外的隐藏目录不归我们管（用户真把项目放那儿也是他的自由）
        XCTAssertTrue(MindsBuilder.isRealProject("/opt/work/app"))
    }

    /// ④ 短语首尾不能是标点：「】改成【」跨 9 个项目 45 次，统计成立但显示是一串符号
    func testBracketFragmentIsNotAPhrase() {
        let corpus = (0..<9).map { i in
            (text: String(repeating: "把【标题】改成【正文】。", count: 6), cwd: "/p/\(i)")
        }
        let phrases = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20).map(\.phrase)
        for p in phrases {
            XCTAssertFalse(MindsBuilder.isPhraseEdgePunctuation(p.first!),
                           "「\(p)」以标点开头")
            XCTAssertFalse(MindsBuilder.isPhraseEdgePunctuation(p.last!),
                           "「\(p)」以标点结尾")
        }
    }

    func testPhraseEdgePunctuationClassifier() {
        for c in "】【（）「」《》，。：、,.:;" {
            XCTAssertTrue(MindsBuilder.isPhraseEdgePunctuation(c), "\(c) 应判为标点")
        }
        for c in "第一性原理skillAI7" {
            XCTAssertFalse(MindsBuilder.isPhraseEdgePunctuation(c), "\(c) 不该判为标点")
        }
    }

    /// ① 三个此前从没被赋值的字段:项目杠杆 / 协作形状 / 周末人格。
    /// 它们空着时,项目表的「杠杆」列永久隐藏,而 MCP 交给 AI 的 md 缺两节——
    /// 「用户看到的」和「AI 拿到的」不是同一份。
    func testLeverageByProjectRendersWhenDataPresent() {
        let doc = render {
            $0.projectLeverage = [
                .init(name: "homelab", userChars: 3_000, totalChars: 135_000, conversationCount: 5),
            ]
        }
        let rows = doc.bullets("LEVERAGE BY PROJECT")
        XCTAssertFalse(rows.isEmpty, "给了数据就必须渲出来——这一节此前永久为空")
        XCTAssertTrue(rows[0].contains("1:45"), rows[0])
    }

    func testCollaborationShapeAndWeekendRenderWhenDataPresent() {
        let doc = render {
            $0.shape = .init(turnBands: [7, 9, 16, 113], durationBands: [34, 46, 17, 48],
                             avgCharsPerMessage: 355)
            $0.weekendSplit = (weekday: [.init(key: "Atlas", count: 54)],
                               weekend: [.init(key: "mindbus", count: 4)])
        }
        XCTAssertFalse(doc.bullets("COLLABORATION SHAPE").isEmpty,
                       "界面靠直查 store 有内容,但 md 空 = AI 拿不到这一节")
        XCTAssertFalse(doc.bullets("WEEKEND SELF").isEmpty)
    }

    /// 「最忙一天」只报场数会误导:真机 58 场里 54 场是 1-6 条的微会话
    func testBusiestDayLineCarriesMessageCount() {
        let doc = render {
            $0.hourQuarters = [1, 1, 1, 1, 1, 1]
            $0.busiestDay = (day: "2026-05-15", count: 58, messages: 6027)
        }
        let line = doc.bullets("WORK RHYTHM").first { $0.contains("busiest day") }
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("58 conversations"), line!)
        XCTAssertTrue(line!.contains("6027 messages"), line!)
    }
}
