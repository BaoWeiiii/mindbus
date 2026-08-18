import XCTest
@testable import MindBusCore

/// 通用性证明：同一套代码、一行不改，跑一份**纯英文、零汉字**的语料。
///
/// 这组用例是「判据是否绑死在中文上」的守门人。任何一条判据要是被改回
/// 中文词表（认可词、疑问词、征询模式、代词），这里会先红。
final class MindsCrossLanguageTests: XCTestCase {

    private func msg(_ role: MessageRole, _ text: String, minute: Int) -> Message {
        Message(id: UUID().uuidString, role: role,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60),
                blocks: [.text(text)])
    }
    private func plain(_ m: Message) -> String { m.firstTextBlock ?? "" }

    private func report(_ head: String) -> String {
        head + ". " + String(repeating: "Every change is listed with its verification below. ", count: 8)
    }

    /// 英文语料里没有一个汉字，认可词必须**学**得出来。
    /// 说中文的人会学到「继续」，说英文的人学到 continue / lgtm。
    private var englishConversations: [[Message]] {
        var convs: [[Message]] = []
        for k in 0..<6 {
            convs.append([
                msg(.assistant, report("Shipped the migration for module \(k)"), minute: 0),
                msg(.user, "continue", minute: 1),
                msg(.assistant, report("Backfill finished for module \(k), 96/96 green"), minute: 2),
                msg(.user, "lgtm", minute: 3),
                msg(.assistant, report("Rollout \(k) done"), minute: 4),
                // 长句反馈不是认可,不该被学进表里
                msg(.user, "hold on, the retry path still looks wrong to me here", minute: 5),
            ])
        }
        return convs
    }

    func testApprovalsAreLearnedFromEnglishCorpus() {
        let learned = MindsMilestones.learnApprovals(conversations: englishConversations,
                                                     text: plain)
        XCTAssertTrue(learned.contains("continue"), "\(learned)")
        XCTAssertTrue(learned.contains("lgtm"), "\(learned)")
        XCTAssertFalse(learned.contains(where: { $0.count > MindsMilestones.maxApprovalLength }),
                       "长句反馈不该被学成认可词：\(learned)")
    }

    func testMilestonesExtractedFromEnglishWithLearnedApprovals() {
        let convs = englishConversations
        let learned = MindsMilestones.learnApprovals(conversations: convs, text: plain)
        let out = convs.flatMap {
            MindsMilestones.extract(messages: $0, approvals: learned, text: plain)
        }
        XCTAssertFalse(out.isEmpty, "英文语料必须也能产出里程碑")
        XCTAssertTrue(out.contains { $0.headline.hasPrefix("Shipped the migration") },
                      out.map(\.headline).description)
        XCTAssertTrue(out.contains { $0.approval == "lgtm" })
        // 没有一条里程碑含汉字——证明输出确实来自英文语料
        XCTAssertFalse(out.contains { $0.headline.contains(where: { ("\u{4E00}"..."\u{9FFF}").contains($0) }) })
    }

    /// 征询判据是「够长 + 问号收尾」，与语言无关
    func testSolicitationAndDecisionWorkInEnglish() {
        let ask = String(repeating: "Both routes have real trade-offs worth weighing carefully. ", count: 6)
            + "Which one do you want?"
        XCTAssertTrue(MindsMilestones.isSolicitation(ask))
        let ms = [msg(.assistant, ask, minute: 0),
                  msg(.user, "ship the smaller one, we can revisit later", minute: 1)]
        let out = MindsMilestones.extractDecisions(messages: ms, text: plain)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].statement, "ship the smaller one, we can revisit later")
    }

    func testEnglishQuestionIsNotADecision() {
        let ask = String(repeating: "Both routes have real trade-offs worth weighing. ", count: 6)
            + "Which one do you want?"
        let ms = [msg(.assistant, ask, minute: 0),
                  msg(.user, "what does the second one cost us?", minute: 1)]
        XCTAssertTrue(MindsMilestones.extractDecisions(messages: ms, text: plain).isEmpty)
    }

    /// 代词过滤靠传进来的表，换成英文代词就服务英文
    func testPronounFilterIsTableDriven() {
        let en: Set<String> = ["we", "i", "this", "that", "what"]
        XCTAssertTrue(MindsBuilder.containsPronoun("what we shipped", pronouns: en))
        XCTAssertFalse(MindsBuilder.containsPronoun("user journey", pronouns: en))
        // 同一个函数、换一张表就服务中文
        XCTAssertTrue(MindsBuilder.containsPronoun("我们自己", pronouns: ["我们", "自己"]))
    }

    /// 词类过滤走系统标注器，标签集跨语言一致（Noun/Verb/Pronoun…）
    func testPOSClassesAreLanguageNeutral() {
        let map = MindsBuilder.contentWordByPOS(
            corpus: ["We should ship the smaller migration first and measure it."])
        XCTAssertFalse(map.isEmpty, "英文语料也要标得出词性")
        for c in ["Adverb", "Conjunction", "Pronoun", "Preposition", "Determiner"] {
            XCTAssertTrue(MindsBuilder.functionWordClasses.contains(c), c)
        }
    }
}

