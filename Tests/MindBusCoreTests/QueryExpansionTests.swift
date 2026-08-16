import XCTest
@testable import MindBusCore

/// RM3 伪相关反馈（spec §7.60）：低重叠查询靠 top-8 段里的高 IDF 词把词汇鸿沟
/// 桥过去。实测低带 R@20 +14pt；副作用 query drift 由 .adaptive 触发条件挡住。
final class QueryExpansionTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "qexp-\(UUID().uuidString).sqlite"
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

    /// 词汇鸿沟场景：查「自动更新」，目标会话只写了「Sparkle」「appcast」。
    /// 桥梁会话同时含两者——扩展应从桥梁段抽出 Sparkle 反查到目标。
    func testExpansionBridgesVocabularyGap() throws {
        let index = try makeIndex()
        try put(index, "bridge", "自动更新我们用 Sparkle 实现，appcast 放 GitHub Releases")
        try put(index, "target", "Sparkle 的 EdDSA 签名密钥要轮换，appcast feed 记得更新")
        try put(index, "noise", "今天讨论了完全无关的界面布局问题")
        for i in 0..<3 {   // df 门槛需要 Sparkle 至少出现在 2 段
            try put(index, "extra-\(i)", "第 \(i) 次提到 Sparkle 相关的构建流程")
        }
        let off = index.search("自动更新", expansion: .off)
        let always = index.search("自动更新", expansion: .always)
        XCTAssertFalse(off.contains("target"), "前提：无扩展时目标够不着（词汇鸿沟成立）")
        XCTAssertTrue(always.contains("target"), "扩展没把词汇鸿沟桥过去")
    }

    /// .adaptive：命中已多（≥40 段）就不扩展——保住高重叠带零损失。
    ///
    /// 简报原始构造只给了 45 条「关键词丰富段落 keyword 第 i 条」——实测（先跑一遍
    /// 变异反证）发现这份语料里**根本抽不出合格扩展词**：中文候选词表为空全退化成
    /// 单字被"长度 < 2"挡掉，"keyword" 因为就是原查询词被排除，数字串被数字规则
    /// 挡掉。于是就算把 `.adaptive` 的阈值判断整个删掉（恒扩展），`expansionTerms`
    /// 依然返回空集，`rankedHitsInsideQueue` 落到"抽不出词→退回原结果"那条兜底，
    /// 这条测试对"阈值判断被删掉"这个变异**没有判别力**（删了阈值检查，测试照样绿）。
    /// 补两个共享罕见词「anchor」的会话把这个漏洞堵上：`anchor-src` 很短（"keyword
    /// anchor"），必然进原查询 top-8，够格成为扩展词来源；`anchor-low` 复刻 rich-i
    /// 的长度模式再加个 anchor，原始排名跟 45 条 rich-i 挤在一起、排不到前面。
    /// df("anchor")=2，47 段时 ceiling=max(2,⌊0.05×47⌋)=2，卡在合法区间边界。
    /// 47 段命中仍 ≥ 40，真实代码（阈值判断还在）不会碰这两个新会话，`.adaptive`
    /// 与 `.off` 依旧原样相等；只有阈值判断被删掉时，`anchor-low` 才会借 anchor
    /// 在扩展列表里的稀有词加成从原始排名垫底的位置往上跳，打破逐位相等。
    func testAdaptiveSkipsExpansionWhenHitsAreAbundant() throws {
        let index = try makeIndex()
        for i in 0..<45 { try put(index, "rich-\(i)", "关键词丰富段落 keyword 第 \(i) 条") }
        try put(index, "anchor-src", "keyword anchor")
        try put(index, "anchor-low", "关键词丰富段落 keyword anchor 第 999 条")
        // 富命中查询：adaptive 与 off 的结果必须完全一致（没有 drift）
        XCTAssertEqual(index.search("keyword", expansion: .adaptive),
                       index.search("keyword", expansion: .off),
                       "命中充足时 adaptive 不该动结果")
    }

    /// .adaptive 的另一半：命中稀少（同 `testExpansionBridgesVocabularyGap` 的词汇鸿沟
    /// 语料，总命中远低于 40 段）时也该触发扩展，不是只有 `.always` 才桥得过去。
    func testAdaptiveExpandsWhenHitsAreScarce() throws {
        let index = try makeIndex()
        try put(index, "bridge", "自动更新我们用 Sparkle 实现，appcast 放 GitHub Releases")
        try put(index, "target", "Sparkle 的 EdDSA 签名密钥要轮换，appcast feed 记得更新")
        try put(index, "noise", "今天讨论了完全无关的界面布局问题")
        for i in 0..<3 {
            try put(index, "extra-\(i)", "第 \(i) 次提到 Sparkle 相关的构建流程")
        }
        XCTAssertFalse(index.search("自动更新", expansion: .off).contains("target"),
                       "前提：无扩展时目标够不着")
        XCTAssertTrue(index.search("自动更新", expansion: .adaptive).contains("target"),
                      "命中稀少（远低于 40 段）时 adaptive 也该扩展")
    }

    /// 扩展词质量门槛：纯数字、超高频词（df >5%N）不得成为扩展词；df 落在合法区间
    /// 内的普通词则不能被误杀（过滤不能矫枉过正到把一切都滤空）。
    func testExpansionTermFilters() throws {
        let index = try makeIndex()
        // "graph"：出现在恰好 3 段——N=100 时 ceiling=max(2, 5)=5，df=3 落在 [2,5] 内，合法。
        for i in 0..<3 { try put(index, "graph-\(i)", "we sketched a graph of the pipeline") }
        // "2026"：同样 df=3（落在合法区间），但纯数字必须被专门的数字规则挡掉，
        // 不能靠 df 门槛侥幸活下来。
        for i in 0..<3 { try put(index, "year-\(i)", "shipped in 2026 after the freeze") }
        // "everywhere"：出现在 94 段，df=94 远超 ceiling=5，必须被 df 上限挡掉。
        for i in 0..<94 { try put(index, "common-\(i)", "this shows up everywhere in the corpus") }
        XCTAssertEqual(index.segmentCount(), 100, "前提：总段数须为 100，ceiling 公式才如上面注释推算的那样")

        let baseTexts = [
            "we sketched a graph of the pipeline",
            "shipped in 2026 after the freeze",
            "this shows up everywhere in the corpus",
        ]
        // limit 给宽松值（20）：这条测试断言的是过滤规则本身，不是 top-N 截断，
        // 避免恰好卡在截断边界让断言变得脆弱。
        let terms = index.expansionTerms(for: baseTexts, excludingQuery: "search interface", limit: 20)
        XCTAssertTrue(terms.contains("graph"), "df 落在合法区间的普通词不该被误杀")
        XCTAssertFalse(terms.contains("everywhere"), "df 超过 5%N 的高频词不该混进扩展词")
        XCTAssertFalse(terms.contains("2026"), "纯数字串不该混进扩展词，即便 df 落在合法区间内")
    }

    /// 原查询结果的相对顺序在扩展后不得被彻底打乱：原第 1 名在融合后仍应排在原
    /// 第 10 名之前（0.45 权重保证原路主导）。
    ///
    /// RRF 融合只看**名次**不看原始 BM25 分数——rrf_orig(第 1 名) 与 rrf_orig(第 10 名)
    /// 的差恒为 `1/61 − 1/70 ≈ 0.00209`，与两者原始分数差多悬殊无关。要让扩展路真正
    /// 有"以权压原"的机会，受益者必须在扩展列表里冲到很高的名次，同时原第 1 名要在
    /// 扩展列表里被压下相当多名次——只让原第 10 名一家独占稀有词、扩展列表里只往前
    /// 挪一两位，0.45 甚至 1.5 倍权重都翻不了盘（先用 1.5 试过，压不动，才改成下面
    /// 这个"多个文档共享稀有词、把原第 1 名往后挤 8 位"的构造）。
    ///
    /// 构造：10 个会话对查询词「widget」的重复次数从 10 递减到 1（rank0 最强/原第 1，
    /// rank9 最弱/原第 10）。罕见词「gizmo」埋进 rank1…rank9（不含 rank0，8 个会话，
    /// 含 top-8 内的 rank3 作扩展词来源）——扩展查询「widget OR gizmo」下这 8 个会话
    /// 同时命中两个词，会把只命中一个词的 rank0 挤到扩展列表第 9 名开外。另加
    /// 190 条不相关填充段，把 df("gizmo")=8 摁进 `2 ≤ df ≤ 5%×200=10` 的合法区间。
    func testOriginalRankingDominatesAfterFusion() throws {
        let index = try makeIndex()
        for k in 0..<10 {
            let tf = 10 - k
            var text = Array(repeating: "widget", count: tf).joined(separator: " ")
            if k != 0 { text += " gizmo" }   // rank0 独自缺席——它是唯一不该被扩展抬升的会话
            try put(index, "rank\(k)", text)
        }
        for i in 0..<190 {
            try put(index, "filler-\(i)", "第 \(i) 条与查询完全无关的填充占位内容")
        }
        XCTAssertEqual(index.segmentCount(), 200, "前提：总段数须为 200，ceiling 公式才如上面注释推算的那样")

        let off = index.search("widget", expansion: .off)
        XCTAssertEqual(off.count, 10, "前提：10 个会话都该命中，填充段不含 widget 不该混进来")
        let rank1 = try XCTUnwrap(off.first)
        let rank10 = try XCTUnwrap(off.last)
        XCTAssertEqual(rank1, "rank0", "前提：重复次数最多的 rank0 应是原第 1 名")
        XCTAssertEqual(rank10, "rank9", "前提：重复次数最少的 rank9 应是原第 10 名")

        let fused = index.search("widget", expansion: .always)
        XCTAssertEqual(Set(fused), Set(off), "扩展不该引入或丢失会话，只该重排")
        let pos1 = try XCTUnwrap(fused.firstIndex(of: rank1))
        let pos10 = try XCTUnwrap(fused.firstIndex(of: rank10))
        XCTAssertLessThan(pos1, pos10,
                          "原第 1 名（\(rank1)）融合后掉到了原第 10 名（\(rank10)）之后——0.45 权重没能保证原路主导")
    }

    /// 空扩展词（top 段抽不出合格词）时结果与 .off 完全一致，不多跑一轮。
    ///
    /// 语料故意造成"抽不出词"：三个会话内容互不重叠（没有任何非查询词在 ≥2 段
    /// 重复出现），且词表为空（未跑 `rebuildLexiconIfNeeded`）——中文候选全部退化成
    /// 单字被"长度 < 2"挡掉，英文候选各自只出现一次被"df < 2"挡掉。`expansionTerms`
    /// 内部因此在候选阶段或 df 阶段就返回空集，`rankedHitsInsideQueue` 应直接落到
    /// `guard !terms.isEmpty else { return orig }`，不发起扩展查询。
    func testNoExpansionTermsMeansNoChange() throws {
        let index = try makeIndex()
        try put(index, "a", "Redis 集群扩容方案讨论")
        try put(index, "b", "完全不同的 pgvector 索引优化")
        try put(index, "c", "第三条无关内容占位")

        XCTAssertEqual(index.search("Redis", expansion: .always),
                       index.search("Redis", expansion: .off),
                       "top-8 段抽不出合格扩展词时，结果应与 .off 完全一致")
    }

    /// 融合后共有 id 的元数据（代表段/位置/命中段数）必须取**原查询**那份。
    ///
    /// 扩展查询多了几个 OR 词，同一会话的"最佳段"很可能换成扩展词所在的段——
    /// 若元数据跟着扩展路走，GUI 的「命中 N 处/跳转位置」就与用户敲的词对不上。
    func testFusionKeepsOriginalMetadataForSharedIDs() throws {
        let index = try makeIndex()
        // conv-x 两段：段 0 含原查询词 Redis 一次；段 5 塞三个 cache——扩展查询
        // (Redis OR cache) 下段 5 的 BM25 明显更强，扩展路的"最佳段"必然是段 5。
        // 若融合把元数据让给扩展路，firstMsg 会从 0 变 5、hitCount 从 1 变 2，断言必红。
        try index.upsert([(lite("conv-x"), [
            Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 1, text: "Redis 的连接池问题"),
            Segmenter.Segment(firstMessageIndex: 5, lastMessageIndex: 6,
                              text: "cache invalidation cache warmup cache 的老难题"),
        ], 1, "")])
        try put(index, "bridge", "Redis 本质上是个 cache 服务")
        try put(index, "other", "cache 层的设计讨论")
        // 填充段抬高总段数：cache 的 df=3，而 ceiling=max(2, 5%×总段数)——
        // 不足 60 段时 ceiling=2 会把 cache 从扩展词里滤掉，整条测试就退化成
        // 「没扩展所以当然相等」的恒真（第一版变异反证正是这样漏的）。
        for i in 0..<60 { try put(index, "pad-\(i)", "填充第 \(i) 段的无关内容而已") }

        let off = index.searchWithHits("Redis", expansion: .off)
        let always = index.searchWithHits("Redis", expansion: .always)
        let offX = try XCTUnwrap(off.first { $0.id == "conv-x" })
        let alwaysX = try XCTUnwrap(always.first { $0.id == "conv-x" })
        XCTAssertEqual(alwaysX.bestSegmentFirstMessageIndex, offX.bestSegmentFirstMessageIndex,
                       "共有 id 的代表段位置必须与原查询一致（不被扩展路顶掉）")
        XCTAssertEqual(alwaysX.segmentHitCount, offX.segmentHitCount,
                       "共有 id 的命中段数必须与原查询一致")
    }
}
