import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// L2 检索结果。三条硬要求：
/// ①按相关度排（`searchWithHits` 已排好，渲染层不许重排）；
/// ②每条都给出能直接跳到那条消息的 `memory_open` 句柄；
/// ③空结果不返回空——给地图节选与可执行的下一步（MEMORY-LAYER-SPEC §1、§3.5）。
final class MemorySearchToolTests: XCTestCase {

    /// 固定用公历构造测试日期——`Calendar.current` 在非公历的区域设置（如佛历）下
    /// 年份会整体偏移，让下面按年/月断言的日期字符串对不上，测试变红
    /// （同 `FacetQueryTests`/Task 1 审查定的口径）。
    private let gregorian = Calendar(identifier: .gregorian)

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "search-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    @discardableResult
    private func seed(_ index: ConversationIndex, id: String, source: ConversationSource = .codex,
                      cwd: String = "/p", year: Int = 2026, month: Int = 7, day: Int = 15,
                      title: String? = nil, messageCount: Int = 40,
                      segments: [Segmenter.Segment]) throws -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 20; c.minute = 14
        let date = gregorian.date(from: c)!
        let text = segments.map(\.text).joined(separator: "\n")
        let lite = ConversationLite(id: id, source: source, startAt: date, endAt: date,
                                    cwd: cwd, gitBranch: nil, title: title,
                                    preview: String(text.prefix(60)), messageCount: messageCount,
                                    fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
        try index.upsert([(lite, segments, 1, text)])
        return date
    }

    private func seg(_ first: Int, _ last: Int, _ text: String) -> Segmenter.Segment {
        Segmenter.Segment(firstMessageIndex: first, lastMessageIndex: last, text: text)
    }

    private func run(_ index: ConversationIndex, _ args: [String: Any]) -> MCPToolOutput {
        MemorySearchTool.spec.run(args, index)
    }

    // MARK: 命中渲染