// MARK: - 词边界（通用化逼出来的真 bug）

extension MindsCrossLanguageTests {

    /// 代词表改成从语料学之后，英文的「I」被学了进来；而匹配是子串匹配，
    /// 于是「AI 味」「AI 产品」当场被误杀（2026-08-18 真机现场）。
    /// 拉丁代词必须按词边界匹配。
    func testLatinPronounsMatchOnWordBoundaryOnly() {
        let learned: Set<String> = ["I", "we", "it", "you"]
        for keep in ["AI 味", "AI 产品", "API 设计", "UI 走查", "CI 挂了", "webhook 回调"] {
            XCTAssertFalse(MindsBuilder.containsPronoun(keep, pronouns: learned),
                           "「\(keep)」里没有独立的代词，不该被过滤")
        }
        for drop in ["what I shipped", "we should ship it", "did you check"] {
            XCTAssertTrue(MindsBuilder.containsPronoun(drop, pronouns: learned), drop)
        }
    }

    /// 中日韩没有词间空格，子串匹配才是正确的匹配
    func testCJKPronounsStillMatchAsSubstring() {
        XCTAssertTrue(MindsBuilder.containsPronoun("我不知道", pronouns: ["我"]))
        XCTAssertTrue(MindsBuilder.containsPronoun("类似这样", pronouns: ["这样"]))
        XCTAssertFalse(MindsBuilder.containsPronoun("用户旅程", pronouns: ["我", "这样"]))
    }

    func testWordBoundaryHelperDirectly() {
        XCTAssertTrue(MindsBuilder.matchesAsWord("we", in: "we ship"))
        XCTAssertTrue(MindsBuilder.matchesAsWord("we", in: "should we ship"))
        XCTAssertTrue(MindsBuilder.matchesAsWord("I", in: "AI, I think"), "同串里有独立词就算命中")
        XCTAssertFalse(MindsBuilder.matchesAsWord("we", in: "webhook"))
        XCTAssertFalse(MindsBuilder.matchesAsWord("I", in: "API"))
    }
}

// MARK: - 短语层的通用性

extension MindsCrossLanguageTests {

    /// 说英文的人也该有「你反复说的话」。原先段和短语都硬性要求含汉字，
    /// 纯英文语料一条都出不来（2026-08-18 真机探针实测返回 []）。
    func testEnglishOnlyCorpusYieldsRepeatedPhrases() {
        let corpus: [(text: String, cwd: String)] = (0..<40).map { i in
            (text: i % 2 == 0
                ? "the user journey needs work before we ship anything"
                : "let us walk the user journey with the product manager first",
             cwd: "/proj\(i % 6)")
        }
        let out = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 10, pronouns: [])
        XCTAssertTrue(out.contains { $0.phrase.contains("user journey") },
                      "纯英文语料也该找出反复说的话，实际: \(out)")
    }

    /// 「AI 产」这类残片不该进榜——它右边永远只跟着「品」，
    /// 说明它是「AI 产品」被切出来的一半，不是一个词。
    func testTruncatedFragmentLosesToTheCompleteWord() {
        // 10 条反复说「AI 产品」+ 30 条背景。语料整齐划一的话每个成分的
        // 会话覆盖率都是 100%,成分过滤会把一切一起毙掉——真实语料不长这样。
        var corpus: [(text: String, cwd: String)] = (0..<10).map { i in
            (text: i % 2 == 0
                ? "这个 AI 产品的调度还要再想想清楚"
                : "我们把 AI 产品做成本地优先的东西",
             cwd: "/proj\(i % 5)")
        }
        corpus += (0..<30).map { i in
            (text: "把仓库里的日志归档一下，顺便看看构建结果", cwd: "/bg\(i % 7)")
        }
        let out = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20, pronouns: [])
        XCTAssertFalse(out.contains { $0.phrase == "AI 产" }, "截断残片不该进榜: \(out)")
        XCTAssertTrue(out.contains { $0.phrase.contains("AI 产品") }, "完整的词该在: \(out)")
    }

    /// 词内部收敛、边界处发散——判据本身
    func testRightBranchingSeparatesFragmentsFromWords() {
        // 残片：右边几乎只有一种可能
        XCTAssertTrue(MindsBuilder.isTruncatedFragment(rightNeighbors: ["品": 84, "的": 8, "，": 8]))
        // 完整的词：右边五花八门
        XCTAssertFalse(MindsBuilder.isTruncatedFragment(
            rightNeighbors: ["团": 16, "的": 15, "在": 12, "，": 20, "": 20, "说": 17]))
        // 标点和段尾是「这里就是词尾」的证据，不算收敛
        XCTAssertFalse(MindsBuilder.isTruncatedFragment(rightNeighbors: ["，": 45, "": 40, "很": 15]))
    }
}

