import XCTest
@testable import MindBusCore

/// Minds 惊喜区（2026-08-12 重构）：断点 / 反复回来 / 沉睡 / 本月 / 收藏 五节的
/// 查询与渲染，以及 VOCABULARY 的 user 语料口径。
/// 信息价值 = 意外度——这些测试锁住「什么算意外」的机械定义本身。
final class MindsSurpriseTests: XCTestCase {
    private var path: String!
    private var index: ConversationIndex!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "surprise-\(UUID().uuidString).sqlite"
        index = try ConversationIndex(path: path)
    }
    override func tearDown() {
        index = nil
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    private func lite(_ id: String, cwd: String = "/tmp/proj", start: Date, end: Date? = nil) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: start, endAt: end ?? start,
                         cwd: cwd, gitBranch: nil, title: "t-\(id)", preview: "p-\(id)",
                         messageCount: 1, fileURL: URL(fileURLWithPath: "/f/\(id)"))
    }

    private func seg(_ text: String) -> [Segmenter.Segment] {
        [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)]
    }

    private func put(_ id: String, cwd: String = "/tmp/proj", start: Date, end: Date? = nil,
                     text: String = "占位", entity: String = "", user: String = "",
                     lastRole: String = "") throws {
        try index.upsert([(lite: lite(id, cwd: cwd, start: start, end: end), segments: seg(text),
                           mtime: 1, entityText: entity, userText: user, lastRole: lastRole)])
    }

    // MARK: - 断点（UNFINISHED THREADS）

    func testUnfinishedThreadsOnlyMatchesUserLastRoleWithinWindow() throws {
        let now = Date()
        try put("cut", start: now.addingTimeInterval(-3_600), lastRole: "user")
        try put("answered", start: now.addingTimeInterval(-3_600), lastRole: "assistant")
        try put("ancient", start: now.addingTimeInterval(-20 * 86_400), lastRole: "user")
        let hits = index.unfinishedThreads(since: now.addingTimeInterval(-14 * 86_400), limit: 5)
        XCTAssertEqual(hits.map(\.id), ["cut"])
        XCTAssertEqual(hits.first?.title, "t-cut")
    }

    func testUnfinishedThreadsSortsMostRecentFirst() throws {
        let now = Date()
        try put("older", start: now.addingTimeInterval(-7_200), lastRole: "user")
        try put("newer", start: now.addingTimeInterval(-600), lastRole: "user")
        XCTAssertEqual(index.unfinishedThreads(since: now.addingTimeInterval(-86_400), limit: 5)
            .map(\.id), ["newer", "older"])
    }

    // MARK: - 反复回来（RECURRING QUESTIONS）

    func testRecurringEntityNeedsCountAndSpan() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 「内存泄漏」3 会话跨 10 天：命中
        try put("r1", start: base, entity: "排查 MemoryLeak 问题")
        try put("r2", start: base.addingTimeInterval(5 * 86_400), entity: "又是 MemoryLeak")
        try put("r3", start: base.addingTimeInterval(10 * 86_400), entity: "MemoryLeak 复发")
        // 「闪退」3 会话但同一天：跨度不够,不算「反复回来」
        try put("s1", start: base, entity: "CrashBug")
        try put("s2", start: base.addingTimeInterval(3_600), entity: "CrashBug")
        try put("s3", start: base.addingTimeInterval(7_200), entity: "CrashBug")
        let hits = index.recurringEntities(minConversations: 3, minSpanDays: 7,
                                           excludeTop: 0, limit: 5)
        XCTAssertTrue(hits.contains { $0.text == "MemoryLeak" }, "跨 10 天的实体该命中: \(hits.map(\.text))")
        XCTAssertFalse(hits.contains { $0.text == "CrashBug" }, "同日 3 次不算反复回来")
    }

    func testRecurringExcludesTopStaples() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 「主项目词」出现 4 会话(全库最高频)——excludeTop: 1 应把它排掉
        for i in 0..<4 {
            try put("t\(i)", start: base.addingTimeInterval(Double(i) * 4 * 86_400),
                    entity: "MainStaple 出现")
        }
        // 「次要词」3 会话跨 8 天
        for i in 0..<3 {
            try put("m\(i)", start: base.addingTimeInterval(Double(i) * 4 * 86_400),
                    entity: "MinorTopic 登场")
        }
        let hits = index.recurringEntities(minConversations: 3, minSpanDays: 7,
                                           excludeTop: 1, limit: 5)
        XCTAssertFalse(hits.contains { $0.text == "MainStaple" }, "Top-1 staple 该被排除")
        XCTAssertTrue(hits.contains { $0.text == "MinorTopic" })
    }

    // MARK: - 本月新实体与工具份额

    func testNewEntitiesSinceOnlyFirstSeenAfterCutoff() throws {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        try put("old", start: cutoff.addingTimeInterval(-30 * 86_400), entity: "OldConcept")
        try put("old2", start: cutoff.addingTimeInterval(5 * 86_400), entity: "OldConcept")   // 又出现≠新
        try put("new", start: cutoff.addingTimeInterval(3 * 86_400), entity: "NewConcept")
        let names = index.newEntities(since: cutoff, limit: 10).map(\.text)
        XCTAssertTrue(names.contains("NewConcept"))
        XCTAssertFalse(names.contains("OldConcept"), "月初前已出现过的实体不算本月新词")
    }

    func testSourceCountsRespectsWindow() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try put("in1", start: base.addingTimeInterval(3_600))
        try put("in2", start: base.addingTimeInterval(7_200))
        try put("out", start: base.addingTimeInterval(-3_600))
        let counts = index.sourceCounts(from: base, to: base.addingTimeInterval(86_400))
        XCTAssertEqual(counts.first?.count, 2)
    }

    // MARK: - user 语料词频（VOCABULARY 新口径）

    func testUserVocabularyCountsTimesSaidInUserCorpusOnly() throws {
        // 隔离「数频次」与「学词」两个阶段（学词逻辑另有 PersonalLexiconTests 覆盖）：
        // 词表直接注入,验证两件事——只数 user 语料(AI 说了你没说的不计),且是
        // **说过次数**(tf,同一会话说两次算 2;df 口径只会给 1,这里就是判别点)。
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let aiHeavy = "第一性原理很重要,反复强调第一性原理"
        try put("a", start: base, text: aiHeavy, user: "我按第一性原理来拆,再用第一性原理复核")
        try put("b", start: base.addingTimeInterval(86_400), text: aiHeavy, user: "")   // AI 说了,你没说
        try put("c", start: base.addingTimeInterval(2 * 86_400), text: aiHeavy, user: "换个话题聊聊天气")
        let tf = MindsBuilder.userVocabularyFrequencies(index: index, lexicon: ["第一性原理"])
        XCTAssertEqual(tf["第一性原理"], 2, "会话 a 里说了 2 次——按说过次数数,不是按会话数")
    }

    // MARK: - 词表双组(思维词/项目词)

    func testVocabularyStatsCountsProjects() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try put("a", cwd: "/p/alpha", start: base, user: "用第一性原理拆")
        try put("b", cwd: "/p/beta", start: base.addingTimeInterval(3_600), user: "还是第一性原理")
        try put("c", cwd: "/p/alpha", start: base.addingTimeInterval(7_200), user: "选题库整理一下")
        let stats = MindsBuilder.userVocabularyStats(
            lexicon: ["第一性原理", "选题库"],
            corpus: index.userCorpusRows().map { (text: $0.text, cwd: $0.cwd) })
        let fp = stats.first { $0.word == "第一性原理" }
        XCTAssertEqual(fp?.tf, 2)
        XCTAssertEqual(fp?.projects, 2, "跨 alpha/beta 两个项目")
        XCTAssertEqual(fp?.df, 2, "出现在 2 场会话(df 按会话去重)")
        XCTAssertEqual(stats.first { $0.word == "选题库" }?.projects, 1)
    }

    func testRenderVocabularyRanksByRepetitionAndDropsFillers() {
        // 口径(2026-08-16 重做):唯一两道筛子——说得够多 + 不是口水词。
        // 不再判断词的「类型」:跨几个项目、几个字、是不是人名,统统不问。
        let stats = [
            MindsBuilder.VocabWord(word: "所有事件类型", tf: 120, projects: 1, df: 4),
            MindsBuilder.VocabWord(word: "第一性原理", tf: 39, projects: 12, df: 14),
            MindsBuilder.VocabWord(word: "需要", tf: 919, projects: 39, df: 68),   // df 47% 口水词
            MindsBuilder.VocabWord(word: "复用", tf: 31, projects: 9, df: 9),      // 2 字,旧口径被字数拦
            MindsBuilder.VocabWord(word: "宫本茂", tf: 17, projects: 1, df: 1),    // 单项目,旧口径被跨项目拦
        ]
        let doc = MindsBuilder.renderVocabulary(stats: stats, totalConversations: 146)
        XCTAssertTrue(doc.contains("所有事件类型 (120×/1p) · 第一性原理 (39×/12p)"),
                      "按说过次数排,不看跨项目数: \(doc)")
        XCTAssertTrue(doc.contains("复用 (31×/9p)"), "2 字词不该被字数门槛拦掉")
        XCTAssertTrue(doc.contains("宫本茂 (17×/1p)"), "只在一个项目里反复说的词同样有用")
        XCTAssertFalse(doc.contains("需要"), "口水词(df 47%)是唯一被排除的")
        XCTAssertFalse(doc.contains("- mind:"), "不再分思维词/项目词两组")
    }

    // MARK: - 语料纯度(v15:系统注入剔除)

    func testUserTextExcludesSystemInjected() {
        let msgs = [
            Message(id: "m1", role: .user, timestamp: Date(), blocks: [.text("帮我改这个函数")]),
            Message(id: "m2", role: .user, timestamp: Date(),
                    blocks: [.text("Stop hook feedback: [合法的覆盖所有事件类型]: The condition")]),
            Message(id: "m3", role: .user, timestamp: Date(),
                    blocks: [.text("This session is being continued from a previous conversation")]),
        ]
        let t = Segmenter.userText(of: msgs)
        XCTAssertTrue(t.contains("帮我改这个函数"))
        XCTAssertFalse(t.contains("Stop hook"), "hook 反馈不是你说的话")
        XCTAssertFalse(t.contains("continued"), "会话续传标记不是你说的话")
    }

    func testUserTextFlattensMultilineMessages() {
        let msgs = [
            Message(id: "m1", role: .user, timestamp: Date(),
                    blocks: [.text("修一下这个:\nimport Foundation\nRun: swift test")]),
            Message(id: "m2", role: .user, timestamp: Date(), blocks: [.text("继续")]),
        ]
        XCTAssertEqual(Segmenter.userText(of: msgs),
                       "修一下这个: import Foundation Run: swift test\n继续",
                       "消息内部换行必须压平——否则粘贴代码的行会被口头禅当成整条短消息(Run:/import ×21 现场)")
    }

    func testUserTextStripsCodexFileMentionHeader() {
        let msgs = [
            Message(id: "m1", role: .user, timestamp: Date(), blocks: [.text(
                "# Files mentioned by the user:\n## 规划.mov: /var/folders/x/规划.mov\n" +
                "## My request for Codex: 录音是我对项目的规划。请调研。")]),
            Message(id: "m2", role: .user, timestamp: Date(), blocks: [.text(
                "# Files mentioned by the user:\n## a.png: /var/folders/y/a.png")]),
        ]
        let t = Segmenter.userText(of: msgs)
        XCTAssertEqual(t, "录音是我对项目的规划。请调研。",
                       "标记后才是用户的话;纯文件清单消息整条丢弃")
    }

    func testLastMeaningfulRoleSkipsInjection() {
        let msgs = [
            Message(id: "m1", role: .user, timestamp: Date(), blocks: [.text("问题来了")]),
            Message(id: "m2", role: .assistant, timestamp: Date(), blocks: [.text("答完了")]),
            Message(id: "m3", role: .user, timestamp: Date(),
                    blocks: [.text("Stop hook feedback: blocked")]),
        ]
        XCTAssertEqual(Segmenter.lastMeaningfulRole(of: msgs), "assistant",
                       "hook 以 user 收尾不该伪造「你问了没人答」")
    }

    // MARK: - 提问形状 / 项目出生句

    func testQuestionShapeCountsByKind() {
        let corpus = ["这个方案是否可行\n怎么优化性能\n为什么会内存泄漏\n要不要重构\n如何部署"]
        let shape = MindsBuilder.questionShape(corpus: corpus)
        let d = Dictionary(uniqueKeysWithValues: shape.map { ($0.kind, $0.count) })
        XCTAssertEqual(d["confirm"], 2, "是否+要不要")
        XCTAssertEqual(d["how"], 2, "怎么+如何")
        XCTAssertEqual(d["why"], 1)
        XCTAssertEqual(d["what"], 0)
    }



    func testProjectFirstCorpusReturnsEarliest() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try put("late", cwd: "/p/alpha", start: base.addingTimeInterval(86_400), user: "后来的话")
        try put("first", cwd: "/p/alpha", start: base, user: "阿尔法项目从这里开始")
        let rows = index.projectFirstCorpus(limit: 5)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.convID, "first", "取项目最早会话")
        XCTAssertTrue(rows.first?.text.contains("从这里开始") == true)
    }

    func testRenderQuestionShapeAndFirstWords() {
        var s = MindsBuilder.SurpriseData()
        s.questionShape = [("confirm", 286), ("how", 206), ("why", 94), ("what", 89)]
        let doc = render(s)
        XCTAssertTrue(doc.contains("- should-we 286 · how-to 206 · why 94 · what-is 89"), doc)
        XCTAssertTrue(doc.contains("you ask AI to judge, more than to explain"), "主导型结论")
    }

    // MARK: - 反复交代的容错边界

    /// 夹具的日期要拉开:这一条测的是**聚类容错**,而 `briefingMinSpanDays`
    /// 会把同期重复挡掉,不拉开就测不到聚类逻辑本身。
    func testRepeatedBriefingsToleratesSmallEdits() {
        // 同一段交代的三个变体,各改 2-3 个字——3-gram Jaccard 应聚成一组
        let corpus = [
            (text: "你是资深审查员,只看规格符合性,不要提出风格意见", convID: "c1", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 0 * 30 * 86_400)),
            (text: "你是资深审查员,只看规格符合性,不要给出风格意见", convID: "c2", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 1 * 30 * 86_400)),
            (text: "你是资深审查员,只看规格的符合性,不要提风格意见", convID: "c3", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 2 * 30 * 86_400)),
        ]
        let groups = MindsBuilder.repeatedBriefings(corpus: corpus, limit: 5)
        XCTAssertEqual(groups.count, 1, "小改动的变体应聚为一组: \(groups)")
        XCTAssertEqual(groups.first?.times, 3)
    }

    func testRepeatedBriefingsAcceptsLongBriefings() {
        // 超过 80 字的长交代(真实场景:完整的角色设定/工作约定)也要能聚类
        let long = String(repeating: "这是一段很长的工作交代,包含背景约束和验收标准,", count: 5)  // ~115 字
        let corpus = [
            (text: long + "最后按清单逐项检查", convID: "c1", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 0 * 30 * 86_400)),
            (text: long + "最后按照清单逐项核对", convID: "c2", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 1 * 30 * 86_400)),
            (text: long + "最后按清单逐一核查", convID: "c3", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 2 * 30 * 86_400)),
        ]
        let groups = MindsBuilder.repeatedBriefings(corpus: corpus, limit: 5)
        XCTAssertEqual(groups.count, 1, "长交代不该被长度上限拒之门外: \(groups)")
    }

    // MARK: - 你搬出过的名字



    // MARK: - 反复说的短语(从真实模式反推的算法)

    func testRepeatedPhrasesFindsCrossProjectPatterns() {
        // 三个项目各说三遍「从第一性原理思考」——跨项目 = 跟着人走
        var corpus: [(text: String, cwd: String)] = []
        for p in ["/a", "/b", "/c"] {
            for _ in 0..<3 {
                corpus.append((text: "从第一性原理思考,这个方案是什么意思", cwd: p))
            }
        }
        let out = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 10)
        let ps = out.map(\.phrase)
        XCTAssertTrue(ps.contains { $0.contains("第一性原理思考") }, "跨项目高频短语该被找到: \(ps)")
        // 「是什么意思」含代词「什么」,2026-08-18 起被代词过滤挡掉:
        // 真机上它的成分覆盖率也有 44%,两道判据结论一致
        XCTAssertTrue(MindsBuilder.containsPronoun("是什么意思"))
    }

    func testRepeatedPhrasesRejectsFragments() {
        // 「的 skill」这类以结构助词开头的碎片必须出局(边界规则)
        var corpus: [(text: String, cwd: String)] = []
        for p in ["/a", "/b", "/c"] {
            for _ in 0..<3 { corpus.append((text: "这个 skill 的写法要改", cwd: p)) }
        }
        let ps = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20).map(\.phrase)
        XCTAssertFalse(ps.contains { $0.hasPrefix("的") || $0.hasSuffix("的") },
                       "结构助词不能做短语首尾: \(ps)")
    }

    func testRepeatedPhrasesNeedsMultipleProjects() {
        // 只在一个项目里反复说 = 项目内容,不是「带着走的说法」
        let corpus = (0..<10).map { _ in (text: "把这个报表导出成表格", cwd: "/only") }
        XCTAssertTrue(MindsBuilder.repeatedPhrases(corpus: corpus, limit: 10).isEmpty)
    }

    // MARK: - 汉语语法位置过滤

    func testGrammarFilterDropsAdjectivesAndKeepsContentWords() {
        let lex: Set<String> = ["复杂", "第一性原理", "架构", "情况", "类似", "可视化"]
        let corpus = [
            // 形容词:能被程度副词修饰(很复杂 / 比较复杂 / 太复杂)
            "这段逻辑很复杂,比较复杂的部分在这里,实在太复杂了,复杂到没法维护,复杂度高",
            // 泛指名词:总要指示词才确定所指
            "这个情况怎么办,那种情况不一样,这个情况要分开看,某种情况下会失败,这个情况再说",
            // 修饰语:总以「X 的」出现
            "类似的做法有很多,类似的方案我见过,类似的问题反复出现,类似的思路,类似的结构",
            // 你的实词:既不被程度副词修饰,也不靠指示词,也不总跟「的」
            "按照第一性原理拆解,用第一性原理想一遍,第一性原理要求回到本质,第一性原理很重要,第一性原理",
            "整个架构要重来,架构上有问题,先定架构再动手,你的架构不清晰,架构评审",
        ]
        let g = MindsBuilder.grammarProfiles(lexicon: lex, corpus: corpus)
        XCTAssertFalse(MindsBuilder.isContentWord(g["复杂"] ?? .init()), "「很复杂」→ 形容词,不是你的词")
        XCTAssertFalse(MindsBuilder.isContentWord(g["情况"] ?? .init()), "「这个情况」→ 泛指名词")
        XCTAssertFalse(MindsBuilder.isContentWord(g["类似"] ?? .init()), "「类似的」→ 修饰语")
        XCTAssertTrue(MindsBuilder.isContentWord(g["第一性原理"] ?? .init()), "你的词该留下")
        XCTAssertTrue(MindsBuilder.isContentWord(g["架构"] ?? .init()), "你的词该留下")
    }

    func testGrammarFilterKeepsRareWordsUnjudged() {
        // 样本不足 5 次:宁放过不误杀(统计不稳,不下判断)
        var p = MindsBuilder.GrammarProfile()
        p.count = 3; p.degree = 3
        XCTAssertTrue(MindsBuilder.isContentWord(p), "样本太少时不判定")
    }

    // MARK: - 委托光谱

    func testDelegationVerbsCountsLinesAndConversations() {
        let corpus = [
            (text: "帮我设计一个方案\n再验证一下结果", convID: "c1"),
            (text: "设计要重新来\n" + String(repeating: "长", count: 200) + "设计", convID: "c2"),
        ]
        let verbs = MindsBuilder.delegationVerbs(corpus: corpus, limit: 8)
        let d = Dictionary(uniqueKeysWithValues: verbs.map { ($0.verb, ($0.lines, $0.conversations)) })
        XCTAssertEqual(d["设计"]?.0, 2, "超长行(≥150 字)是粘贴不是指令,不计")
        XCTAssertEqual(d["设计"]?.1, 2, "两场会话都出现")
        XCTAssertEqual(d["验证"]?.0, 1)
        XCTAssertEqual(d["验证"]?.1, 1)
    }

    func testResearchDestinationsFindsGithub() {
        let corpus = ["你需要调研一下,看 GitHub 有没有类似的最佳实践\n去调研竞品的做法\n看看 github 上的实现",
                      "调研最新的行业趋势"]
        let dests = MindsBuilder.researchDestinations(corpus: corpus)
        let d = Dictionary(uniqueKeysWithValues: dests.map { ($0.dest, $0.count) })
        XCTAssertEqual(d["github"], 1, "大小写不敏感;第三行没有「调研」不计")
        XCTAssertEqual(d["竞品"], 1)
        XCTAssertEqual(d["最新"], 1)
        XCTAssertEqual(d["行业"], 1)
    }

    func testRenderDelegation() {
        var s = MindsBuilder.SurpriseData()
        s.delegationVerbs = [(verb: "设计", lines: 215, conversations: 36),
                             (verb: "调研", lines: 64, conversations: 22)]
        s.researchDestinations = [(dest: "github", count: 12), (dest: "产品", count: 9)]
        let doc = render(s)
        XCTAssertTrue(doc.contains("## DELEGATION"), doc)
        XCTAssertTrue(doc.contains("设计 215×/36c · 调研 64×/22c"), doc)
        XCTAssertTrue(doc.contains("research destination #1: github (12"), "调研目的地亮点行")
    }

    // MARK: - 渲染（纯函数,注入数据）

    private func render(_ surprise: MindsBuilder.SurpriseData) -> String {
        MindsBuilder.renderDocument(
            overview: ConversationIndex.MapOverview(conversationCount: 0, earliest: nil, latest: nil,
                                                    bySource: [], byProject: [], byMonth: [], topEntities: []),
            projects: [], vocabulary: [], refs: [], surprise: surprise,
            builtAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testRenderSurpriseSectionsAppearBeforeStats() {
        let doc = render(MindsBuilder.SurpriseData())
        for header in ["## DORMANT PROJECTS", "## THIS MONTH"] {
            XCTAssertTrue(doc.contains(header), "缺 \(header)")
            XCTAssertLessThan(doc.range(of: header)!.lowerBound,
                              doc.range(of: "## OVERVIEW")!.lowerBound,
                              "\(header) 必须排在统计区之前")
        }
        XCTAssertTrue(doc.contains("the raw counts your AI consumes"), "统计区要有分隔说明")
    }


    func testRenderThisMonthShowsDelta() {
        var s = MindsBuilder.SurpriseData()
        s.monthCurrent = [.init(key: "claudeCode", count: 12)]
        s.monthPrevious = [.init(key: "claudeCode", count: 20)]
        let doc = render(s)
        XCTAssertTrue(doc.contains("12 conversations so far (-8 vs last month)"), doc)
    }

    // MARK: - 二批：作息 / 杠杆 / 马拉松 / 不再说的词

    func testHourQuarterHistogramBucketsLocalHours() throws {
        // 用本机时区构造「今天 21:30」与「今天 02:10」各一条,断言落在 20-24 与 00-04 桶
        let cal = Calendar.current
        let evening = cal.date(bySettingHour: 21, minute: 30, second: 0, of: Date())!
        let night = cal.date(bySettingHour: 2, minute: 10, second: 0, of: Date())!
        try put("e", start: evening)
        try put("n", start: night)
        let buckets = index.hourQuarterHistogram()
        XCTAssertEqual(buckets.count, 6)
        XCTAssertEqual(buckets[5], 1, "21:30 → 20-24 桶")
        XCTAssertEqual(buckets[0], 1, "02:10 → 00-04 桶")
        XCTAssertEqual(buckets.reduce(0, +), 2)
    }

    func testBusiestDayPicksTheDenseDay() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 { try put("d\(i)", start: base.addingTimeInterval(Double(i) * 600)) }
        try put("lone", start: base.addingTimeInterval(5 * 86_400))
        let b = index.busiestDay()
        XCTAssertEqual(b?.count, 3)
    }

    func testProjectSwitchingCountsDistinctCwdPerDay() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try put("a1", cwd: "/p/alpha", start: base)
        try put("a2", cwd: "/p/beta", start: base.addingTimeInterval(3_600))
        try put("a3", cwd: "/p/alpha", start: base.addingTimeInterval(7_200))   // 同项目重复不加
        try put("b1", cwd: "/p/alpha", start: base.addingTimeInterval(3 * 86_400))
        let s = index.projectSwitching()
        XCTAssertEqual(s.peak?.count, 2, "第一天 alpha+beta 两个项目")
        XCTAssertEqual(s.avgPerDay, 1.5, accuracy: 0.01, "(2+1)/2 天")
    }

    func testCorpusVolumeSumsUserVsTotal() throws {
        try put("a", start: Date(), text: "十个字十个字十个字十", user: "五个字五个")
        let v = index.corpusVolume()
        XCTAssertEqual(v.userChars, 5)
        XCTAssertEqual(v.totalChars, 10)
    }

    func testMarathonsOrderedByMessageCount() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let big = ConversationLite(id: "big", source: .claudeCode, startAt: base,
                                   endAt: base.addingTimeInterval(90 * 3_600), cwd: "/p", gitBranch: nil,
                                   title: "马拉松", preview: "p", messageCount: 500,
                                   fileURL: URL(fileURLWithPath: "/f/big"))
        try index.upsert([(lite: big, segments: seg("t"), mtime: 1, entityText: "",
                           userText: "", lastRole: "")])
        try put("small", start: base)
        let m = index.marathons(limit: 2)
        XCTAssertEqual(m.first?.id, "big")
        XCTAssertEqual(m.first?.messageCount, 500)
        XCTAssertEqual(m.first?.spanHours ?? 0, 90, accuracy: 0.01)
    }

    func testFadedWordsNeedsVolumeAndSilence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 200 * 86_400)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = now.addingTimeInterval(-10 * 86_400)
        // 「协变量」说 15 次都在 200 天前 → faded;「上下文」老 15 次+近期 1 次 → 还活着;
        // 「偶尔词」只说 3 次 → 不够分量
        let oldText = Array(repeating: "协变量", count: 15).joined(separator: ",")
            + "," + Array(repeating: "上下文", count: 15).joined(separator: ",")
            + ",偶尔词,偶尔词,偶尔词"
        let corpus = [(text: oldText, startAt: old), (text: "上下文还在说", startAt: fresh)]
        let faded = MindsBuilder.fadedWords(corpus: corpus,
                                            lexicon: ["协变量", "上下文", "偶尔词"],
                                            now: now, limit: 5)
        XCTAssertEqual(faded.map(\.word), ["协变量"])
        XCTAssertEqual(faded.first?.totalCount, 15)
        XCTAssertEqual(faded.first?.silentDays, 200)
    }

    func testRenderSecondBatchSections() {
        var s = MindsBuilder.SurpriseData()
        s.hourQuarters = [1, 0, 0, 2, 3, 6]
        s.busiestDay = (day: "2026-05-15", count: 6, messages: 420)
        s.switching = (avgPerDay: 1.7, peak: (day: "2026-08-05", count: 5))
        s.volume = (userChars: 1_308_411, totalChars: 15_620_688)
        s.marathons = [ConversationIndex.Marathon(id: "m1", title: "继续", preview: "p",
                                                  cwd: "/p/StrategyGame", messageCount: 5497,
                                                  spanHours: 1542.9)]
        s.fadedWords = [MindsBuilder.FadedWord(word: "协变量", totalCount: 38, silentDays: 92)]
        let doc = render(s)
        XCTAssertTrue(doc.contains("most conversations start 20-24 — 50% (6 of 12)"), doc)
        XCTAssertTrue(doc.contains("busiest day: 2026-05-15 — 6 conversations, 420 messages "
                                   + "(50% of your conversations, in one day)"), doc)
        XCTAssertTrue(doc.contains("you juggle 1.7 projects per active day — peak 5 on 2026-08-05"))
        XCTAssertTrue(doc.contains("you typed 1.3M characters; the conversations hold 15.6M — leverage 1:11"))
        XCTAssertTrue(doc.contains("- 继续 — 5497 messages over 64 days, StrategyGame (id: m1)"))
        XCTAssertTrue(doc.contains("- 协变量 — said 38 times, silent 92 days"))
        // 新四节都在统计区之前
        for header in ["## WORK RHYTHM", "## LEVERAGE", "## MARATHONS", "## FADED WORDS"] {
            XCTAssertLessThan(doc.range(of: header)!.lowerBound,
                              doc.range(of: "## OVERVIEW")!.lowerBound, "\(header) 应在惊喜区")
        }
    }

    // MARK: - 三批：那年今日 / 口头禅 / 独特性 / 活跃天数

    func testOnThisDayMatchesMonthDayExcludingRecent() throws {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "MM-dd"
        let md = f.string(from: now)
        // 365 天前(同日号)与 30 天整前(约同日号,看月长)与 10 天前(豁免期内)
        try put("old", start: now.addingTimeInterval(-365 * 86_400))
        try put("recent", start: now.addingTimeInterval(-10 * 86_400))
        let hits = index.onThisDay(monthDay: md, minAgeDays: 30, now: now, limit: 5)
        XCTAssertTrue(hits.map(\.id).contains("old"), "同日号的老会话命中(日号口径,跨月即可)")
        XCTAssertFalse(hits.map(\.id).contains("recent"), "近 30 天的不算重逢")
    }

    func testLatestNightPicksLatestClockBeforeSix() throws {
        let cal = Calendar.current
        let base = cal.date(bySettingHour: 2, minute: 10, second: 0, of: Date())!
        let later = cal.date(bySettingHour: 4, minute: 47, second: 0, of: Date().addingTimeInterval(-86_400))!
        let daytime = cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        try put("night1", start: base)
        try put("night2", start: later)
        try put("day", start: daytime)
        let hit = index.latestNightConversation()
        XCTAssertEqual(hit?.thread.id, "night2", "凌晨 4:47 比 2:10 更「晚」;白天的不算")
        XCTAssertEqual(hit?.clock, "04:47")
    }

    func testOneOffTopicsOnlySingleConversationOldEntities() throws {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        try put("a", start: now.addingTimeInterval(-100 * 86_400), entity: "GhostTopic")
        try put("b1", start: now.addingTimeInterval(-100 * 86_400), entity: "TwiceTopic")
        try put("b2", start: now.addingTimeInterval(-99 * 86_400), entity: "TwiceTopic")
        try put("c", start: now.addingTimeInterval(-5 * 86_400), entity: "FreshTopic")
        let hits = index.oneOffTopics(minAgeDays: 90, now: now, limit: 10).map(\.text)
        XCTAssertTrue(hits.contains("GhostTopic"), "只出现一次且够老:命中")
        XCTAssertFalse(hits.contains("TwiceTopic"), "两个会话都有:不是一次性")
        XCTAssertFalse(hits.contains("FreshTopic"), "太新:还不算「再没回来」")
    }

    func testCatchphrasesCountsShortLinesOnly() {
        let corpus = [
            "继续\n把这个改一下,顺便看看那个很长很长的需求描述\n继续\n好的\n继续",
            "继续\n好的\n好的",
        ]
        let phrases = MindsBuilder.catchphrases(corpus: corpus, limit: 5)
        XCTAssertEqual(phrases.first?.phrase, "继续")
        XCTAssertEqual(phrases.first?.count, 4)
        XCTAssertTrue(phrases.contains { $0.phrase == "好的" && $0.count == 3 })
        XCTAssertFalse(phrases.contains { $0.phrase.count > 8 }, "长消息不算口头禅")
    }

    func testPolitenessCountsMarkerLines() {
        let corpus = ["帮我改这个\n谢谢,很好\nplease fix this\n没有礼貌词的行"]
        let p = MindsBuilder.politeness(corpus: corpus)
        XCTAssertTrue(p.contains { $0.word == "帮我" && $0.count == 1 })
        XCTAssertTrue(p.contains { $0.word == "谢谢" && $0.count == 1 })
        XCTAssertTrue(p.contains { $0.word == "please" && $0.count == 1 })
    }

    func testActiveDaysRunAndGap() {
        let daily = [("2026-08-01", 3), ("2026-08-02", 1), ("2026-08-03", 2),
                     ("2026-08-10", 1), ("2026-08-11", 4)]
        let a = MindsBuilder.activeDays(daily: daily.map { (day: $0.0, count: $0.1) }, window: 365)
        XCTAssertEqual(a.active, 5)
        XCTAssertEqual(a.longestRun, 3, "8/1-8/3 连续 3 天")
        XCTAssertEqual(a.longestGap, 6, "8/3 到 8/10 之间隔 6 天")
    }

    func testDailyCountsGroupsByLocalDay() throws {
        let now = Date()
        try put("d1", start: now.addingTimeInterval(-3_600))
        try put("d2", start: now.addingTimeInterval(-7_200))
        let daily = index.dailyCounts(days: 30, now: now)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.count }, 2)
    }

    func testRenderThirdBatchSections() {
        var s = MindsBuilder.SurpriseData()
        s.catchphrases = [(phrase: "继续", count: 47), (phrase: "好的", count: 23)]
        s.politeness = [(word: "帮我", count: 89)]
        s.activeDays = MindsBuilder.ActiveDays(active: 98, window: 365, longestRun: 12, longestGap: 9)
        s.hourQuarters = [0, 0, 0, 0, 0, 4]
        let doc = render(s)
        XCTAssertTrue(doc.contains("- 继续 ×47 · 好的 ×23"))
        XCTAssertTrue(doc.contains("politeness & delegation: 帮我 ×89"))
        XCTAssertTrue(doc.contains("active 98 of the last 365 days — longest run 12, longest break 9"))
    }

    // MARK: - B 批:个人史百分位 / 去年同月

    func testWeekPercentileAgainstOwnHistory() {
        let weekly = [("2026-W01", 5), ("2026-W02", 10), ("2026-W03", 3), ("2026-W04", 8),
                      ("2026-W05", 12), ("2026-W06", 20)]
            .map { (week: $0.0, count: $0.1) }
        let wp = MindsBuilder.weekPercentile(weekly: weekly, currentWeek: "2026-W06")
        XCTAssertEqual(wp?.thisWeek, 20)
        XCTAssertEqual(wp?.percentile, 100, "历史 5 周全部低于 20 → P100")
        XCTAssertEqual(wp?.median, 8, "历史 [3,5,8,10,12] 中位 8")
    }

    func testWeekPercentileNeedsEnoughHistory() {
        let weekly = [("2026-W01", 5), ("2026-W02", 10), ("2026-W03", 3)]
            .map { (week: $0.0, count: $0.1) }
        XCTAssertNil(MindsBuilder.weekPercentile(weekly: weekly, currentWeek: "2026-W03"),
                     "历史周不足 4 个,分位数没有意义")
    }

    func testRenderWeekPercentileAndYoYLines() {
        var s = MindsBuilder.SurpriseData()
        s.hourQuarters = [0, 0, 0, 0, 0, 4]
        s.weekPercentile = (thisWeek: 23, percentile: 92, median: 11)
        s.monthCurrent = [.init(key: "claudeCode", count: 22)]
        s.lastYearSameMonth = 9
        let doc = render(s)
        XCTAssertTrue(doc.contains("this week so far: 23 conversations — P92 of your own history (median 11)"), doc)
        XCTAssertTrue(doc.contains("same month last year: 9 conversations"))
    }

    func testMonthTotalQuery() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM"
        let now = Date()
        try put("m1", start: now)
        try put("m2", start: now.addingTimeInterval(-60))
        XCTAssertEqual(index.monthTotal(yearMonth: f.string(from: now)), 2)
        XCTAssertEqual(index.monthTotal(yearMonth: "1999-01"), 0)
    }

    // MARK: - 四批:协作形状 / 周末人格 / 项目杠杆榜 / 知识流动

    func testCollaborationShapeBucketsTurnsAndDurations() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 2 轮短会话(90 秒)与 17 轮马拉松(3 小时)
        try put("quick", start: base, end: base.addingTimeInterval(90),
                user: "第一句\n第二句")
        try put("deep", start: base.addingTimeInterval(86_400),
                end: base.addingTimeInterval(86_400 + 3 * 3_600),
                user: (1...17).map { "指令\($0)" }.joined(separator: "\n"))
        let sh = index.collaborationShape()
        XCTAssertEqual(sh.turnBands, [1, 0, 0, 1], "2 轮→桶 0;17 轮→桶 3")
        XCTAssertEqual(sh.durationBands, [1, 0, 0, 1], "90 秒→<2min;3 小时→2h+")
        XCTAssertGreaterThan(sh.avgCharsPerMessage, 0)
    }

    func testWeekendSplitSeparatesByLocalWeekday() throws {
        // 用本机时区构造:找最近的周六与周三
        let cal = Calendar.current
        var day = Date()
        while cal.component(.weekday, from: day) != 7 { day = day.addingTimeInterval(-86_400) }   // 周六
        var wed = Date()
        while cal.component(.weekday, from: wed) != 4 { wed = wed.addingTimeInterval(-86_400) }   // 周三
        try put("s1", cwd: "/p/side", start: day)
        try put("s2", cwd: "/p/side", start: day.addingTimeInterval(-7 * 86_400))
        try put("w1", cwd: "/p/work", start: wed)
        try put("w2", cwd: "/p/work", start: wed.addingTimeInterval(-7 * 86_400))
        let split = index.weekendSplit(minCount: 2)
        XCTAssertEqual(split.weekend.map(\.key), ["side"])
        XCTAssertEqual(split.weekday.map(\.key), ["work"])
    }

    func testProjectLeverageComputesPerProjectRatio() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            try put("p\(i)", cwd: "/p/lever", start: base.addingTimeInterval(Double(i) * 3_600),
                    text: String(repeating: "全", count: 100), user: String(repeating: "我", count: 10))
        }
        let rows = index.projectLeverage(minConversations: 5, limit: 5)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "lever")
        XCTAssertEqual(rows.first?.ratio, 10, "500 总字 / 50 你的字 = 1:10")
    }

    func testKnowledgeFlowsCountsSharedEntities() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // alpha 与 beta 共享 SharedConcept;gamma 无共享
        try put("a", cwd: "/p/alpha", start: base, entity: "SharedConcept AlphaOnly")
        try put("b", cwd: "/p/beta", start: base.addingTimeInterval(3_600), entity: "SharedConcept BetaOnly")
        try put("g", cwd: "/p/gamma", start: base.addingTimeInterval(7_200), entity: "GammaOnly")
        let flows = index.knowledgeFlows(minShared: 1, limit: 5)
        XCTAssertEqual(flows.count, 1)
        XCTAssertEqual(flows.first?.sharedEntities, 1)
        XCTAssertEqual(Set([flows.first?.projectA, flows.first?.projectB]), Set(["alpha", "beta"]))
    }

    func testRenderFourthBatchSections() {
        var s = MindsBuilder.SurpriseData()
        s.shape = ConversationIndex.CollaborationShape(
            turnBands: [7, 9, 16, 113], durationBands: [34, 46, 17, 48], avgCharsPerMessage: 38)
        s.weekendSplit = (weekday: [.init(key: "StrategyGame", count: 54), .init(key: "Codex", count: 7)],
                          weekend: [.init(key: "mindbus", count: 3)])
        s.projectLeverage = [
            ConversationIndex.ProjectLeverage(name: "homelab", userChars: 3_730, totalChars: 170_637, conversationCount: 5),
            ConversationIndex.ProjectLeverage(name: "Codex", userChars: 70_255, totalChars: 148_600, conversationCount: 7),
        ]
        let doc = render(s)
        XCTAssertTrue(doc.contains("77% of conversations run 16+ of your turns"),
                      "113/145 整数除法 = 77%")
        XCTAssertTrue(doc.contains("23% under 2 min, 33% over 2 h"))
        XCTAssertTrue(doc.contains("your average message: 38 chars"))
        XCTAssertTrue(doc.contains("- weekend: mindbus 3"))
        XCTAssertTrue(doc.contains("- weekdays: StrategyGame 54 · Codex 7"))
        XCTAssertTrue(doc.contains("- homelab — 1:45"))
        XCTAssertTrue(doc.contains("- Codex — 1:2"))
        for h in ["## COLLABORATION SHAPE", "## WEEKEND SELF", "## LEVERAGE BY PROJECT"] {
            XCTAssertLessThan(doc.range(of: h)!.lowerBound, doc.range(of: "## OVERVIEW")!.lowerBound,
                              "\(h) 应在惊喜区")
        }
    }

    // MARK: - 五批:守护状态(价值感)

    func testSanctuaryStatsCountsOutlivedClaudeCode() throws {
        let now = Date()
        // claudeCode 40 天前(越线)与 10 天前(未越线);codex 40 天前不算(政策不同)
        let old = ConversationLite(id: "cc-old", source: .claudeCode,
                                   startAt: now.addingTimeInterval(-40 * 86_400),
                                   endAt: now.addingTimeInterval(-40 * 86_400), cwd: "/p",
                                   gitBranch: nil, preview: "p", messageCount: 1,
                                   fileURL: URL(fileURLWithPath: "/f/cc-old"))
        let fresh = ConversationLite(id: "cc-new", source: .claudeCode,
                                     startAt: now.addingTimeInterval(-10 * 86_400),
                                     endAt: now.addingTimeInterval(-10 * 86_400), cwd: "/p",
                                     gitBranch: nil, preview: "p", messageCount: 1,
                                     fileURL: URL(fileURLWithPath: "/f/cc-new"))
        try index.upsert([(lite: old, segments: seg("t"), mtime: 1, entityText: "", userText: "", lastRole: ""),
                          (lite: fresh, segments: seg("t"), mtime: 1, entityText: "", userText: "", lastRole: "")])
        try put("cx", start: now.addingTimeInterval(-40 * 86_400))   // codex(put 默认 claudeCode?查 helper)
        let st = index.sanctuaryStats(now: now)
        XCTAssertEqual(st.conversationCount, 3)
        XCTAssertNotNil(st.earliest)
    }

    func testBookEquivalent() {
        XCTAssertEqual(MindsBuilder.bookEquivalent(15_980_000), 53)
        XCTAssertEqual(MindsBuilder.bookEquivalent(100_000), 0)
    }

    func testRenderSanctuarySection() {
        var s = MindsBuilder.SurpriseData()
        s.sanctuary = ConversationIndex.SanctuaryStats(
            conversationCount: 145,
            earliest: Date(timeIntervalSince1970: 1_700_000_000 - 110 * 86_400),
            latestActivity: Date(timeIntervalSince1970: 1_700_000_000),
            outlivedClaudeCode: 8)
        s.vaultFiles = 149
        s.vaultBytes = 317 * 1_048_576
        let doc = render(s)
        XCTAssertTrue(doc.contains("## SANCTUARY"))
        XCTAssertTrue(doc.contains("145 conversations · 149 archived copies (317 MB) · day 111 of your library"), doc)
        XCTAssertTrue(doc.contains("8 conversations have outlived Claude Code's 30-day window — here, they stay"))
        // SANCTUARY 是惊喜区第一节(守护宣言开场)
        XCTAssertLessThan(doc.range(of: "## SANCTUARY")!.lowerBound,
                          doc.range(of: "## THIS MONTH")!.lowerBound)
    }

    func testRenderSanctuaryOmitsOutlivedWhenZero() {
        var s = MindsBuilder.SurpriseData()
        s.sanctuary = ConversationIndex.SanctuaryStats(
            conversationCount: 3, earliest: Date(timeIntervalSince1970: 1_699_000_000),
            latestActivity: Date(timeIntervalSince1970: 1_700_000_000), outlivedClaudeCode: 0)
        let doc = render(s)
        XCTAssertFalse(doc.contains("outlived"), "没有越线会话就不吹——0 不渲染")
    }

    func testHighestMilestone() {
        XCTAssertEqual(MindsBuilder.highestMilestone(145, in: MindsBuilder.conversationMilestones), 100)
        XCTAssertEqual(MindsBuilder.highestMilestone(99, in: MindsBuilder.conversationMilestones), nil)
        XCTAssertEqual(MindsBuilder.highestMilestone(16_100_000, in: MindsBuilder.characterMilestones), 10_000_000)
    }

    func testRenderSanctuaryMilestoneLine() {
        var s = MindsBuilder.SurpriseData()
        s.sanctuary = ConversationIndex.SanctuaryStats(
            conversationCount: 145, earliest: Date(timeIntervalSince1970: 1_690_000_000),
            latestActivity: Date(timeIntervalSince1970: 1_700_000_000), outlivedClaudeCode: 0)
        s.volume = (userChars: 1_300_000, totalChars: 16_100_000)
        let doc = render(s)
        XCTAssertTrue(doc.contains("milestones passed: 100 conversations · 10.0M characters"), doc)
    }

    // MARK: - 观察项 A:反复交代的话

    func testRepeatedBriefingsClustersSimilarCrossConversation() {
        let brief = "你是资深审查员,正在审查 Task N 的代码质量,请只看规格符合性"
        let corpus: [(text: String, convID: String, startAt: Date)] = [
            (text: brief.replacingOccurrences(of: "N", with: "3"), convID: "a", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 0 * 30 * 86_400)),
            (text: brief.replacingOccurrences(of: "N", with: "4"), convID: "b", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 1 * 30 * 86_400)),
            (text: brief.replacingOccurrences(of: "N", with: "5"), convID: "c", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 2 * 30 * 86_400)),
            (text: "完全无关的一句话,聊聊今天天气怎么样吧", convID: "d", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 3 * 30 * 86_400)),
        ]
        let groups = MindsBuilder.repeatedBriefings(corpus: corpus, limit: 5)
        XCTAssertEqual(groups.count, 1, "三条同模板该聚成一组,无关句不进: \(groups)")
        XCTAssertEqual(groups.first?.times, 3)
        XCTAssertEqual(groups.first?.conversations, 3)
    }

    func testRepeatedBriefingsFiltersNoiseAndSameConversation() {
        let corpus: [(text: String, convID: String, startAt: Date)] = [
            // 编号行与 JSON 键值是粘贴残留,不算「你讲的话」
            (text: "1. 地形倍率:road 1、plain 1、mountain 1.35", convID: "a", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 0 * 30 * 86_400)),
            (text: "2. 地形倍率:road 1、plain 1、mountain 1.35", convID: "b", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 1 * 30 * 86_400)),
            (text: "3. 地形倍率:road 1、plain 1、mountain 1.35", convID: "c", startAt: Date(timeIntervalSince1970: 1_700_000_000 + 2 * 30 * 86_400)),
            // 同一会话内的三遍重复:times 够但 conversations=1,不算「反复交代」
            (text: "帮我把这个模块重构一下注意保持接口\n帮我把这个模块重构一下注意保持接口\n帮我把这个模块重构一下注意保持接口", convID: "x", startAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        XCTAssertTrue(MindsBuilder.repeatedBriefings(corpus: corpus, limit: 5).isEmpty)
    }

    func testRenderRepeatedBriefings() {
        var s = MindsBuilder.SurpriseData()
        s.repeatedBriefings = [MindsBuilder.RepeatedBriefing(
            sample: "你是 Senior Code Reviewer,正在审查 Task 4 的代码质量", times: 6, conversations: 4)]
        let doc = render(s)
        XCTAssertTrue(doc.contains("## REPEATED BRIEFINGS"))
        XCTAssertTrue(doc.contains("said 6× across 4 conversations"))
        XCTAssertTrue(doc.contains("minds_enrich"), "节说明要引导宿主模型走 enrich 管道")
    }

    // MARK: - 屏蔽机制

    func testMutedResurfaceStoreRoundTrip() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "muted-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MutedResurfaceStore(fileURL: url)
        XCTAssertFalse(store.isMuted("c1"))
        store.mute("c1")
        XCTAssertTrue(store.isMuted("c1"))
        // 重新加载(持久化验证)
        let reloaded = MutedResurfaceStore(fileURL: url)
        XCTAssertTrue(reloaded.isMuted("c1"))
        reloaded.unmute("c1")
        XCTAssertFalse(reloaded.isMuted("c1"))
    }

    // MARK: - 补全:知识流动方向 / FADED 月度序列

    func testKnowledgeFlowDirectionByFirstSeen() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // SharedConcept 先出现在 alpha(早 5 天),后出现在 beta → 方向 alpha→beta
        try put("a1", cwd: "/p/alpha", start: base, entity: "SharedConcept")
        try put("b1", cwd: "/p/beta", start: base.addingTimeInterval(5 * 86_400), entity: "SharedConcept")
        let flows = index.knowledgeFlows(minShared: 1, limit: 5)
        XCTAssertEqual(flows.count, 1)
        let f = flows[0]
        // cwd 字典序 alpha<beta → projectA=alpha
        XCTAssertEqual(f.projectA, "alpha")
        XCTAssertEqual(f.bornInAFirst, 1, "实体先现于 alpha")
        XCTAssertEqual(f.bornInBFirst, 0)
    }


    func testMonthlyOccurrencesBucketsOldToNew() {
        let now = Date(timeIntervalSince1970: 1_755_000_000)
        let cal = Calendar.current
        let m0 = MindsBuilder.monthStart(of: now)                                   // 本月
        let m3 = cal.date(byAdding: .month, value: -3, to: m0)!                     // 三个月前
        let corpus: [(text: String, startAt: Date)] = [
            (text: "协变量很重要,协变量决定一切", startAt: m3.addingTimeInterval(3_600)),
            (text: "再提一次协变量", startAt: m0.addingTimeInterval(3_600)),
        ]
        let series = MindsBuilder.monthlyOccurrences(corpus: corpus, word: "协变量",
                                                     monthsBack: 12, now: now)
        XCTAssertEqual(series.count, 12)
        XCTAssertEqual(series[11], 1, "本月 1 次(末位=最新)")
        XCTAssertEqual(series[8], 2, "三个月前 2 次(同文本内两次都数)")
        XCTAssertEqual(series.reduce(0, +), 3)
    }

    // MARK: - 救回可见化

    func testComputeRescuedOnlyMissingWithArchive() {
        let rows = [(id: "gone", path: "/f/gone"), (id: "alive", path: "/f/alive"),
                    (id: "noarch", path: "/f/noarch"), (id: "browser", path: "browser-x/1.jsonl#3")]
        let rescued = ConversationStore.computeRescued(
            rows: rows,
            exists: { $0 == "/f/alive" },
            hasArchive: { $0 == "/f/gone" })
        XCTAssertEqual(rescued, ["gone"], "只有「源没了且有归档」算救回;伪路径/无归档/还活着都不算")
    }

    func testRenderSanctuaryRescuedLineFirst() {
        var s = MindsBuilder.SurpriseData()
        s.sanctuary = ConversationIndex.SanctuaryStats(
            conversationCount: 145, earliest: Date(timeIntervalSince1970: 1_690_000_000),
            latestActivity: Date(timeIntervalSince1970: 1_700_000_000), outlivedClaudeCode: 8)
        s.rescuedCount = 3
        let doc = render(s)
        XCTAssertTrue(doc.contains("**3 conversations rescued** — deleted by their tool, alive here"), doc)
        XCTAssertLessThan(doc.range(of: "rescued")!.lowerBound,
                          doc.range(of: "outlived")!.lowerBound, "救回行排在越线行之前——最强证明置首")
    }

}

