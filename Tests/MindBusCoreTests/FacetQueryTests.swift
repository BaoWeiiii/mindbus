import XCTest
@testable import MindBusCore

/// 切面查询：MCP 的 L1 页与 GUI 的实体页共用同一套口径。
/// 月份分桶必须和 `mapOverview()` 用同一条 strftime 表达式——两处各写一遍就会在
/// 时区边界上给出不一致的答案（地图说 7 月有 33 场，点进去只有 32 场）。
final class FacetQueryTests: XCTestCase {

    /// 固定用公历构造测试日期——`Calendar.current` 在非公历的区域设置（如佛历）下
    /// 年份会整体偏移，让下面按 `year:`/`month:` 断言的月份字符串对不上，测试变红。
    private let gregorian = Calendar(identifier: .gregorian)

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "facet-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    /// 造一条会话：endAt 用 DateComponents 在**本机时区**构造，让 strftime 的
    /// localtime 分桶结果与断言里的月份字符串必然一致（跨时区跑测试不会红）。
    private func seed(_ index: ConversationIndex, id: String, source: ConversationSource,
                      cwd: String, year: Int, month: Int, text: String) throws {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = 15; c.hour = 12
        let date = gregorian.date(from: c)!
        let lite = ConversationLite(id: id, source: source, startAt: date, endAt: date,
                                    cwd: cwd, gitBranch: nil, preview: "p", messageCount: 1,
                                    fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
        try index.upsert([(lite, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)], 1, text)])
    }

    func testConversationIDsBySourceProjectMonth() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex,      cwd: "/p/one", year: 2026, month: 7, text: "alpha")
        try seed(index, id: "b", source: .claudeCode, cwd: "/p/one", year: 2026, month: 7, text: "beta")
        try seed(index, id: "c", source: .claudeCode, cwd: "/p/two", year: 2026, month: 8, text: "gamma")

        XCTAssertEqual(Set(index.conversationIDs(for: .source(.claudeCode), limit: 10)), ["b", "c"])
        XCTAssertEqual(Set(index.conversationIDs(for: .project("/p/one"), limit: 10)), ["a", "b"])
        XCTAssertEqual(Set(index.conversationIDs(for: .month("2026-08"), limit: 10)), ["c"])
        XCTAssertEqual(index.conversationCount(for: .source(.claudeCode)), 2)
        XCTAssertEqual(index.conversationCount(for: .month("2026-07")), 2)
    }

    /// 月份分桶与地图必须一致：同一份库，地图里 2026-07 的计数就是切面页能列出的条数。
    func testMonthFacetAgreesWithMapOverview() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        try seed(index, id: "b", source: .codex, cwd: "/p", year: 2026, month: 7, text: "beta")
        try seed(index, id: "c", source: .codex, cwd: "/p", year: 2026, month: 8, text: "gamma")

        for bucket in index.mapOverview().byMonth {
            XCTAssertEqual(index.conversationCount(for: .month(bucket.key)), bucket.count,
                           "地图与切面页对 \(bucket.key) 的计数不一致")
        }
    }

    /// 跨月会话按**开始**月分桶。
    ///
    /// 这条测试的存在理由：把 `monthBucketSQL` 从 `start_at` 改成 `end_at`（或反过来）
    /// 曾经能让全仓测试一条不红地通过——因为所有种子数据的 startAt 都等于 endAt，
    /// 没有一条测试区分得开这两者。跨月的会话正是唯一能区分的输入。
    func testCrossMonthConversationBucketsByStartMonth() throws {
        let index = try makeIndex()
        var start = DateComponents()
        start.year = 2026; start.month = 7; start.day = 31; start.hour = 22
        var end = DateComponents()
        end.year = 2026; end.month = 8; end.day = 1; end.hour = 2
        let lite = ConversationLite(
            id: "overnight", source: .codex,
            startAt: gregorian.date(from: start)!,
            endAt: gregorian.date(from: end)!,
            cwd: "/p", gitBranch: nil, preview: "p", messageCount: 2,
            fileURL: URL(fileURLWithPath: "/tmp/overnight.jsonl"))
        try index.upsert([(lite, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 1, text: "alpha")],
                           1, "alpha")])

        XCTAssertEqual(index.conversationIDs(for: .month("2026-07"), limit: 10), ["overnight"])
        XCTAssertEqual(index.conversationCount(for: .month("2026-08")), 0)
        XCTAssertEqual(index.mapOverview().byMonth.map(\.key), ["2026-07"],
                       "地图与切面页必须对同一场跨月会话给出同一个月份")
    }

    func testConversationIDsRespectsLimitAndRecencyOrder() throws {
        let index = try makeIndex()
        try seed(index, id: "old", source: .codex, cwd: "/p", year: 2026, month: 5, text: "alpha")
        try seed(index, id: "new", source: .codex, cwd: "/p", year: 2026, month: 8, text: "beta")
        XCTAssertEqual(index.conversationIDs(for: .source(.codex), limit: 1), ["new"],
                       "切面页第一条必须是最近的")
    }

    /// MCP 层表达"不限条数"最自然的写法是 `limit: Int.max`（本仓库 `JSONLReader`
    /// 就是 `?? Int.max` 这个模式）。SQL 绑定那一步若用裸 `Int32(limit)` 转换，
    /// 遇到 `Int.max` 会因为超出 Int32 范围而运行时陷阱、整个进程 abort——
    /// 这条测试锁住"不崩溃且返回全部"，而不只是"不崩溃"。
    func testConversationIDsWithIntMaxLimitDoesNotCrashAndReturnsAll() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        try seed(index, id: "b", source: .codex, cwd: "/p", year: 2026, month: 8, text: "beta")
        XCTAssertEqual(Set(index.conversationIDs(for: .source(.codex), limit: Int.max)), ["a", "b"])
    }

    /// `.entity` 必须在 `clause(for:)` 之前被分流——`clause(for:)` 对 `.entity` 分支
    /// 是 `preconditionFailure`（entity 切面要 JOIN 实体表，写不出一条简单 WHERE
    /// 子句）。`conversationCount(for:)` 根本没有 limit 参数，"unlimited count"这个
    /// 旧名字名不符实；这条测试真正锁住的是分流本身——走错分支是直接 precondition
    /// 崩溃，不是返回一个错误的数字，所以哪怕只调用一次也足以暴露分流缺失。
    func testEntityFacetIsRoutedBeforeClauseBuilder() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7,
                 text: "见 src/index.ts 第 3 行")
        try seed(index, id: "b", source: .codex, cwd: "/p", year: 2026, month: 7,
                 text: "改了 src/index.ts")
        XCTAssertEqual(index.conversationCount(for: .entity("src/index.ts")), 2)
        XCTAssertEqual(Set(index.conversationIDs(for: .entity("src/index.ts"), limit: 10)), ["a", "b"])
    }

    func testMetadataForIDsPreservesRequestedOrderAndSkipsUnknown() throws {
        let index = try makeIndex()
        try seed(index, id: "a", source: .codex, cwd: "/p", year: 2026, month: 7, text: "alpha")
        try seed(index, id: "b", source: .codex, cwd: "/p", year: 2026, month: 8, text: "beta")

        XCTAssertEqual(index.metadata(forIDs: ["b", "nope", "a"]).map(\.id), ["b", "a"],
                       "必须保持传入顺序——那是相关度顺序，重排等于把排序结果扔掉")
        // 反向断言：只测 ["b","nope","a"]→["b","a"] 是半区分的——"b" 的 end_at 更晚，
        // 所以哪怕实现偷懒写成「IN (...) ORDER BY end_at DESC」也会凑巧给出同样的结果。
        // 反过来请求 ["a","nope","b"]：若真按 end_at DESC 排，会给出 ["b","a"]，
        // 与期望的 ["a","b"]（保持请求顺序）不同——这才挡得住那种错误实现。
        XCTAssertEqual(index.metadata(forIDs: ["a", "nope", "b"]).map(\.id), ["a", "b"],
                       "顺序必须跟随请求本身，不能是 end_at 排序的副产品")
        XCTAssertNil(index.metadata(forID: "nope"))
        XCTAssertEqual(index.metadata(forID: "a")?.cwd, "/p")
    }
}