    func testHitCarriesLocationSnippetAndOpenHandle() throws {
        let index = try makeIndex()
        try seed(index, id: "conv-1", title: "自动更新调研", messageCount: 40, segments: [
            seg(0, 5, "先聊了别的事情"),
            seg(20, 26, "确认 Sparkle 的 appcast 走 GitHub Releases 就够，不必自建服务器"),
        ])

        let out = run(index, ["query": "Sparkle"]).text
        XCTAssertTrue(out.contains(#"QUERY "Sparkle""#))
        XCTAssertTrue(out.contains("1 conversations matched"))
        XCTAssertTrue(out.contains("2026-07-15 20:14"))
        XCTAssertTrue(out.contains("codex"))
        XCTAssertTrue(out.contains("(40 msgs, 1 hits)"))
        XCTAssertTrue(out.contains("自动更新调研"))
        XCTAssertTrue(out.contains("hit:"))
        XCTAssertTrue(out.contains("appcast"), "命中片段要覆盖到命中词附近，不是段首 300 字")
        XCTAssertTrue(out.contains(#"memory_open(conversation_id="conv-1", message=20)"#),
                      "必须给出跳到命中段首条消息的句柄")
    }

    /// 相关度顺序由索引层决定，渲染层不许按时间重排——那等于把 BM25 白算了。
    func testResultOrderFollowsIndexRelevanceNotRecency() throws {
        let index = try makeIndex()
        // 老会话命中密度高，新会话只提一次
        try seed(index, id: "old-dense", month: 5, segments: [
            seg(0, 3, "Sparkle Sparkle Sparkle 全篇都在说 Sparkle"),
            seg(4, 7, "继续 Sparkle 的细节"),
        ])
        try seed(index, id: "new-sparse", month: 8, segments: [seg(0, 3, "顺带提一句 Sparkle")])

        let ranked = index.searchWithHits("Sparkle").map(\.id)
        let out = run(index, ["query": "Sparkle"]).text
        let positions = ranked.map { id -> Int in
            out.range(of: "conversation_id=\"\(id)\"").map { out.distance(from: out.startIndex, to: $0.lowerBound) } ?? .max
        }
        XCTAssertEqual(positions, positions.sorted(),
                       "渲染顺序偏离了索引给出的相关度顺序")
    }

    func testMultipleSegmentHitsAreCounted() throws {
        let index = try makeIndex()
        try seed(index, id: "conv-1", segments: [
            seg(0, 3, "Sparkle 第一处"),
            seg(4, 7, "Sparkle 第二处"),
            seg(8, 11, "无关内容"),
        ])
        XCTAssertTrue(run(index, ["query": "Sparkle"]).text.contains("2 hits"))
    }

    /// 结果行内的日期必须与 `memory_browse` L1 页同一口径：印 startAt，不印 endAt
    /// （见 `MemoryBrowseToolTests.testFacetPageInlineDateUsesStartAtNotEndAtForCrossMonthConversation`
    /// 的注释——这条口径此前在 memory_browse 上被审查揪出过两次）。上面几条测试的
    /// seed helper 把 startAt/endAt 造成同一个值，掩盖不了这条口径，这里专门造一场
    /// startAt/endAt 分属不同日期的会话来区分。
    func testResultInlineDateUsesStartAtNotEndAt() throws {
        let index = try makeIndex()
        var startComponents = DateComponents()
        startComponents.year = 2026; startComponents.month = 7; startComponents.day = 31
        startComponents.hour = 23; startComponents.minute = 30
        let start = gregorian.date(from: startComponents)!

        var endComponents = DateComponents()
        endComponents.year = 2026; endComponents.month = 8; endComponents.day = 1
        endComponents.hour = 2; endComponents.minute = 10
        let end = gregorian.date(from: endComponents)!

        let lite = ConversationLite(id: "cross-month", source: .codex, startAt: start, endAt: end,
                                    cwd: "/p", gitBranch: nil, title: "跨月",
                                    preview: "跨月对话", messageCount: 3,
                                    fileURL: URL(fileURLWithPath: "/tmp/cross-month.jsonl"))
        try index.upsert([(lite, [seg(0, 2, "Sparkle 跨月对话内容")], 1, "Sparkle 跨月对话内容")])

        let out = run(index, ["query": "Sparkle"]).text
        XCTAssertTrue(out.contains("2026-07-31 23:30"), "结果行日期应为开始时间")
        XCTAssertFalse(out.contains("2026-08-01"), "不该印成结束时间所在的 8 月 1 日")
    }

    /// title 缺失且 preview 也是空白时不能印出看不出内容的空白行——同
    /// `MemoryBrowseTool` L1 页的回落规则（`testFacetPageFallsBackForBlankTitleAndEmptyCwd`）。
    func testResultFallsBackToNoTitleWhenTitleAndPreviewAreBlank() throws {
        let index = try makeIndex()
        let lite = ConversationLite(id: "blank", source: .codex, startAt: Date(), endAt: Date(),
                                    cwd: "/p", gitBranch: nil, title: nil, preview: "   ",
                                    messageCount: 1, fileURL: URL(fileURLWithPath: "/tmp/blank.jsonl"))
        try index.upsert([(lite, [seg(0, 0, "Sparkle 相关内容")], 1, "Sparkle 相关内容")])

        let out = run(index, ["query": "Sparkle"]).text
        XCTAssertTrue(out.contains("(no title)"),
                      "标题缺失且预览空白时不能印出看不出内容的空白行")
    }

    // MARK: 空结果救援

    func testEmptyResultReturnsMapExcerptAndNextSteps() throws {
        let index = try makeIndex()
        try seed(index, id: "conv-1", segments: [seg(0, 3, "改 src/index.ts 的导出")])

        let out = run(index, ["query": "完全不存在的词组zzz"]).text
        XCTAssertTrue(out.contains("no hits"))
        XCTAssertFalse(out.hasFewerThanThreeLines, "空结果绝不能只回一行")
        XCTAssertTrue(out.contains("1 conversations"), "要报库存总量")
        XCTAssertTrue(out.contains("src/index.ts"), "要给可以照抄去搜的实体")
        XCTAssertTrue(out.contains("memory_browse"), "要给回到地图的路")
    }

    /// 空库上搜东西不能崩，也不能装作有内容。
    func testEmptyIndexSearchSaysIndexIsEmpty() throws {
        let out = run(try makeIndex(), ["query": "anything"]).text
        XCTAssertTrue(out.contains("0 conversations") || out.lowercased().contains("empty"))
    }

    func testMissingQueryIsToolError() throws {
        let out = run(try makeIndex(), [:])
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("query"))
    }

    func testBlankQueryIsToolError() throws {
        XCTAssertTrue(run(try makeIndex(), ["query": "   "]).isError)
    }

    // MARK: 过滤

    func testSourceProjectAndSinceFiltersNarrowResults() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex,      cwd: "/p/one", month: 5,
                 segments: [seg(0, 3, "Sparkle 在 codex 这边")])
        try seed(index, id: "b", source: .claudeCode, cwd: "/p/two", month: 8,
                 segments: [seg(0, 3, "Sparkle 在 claudeCode 这边")])

        let bySource = run(index, ["query": "Sparkle", "source": "codex"]).text
        XCTAssertTrue(bySource.contains("conversation_id=\"a\""))
        XCTAssertFalse(bySource.contains("conversation_id=\"b\""))

        let byProject = run(index, ["query": "Sparkle", "project": "/p/two"]).text
        XCTAssertTrue(byProject.contains("conversation_id=\"b\""))
        XCTAssertFalse(byProject.contains("conversation_id=\"a\""))

        let bySince = run(index, ["query": "Sparkle", "since": "2026-07-01"]).text
        XCTAssertTrue(bySince.contains("conversation_id=\"b\""))
        XCTAssertFalse(bySince.contains("conversation_id=\"a\""))
    }