// MARK: - 技术名词也算常用词（2026-08-18）

extension MindsSurpriseTests {

    /// 真机现场：GitHub 说了 160 次、覆盖 33 场、跨 28 个项目，却从没进过「常用词」——
    /// 因为个人词表只挖中文（`PersonalLexicon` 碰到非 CJK 就断 run，含拉丁字母的词恒为 0）。
    func testTechnicalTermsAdmitsCrossProjectIdentifier() {
        let corpus = (0..<5).map { i in
            (text: String(repeating: "去 GitHub 调研一下。", count: 4), cwd: "/p/\(i)")
        }
        let terms = MindsBuilder.technicalTerms(
            candidates: [(text: "GitHub", projects: 28)],
            corpus: corpus, excluding: [], minTF: 15, minProjects: 3)
        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].word, "GitHub", "显示用实体的规范写法")
        XCTAssertEqual(terms[0].tf, 20)
        XCTAssertEqual(terms[0].projects, 5)
    }

    /// 大小写不敏感地计数：用户既写 GitHub 也写 github，是同一个词
    func testTechnicalTermsCountsCaseInsensitively() {
        let corpus = [(text: "GitHub github GITHUB gIthUb", cwd: "/p/a"),
                      (text: "github 上看看", cwd: "/p/b"),
                      (text: "再去 GitHub", cwd: "/p/c")]
        let terms = MindsBuilder.technicalTerms(
            candidates: [(text: "GitHub", projects: 9)],
            corpus: corpus, excluding: [], minTF: 6, minProjects: 3)
        XCTAssertEqual(terms.first?.tf, 6)
        XCTAssertEqual(terms.first?.df, 3)
    }

    /// 项目内部的标识符不算「你的词」：NodeNext 说了 48 次但只跨 2 个项目
    func testTechnicalTermsRejectsSingleProjectIdentifier() {
        let corpus = [(text: String(repeating: "NodeNext ", count: 48), cwd: "/p/only")]
        let terms = MindsBuilder.technicalTerms(
            candidates: [(text: "NodeNext", projects: 2)],
            corpus: corpus, excluding: [], minTF: 15, minProjects: 3)
        XCTAssertTrue(terms.isEmpty, "跨项目数不够就不算跟着你走的词")
    }

    /// 粘报错时捎带进来的：node_modules 跨 6 个项目但只说过 5 次
    func testTechnicalTermsRejectsLowFrequencyNoise() {
        let corpus = (0..<5).map { i in (text: "node_modules", cwd: "/p/\(i)") }
        let terms = MindsBuilder.technicalTerms(
            candidates: [(text: "node_modules", projects: 6)],
            corpus: corpus, excluding: [], minTF: 15, minProjects: 3)
        XCTAssertTrue(terms.isEmpty)
    }

    /// 项目自己的名字不算——「我反复聊 MindBus」零意外度（与 recurring 同一条理由）
    func testTechnicalTermsExcludesProjectOwnName() {
        let corpus = (0..<5).map { i in
            (text: String(repeating: "MindBus ", count: 8), cwd: "/p/\(i)")
        }
        let terms = MindsBuilder.technicalTerms(
            candidates: [(text: "MindBus", projects: 5)],
            corpus: corpus, excluding: ["mindbus"], minTF: 15, minProjects: 3)
        XCTAssertTrue(terms.isEmpty)
    }

    /// 口水词的 df 阈值只管中文：它的经验依据全来自中文双字词，
    /// 拿去卡拉丁专名会把 GitHub（覆盖 22%）判成「口头语」
    func testLatinTermsAreExemptFromChineseStopwordRatio() {
        let n = 150
        let cjkFiller = MindsBuilder.VocabWord(word: "我们", tf: 400, projects: 20, df: 35)   // 23%
        let latinNoun = MindsBuilder.VocabWord(word: "GitHub", tf: 160, projects: 25, df: 33) // 22%
        let doc = MindsBuilder.renderVocabulary(stats: [cjkFiller, latinNoun],
                                                totalConversations: n)
        XCTAssertTrue(doc.contains("GitHub"), "拉丁专名不该被中文口水词阈值毙掉：\(doc)")
        XCTAssertFalse(doc.contains("我们"), "中文口水词仍要被挡住：\(doc)")
    }
}

