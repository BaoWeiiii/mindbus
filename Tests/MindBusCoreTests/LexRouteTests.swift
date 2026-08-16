import XCTest
@testable import MindBusCore

/// 第三路（个人词表）FTS：`库存经理` 这类领域词从 trigram 碎片变成完整词元。
/// 三路 RRF：trigram 兜子串、unicode61 管英文、lex 路管中文词级。
final class LexRouteTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "lex-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    private func lite(_ id: String, cwd: String = "/p") -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(timeIntervalSince1970: 1_000),
                         endAt: Date(timeIntervalSince1970: 2_000), cwd: cwd, gitBranch: nil,
                         preview: "p", messageCount: 1,
                         fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    private func put(_ index: ConversationIndex, _ id: String, _ text: String) throws {
        try index.upsert([(lite(id),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)],
                           1, text)])
    }

    /// 造出足以让 `库存经理` 进词表的语料并触发重建。
    ///
    /// 简报原始版本只给了这 10 句上下文，实测（`[lexicon] rebuilt: 0 words from 140
    /// chars`）产出空词表——凝固度实测约 15，门槛要求 ≥180（`60×(4-1)`），差 12 倍：
    /// 与 Task 1 报告记录的迷你语料问题同源（`PersonalLexiconTests.
    /// testBuildExtractsFrequentCohesiveWord` 当初也是这样），门槛按真实语料（几百万字）
    /// 标定，10 句话的语料连"库存经理"自己的二分切法都显得概率很高。
    ///
    /// 修法照抄 Task 1 报告验证过的手法：补一份与 `收/益/经/理` 及上下文字符完全不相交的
    /// 8 字符池，三重循环生成 512 条 3 字 filler。3 字 filler 只贡献 1/2/3-gram 的语料
    /// 总数（`PersonalLexicon.build` 的候选循环 `guard chars.count >= n else { break }`
    /// 让 3 字 run 天然不产生 4-gram），完全不稀释"库存经理"自身的概率（分子分母都在
    /// 4-gram 那一层，filler 摸不到），只稀释二分切法两侧（1/2/3-gram）的概率——
    /// 净效果是把凝固度从约 15 拉到约 963（相对门槛 5 倍安全边际），实测确认词表最终
    /// 只含 `库存经理` 一项（filler 两两拼接的凝固度约 1，边界熵也因为三重循环保证每个
    /// 2 字前缀/后缀恰好出现 8 次而稀释，够不到 60 的门槛，不会混进词表）。
    /// 门槛数值本身不改（spec §7.62 定稿），只改语料。
    private func seedLexiconCorpus(_ index: ConversationIndex) throws {
        let contexts = [("找", "谈"), ("和", "说"), ("让", "看"), ("由", "定"),
                        ("请", "来"), ("跟", "聊"), ("给", "批"), ("为", "办"),
                        ("同", "商"), ("在", "问")]
        var rows: [(lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String)] = []
        for (i, (l, r)) in contexts.enumerated() {
            let text = "\(l)库存经理\(r)一下这季度的目标"
            rows.append((lite("seed-\(i)"),
                         [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)], 1, text))
        }
        let fillerPool = Array("甲乙丙丁戊己庚辛")   // 与目标词、左右语境字均不相交
        var n = 0
        for a in fillerPool {
            for b in fillerPool {
                for c in fillerPool {
                    let text = "\(a)\(b)\(c)"
                    rows.append((lite("filler-\(n)"),
                                 [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)], 1, text))
                    n += 1
                }
            }
        }
        try index.upsert(rows)
    }

    func testRebuildProducesLexiconAndRefillsLexRoute() throws {
        let index = try makeIndex()
        try seedLexiconCorpus(index)
        XCTAssertTrue(index.rebuildLexiconIfNeeded(), "词表为空时必须重建")
        XCTAssertTrue(index.loadLexicon().contains("库存经理"))
        // 重建幂等：语料没涨就不再重建
        XCTAssertFalse(index.rebuildLexiconIfNeeded(), "语料未增长不该重复重建")
    }

    /// 决定性检验（spec §7.62 的核心主张）：词表词整词查询，lex 路命中。
    func testLexiconWordMatchesAsWholeToken() throws {
        let index = try makeIndex()
        try seedLexiconCorpus(index)
        _ = index.rebuildLexiconIfNeeded()
        let hits = index.search("库存经理")
        XCTAssertFalse(hits.isEmpty, "词表词整词检索不该为空")
    }

    /// 行数守恒：哨兵红线——每个段必有 lex 行，词表空时也一样。
    func testLexRowCountAlwaysMatchesSegments() throws {
        let index = try makeIndex()
        try put(index, "a", "还没有词表时也要写第三路")
        XCTAssertEqual(index.lexRouteRowCount(), index.segmentCount(),
                       "词表为空时 _lex 行数也必须与 segments 守恒")
        try seedLexiconCorpus(index)
        _ = index.rebuildLexiconIfNeeded()
        XCTAssertEqual(index.lexRouteRowCount(), index.segmentCount(), "重灌后守恒")
        // 换血更新（同 file_path 再 upsert）后仍守恒
        try put(index, "a", "换了一段新内容")
        XCTAssertEqual(index.lexRouteRowCount(), index.segmentCount(), "换血后守恒")
    }

    /// 行数守恒只锁「每段必有一行」，锁不住「那一行写的是切分后的词元」——索引侧若把
    /// `PersonalLexicon.segment` 的调用删掉、直接写原文，行数依旧守恒，但长 CJK run 在
    /// unicode61 tokenizer 下会粘成一个巨长词元，整词 MATCH 永远对不上，第三路名存实亡。
    /// 这条测试直接对 `segments_fts_lex` 做整词 MATCH 断言，覆盖重灌与 upsert 两条各自
    /// 独立调用 `PersonalLexicon.segment` 的写入路径（`rebuildLexiconIfNeeded` 与
    /// `upsertOne`），经 `lexRouteMatchCount` 这个新查询口（同 `lexRouteRowCount`
    /// 模式：单层 `queue.sync`，不重入）。
    func testLexRouteIndexesSegmentedTextNotRawText() throws {
        let index = try makeIndex()
        // 重灌路径：seedLexiconCorpus 的段在词表为空时先按退化单字写入，
        // rebuildLexiconIfNeeded 用刚建好的词表整表重灌——这里断言的是重灌后的结果。
        try seedLexiconCorpus(index)
        _ = index.rebuildLexiconIfNeeded()
        XCTAssertGreaterThan(index.lexRouteMatchCount("\"库存经理\""), 0,
                             "重灌路径：索引侧须按词表切分写入，整词 MATCH 才对得上")

        // upsert 路径：词表已建好后，新会话走 upsertOne（不经过上面的重灌循环）——
        // 用「新增一条命中」的行数增量确认这条独立的写入路径也在切分，不是重灌覆盖
        // 全表之后才凑巧对上。
        let before = index.lexRouteMatchCount("\"库存经理\"")
        try put(index, "fresh", "又聊到库存经理了")
        let after = index.lexRouteMatchCount("\"库存经理\"")
        XCTAssertEqual(after, before + 1,
                       "upsert 路径（非重灌）：新段也须按词表切分写入")
    }

    func testPruneRemovesLexRows() throws {
        let index = try makeIndex()
        try put(index, "a", "将被删除的内容")
        index.prune(missingPaths: ["/tmp/a.jsonl"])
        XCTAssertEqual(index.lexRouteRowCount(), 0, "prune 漏删 _lex = 孤儿行")
    }

    /// 词表重建后，**已入库的旧段**也能按新词表整词命中——这就是重灌的意义。
    func testRefillReindexesPreexistingSegments() throws {
        let index = try makeIndex()
        try put(index, "old", "早就入库的那条也提到库存经理了")   // 此时词表为空
        try seedLexiconCorpus(index)
        _ = index.rebuildLexiconIfNeeded()
        XCTAssertTrue(index.search("库存经理").contains("old"),
                      "重灌没有覆盖存量段——旧内容永远享受不到词表")
    }

    /// 语料增长 >20% 触发重建（阈值语义直测）。
    func testRebuildTriggersOnCorpusGrowth() throws {
        let index = try makeIndex()
        try seedLexiconCorpus(index)
        _ = index.rebuildLexiconIfNeeded()
        // 增长 <20%：一条短文本
        try put(index, "tiny", "一小条")
        XCTAssertFalse(index.rebuildLexiconIfNeeded())
        // 大量新增 >20%
        for i in 0..<12 {
            try put(index, "grow-\(i)", String(repeating: "全新的一大段语料内容增长起来了", count: 4))
        }
        XCTAssertTrue(index.rebuildLexiconIfNeeded(), "语料涨了 >20% 该重建")
    }

    /// 自查项①（任务简报明确要求）：纯英文语料下 `PersonalLexicon.build` 合法产出空集
    /// （候选只从连续中文 run 里找，见 `PersonalLexicon.isCJK`），这不等于「没建过」。
    /// 若「建过没有」误用 `lexicon` 表行数判断（空表与「从未构建」在行数上无法区分），
    /// 语料完全没涨的情况下每轮扫描都会被误判成「没建过」而重复整表重建——正确判据
    /// 是 `lexicon_meta` 是否有行（构建这个动作本身发生过，不管产出是否为空）。
    /// 门控直测（四种输入，见 `ConversationIndex.lexRouteHasSignal` 注释）：只在切分产出
    /// 「≥2 字纯 CJK 词元」时才该发言。用代表性的「已切分」字符串直测这个纯函数，不经
    /// `PersonalLexicon.segment`——门控逻辑本身与词表内容无关，只看切分产出的形状。
    func testLexRouteHasSignalGating() {
        // ①纯英文：unicode61 分词与 _uni 完全同构，跑了就是把信号双计——门控必须拒绝。
        XCTAssertFalse(ConversationIndex.lexRouteHasSignal(segmentedQuery: "hello world"),
                       "纯英文查询不该有 lex 信号")
        // ②含词表词的中文：整词切分产出 ≥2 字 CJK 词元，必然来自词表命中——门控放行。
        XCTAssertTrue(ConversationIndex.lexRouteHasSignal(segmentedQuery: "库存经理"),
                      "词表词整词切分该有 lex 信号")
        // ③词表外中文：`PersonalLexicon.segment` 对未命中的字全落单字，用空格隔开——
        // 每个词元长度 1，全是噪声，门控必须拒绝（「随便说说」不该命中任何含「说」的段）。
        XCTAssertFalse(ConversationIndex.lexRouteHasSignal(segmentedQuery: "随 便 说 说"),
                       "全单字切分（词表外中文）不该有 lex 信号")
        // ④中英混合但含词表词：英文部分透传、中文部分命中词表产出整词——只要有一个
        // ≥2 字 CJK 词元就该放行，不因为混了英文就被拒。
        XCTAssertTrue(ConversationIndex.lexRouteHasSignal(segmentedQuery: "hello 库存经理"),
                      "中英混合但含词表词该有 lex 信号")
    }

    func testRebuildDoesNotLoopWhenLexiconLegitimatelyEmpty() throws {
        let index = try makeIndex()
        for i in 0..<5 {
            try put(index, "en-\(i)", "the quick brown fox jumps over the lazy dog for padding purposes")
        }
        XCTAssertTrue(index.rebuildLexiconIfNeeded(), "首次必须构建，哪怕产出空词表")
        XCTAssertTrue(index.loadLexicon().isEmpty, "纯英文语料词表应为空——这是合法结果，不是异常")
        XCTAssertFalse(index.rebuildLexiconIfNeeded(),
                       "词表为空但已建过、语料未增长——不该被误判成「没建过」而重复全量重建")
    }

    /// 排序判别测试（审查变异实锤：把第三路 append 改成 `if false`，原有 7 条测试全绿——
    /// OR 语义 + trigram 子串路存在，lex 路几乎不可能对「结果集」独有，它的价值在
    /// **排序**。这条测试构造「有 lex 路」与「无 lex 路」最终第一名相反的两个候选，
    /// 变异同一处会让它由绿转红）。
    ///
    /// 实现相对简报字面构造做了必要调整，原因记入报告「拍板有误的地方」：简报设想
    /// X 含整词「库存经理」一次、Y 含"收益经""益经理"等 3-gram 碎片但无整词，靠 trigram
    /// 路的碎片密度把 Y 排到 X 前面。实测（sqlite3 CLI 直接建 trigram FTS5 表验证）
    /// trigram 路的查询是**引号短语**（`ftsQuery` 给无空格输入包一层引号），FTS5 对
    /// trigram tokenizer 的短语查询要求切出的子词元位置相邻——等价于「逐字节子串必须
    /// 整个出现」，不是「碎片累积算分」；纯碎片（子串不连续出现）在 trigram 路命中数
    /// 为 0，不会进候选集，"加大碎片密度"这条简报给的调参路径救不回来。而且在
    /// 词表={"库存经理"}（单一词条、四字两两不同、无自重叠）下，贪心切词器扫到任意一次
    /// 逐字节出现都会切出整词——trigram 命中集合与 lex 命中集合因此恒等，"trigram 命中
    /// 但 lex 不命中"在这个设置下数学上不可达。
    ///
    /// 改用两路对「文档长度」感知不同这一更换的、真实可达的机制：句号对 trigram
    /// 计入每个字符（拖长文档、拖差 BM25），对 unicode61/lex 则是纯分隔符（零开销、不
    /// 产生词元）。X 用少量句号把**只有 trigram 感知到**的长度调差，被无标点的 Y
    /// 反超；lex 侧 X 保持最短（仅 2 词元）稳居第一。仅两个候选时 RRF 名次和会因加法
    /// 交换律恒等打平（1/(k+1)+1/(k+2) 不论谁拿第几名，总和相等）——补 3 个 decoy 段
    /// （X 的变体：同样句号拖长 trigram、lex 侧比 X 多 2 个单字词元）把 Y 的 lex 名次从
    /// 「贴着 X 的第 2」推远到「第 5」，让最终名次和产生真实、非并列的净胜差，不依赖
    /// 会话 id 字母序破平局的巧合。
    func testLexRouteRankingIsLoadBearing() throws {
        let index = try makeIndex()
        try seedLexiconCorpus(index)
        _ = index.rebuildLexiconIfNeeded()
        XCTAssertTrue(index.loadLexicon().contains("库存经理"), "前提：词表须含该词才谈得上第三路")

        // X：trigram 侧靠 5 个句号故意拖长（lex 不可见）——单看 trigram 路会略负于 Y，
        // 但 lex 路上 X 是最短文档（「库存经理」+「甲」= 2 词元），稳居第一。「甲」是
        // 必需的：若 X 只有裸「库存经理」+ 句号，句号会把连续汉字 run 恰好切成
        // 「库存经理」四字，与 uni 路未切分查询本身分出的单一词元意外整词相等，
        // 污染了这条测试要求保持中立的 uni 路（`rankedHits` 顶部注释「unicode61 管英文
        // 词法」——对纯 CJK 查询它几乎不可能有信号，除非像这样意外对齐）；接一个词表外的
        // 「甲」把 run 撑到 5 字，不再等于查询词，uni 路命中清零（实测 0 行）。
        let xText = "库存经理甲" + String(repeating: "。", count: 5)
        // Y：无标点，trigram 侧比 X 短、排名更靠前；但整词后面缀 5 个词表外单字，
        // lex 路分词结果变成 6 个词元（1 整词 + 5 单字），比 X 的 2 个词元长得多，
        // 把 lex 名次甩到 X 后面。
        let yText = "库存经理" + "甲乙丙丁戊"
        try put(index, "x", xText)
        try put(index, "y", yText)
        // decoy：结构上是「X 的变体」，lex 侧排在 X 之后、Y 之前，trigram 侧排在全部
        // seed 之后（不干扰 X/Y 的 trigram 名次关系）——纯粹用来把 Y 的 lex 名次推远，
        // 见上方方法注释「仅两个候选时……」一段。
        for i in 0..<3 {
            try put(index, "decoy-\(i)", "库存经理乙丙" + String(repeating: "。", count: 100))
        }

        // 真实代码（lex 路开着）：X 该是第一名。
        XCTAssertEqual(index.search("库存经理").first, "x",
                       "有 lex 路：X（lex 路最短文档）应反超 Y（trigram 路更短但 lex 名次被稀释）")
    }
}