// MARK: - 放开非中文之后冒出来的三类噪声（2026-08-18 真机）

extension MindsCrossLanguageTests {

    func noise(_ n: Int) -> [(text: String, cwd: String)] {
        (0..<n).map { i in (text: "把仓库里的日志归档一下，顺便看看构建结果", cwd: "/bg\(i % 7)") }
    }

    /// 文件路径、XML 片段、工具输出不是「你说的话」。真机上短语层一放开非中文，
    /// 家目录路径 306 次冲到榜首（还带着用户名），「image> </image」
    /// 「path="/var/folders」紧随其后——它们都带着自然语言里不会出现的字符。
    func testMachineTextNeverBecomesAPhrase() {
        var corpus: [(text: String, cwd: String)] = (0..<12).map { i in
            (text: "看看 Users/somebody/dev 和 <image name=\"cover\"> 的差别", cwd: "/proj\(i % 5)")
        }
        corpus += noise(30)
        let out = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20, pronouns: [])
        XCTAssertFalse(out.contains { p in
            "/<>=\"{}[]|\\".contains(where: { p.phrase.contains($0) })
        }, "路径与标记不是人说的话: \(out)")
    }

    /// 英文短语的首尾不能是虚词——这与中文 `phraseEdgeStops`（的/了/着/地/得）
    /// 是同一条规矩，区别只在中文那张表是手写的、英文这张是 POS 学出来的。
    func testLatinEdgeFunctionWordsAreRejected() {
        let fw: Set<String> = ["the", "in", "to", "is", "a", "as", "on", "we"]
        for bad in ["the user", "in the", "is a", "ship it to", "we ship"] {
            XCTAssertTrue(MindsBuilder.edgeIsFunctionWord(bad, functionWords: fw), bad)
        }
        for good in ["user journey", "Claude Code", "AI 味", "product manager"] {
            XCTAssertFalse(MindsBuilder.edgeIsFunctionWord(good, functionWords: fw), good)
        }
    }

    /// 功能词表也是学出来的，不是写死的英文停用词表
    func testFunctionWordsAreLearnedNotHardcoded() {
        let corpus = Array(repeating: "we should ship the redesign to the team in a week", count: 12)
        let fw = MindsBuilder.functionWordsByPOS(corpus: corpus)
        XCTAssertTrue(fw.contains("the"), "\(fw)")
        XCTAssertFalse(fw.contains("redesign"), "\(fw)")
    }

    /// 段的下限按字符算、上限按词元算：「有 AI 味」只有 3 个词元却有 6 个字，
    /// 下限也按词元卡的话这种短句会被整段丢掉（真机上「AI 味」因此从 61 掉到 31 次）。
    func testShortSegmentsWithLatinWordsStillCount() {
        var corpus: [(text: String, cwd: String)] = (0..<12).map { i in
            (text: "有 AI 味，改掉", cwd: "/proj\(i % 5)")
        }
        corpus += noise(30)
        let out = MindsBuilder.repeatedPhrases(corpus: corpus, limit: 20, pronouns: [])
        // 这条语料里「AI 味」只跟在「有」后面出现,留下的整串是对的;
        // 要验的是这种短句没有被整段丢掉。
        XCTAssertTrue(out.contains { $0.phrase.contains("AI 味") }, "\(out)")
    }
}