// MARK: - 你引用过的人（2026-08-18）

extension MindsSurpriseTests {

    /// 用真机实测到的数字当夹具。断言的是**策略**（跨项目 + 一致性），
    /// 不是 NLTagger 的判断——那是系统 ML 模型，行为随 OS 版本变，
    /// 写进断言等于测苹果。识别本身只做冒烟（见最后一条）。
    private var realWorldDetections: [MindsBuilder.NameDetection] {
        [.init(name: "乔布斯", taggedHits: 8),    // 一致性 8/8   = 100%
         .init(name: "马斯克", taggedHits: 3),    // 3/3   = 100%
         .init(name: "宫本茂", taggedHits: 17),   // 17/18 = 94%
         .init(name: "贝索斯", taggedHits: 1),    // 1/3   = 33%
         .init(name: "曹操", taggedHits: 29),     // 100% 但只 1 个项目
         .init(name: "袁绍", taggedHits: 6),
         .init(name: "小红", taggedHits: 6),      // 6/27  = 22% ←「小红书」
         .init(name: "高亮", taggedHits: 4)]      // 4/16  = 25% ← UI 术语
    }

    /// 语料只用来算一致性的分母，按真机的总出现次数造
    /// 按真机的项目分布造：曹操/袁绍只在一个项目（三国游戏），
    /// 乔布斯跨 3 个、马斯克/宫本茂/贝索斯跨 2 个
    private var realWorldCorpus: [(text: String, cwd: String)] {
        func rep(_ w: String, _ n: Int) -> String { String(repeating: w + "。", count: n) }
        return [(text: rep("乔布斯", 4) + rep("马斯克", 2) + rep("宫本茂", 9)
                     + rep("贝索斯", 2) + rep("曹操", 29) + rep("袁绍", 8)
                     + rep("小红书", 11) + rep("小红", 3)
                     + rep("高亮显示", 6) + rep("高亮", 2), cwd: "/p/game"),
                (text: rep("乔布斯", 2) + rep("马斯克", 1) + rep("宫本茂", 9)
                     + rep("贝索斯", 1) + rep("小红书", 10) + rep("小红", 3)
                     + rep("高亮显示", 6) + rep("高亮", 2), cwd: "/p/b"),
                (text: rep("乔布斯", 2), cwd: "/p/c")]
    }