    /// `context_path`（spec §7.61 情境先验）必须真的接到 `searchWithHits`——这里测的是
    /// 参数解析与接线本身（读出、空串归 nil、传下去），排序机制的单元覆盖在
    /// `ContextPriorTests`。软加权，不是过滤：两条会话都还在，只是顺序变了。
    func testContextPathArgumentBoostsSameRepoConversation() throws {
        let index = try makeIndex()
        try seed(index, id: "same-repo", cwd: "/proj/a",
                 segments: [seg(0, 0, "Sparkle")])
        try seed(index, id: "other-repo", cwd: "/proj/b",
                 segments: [seg(0, 0, "Sparkle Sparkle Sparkle Sparkle")])

        func position(_ id: String, in text: String) -> Int {
            text.range(of: "conversation_id=\"\(id)\"")
                .map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? .max
        }

        let withoutContext = run(index, ["query": "Sparkle"]).text
        XCTAssertLessThan(position("other-repo", in: withoutContext), position("same-repo", in: withoutContext),
                          "前提：无 context_path 时文本命中更强的 other-repo 应排前面")

        let withContext = run(index, ["query": "Sparkle", "context_path": "/proj/a"]).text
        XCTAssertLessThan(position("same-repo", in: withContext), position("other-repo", in: withContext),
                          "context_path 参数要接到 searchWithHits，让同 repo 结果翻到前面")
        XCTAssertTrue(withContext.contains("other-repo"), "软加权绝不过滤——异 repo 结果仍必须在输出里")
    }

    /// 空串 `context_path` 视同未传——不报错，也不触发任何加权。
    func testBlankContextPathIsTreatedAsNoContext() throws {
        let index = try makeIndex()
        try seed(index, id: "a", segments: [seg(0, 3, "Sparkle")])
        let withBlank = run(index, ["query": "Sparkle", "context_path": ""])
        XCTAssertFalse(withBlank.isError)
        XCTAssertTrue(withBlank.text.contains("conversation_id=\"a\""))
    }

    func testInvalidSourceAndSinceAreToolErrorsNotSilentNoFilter() throws {
        let index = try makeIndex()
        try seed(index, id: "a", segments: [seg(0, 3, "Sparkle")])
        // 静默忽略非法过滤条件 = 模型以为自己筛过了，结果看到的是全库
        XCTAssertTrue(run(index, ["query": "Sparkle", "source": "nope"]).isError)
        XCTAssertTrue(run(index, ["query": "Sparkle", "since": "2026/07/01"]).isError)
    }

