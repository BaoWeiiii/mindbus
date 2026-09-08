import XCTest
@testable import MindBusCore

@MainActor
final class ConversationStoreTests: XCTestCase {
    /// 生产库隔离必须成立 —— 这条断言防的是一次真实事故：
    /// 隔离原本只查 `XCTestConfigurationFilePath`（Xcode 测试运行器专有），
    /// 命令行 `swift test` 不设该变量，于是测试直接在用户的
    /// `~/Library/Application Support/MindBus/index.sqlite` 上跑了数据政策迁移，
    /// 把整个索引清空重建。这条测试在 Xcode 与 SwiftPM 两条链路下都必须通过。
    func testDefaultIndexPathIsIsolatedUnderTests() {
        XCTAssertTrue(ConversationStore.isRunningTests(),
                      "测试进程未被识别 —— 生产库隔离已失效")
        let path = ConversationStore.defaultIndexPath()
        XCTAssertFalse(path.contains("Application Support/MindBus"),
                       "测试绝不能碰生产索引，实际路径: \(path)")
        XCTAssertTrue(path.hasPrefix(NSTemporaryDirectory()),
                      "测试索引应落在临时目录，实际路径: \(path)")
    }

    /// `creatingDirectory: false`（MCP 只读进程用）不该改变测试隔离下的路径解析——两种
    /// 调用方式必须落在同一个临时路径上。"不建 Application Support 目录"这半句由
    /// `if creatingDirectory { ... }` 这行守卫在代码结构上保证：测试进程里
    /// `isRunningTests()` 提前返回，函数根本走不到那一行；要动态验证就得读写真实的
    /// `~/Library/Application Support/MindBus/`，而这正是上一条测试要防的事故本身
    /// （见 `isRunningTests()` 文档注释里记录的两次生产库事故），所以这里只锁住
    /// "传 false 不会意外换了一条路径"这个能安全验证的部分。
    func testDefaultIndexPathCreatingDirectoryFalseStaysIsolatedUnderTests() {
        XCTAssertEqual(ConversationStore.defaultIndexPath(creatingDirectory: false),
                       ConversationStore.defaultIndexPath(),
                       "creatingDirectory 参数不该影响测试隔离下的路径解析")
    }

    private func makeConversation(
        id: String,
        startAt: Date,
        userText: String,
        source: ConversationSource = .claudeCode
    ) -> ConversationLite {
        ConversationLite(
            id: id,
            source: source,
            startAt: startAt,
            endAt: startAt.addingTimeInterval(60),
            cwd: "/tmp",
            gitBranch: nil,
            preview: userText,
            messageCount: 1,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl")
        )
    }

    func testSetAllPopulatesFiltered() {
        let store = ConversationStore()
        let a = makeConversation(id: "a", startAt: Date(), userText: "hello")
        store.setAll([a])
        XCTAssertEqual(store.filteredConversations.count, 1)
    }

    func testTimeFilterTodayExcludesOldConversations() {
        let store = ConversationStore()
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86400)
        store.setAll([
            makeConversation(id: "recent", startAt: now, userText: "x"),
            makeConversation(id: "old", startAt: tenDaysAgo, userText: "y"),
        ])
        store.timeFilter = .today
        XCTAssertEqual(store.filteredConversations.map(\.id), ["recent"])
    }

    /// 搜索现走 SQLite FTS 索引：填充 index → 指向 store → await runSearch 确定性断言。
    /// （trigram/LIKE 匹配语义本身在 ConversationIndexTests 覆盖，这里测 store 的过滤接线。）
    private func tempIndexPath() -> String {
        NSTemporaryDirectory() + "store-\(UUID().uuidString).sqlite"
    }
    private func cleanup(_ path: String) {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    func testSearchMatchesUserText() async throws {
        let path = tempIndexPath(); defer { cleanup(path) }
        let idx = try ConversationIndex(path: path)
        let a = makeConversation(id: "a", startAt: Date(), userText: "讨论 Redis 迁移方案")
        let b = makeConversation(id: "b", startAt: Date(), userText: "讨论 pgvector 索引")
        try idx.upsert([
            (a, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "讨论 Redis 迁移方案")], 1, "讨论 Redis 迁移方案"),
            (b, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "讨论 pgvector 索引")], 2, "讨论 pgvector 索引"),
        ])
        let store = ConversationStore(indexPath: path)
        store.setAll([a, b])
        store.searchQuery = "Redis"
        await store.runSearch()
        XCTAssertEqual(store.filteredConversations.map(\.id), ["a"])
    }

    func testSearchCaseInsensitive() async throws {
        let path = tempIndexPath(); defer { cleanup(path) }
        let idx = try ConversationIndex(path: path)
        let a = makeConversation(id: "a", startAt: Date(), userText: "Redis cluster")
        try idx.upsert([(a, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "Redis cluster")], 1, "Redis cluster")])
        let store = ConversationStore(indexPath: path)
        store.setAll([a])
        store.searchQuery = "redis"
        await store.runSearch()
        XCTAssertEqual(store.filteredConversations.count, 1)
    }

    func testEmptyQueryClearsSearchFilter() async throws {
        let path = tempIndexPath(); defer { cleanup(path) }
        let idx = try ConversationIndex(path: path)
        let a = makeConversation(id: "a", startAt: Date(), userText: "Redis cluster")
        try idx.upsert([(a, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "Redis cluster")], 1, "Redis cluster")])
        let store = ConversationStore(indexPath: path)
        store.setAll([a])
        store.searchQuery = "zzz不存在"
        await store.runSearch()
        XCTAssertEqual(store.filteredConversations.count, 0)
        store.searchQuery = ""
        await store.runSearch()
        XCTAssertEqual(store.filteredConversations.count, 1)   // 清空查询恢复全列表
    }

    func testFocusedSourceShowsOnlyThatTool() {
        let store = ConversationStore()
        store.setAll([
            makeConversation(id: "cc", startAt: Date(), userText: "x", source: .claudeCode),
            makeConversation(id: "cx", startAt: Date(), userText: "y", source: .codex),
        ])
        store.focusedSource = .codex
        XCTAssertEqual(store.filteredConversations.map(\.id), ["cx"])
    }

    func testFocusedNilShowsOnlyBrowsableSources() {
        let store = ConversationStore()
        store.setAll([
            makeConversation(id: "cc", startAt: Date(), userText: "x", source: .claudeCode),  // 可浏览
            makeConversation(id: "cu", startAt: Date(), userText: "y", source: .cursor),       // 不在 3 源内
        ])
        store.focusedSource = nil   // 全部
        XCTAssertEqual(store.filteredConversations.map(\.id), ["cc"])   // cursor 被排除
    }

    func testSortedByUpdatedTimeDescending() {
        let store = ConversationStore()
        let now = Date()
        store.setAll([
            makeConversation(id: "older", startAt: now.addingTimeInterval(-3600), userText: "x"),
            makeConversation(id: "newer", startAt: now, userText: "y"),
        ])
        XCTAssertEqual(store.filteredConversations.map(\.id), ["newer", "older"])   // 更新时间倒序
    }
}