    func testCitedPeopleDropsProjectCharacters() {
        let people = MindsBuilder.citedPeople(detections: realWorldDetections,
                                              corpus: realWorldCorpus).map(\.name)
        XCTAssertFalse(people.contains("曹操"), "29 次但只在 1 个项目——那是游戏角色数据：\(people)")
        XCTAssertFalse(people.contains("袁绍"), people.description)
    }

    func testCitedPeopleDropsLowConsistencyFalsePositives() {
        let people = MindsBuilder.citedPeople(detections: realWorldDetections,
                                              corpus: realWorldCorpus).map(\.name)
        XCTAssertFalse(people.contains("小红"), "27 次里只有 6 次被判人名(其余是小红书)：\(people)")
        XCTAssertFalse(people.contains("高亮"), "UI 术语被误判成人名：\(people)")
    }

    func testCitedPeopleKeepsRealCitations() {
        let people = MindsBuilder.citedPeople(detections: realWorldDetections,
                                              corpus: realWorldCorpus).map(\.name)
        XCTAssertTrue(people.contains("乔布斯"), people.description)
        XCTAssertTrue(people.contains("马斯克"), people.description)
        XCTAssertTrue(people.contains("宫本茂"), people.description)
    }

    /// 频次不是门槛——这正是这一节存在的理由：马斯克真机只说过 3 次，
    /// 按任何频次口径都排不进任何榜
    func testCitedPeopleHasNoFrequencyFloor() {
        let people = MindsBuilder.citedPeople(detections: realWorldDetections,
                                              corpus: realWorldCorpus)
        let musk = people.first { $0.name == "马斯克" }
        XCTAssertEqual(musk?.mentions, 3)
        XCTAssertEqual(musk?.projects, 2)
    }

