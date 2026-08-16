import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// L0 地图 / L1 切面页。两条硬要求来自 MEMORY-LAYER-SPEC §1：
/// ①每一层都要给出通向下一层的**可执行句柄**，且句柄能原样当下一次调用的参数；
/// ②空结果不返回空——返回地图节选加切面建议。
final class MemoryBrowseToolTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        try makeIndexWithPath().0
    }

    /// 同 `makeIndex()`，额外把库文件路径带出来——个别测试需要开一条独立的原始
    /// SQLite 连接直接改列（造 Swift 类型层面构造不出的脏数据，如未知 source），
    /// 参照 `ReadOnlyIndexTests` 里已经验证过的同一手法：WAL 模式下多连接指向
    /// 同一文件是安全的。
    private func makeIndexWithPath() throws -> (ConversationIndex, String) {
        let path = NSTemporaryDirectory() + "browse-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return (try ConversationIndex(path: path), path)
    }

    private func seed(_ index: ConversationIndex, id: String, source: ConversationSource,
                      cwd: String, year: Int, month: Int, day: Int = 15,
                      title: String? = nil, text: String) throws {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 21; c.minute = 14
        let date = Calendar(identifier: .gregorian).date(from: c)!
        let lite = ConversationLite(id: id, source: source, startAt: date, endAt: date,
                                    cwd: cwd, gitBranch: nil, title: title,
                                    preview: String(text.prefix(60)), messageCount: 7,
                                    fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
        try index.upsert([(lite, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 6, text: text)],
                           1, text)])
    }

    private func render(_ index: ConversationIndex, facet: String? = nil, limit: Int = 20) -> String {
        var args: [String: Any] = ["limit": limit]
        if let facet { args["facet"] = facet }
        return MemoryBrowseTool.spec.run(args, index).text
    }

    // MARK: L0 地图

    func testMapListsEveryFacetWithUsableHandles() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex,      cwd: "/p/one", year: 2026, month: 7,
                 text: "改 src/index.ts 的导出")
        try seed(index, id: "b", source: .claudeCode, cwd: "/p/two", year: 2026, month: 8,
                 text: "改 src/index.ts 的类型")

        let out = render(index)
        XCTAssertTrue(out.contains("2 conversations"))
        XCTAssertTrue(out.contains("BY TOOL"))
        XCTAssertTrue(out.contains(#"facet="source:codex""#))
        XCTAssertTrue(out.contains(#"facet="project:/p/one""#))
        XCTAssertTrue(out.contains(#"facet="month:2026-08""#))
        XCTAssertTrue(out.contains("NEXT:"))
        // NEXT 行的 query 占位符不能与真句柄（`facet="value"`）同形——同理见
        // `testFacetPageNextLineHandleIsNotACopyablePlaceholder`。
        XCTAssertFalse(out.contains(#"query="…""#),
                       "地图页 NEXT 行的 query 占位符不能印成带引号的假句柄")
    }

    /// 句柄必须能原样喂回去——这是 §1 的硬要求，也是最容易做残的地方
    /// （给了 `source:codex` 但解析器只认 `codex`，模型照抄就空手而归）。
    func testEveryHandleOnTheMapRoundTrips() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p/one", year: 2026, month: 7,
                 text: "改 src/index.ts 的导出")

        let handles = render(index)
            .components(separatedBy: "facet=\"")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "\"").first }
        XCTAssertFalse(handles.isEmpty)
        for handle in handles {
            let parsed = MemoryBrowseTool.parseFacet(handle)
            XCTAssertNotNil(parsed, "地图印出的句柄 \(handle) 解析不回来")
            XCTAssertFalse(render(index, facet: handle).contains("0 conversations"),
                           "地图印出的句柄 \(handle) 点进去是空的")
        }
    }

    func testMapOnEmptyLibrarySaysSoWithoutPretendingToHaveFacets() throws {
        let out = render(try makeIndex())
        XCTAssertTrue(out.contains("0 conversations"))
        XCTAssertTrue(out.lowercased().contains("open the mindbus app"),
                      "空库要告诉用户去建库，而不是印一张空表")
    }

    /// `mapOverview().byProject` 在 Core 侧已经被截到前 20（见 `MapOverview.byProject` 的
    /// 文档注释），地图页在此基础上再截到前 10 显示。若拿到的列表长度恰好等于 Core 的
    /// 截断上限，真实项目总数完全可能比这个数更多——"of M" 这时不能把截断值当真总数印
    /// 出去（那和"静默截断读起来像全部都在这儿了"是同一类问题，只是发生在总数而非列表上）。
    func testMapByProjectHonestlyFlagsUnknownTotalWhenCoreListIsAtItsCap() throws {
        let index = try makeIndex()
        for i in 0..<25 {
            try seed(index, id: "p\(i)", source: .codex, cwd: "/p/project\(i)",
                     year: 2026, month: 7, text: "alpha")
        }
        let out = render(index)
        XCTAssertTrue(out.contains("BY PROJECT (top 10 of 20+)"),
                      "Core 只给前 20 个项目，真实总数可能更多，不能断言恰好是 20")
    }

    /// `topEntities(limit: 20)` 是 Core 侧硬上限，地图页只再取前 15 显示——表头必须
    /// 说清"顶多显示这些"，不能让 20 这个采样上限被当成真总数印出来（与上一轮给
    /// BY PROJECT 加的 "(top 10 of 20+)" 是同一类问题，这次落在 TOP ENTITIES 上）。
    func testMapTopEntitiesHonestlyFlagsUnknownTotalWhenCoreListIsAtItsCap() throws {
        let index = try makeIndex()
        // 25 个互不相同、只各出现一次的路径实体——文档频率远低于滤板板阈值，
        // 不会被 topEntities 的 HAVING 子句滤掉。
        for i in 0..<25 {
            try seed(index, id: "e\(i)", source: .codex, cwd: "/p", year: 2026, month: 7,
                     text: "改 src/file\(i).ts 的导出")
        }
        let out = render(index)
        XCTAssertTrue(out.contains("TOP ENTITIES (top 15 of 20+)"),
                      "Core 只给前 20 个实体，真实总数可能更多，不能断言恰好是 20")
    }

    /// 两个实测可达的"印得出、喂不回"场景之一：DB 里的 source 列若不是当前二进制
    /// 认得的枚举值（新 App 写入新 source、宿主还在跑旧 mindbus-mcp 二进制），
    /// Swift 类型层面（`ConversationSource` 是穷举枚举）造不出这种脏数据，必须直接
    /// 开一条独立连接改列才能复现——手法与 `ReadOnlyIndexTests` 一致。
    func testMapSkipsHandleForUnrecognisedSourceButStillShowsTheRow() throws {
        let (index, path) = try makeIndexWithPath()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        let raw = try SQLiteDB(path: path)
        try raw.exec("UPDATE conversations SET source = 'gemini' WHERE id = 'a';")

        let out = render(index)
        XCTAssertTrue(out.contains("BY TOOL"))
        XCTAssertTrue(out.contains("gemini"), "行本身仍要显示——分项计数得跟地图总数对得上")
        XCTAssertFalse(out.contains(#"facet="source:gemini""#),
                       "未知 source 解析不回来，不能把它印成一个看似能用的句柄")
    }

    /// 两个实测可达场景之二：`start_at` 超出 SQLite `strftime` 能表示的范围时
    /// （有 loader 把未校验时间戳直接除以 1000，ns 级脏数据即溢出），月份分桶表达式
    /// 返回 SQL NULL，读出来是空字符串——地图若照印会得到 `facet="month:"`。
    func testMapSkipsHandleForOutOfRangeMonthBucketButStillShowsTheRow() throws {
        let (index, path) = try makeIndexWithPath()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        let raw = try SQLiteDB(path: path)
        // 1e18 秒早已超出 SQLite 日期函数能表示的范围——实测
        // `strftime('%Y-%m', 1e18, 'unixepoch', 'localtime')` 直接返回 NULL。
        try raw.exec("UPDATE conversations SET start_at = 1e18 WHERE id = 'a';")

        let out = render(index)
        XCTAssertTrue(out.contains("BY MONTH"))
        XCTAssertFalse(out.contains(#"facet="month:""#),
                       "空月份桶解析不回来，不能把它印成一个看似能用的句柄")
    }

    /// cwd 含双引号或换行会让 `facet="…"` 这个引号包裹的句柄结构本身断裂——即使
    /// `parseFacet` 认得这个值，印出来的文本对模型来说已经不是一个能干净复制的句柄。
    func testMapSkipsProjectHandleWhenCwdContainsQuoteOrNewline() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p/one\"two", year: 2026, month: 7, text: "alpha")
        try seed(index, id: "b", source: .codex, cwd: "/p/three\nfour", year: 2026, month: 7, text: "beta")

        let out = render(index)
        XCTAssertTrue(out.contains("/p/one\"two"), "展示文本仍要保留原始 cwd，只是不给句柄")
        XCTAssertFalse(out.contains(#"facet="project:/p/one"two""#),
                       "cwd 含引号时不能印成 facet=\"…\" 句柄——引号会让句柄的引号配对断裂")
        XCTAssertFalse(out.contains(#"facet="project:/p/three"#),
                       "cwd 含换行时不能印成 facet=\"…\" 句柄——真换行会把一行拆成两行")
    }

    /// `day()` 对越界日期返回空串而不是 nil；若只判断"两个 Date 都非 nil"就直接拼
    /// "→"，越界的一侧会拼出空字符串，首行读起来自相矛盾。这里两个日期一个正常、
    /// 一个越界，验证整段时间跨度被一起省略，而不是印出一半。
    func testMapOmitsDateSpanEntirelyWhenEitherEndFormatsToEmptyString() throws {
        let (index, path) = try makeIndexWithPath()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        let raw = try SQLiteDB(path: path)
        try raw.exec("UPDATE conversations SET end_at = 1e18 WHERE id = 'a';")

        let out = render(index)
        XCTAssertTrue(out.contains("1 conversations"))
        XCTAssertFalse(out.contains(" → "), "任一端格式化失败就不该印半个时间跨度")
    }

    /// `String.padding(toLength:)` 按 UTF-16 code unit 计长度，不是 Swift 的 Character 计数——
    /// 代理对字符（emoji 等）会让它数出的长度比 Character 计数更大，若两种计数方式在同一处
    /// 被混用，对齐补空格时会把最后一个字符悄悄切掉（实测会切出一个悬空代理项，
    /// 转回 String 时变成 U+FFFD 替换字符）。
    func testMapDoesNotTruncateAstralCharactersWhenAligningColumns() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p/🎉", year: 2026, month: 7, text: "alpha")
        let out = render(index)
        let projectLine = try XCTUnwrap(
            out.components(separatedBy: "\n").first { $0.contains(#"facet="project:"#) })
        let displayColumn = try XCTUnwrap(projectLine.components(separatedBy: "facet=").first)
        XCTAssertTrue(displayColumn.contains("/p/🎉"),
                      "对齐补空格的展示列把代理对字符切掉了：\(projectLine)")
    }

    // MARK: L1 切面页

    func testFacetPageListsConversationsWithOpenHandles() throws {
        let index = try makeIndex()
        try seed(index, id: "conv-1", source: .codex, cwd: "/p/one", year: 2026, month: 7,
                 title: "重构导出", text: "改 src/index.ts 的导出")

        let out = render(index, facet: "source:codex")
        XCTAssertTrue(out.contains("FACET source:codex"))
        XCTAssertTrue(out.contains("1 conversations"))
        XCTAssertTrue(out.contains("2026-07-15 21:14"))
        XCTAssertTrue(out.contains("/p/one"))
        XCTAssertTrue(out.contains("(7 msgs)"))
        XCTAssertTrue(out.contains("重构导出"), "有官方标题就用标题")
        XCTAssertTrue(out.contains(#"conversation_id="conv-1""#))
        XCTAssertTrue(out.contains("memory_open"))
    }

    /// L1 切面页最后一行此前是 `NEXT: memory_open(conversation_id="…") reads the
    /// original messages.`——与同一页三行前的真句柄 `conversation_id="conv-1"` 完全
    /// 同形、同页、相隔三行，模型照抄 `"…"` 就白烧一轮。这里扫描输出里所有
    /// `conversation_id="..."` 提取值，断言每一个都真的是本页列出的会话 id，
    /// 不存在 "…" 这类占位字面量混进真句柄的行列。
    func testFacetPageNextLineHandleIsNotACopyablePlaceholder() throws {
        let index = try makeIndex()
        try seed(index, id: "conv-1", source: .codex, cwd: "/p/one", year: 2026, month: 7,
                 title: "重构导出", text: "改 src/index.ts 的导出")
        try seed(index, id: "conv-2", source: .codex, cwd: "/p/one", year: 2026, month: 7,
                 title: "修 bug", text: "修 tests/unit.test.ts")

        let out = render(index, facet: "source:codex")
        let handles = out.components(separatedBy: "conversation_id=\"")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "\"").first }
        XCTAssertFalse(handles.isEmpty)
        let realIDs: Set<String> = ["conv-1", "conv-2"]
        for h in handles {
            XCTAssertTrue(realIDs.contains(h),
                          "conversation_id=\"\(h)\" 不是本页列出的真会话 id——NEXT 行的占位符" +
                          "与真句柄同形，模型会照抄")
        }
    }

    func testFacetPageFallsBackToPreviewWhenTitleMissing() throws {
        let index = try makeIndex()
        try seed(index, id: "conv-1", source: .codex, cwd: "/p", year: 2026, month: 7,
                 title: nil, text: "改 src/index.ts 的导出")
        XCTAssertTrue(render(index, facet: "source:codex").contains("改 src/index.ts 的导出"))
    }

    func testEntityFacetAddsCoOccurringEntities() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7,
                 text: "改 src/index.ts 时顺手动了 tests/unit.test.ts")
        try seed(index, id: "b", source: .codex, cwd: "/p", year: 2026, month: 7,
                 text: "src/index.ts 与 tests/unit.test.ts 又对不上了")

        let out = render(index, facet: "entity:src/index.ts")
        XCTAssertTrue(out.contains("FACET entity:src/index.ts"))
        XCTAssertTrue(out.contains("CO-OCCURRING ENTITIES"))
        XCTAssertTrue(out.contains(#"facet="entity:tests/unit.test.ts""#))
    }

    /// 月份切面按 `start_at` 分桶（见 `ConversationIndex.monthBucketSQL` 注释），但 L1
    /// 行内此前印的是 `endAt`——跨月会话（7-31 深夜开始、8-1 凌晨结束）在
    /// `month:2026-07` 页里那一行会印出 8 月的日期，模型问 7 月却看到 8 月，分桶轴与
    /// 行内展示打架。
    func testFacetPageInlineDateUsesStartAtNotEndAtForCrossMonthConversation() throws {
        let index = try makeIndex()
        var startComponents = DateComponents()
        startComponents.year = 2026; startComponents.month = 7; startComponents.day = 31
        startComponents.hour = 23; startComponents.minute = 30
        let start = Calendar(identifier: .gregorian).date(from: startComponents)!

        var endComponents = DateComponents()
        endComponents.year = 2026; endComponents.month = 8; endComponents.day = 1
        endComponents.hour = 2; endComponents.minute = 10
        let end = Calendar(identifier: .gregorian).date(from: endComponents)!

        let lite = ConversationLite(id: "cross-month", source: .codex, startAt: start, endAt: end,
                                    cwd: "/p", gitBranch: nil, title: "跨月",
                                    preview: "跨月对话", messageCount: 3,
                                    fileURL: URL(fileURLWithPath: "/tmp/cross-month.jsonl"))
        try index.upsert([(lite, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 2,
                                                    text: "跨月对话内容")], 1, "跨月对话内容")])

        let out = render(index, facet: "month:2026-07")
        XCTAssertTrue(out.contains("2026-07-31 23:30"), "行内日期应为开始时间，与月份分桶轴一致")
        XCTAssertFalse(out.contains("2026-08-01"), "月份切面是 2026-07，行内日期不该印成 8 月")
    }

    /// title 缺失且 preview 也是空白（纯空格/空字符串）时，不能印出四个空格的空
    /// 行——模型读不出那是"没有标题"还是排版事故。cwd 空串（browser 伪会话没有真实
    /// 路径）同理不能让展示列悄悄塌成四个连续空格。
    func testFacetPageFallsBackForBlankTitleAndEmptyCwd() throws {
        let index = try makeIndex()
        let lite = ConversationLite(id: "blank", source: .browser, startAt: Date(), endAt: Date(),
                                    cwd: "", gitBranch: nil, title: nil, preview: "   ",
                                    messageCount: 1, fileURL: URL(fileURLWithPath: "/tmp/blank.jsonl"))
        try index.upsert([(lite, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0,
                                                    text: "内容")], 1, "内容")])

        let out = render(index, facet: "source:browser")
        XCTAssertTrue(out.contains("(no title)"))
        XCTAssertTrue(out.contains("(no project)"))
        let lines = out.components(separatedBy: "\n")
        XCTAssertFalse(lines.contains("    "), "标题行不该退化成四个空格的空行")
    }

    /// `run` 判空用的是 trim 过的值，但此前传给 `parseFacet` 的是原始 `raw`——
    /// `"project:/p/one "`（尾空格）会被当成一个字面上确实不存在的项目路径，查出
    /// 0 条，比报错更糟：该项目明明有会话，却被说成"这个切面是空的"。
    func testFacetWithTrailingWhitespaceMatchesTrimmedFacet() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p/one", year: 2026, month: 7, text: "alpha")
        let trimmed = render(index, facet: "project:/p/one")
        let padded = render(index, facet: "project:/p/one ")
        XCTAssertEqual(trimmed, padded)
        XCTAssertFalse(padded.contains("0 conversations"))
    }

    /// `render(facet:limit:index:)` 是 public API，钳制此前只活在 `spec.run` 里——任何
    /// 绕过 `spec.run` 直接调 `render` 的调用方都会把一个没夹过的 limit 直接送进 SQL。
    /// 这里直接调 `render` 本身验证钳制生效。
    func testRenderClampsLimitEvenWhenCalledDirectly() throws {
        let index = try makeIndex()
        for i in 0..<5 {
            try seed(index, id: "c\(i)", source: .codex, cwd: "/p", year: 2026, month: 7,
                     day: i + 1, text: "alpha \(i)")
        }
        let full = MemoryBrowseTool.render(facet: .source(.codex), limit: 99_999, index: index)
        XCTAssertFalse(full.isError)
        XCTAssertFalse(full.text.contains("showing"), "5 条全展示，不该出现截断提示")

        let clamped = MemoryBrowseTool.render(facet: .source(.codex), limit: -50, index: index)
        XCTAssertFalse(clamped.isError)
        XCTAssertTrue(clamped.text.contains("showing 1"),
                      "负数 limit 必须钳到 1，而不是原样传给 SQL LIMIT")
    }

    /// `"%2d"` 在 limit 上限恰好 100 行时会让第 100 行比前面多一位数字，把对齐撑歪——
    /// 宽度必须按实际展示的行数动态算。这里用 100 条会话验证第 1 行与第 100 行的
    /// 行号宽度真的一致（回归会表现为两种宽度混杂在同一页里）。
    func testFacetPageRowLabelsStayAlignedAtMaxLimit() throws {
        let index = try makeIndex()
        for i in 0..<100 {
            try seed(index, id: "c\(i)", source: .codex, cwd: "/p", year: 2026, month: 7,
                     day: (i % 28) + 1, text: "alpha \(i)")
        }
        let out = render(index, facet: "source:codex", limit: 100)
        let headerLines = out.components(separatedBy: "\n").filter { $0.contains("msgs)") }
        XCTAssertEqual(headerLines.count, 100)
        // 每行第一个 "." 就是行号后面那个点（日期用 "-"、消息数用 "(N msgs)"，
        // 都不含 "."）——它的位置即行号标签的宽度，全部 100 行必须完全一致。
        let dotPositions = Set(headerLines.compactMap { line -> Int? in
            guard let dotIndex = line.firstIndex(of: ".") else { return nil }
            return line.distance(from: line.startIndex, to: dotIndex)
        })
        XCTAssertEqual(dotPositions, [3],
                       "100 行时每行的行号宽度必须一致按 3 位对齐，不能只有第 100 行单独多一位")
    }

    /// 有效语法但库里没有：不能只回一行"0 条"，要给回到地图的路。
    func testEmptyFacetSuggestsGoingBackToTheMap() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        let out = render(index, facet: "source:cursor")
        XCTAssertTrue(out.contains("0 conversations"))
        XCTAssertTrue(out.contains("memory_browse"))
    }

    func testInvalidFacetSyntaxExplainsTheGrammar() throws {
        let index = try makeIndex()
        let output = MemoryBrowseTool.spec.run(["facet": "codex"], index)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("source:"))
        XCTAssertTrue(output.text.contains("month:"))
    }

    // MARK: 解析与上限

    func testParseFacetAcceptsAllFourKindsAndRejectsGarbage() {
        XCTAssertEqual(MemoryBrowseTool.parseFacet("source:codex"), .source(.codex))
        XCTAssertEqual(MemoryBrowseTool.parseFacet("month:2026-07"), .month("2026-07"))
        // 路径本身含冒号也要能过（只切第一个冒号）
        XCTAssertEqual(MemoryBrowseTool.parseFacet("project:/p/a:b"), .project("/p/a:b"))
        XCTAssertEqual(MemoryBrowseTool.parseFacet("entity:http://x/y"), .entity("http://x/y"))
        XCTAssertNil(MemoryBrowseTool.parseFacet("codex"))
        XCTAssertNil(MemoryBrowseTool.parseFacet("source:nope"))
        XCTAssertNil(MemoryBrowseTool.parseFacet("month:2026-7"))
        XCTAssertNil(MemoryBrowseTool.parseFacet(""))
    }

    /// 上限被吃掉时必须说出来——静默截断读起来就是"全部都在这儿了"。
    func testFacetPageAnnouncesTruncation() throws {
        let index = try makeIndex()
        for i in 0..<5 {
            try seed(index, id: "c\(i)", source: .codex, cwd: "/p", year: 2026, month: 7,
                     day: i + 1, text: "alpha \(i)")
        }
        let out = render(index, facet: "source:codex", limit: 2)
        XCTAssertTrue(out.contains("5 conversations"))
        XCTAssertTrue(out.contains("showing 2"))
    }

    func testLimitIsClampedToSaneRange() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        // 负数与超大值都不该炸，也不该让 SQL 收到荒谬的 LIMIT
        XCTAssertFalse(MemoryBrowseTool.spec.run(["facet": "source:codex", "limit": -5], index).isError)
        XCTAssertFalse(MemoryBrowseTool.spec.run(["facet": "source:codex", "limit": 99_999], index).isError)
    }

    /// 上面那条 `testLimitIsClampedToSaneRange` 只断言 `isError == false`——把
    /// `clampLimit` 改成 `?? 1`、删掉上限、下限改 0，全都照绿，没有判别力。这里直接
    /// 对 `clampLimit` 本身按输入类型/边界逐个断言。
    func testClampLimitDefaultsAndBoundaries() {
        XCTAssertEqual(MemoryBrowseTool.clampLimit(nil), MemoryBrowseTool.defaultLimit)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(-5), 1)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(0), 1)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(99_999), MemoryBrowseTool.maxLimit)
        // Int(exactly:) 对非有限值/超出位宽的值返回 nil，回落默认——不能让这类输入
        // 直接把 Int(Double) 的 trap 带进 mindbus-mcp 进程。
        XCTAssertEqual(MemoryBrowseTool.clampLimit(Double.infinity), MemoryBrowseTool.defaultLimit)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(-Double.infinity), MemoryBrowseTool.defaultLimit)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(Double.nan), MemoryBrowseTool.defaultLimit)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(1e300), MemoryBrowseTool.defaultLimit)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(50), 50)
        XCTAssertEqual(MemoryBrowseTool.clampLimit(50.0), 50)
    }

    /// JSON 数字的指数可以大到解析成 Double.infinity（如 `1e400`），普通有限但超大的
    /// Double（如 `1e300`）也装不进 Int；`Int(Double)` 对这两类输入都会直接 trap，
    /// 拖死整个 MCP 进程（`JSONRPC.RequestID.from` 已经因同一类问题改用
    /// `Int(exactly:)`，这里必须用同样的写法而不是重蹈覆辙）。
    func testLimitSurvivesNonFiniteOrOutOfRangeDouble() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        for bad: Any in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300] {
            XCTAssertFalse(MemoryBrowseTool.spec.run(["facet": "source:codex", "limit": bad], index).isError,
                           "limit=\(bad) 不该让工具报错，更不该让进程崩溃")
        }
    }

    // MARK: 注册

    func testToolIsRegisteredWithSchemaAndRetrievalLoop() {
        let spec = try? XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_browse" })
        XCTAssertNotNil(spec)
        let properties = (spec?.inputSchema["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(properties["facet"])
        XCTAssertNotNil(properties["limit"])
        // 检索循环必须写死在 description 里（§4）
        XCTAssertTrue(spec?.description.contains("memory_search") == true)
    }

    /// `inputSchema` 要经 `JSONSerialization` 序列化进 `tools/list` 的响应——里面任何一个
    /// 值不是合法 JSON（枚举、URL、非有限 Double……）都会让 `JSONRPC.encode` 走兜底错误帧，
    /// 宿主拿到的 `tools/list` 就会缺这个工具的完整 schema。
    func testInputSchemaIsValidJSON() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_browse" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema))
    }
}
