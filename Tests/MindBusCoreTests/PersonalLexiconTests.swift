import XCTest
@testable import MindBusCore

/// 个人词表：零词典零模型，从用户自己的语料统计出高频凝固词（spec §7.62）。
/// 决定性动机：`库存经理` 这类领域词被 trigram 切成 `收益经`/`益经理` 碎片，
/// 词级检索永远拼不回整词——第三路用这个词表切分后才有词级倒排。
final class PersonalLexiconTests: XCTestCase {

    /// 高频强凝固词必须被抽出：`库存经理` 反复整词出现、左右邻字多样。
    func testBuildExtractsFrequentCohesiveWord() {
        var corpus: [String] = []
        // 左右邻字要多样（边界熵门槛），整词反复出现（频次+凝固度门槛）
        let contexts = [("找", "谈"), ("和", "说"), ("让", "看"), ("由", "定"),
                        ("请", "来"), ("跟", "聊"), ("给", "批"), ("为", "办"),
                        ("同", "商"), ("请", "审")]
        for (l, r) in contexts {
            corpus.append("\(l)库存经理\(r)这件事")
        }
        // 背景语料：凝固度＝整体概率／二分切法概率积，概率的分母是语料里对应长度
        // n-gram 的总数。真实语料几百万字时，`库存经理` 之外的海量内容天然把这些
        // 分母撑到很大，凝固度才有区分力；这里手工写的 10 句话语料太小，分母小到
        // 连它自身的二分切法都显得「概率很高」，凝固度算出来虚低（实测约 10.5，
        // 门槛要求 ≥180）——不是算法或门槛错，是这份迷你语料没有真实语料的稀释效应。
        // 用一个与目标词完全不相交的字符池填充背景：只撑分母，不新增任何
        // `收/益/经/理` 及其子串的出现次数。三重循环保证每个 2 字前缀/后缀最多出现
        // 8 次（字符池大小），不会误触发频次门槛而混进词表干扰断言之外的东西。
        // 门槛数值本身不许改（spec §7.62 定稿）——这里改的是语料，不是门槛。
        let fillerPool = Array("甲乙丙丁戊己庚辛")   // 与目标词、左右语境字均不相交
        for a in fillerPool {
            for b in fillerPool {
                for c in fillerPool {
                    corpus.append("\(a)\(b)\(c)")
                }
            }
        }
        let lexicon = PersonalLexicon.build(corpus: corpus)
        XCTAssertTrue(lexicon.contains("库存经理"), "高频凝固词没被抽出，词表: \(lexicon)")
    }

    /// 低频串不进词表——门槛就是防把偶然共现当成词。
    func testBuildRejectsInfrequentNgrams() {
        let lexicon = PersonalLexicon.build(corpus: ["昨天路过一家新开的面馆", "今天天气不错"])
        XCTAssertTrue(lexicon.isEmpty, "低频语料不该产出任何词: \(lexicon)")
    }

    /// 只在同一个固定上下文里出现的串，边界熵低，不是独立词。
    /// `汇报进度` 每次都被「向他」「了吗」夹着——它可能只是更长短语的碎片。
    func testBuildRejectsFixedContextNgrams() {
        let corpus = Array(repeating: "向他汇报进度了吗", count: 20)
        let lexicon = PersonalLexicon.build(corpus: corpus)
        XCTAssertFalse(lexicon.contains("汇报进度"),
                       "左右邻字单一（熵≈0）的串不该进词表")
    }

    /// 凝固度门槛：两个各自高频的词拼在一起（`今天代码`）整体概率
    /// 远低于部分之积，不该被当成一个词。
    func testBuildRejectsLowCohesionPairs() {
        var corpus: [String] = []
        let lefts = ["今天", "明天", "昨天"], rights = ["代码", "文档", "测试"]
        for l in lefts { for r in rights { for i in 0..<9 {
            corpus.append("\(i)号说\(l)看看\(r)吧")       // 各自独立高频出现
            corpus.append("\(l)\(r)")                     // 偶尔相邻
        } } }
        let lexicon = PersonalLexicon.build(corpus: corpus)
        XCTAssertFalse(lexicon.contains("今天代码"), "低凝固组合不该成词")
    }

    // MARK: 切分

    func testSegmentUsesLongestMatch() {
        let lexicon: Set<String> = ["库存经理", "收益"]
        XCTAssertEqual(PersonalLexicon.segment("找库存经理谈", lexicon: lexicon),
                       "找 库存经理 谈", "该取最长的『库存经理』而不是『收益』")
    }

    func testSegmentFallsBackToSingleCharsOutsideLexicon() {
        XCTAssertEqual(PersonalLexicon.segment("随便说说", lexicon: []),
                       "随 便 说 说")
    }

    /// 中英混排：英文与标点原样透传（它们本身就是 unicode61 的词边界），
    /// 只有连续中文 run 参与词表切分。
    func testSegmentPreservesNonChineseRuns() {
        let lexicon: Set<String> = ["库存经理"]
        XCTAssertEqual(PersonalLexicon.segment("ping库存经理via Slack!", lexicon: lexicon),
                       "ping 库存经理 via Slack!")
    }

    func testSegmentEmptyAndPureASCII() {
        XCTAssertEqual(PersonalLexicon.segment("", lexicon: ["任意"]), "")
        XCTAssertEqual(PersonalLexicon.segment("pure ascii text", lexicon: ["任意"]),
                       "pure ascii text")
    }