    /// 排序:跨项目多的在前(乔布斯 3 > 马斯克/宫本茂 2)
    func testCitedPeopleRanksByProjectSpread() {
        let people = MindsBuilder.citedPeople(detections: realWorldDetections,
                                              corpus: realWorldCorpus)
        XCTAssertEqual(people.first?.name, "乔布斯")
    }

    /// 一致性阈值是可调的策略,不是魔法数:贝索斯真机 33%,阈值抬到 0.5 就该出局
    func testConsistencyThresholdIsWhatDecidesBezos() {
        let loose = MindsBuilder.citedPeople(detections: realWorldDetections,
                                             corpus: realWorldCorpus,
                                             minConsistency: 0.3).map(\.name)
        let strict = MindsBuilder.citedPeople(detections: realWorldDetections,
                                              corpus: realWorldCorpus,
                                              minConsistency: 0.5).map(\.name)
        XCTAssertTrue(loose.contains("贝索斯"), loose.description)
        XCTAssertFalse(strict.contains("贝索斯"), strict.description)
    }

    func testCitedPeopleRendersAndParsesBack() {
        var s = MindsBuilder.SurpriseData()
        s.citedPeople = [.init(name: "乔布斯", mentions: 8, projects: 3),
                         .init(name: "马斯克", mentions: 3, projects: 2)]
        let doc = MindsDocument(markdown: render(s))
        let chips = doc.chipRow("PEOPLE YOU CITE")
        XCTAssertEqual(chips.map(\.word), ["乔布斯", "马斯克"])
        XCTAssertEqual(chips.first?.meta, "8×/3p")
    }

