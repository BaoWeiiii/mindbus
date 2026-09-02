import XCTest
@testable import MindBusCore

/// 收藏存储 v2:记录化、软删撤销、v1 迁移、聚合口径。
@MainActor
final class StarredMessagesStoreTests: XCTestCase {

    private func makeStore() -> (StarredMessagesStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "star-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (StarredMessagesStore(fileURL: url), url)
    }

    func testStarUnstarRestoreRoundTrip() {
        let (store, _) = makeStore()
        store.star(conversationID: "c1", messageID: "m1", role: "assistant", snapshot: "重要结论")
        let key = StarredMessagesStore.key(conversationID: "c1", messageID: "m1")
        XCTAssertTrue(store.isStarred(key))
        XCTAssertEqual(store.record(for: key)?.contentSnapshot, "重要结论")

        store.unstar(key)
        XCTAssertFalse(store.isStarred(key), "软删后不算有效收藏")
        XCTAssertNotNil(store.record(for: key), "软删期记录仍在——撤销的本钱")

        store.restore(key)
        XCTAssertTrue(store.isStarred(key), "撤销后恢复")
    }

    /// 软删期内重新收藏同一条 = 恢复原记录(favoritedAt 不变,不算新收藏)。
    func testRestarDuringSoftDeleteRestoresOriginal() {
        let (store, _) = makeStore()
        store.star(conversationID: "c1", messageID: "m1", role: "user", snapshot: "s")
        let key = "c1#m1"
        let originalAt = store.record(for: key)!.favoritedAt
        store.unstar(key)
        store.star(conversationID: "c1", messageID: "m1", role: "user", snapshot: "changed")
        XCTAssertEqual(store.record(for: key)?.favoritedAt, originalAt)
        XCTAssertEqual(store.record(for: key)?.contentSnapshot, "s", "恢复不该覆盖原快照")
    }

    func testPersistsAcrossReload() {
        let (store, url) = makeStore()
        store.star(conversationID: "c1", messageID: "m1", role: "assistant", snapshot: "a")
        store.star(conversationID: "c1", messageID: "m2", role: "user", snapshot: "b")
        store.unstar("c1#m1")
        let reloaded = StarredMessagesStore(fileURL: url)
        XCTAssertFalse(reloaded.isStarred("c1#m1"))
        XCTAssertNotNil(reloaded.record(for: "c1#m1"), "软删记录跨启动仍在(撤销窗口宽限)")
        XCTAssertTrue(reloaded.isStarred("c1#m2"))
    }

    /// v1 裸键数组自动迁移。
    func testMigratesV1Format() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "star-v1-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try #"["c1#m1","c2#m9"]"#.write(to: url, atomically: true, encoding: .utf8)
        let store = StarredMessagesStore(fileURL: url)
        XCTAssertTrue(store.isStarred("c1#m1"))
        XCTAssertEqual(store.record(for: "c2#m9")?.conversationID, "c2")
        XCTAssertEqual(store.record(for: "c2#m9")?.messageID, "m9")
        // 迁移即升格:重读走 v2
        let reloaded = StarredMessagesStore(fileURL: url)
        XCTAssertTrue(reloaded.isStarred("c1#m1"))
    }

    /// 聚合口径:同会话多条收藏 → 一条 summary;count/lastAt/preview 正确。
    func testSummariesAggregateByConversation() {
        let (store, _) = makeStore()
        store.star(conversationID: "c1", messageID: "m1", role: "a", snapshot: "第一条")
        store.star(conversationID: "c1", messageID: "m2", role: "a", snapshot: "第二条")
        store.star(conversationID: "c2", messageID: "m1", role: "a", snapshot: "别家")
        store.unstar("c2#m1")   // 软删的不进聚合

        let sums = store.summaries()
        XCTAssertEqual(sums.count, 1, "软删会话不该出现")
        XCTAssertEqual(sums.first?.conversationID, "c1")
        XCTAssertEqual(sums.first?.favoriteCount, 2)
        XCTAssertEqual(sums.first?.latestPreview, "第二条", "摘要取最近收藏的快照")
    }

    func testRecentFavoritesOrderAndLimit() {
        let (store, _) = makeStore()
        for i in 0..<5 {
            store.star(conversationID: "c\(i)", messageID: "m", role: "a", snapshot: "s\(i)")
        }
        let recent = store.recentFavorites(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.first?.contentSnapshot, "s4", "favoritedAt 倒序")
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "star-bad-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF, 0x7B]).write(to: url)
        XCTAssertTrue(StarredMessagesStore(fileURL: url).records.isEmpty)
    }
}