    /// 5 字词必须能被抽出——「第一性原理」当年因 n-gram 上限 4 字结构性缺席,
    /// 用户一眼看穿「我的高频词里肯定有第一性原理,现在这些不像我给的」。
    func testFiveCharConceptIsExtracted() {
        let tail = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        var corpus = (0..<512).map { "杂讯" + tail[$0 % 10] }
        let contexts = [("按", "拆"), ("用", "想"), ("从", "看"), ("讲", "析"),
                        ("以", "推"), ("按", "断"), ("拿", "量"), ("靠", "判"),
                        ("依", "证"), ("凭", "算")]
        for (l, r) in contexts { corpus.append("\(l)第一性原理\(r)") }
        let lexicon = PersonalLexicon.build(corpus: corpus)
        XCTAssertTrue(lexicon.contains("第一性原理"),
                      "5 字概念词没被抽出,词表: \(lexicon.filter { $0.count >= 4 })")
        // 切分侧同样认它:整词落下不碎
        XCTAssertEqual(PersonalLexicon.segment("按第一性原理拆", lexicon: ["第一性原理"]),
                       "按 第一性原理 拆")
    }

    /// 边界熵门槛的**隔离**测试：同一个词，凝固度余量足够，只有熵在变——
    /// 多样上下文放行、固定上下文拒绝。
    ///
    /// 为什么必须有：另外三条 reject 测试的候选都被多个门槛同时拦（删掉熵 guard
    /// 九条测试照样全绿，审查探针实证过）；这条让「熵门槛存在且方向正确」有了
    /// 唯一的守卫——谁把 min(左熵,右熵) 写成 max、或把 guard 删了，这里必红。
    func testBoundaryEntropyGateIsolated() {
        // 共用的 3 字 filler：不产 4-gram，只稀释分母把凝固度顶过门槛。
        // 尾字必须是真汉字——曾用 "杂讯\($0 % 10)" 的数字尾，数字不是 CJK，
        // filler 实际只产 2 字 run、3-gram 分母塌掉，凝固度 144 < 180 被**凝固度**
        // 拦住，这条测试就测不到熵了（探针逐门槛试探定位的）。
        let tail = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        let filler = (0..<512).map { "杂讯" + tail[$0 % 10] }

        var diverse = filler
        let contexts = [("找", "谈"), ("和", "说"), ("让", "看"), ("由", "定"),
                        ("请", "来"), ("跟", "聊"), ("给", "批"), ("为", "办"),
                        ("同", "商"), ("在", "问")]
        for (l, r) in contexts { diverse.append("\(l)库存经理\(r)") }
        XCTAssertTrue(PersonalLexicon.build(corpus: diverse).contains("库存经理"),
                      "凝固度过线 + 邻字多样：应放行")

        // 反向构造必须「左邻多样、右邻单一」：左右都是 0 熵的话，min 写成 max
        // 也照样拒绝，测试就区分不出取小还是取大（第一版反向验证正是这样漏的）。
        // 现在左熵 ≈ log2(10)、右熵 = 0：min → 0 拒绝 ✓；写错成 max → 3.3 放行 ✗。
        var fixed = filler
        for (l, _) in contexts { fixed.append("\(l)库存经理们") }   // 右邻恒「们」
        XCTAssertFalse(PersonalLexicon.build(corpus: fixed).contains("库存经理"),
                       "凝固度过线、左邻多样但右邻单一：熵取小者，必须拒绝")
    }

    /// 构建性能护栏：几 MB 语料必须秒级——它跑在扫描收尾，不能拖住整个流水线。
    ///
    /// 语料必须**多样**：高重复语料的 distinct gram 极少，字典与最终过滤循环
    /// 几乎没被压到，实测比多样语料快 2-2.5 倍——那样的护栏守不住真实开销。
    /// 这里用组合造 40 万字、几十万 distinct gram（贴近真实对话语料形态）。
    func testBuildPerformanceGuard() throws {
        // 护栏守的是「扫描收尾在用户实机（Apple Silicon）上不被拖死」；
        // CI 虚拟机跑同语料 11.7s（实测），性能与目标硬件无关，只在本地生效。
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "CI 虚拟机性能不代表目标硬件，护栏只在本地生效")
        var corpus: [String] = []
        let heads = ["收益", "工作", "聚焦", "测试", "目标", "季度", "地图", "会议",
                     "方案", "结构", "索引", "检索", "词表", "语料", "上下", "文本"]
        let tails = ["经理", "空间", "重建", "对齐", "偏移", "融合", "切分", "统计",
                     "评审", "验证", "回流", "先验", "扩展", "窗口", "片段", "边界"]
        var n = 0
        outer: for i in 0..<400 {
            for h in heads { for t in tails {
                corpus.append("第\(i)轮把\(h)\(t)和\(t)\(h)的进展记录了一下")
                n += 1
                if n >= 25_000 { break outer }   // ≈ 40 万中文字符
            } }
        }
        let start = Date()
        _ = PersonalLexicon.build(corpus: corpus)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10.0,
                          "40 万字多样语料构建超 10 秒——扫描收尾会被拖死")
    }
}

// MARK: - 拉丁词表（2026-08-18）

extension PersonalLexiconTests {

    /// 虚词判据交给词性标注器，不写停用词表。这是能不能给说英文的人
    /// 出词表的关键——频次判据在一份以中文和代码为主的语料上标定不出来。
    func testLatinFunctionWordsAreRecognized() {
        for f in ["the", "of", "a", "to", "and", "in", "that", "with", "it"] {
            XCTAssertTrue(PersonalLexicon.isLatinFunctionWord(f), f)
        }
        // 名词绝不能被误杀:它们才是词表的正身
        for c in ["user", "journey", "product", "manager", "cache", "latency", "rpc"] {
            XCTAssertFalse(PersonalLexicon.isLatinFunctionWord(c), c)
        }
    }
}