    /// 冒烟:识别这一层只保证「跑得起来、不崩、不返回空串」,不断言认出了谁
    func testDetectPersonNamesSmoke() {
        let found = MindsBuilder.detectPersonNames(
            corpus: [(text: "乔布斯在发布会上说专注就是拒绝一百件事", cwd: "/p/a")])
        XCTAssertTrue(found.allSatisfy { !$0.name.isEmpty && $0.taggedHits > 0 })
    }
}

extension MindsSurpriseTests {
    /// 背景语料：不含被测短语的普通对话。
    /// 没有它，测试语料里每个成分的会话覆盖率都是 100%，
    /// 成分过滤会把一切毙掉——真实语料从来不长这样。
    func backgroundCorpus(_ n: Int) -> [(text: String, cwd: String)] {
        (0..<n).map { i in
            (text: "把仓库里的日志归档一下，顺便看看构建产物 \(i)", cwd: "/bg/\(i % 7)")
        }
    }
}

// MARK: - 短语成分口水词过滤（2026-08-18）

extension MindsSurpriseTests {

    /// 「需要 X」这一族是句式框架不是概念。判据不是黑名单：短语里任一 CJK 双字
    /// 成分覆盖太多会话，它就是模板。真机上「需要」覆盖 45% 的对话，
    /// 于是需要优化/需要增加/需要怎么/是否需要 被一次清掉。
    func testFrameworkPhrasesAreDroppedByComponentRatio() {
        var corpus = backgroundCorpus(40)
        // 「需要」出现在几乎每一场——它是这个人的口头语
        for i in 0..<40 {
            corpus.append((text: "这里需要优化一下。还需要增加一个开关。需要优化。",
                           cwd: "/p/\(i % 5)"))
        }
        // 「用户旅程」只在少数几场，但两个成分都不是口头语
        for i in 0..<6 {
            corpus.append((text: "把用户旅程重新梳理一遍。用户旅程。", cwd: "/p/x\(i % 4)"))
        }
        let phrases = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20).map(\.phrase)
        XCTAssertTrue(phrases.contains { $0.contains("用户旅程") }, phrases.description)
        XCTAssertFalse(phrases.contains { $0.hasPrefix("需要") },
                       "含高覆盖成分的短语是句式框架：\(phrases)")
    }

    /// ASCII 的字母 bigram 天然高频（skill 里的 il/ll），不能拿它算成分覆盖率，
    /// 否则所有含英文的短语都会被误杀
    func testAsciiBigramsDoNotCountAsComponents() {
        var corpus: [(text: String, cwd: String)] = []
        for i in 0..<8 {
            corpus.append((text: "把 AI 味去掉。AI 味太重了。", cwd: "/p/\(i % 4)"))
        }
        corpus += backgroundCorpus(40)
        let phrases = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20).map(\.phrase)
        XCTAssertTrue(phrases.contains { $0.contains("AI") },
                      "含英文的短语不该被字母 bigram 误杀：\(phrases)")
    }

    /// 阈值是可调的策略，不是魔法数
    /// 阈值是策略不是魔法数。真机定阈现场:概念型 热点事件 20% · 第一性原理 23% ·
    /// 用户旅程 25% · 产品经理 27%;框架型 怎么设计 30% · 这个地方 39% ·
    /// 一个完整 43% · 需要 X 一族 45%。分界在 27%→30% 之间。
    func testComponentRatioThresholdSitsInTheRealGap() {
        XCTAssertGreaterThan(MindsBuilder.phraseComponentDFRatio, 0.27,
                             "低于 0.27 会误伤「产品经理」这类真概念")
        XCTAssertLessThanOrEqual(MindsBuilder.phraseComponentDFRatio, 0.30,
                                 "高于 0.30 会放进「怎么设计」这类句式框架")
    }

    /// 小语料豁免:9 场里每个成分覆盖率都接近 100%,比例失去分辨力,
    /// 此时不做成分过滤——否则所有短语一起出局
    func testComponentFilterIsSkippedOnTinyCorpus() {
        var corpus: [(text: String, cwd: String)] = []
        for p in ["/a", "/b", "/c"] {
            for _ in 0..<3 { corpus.append((text: "从第一性原理思考整件事", cwd: p)) }
        }
        XCTAssertLessThan(corpus.count, MindsBuilder.phraseComponentMinConversations)
        let ps = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 10).map(\.phrase)
        XCTAssertFalse(ps.isEmpty, "样本不足时不该把短语全毙掉：\(ps)")
    }
}