    /// `DateFormatter` 单靠 `isLenient = false` 挡不住这件事：实测哪怕设了它，
    /// `"2026/07/01"`、`"2026.07.01"`、`"2026 07 01"` 依然全部解析成功——`isLenient`
    /// 管的是数值范围，不管分隔符本身，ICU 会把字段之间的非字母数字字符当通配符。
    /// 这条把当时实测触发过的几种形状一次性钉住，防止将来又退回纯 `DateFormatter` 方案。
    func testSinceRejectsAnySeparatorOtherThanDashAndAnyNonYYYYMMDDShape() throws {
        let index = try makeIndex()
        try seed(index, id: "a", segments: [seg(0, 3, "Sparkle")])
        for bad in ["2026/07/01", "2026.07.01", "2026 07 01", "2026-7-1", "26-07-01",
                    "2026-07-01x", "not-a-date"] {
            XCTAssertTrue(run(index, ["query": "Sparkle", "since": bad]).isError,
                          "since=\"\(bad)\" 应该报错，而不是被 DateFormatter 悄悄解析成功")
        }
        // 合法值必须仍然放行——不能矫枉过正把正确格式也挡住
        XCTAssertFalse(run(index, ["query": "Sparkle", "since": "2026-07-01"]).isError)
    }

    /// 过滤只扫相关度前 scanCap 条；这个上限一旦生效必须说出来。
    func testFilterScanCapIsAnnouncedWhenItBites() throws {
        let index = try makeIndex()
        for i in 0..<(MemorySearchTool.scanCap + 5) {
            try seed(index, id: "c\(i)", source: .codex, cwd: "/p",
                     day: (i % 28) + 1, segments: [seg(0, 3, "Sparkle 第 \(i) 条")])
        }
        let out = run(index, ["query": "Sparkle", "source": "claudeCode"]).text
        XCTAssertTrue(out.contains("\(MemorySearchTool.scanCap)"),
                      "上限吃掉了结果却没说——读起来就是「筛完了，一条都没有」")
    }

    func testLimitCapsListedResultsAndReportsTotal() throws {
        let index = try makeIndex()
        for i in 0..<5 { try seed(index, id: "c\(i)", day: i + 1, segments: [seg(0, 3, "Sparkle \(i)")]) }
        let out = run(index, ["query": "Sparkle", "limit": 2]).text
        XCTAssertTrue(out.contains("5 conversations matched"))
        XCTAssertTrue(out.contains("showing 2"))
    }

    // MARK: limit 钳制

    /// 只断言 `.isError == false` 没有判别力（把 `clampLimit` 改成 `?? 1`、删掉上限、
    /// 下限改 0，全都照绿）。这里直接对 `clampLimit` 本身按输入类型/边界逐个断言
    /// （同 `MemoryBrowseToolTests.testClampLimitDefaultsAndBoundaries`）。
    func testClampLimitDefaultsAndBoundaries() {
        XCTAssertEqual(MemorySearchTool.clampLimit(nil), MemorySearchTool.defaultLimit)
        XCTAssertEqual(MemorySearchTool.clampLimit(-5), 1)
        XCTAssertEqual(MemorySearchTool.clampLimit(0), 1)
        XCTAssertEqual(MemorySearchTool.clampLimit(99_999), MemorySearchTool.maxLimit)
        // Int(exactly:) 对非有限值/超出位宽的值返回 nil，回落默认——不能让这类输入
        // 直接把 Int(Double) 的 trap 带进 mindbus-mcp 进程。
        XCTAssertEqual(MemorySearchTool.clampLimit(Double.infinity), MemorySearchTool.defaultLimit)
        XCTAssertEqual(MemorySearchTool.clampLimit(-Double.infinity), MemorySearchTool.defaultLimit)
        XCTAssertEqual(MemorySearchTool.clampLimit(Double.nan), MemorySearchTool.defaultLimit)
        XCTAssertEqual(MemorySearchTool.clampLimit(1e300), MemorySearchTool.defaultLimit)
        XCTAssertEqual(MemorySearchTool.clampLimit(30), 30)
        XCTAssertEqual(MemorySearchTool.clampLimit(30.0), 30)
    }