// MARK: - 同族合并与代词过滤（2026-08-18）

extension MindsSurpriseTests {

    /// 同一个概念的不同说法只占一个位置。真机现场：「第一性原理」一族独占 5 个位置
    /// （第一性原理 53× / 从第一性原理 26× / 第一性原理思考 16× /
    /// 从第一性原理思考 12× / 按照第一性原理 10×），把别的概念全挤出榜。
    func testPhraseFamilyCollapsesToItsCore() {
        var corpus = backgroundCorpus(80)
        for i in 0..<10 {
            corpus.append((text: "从第一性原理思考这件事。第一性原理。按照第一性原理来看。第一性原理。",
                           cwd: "/p/\(i % 6)"))
        }
        let ps = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20).map(\.phrase)
        let family = ps.filter { $0.contains("第一性") }
        XCTAssertEqual(family.count, 1, "一族只该占一个位置：\(family)")
        XCTAssertEqual(family.first, "第一性原理", "留下的该是最核心的说法（子串频次必然更高）")
    }

    /// 两步顺序不能颠倒：先按长度去碎片，再按频次合并同族。
    /// 反过来做（直接按频次排）会让「从第一性」「原理思考」这类部分重叠的碎片
    /// 没人吃掉——2026-08-18 改错过一次的现场。
    func testFamilyMergeDoesNotResurrectFragments() {
        var corpus = backgroundCorpus(80)
        for i in 0..<10 {
            corpus.append((text: "从第一性原理思考。第一性原理。第一性原理思考。",
                           cwd: "/p/\(i % 6)"))
        }
        let ps = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20).map(\.phrase)
        for bad in ["从第一性", "原理思考", "一性原理思", "照第一性原"] {
            XCTAssertFalse(ps.contains(bad), "碎片不该出现：\(ps)")
        }
    }

    /// 代词是封闭类，不是语义黑名单。真机上挡住的是 我不知道 · 让我看看 ·
    /// 我希望能 · 我觉得你 · 我的理解 · 我们自己 · 类似这样 · 这些信息。
    func testPronounPhrasesAreDropped() {
        var corpus = backgroundCorpus(80)
        for i in 0..<10 {
            corpus.append((text: "我不知道这样对不对。我们自己看看。这些信息够吗。用户旅程要重梳。",
                           cwd: "/p/\(i % 6)"))
        }
        let ps = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20).map(\.phrase)
        XCTAssertFalse(ps.contains { MindsBuilder.containsPronoun($0) }, ps.description)
        XCTAssertTrue(ps.contains { $0.contains("用户旅程") }, "不含代词的概念该留下：\(ps)")
    }

    func testContainsPronounClassifier() {
        for p in ["我不知道", "我们自己", "这些信息", "类似这样", "那个方案", "什么意思"] {
            XCTAssertTrue(MindsBuilder.containsPronoun(p), p)
        }
        for p in ["用户旅程", "第一性原理", "产品经理", "热点事件", "最佳实践", "在 github"] {
            XCTAssertFalse(MindsBuilder.containsPronoun(p), p)
        }
    }
}

// MARK: - 反复交代的话：跨度门槛（2026-08-18）

extension MindsSurpriseTests {

    /// 同一个任务周期里的重复不算「反复交代」。真机验证：不加跨度门槛时
    /// 12 条里 11 条跨度 0-4 天，全部来自同一批讨论——会话被切分后用户重新
    /// 粘贴前情造成的，不是隔了一段时间还要再讲一遍的规矩。
    func testBriefingsRejectSameTaskRepetition() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let line = "你写的评估方法太复杂了，稍微简单一点，我只要短期和长期两套"
        let corpus = (0..<3).map { i in
            (text: line, convID: "c\(i)", startAt: base.addingTimeInterval(Double(i) * 86_400))
        }
        let out = MindsBuilder.repeatedBriefings(corpus: corpus, limit: 5)
        XCTAssertTrue(out.isEmpty, "跨 2 天的重复是同一个任务的上下文，不是反复交代：\(out)")
    }

    /// 隔了一段时间还在讲，才是该沉淀成模板的那种
    func testBriefingsKeepLongSpanRepetition() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let line = "按照我们之前聊的那套做法，利用 skill 把这件事继续推下去"
        let corpus = [
            (text: line, convID: "a", startAt: base),
            (text: line, convID: "b", startAt: base.addingTimeInterval(40 * 86_400)),
            (text: line, convID: "c", startAt: base.addingTimeInterval(82 * 86_400)),
        ]
        let out = MindsBuilder.repeatedBriefings(corpus: corpus, limit: 5)
        XCTAssertEqual(out.count, 1, "\(out)")
        XCTAssertEqual(out.first?.conversations, 3)
        XCTAssertGreaterThanOrEqual(out.first?.spanDays ?? 0, MindsBuilder.briefingMinSpanDays)
    }

    func testBriefingSpanFloorIsTwoWeeks() {
        XCTAssertEqual(MindsBuilder.briefingMinSpanDays, 14)
    }
}

// MARK: - 词性剔虚词（2026-08-18）

extension MindsSurpriseTests {

    /// 词类是语法事实不是词义判断——介词/连词/代词/副词在汉语里是封闭类。
    /// 真机验证：按跨项目排序时 非常(Adverb) · 完全(OtherWord) · 以及(Conjunction)
    /// 会混进 top16，而 目标/平台/识别/架构/信号 全是 Noun/Verb。
    func testFunctionWordClassesCoverTheClosedClasses() {
        for c in ["Adverb", "Conjunction", "Pronoun", "Preposition", "Particle", "Determiner"] {
            XCTAssertTrue(MindsBuilder.functionWordClasses.contains(c), c)
        }
        for c in ["Noun", "Verb", "Adjective"] {
            XCTAssertFalse(MindsBuilder.functionWordClasses.contains(c), c)
        }
    }

    /// 查不到词性的必须保留：系统分词器不认识的词（真机上「大模型」被它切开了）
    /// 不该因为工具的局限而出局
    func testUnknownPOSDefaultsToKeeping() {
        let map = MindsBuilder.contentWordByPOS(corpus: ["把这个平台的识别逻辑理一遍"])
        // 没被切成独立词元的串查不到，调用方按「保留」处理
        XCTAssertNil(map["某个分词器不认识的怪词"])
    }

    /// 冒烟:标注这一层只保证跑得起来、给出的是布尔判断。
    /// 不断言具体词的词性——那是系统 ML 模型,行为随 OS 版本变。
    func testContentWordByPOSSmoke() {
        let map = MindsBuilder.contentWordByPOS(
            corpus: ["我们非常需要一个平台以及完整的识别能力"])
        XCTAssertFalse(map.isEmpty)
    }
}