    /// JSON 数字的指数可以大到解析成 Double.infinity（如 `1e400`），普通有限但超大的
    /// Double（如 `1e300`）也装不进 Int；`Int(Double)` 对这两类输入都会直接 trap，
    /// 拖死整个 MCP 进程。这里从 `run(_:_:)` 整条路径喂这些值进去，确认真正接线的地方
    /// （不只是 `clampLimit` 单元本身）也不会崩、不会报错。
    func testLimitSurvivesNonFiniteOrOutOfRangeDoubleThroughRun() throws {
        let index = try makeIndex()
        try seed(index, id: "a", segments: [seg(0, 3, "Sparkle")])
        for bad: Any in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300] {
            XCTAssertFalse(run(index, ["query": "Sparkle", "limit": bad]).isError,
                           "limit=\(bad) 不该让工具报错，更不该让进程崩溃")
        }
    }

    // MARK: 片段取窗

    func testSnippetCentersOnTheNeedleAndCollapsesWhitespace() {
        let head = String(repeating: "前", count: 400)
        let tail = String(repeating: "后", count: 400)
        let snippet = MCPText.snippet(head + "\n\tNEEDLE  here\n" + tail, around: "needle", max: 120)
        XCTAssertTrue(snippet.contains("NEEDLE"), "命中词落在窗口外，片段等于没用")
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertFalse(snippet.contains("  "), "连续空白没折叠")
        XCTAssertTrue(snippet.count <= 130)
    }

    /// 母串必须**长于** max，取窗逻辑才真的会走到——短母串在 `guard flat.count > max`
    /// 就提前返回整串，那样的断言无论取窗对错都绿（审查抓过一次这种恒真测试）。
    func testSnippetFallsBackToHeadWhenNeedleAbsent() {
        let long = "alpha beta gamma " + String(repeating: "filler ", count: 40)
        let snippet = MCPText.snippet(long, around: "zzz", max: 30)
        XCTAssertTrue(snippet.hasPrefix("alpha"), "找不到命中词就该从头取窗")
        XCTAssertTrue(snippet.hasSuffix("…"), "母串被截了却没有截断标记")
        XCTAssertLessThanOrEqual(snippet.count, 40)
    }

    /// 多词查询用第一个词取窗；CJK 与英文紧邻也要能找到（trigram 路命中的正是这种）。
    /// 同样要求母串长于 max：这条测试曾因母串 21 字 < max 60 而从未走到 `range(of:)`。
    func testSnippetHandlesCJKAdjacentNeedle() {
        let text = String(repeating: "前置内容", count: 30)
            + "看一下VaultArchive这个类的实现" + String(repeating: "后续", count: 20)
        let snippet = MCPText.snippet(text, around: "VaultArchive", max: 40)
        XCTAssertTrue(snippet.contains("VaultArchive"), "CJK 紧邻的命中词落在窗口外")
        XCTAssertTrue(snippet.hasPrefix("…"), "窗口从中段开始却没有前导省略号")
    }

    /// `max` 为负数时 `lead = max/4` 为负、`flat.index(start, offsetBy: max, limitedBy:)`
    /// 会把窗口终点算到起点之前——`limitedBy` 只挡住越过 limit 方向的越界，挡不住反方向
    /// 越过 `start` 本身，实测在未加保护时直接触发 "Range requires lowerBound <=
    /// upperBound" 的 Fatal error，崩掉整个 mindbus-mcp 进程。`MCPText.snippet` 是
    /// public API，不能假设调用方永远传正数（今天唯一的调用点传的是常量 220，
    /// 但下一个调用点未必是常量）。
    func testSnippetWithNegativeMaxDoesNotCrashAndDegradesToEmptyWindow() {
        let text = String(repeating: "x", count: 50)
        let snippet = MCPText.snippet(text, around: "needle", max: -5)
        XCTAssertEqual(snippet, "…",
                       "负数窗口应钳到 0、退化成一个空窗口+省略号，而不是崩溃：\(snippet)")
    }

    // MARK: 注册

    func testToolIsRegisteredWithFullSchemaAndRetrievalLoop() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_search" })
        let properties = try XCTUnwrap(spec.inputSchema["properties"] as? [String: Any])
        for key in ["query", "source", "project", "since", "limit", "context_path"] {
            XCTAssertNotNil(properties[key], "schema 缺 \(key)")
        }
        XCTAssertEqual(spec.inputSchema["required"] as? [String], ["query"])
        XCTAssertTrue(spec.description.contains("memory_browse"),
                      "检索循环必须写死在 description 里")
        XCTAssertTrue(spec.description.contains("memory_open"))
    }

    /// `inputSchema` 要经 `JSONSerialization` 序列化进 `tools/list` 的响应——里面任何一个
    /// 值不是合法 JSON 都会让 `JSONRPC.encode` 走兜底错误帧，宿主拿到的 `tools/list`
    /// 就会缺这个工具的完整 schema（同 `MemoryBrowseToolTests.testInputSchemaIsValidJSON`）。
    func testInputSchemaIsValidJSON() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_search" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema))
    }

    /// `memory_search` 是检索循环的第一入口，必须排在工具列表最前面。
    func testMemorySearchIsListedBeforeMemoryBrowse() {
        let names = MCPToolCatalog.all.map(\.name)
        let searchIdx = names.firstIndex(of: "memory_search")
        let browseIdx = names.firstIndex(of: "memory_browse")
        XCTAssertNotNil(searchIdx)
        XCTAssertNotNil(browseIdx)
        if let searchIdx, let browseIdx {
            XCTAssertLessThan(searchIdx, browseIdx, "搜索是第一入口，应排在浏览前面")
        }
    }

    // MARK: 借宿主改写（spec §5：机械 RM3 只能桥有共现的词，语义跨越借宿主智能）

    /// 零命中救援必须带结构化改写指令——宿主是语言模型，让它生成语义改写再查。
    func testZeroHitRescueCarriesRewriteInstruction() throws {
        let index = try makeIndex()
        try seed(index, id: "a", segments: [seg(0, 3, "毫无关联的内容")])
        let out = run(index, ["query": "完全查不到的词zzz"]).text
        XCTAssertTrue(out.contains("REWRITE"), "零命中该给宿主改写指令")
        XCTAssertTrue(out.contains("Do not repeat the original wording"),
                      "要明说别重复原词——机械扩展已经试过共现词了")
    }

    /// 低命中（1-3 条）时结果照给，但要附加改写建议。
    func testLowHitAppendsRewriteSuggestion() throws {
        let index = try makeIndex()
        try seed(index, id: "a", segments: [seg(0, 3, "Sparkle 的相关讨论")])
        try seed(index, id: "b", day: 16, segments: [seg(0, 3, "Sparkle 又一场")])
        let out = run(index, ["query": "Sparkle"]).text
        XCTAssertTrue(out.contains("conversations matched"), "结果本身照常给")
        XCTAssertTrue(out.contains("rewrite the query"), "低命中要提示改写")
    }

    /// 命中充足（≥4 条）不打扰——指令噪声只在弱区出现。
    func testAbundantHitsCarryNoRewriteNoise() throws {
        let index = try makeIndex()
        for i in 0..<5 {
            try seed(index, id: "c\(i)", day: i + 1, segments: [seg(0, 3, "Sparkle 第 \(i) 场")])
        }
        let out = run(index, ["query": "Sparkle"]).text
        XCTAssertFalse(out.contains("REWRITE"))
        XCTAssertFalse(out.contains("rewrite the query"))
    }
}

/// 只给上面「空结果绝不能只回一行」那条断言用的小工具：判"输出短到等于什么都没说"
/// （原简报写的是 `isError2Empty`，与 `MCPToolOutput.isError` 无关，容易读错，改成
/// 直白描述实现的名字）。
private extension String {
    var hasFewerThanThreeLines: Bool { split(separator: "\n").count < 3 }

}
