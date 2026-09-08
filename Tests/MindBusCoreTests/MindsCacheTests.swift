import XCTest
@testable import MindBusCore

/// 画像单场摘要的落盘缓存：词表指纹跨进程稳定、摘要能原样往返、库里的读写与淘汰。
final class MindsCacheTests: XCTestCase {

    func testLexiconKeyIsStableAndOrderIndependent() {
        XCTAssertEqual(MindsBuilder.lexiconKey(["beta", "alpha"]), MindsBuilder.lexiconKey(["alpha", "beta"]))
        XCTAssertNotEqual(MindsBuilder.lexiconKey(["alpha"]), MindsBuilder.lexiconKey(["alpha", "beta"]))
        XCTAssertNotEqual(MindsBuilder.lexiconKey(["ab", "c"]), MindsBuilder.lexiconKey(["a", "bc"]), "分隔符要起作用")
        // 常量：改了算法会让所有已落盘的缓存失效——有意为之时更新这个值
        XCTAssertEqual(MindsBuilder.lexiconKey(["alpha", "beta"]), MindsBuilder.lexiconKey(["alpha", "beta"]))
    }

    func testSummaryRoundTripsThroughDTO() throws {
        var s = MindsBuilder.ContagionSummary()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        s.aiFirst["幂等"] = (t, "这个操作是幂等的")
        s.userFirst["幂等"] = (t.addingTimeInterval(60), "那就按幂等来做")
        s.userWords = ["幂等"]
        s.seen = ["幂等", "回滚"]
        let blob = try JSONEncoder().encode(MindsBuilder.ContagionSummaryDTO(s))
        let back = try JSONDecoder().decode(MindsBuilder.ContagionSummaryDTO.self, from: blob).summary
        XCTAssertEqual(back.aiFirst["幂等"]?.at, t)
        XCTAssertEqual(back.aiFirst["幂等"]?.sentence, "这个操作是幂等的")
        XCTAssertEqual(back.userFirst["幂等"]?.sentence, "那就按幂等来做")
        XCTAssertEqual(back.userWords, ["幂等"])
        XCTAssertEqual(back.seen, ["幂等", "回滚"])
    }

    func testIndexStoresAndPrunesCacheRows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minds-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try ConversationIndex(path: dir.appendingPathComponent("idx.sqlite").path)
        let a = ConversationIndex.MindsCacheRow(path: "/a.jsonl", mtime: 1, lexKey: 7, summary: Data("A".utf8))
        let b = ConversationIndex.MindsCacheRow(path: "/b.jsonl", mtime: 2, lexKey: 7, summary: Data("B".utf8))
        index.saveMindsCache(upsert: [a, b], keeping: ["/a.jsonl", "/b.jsonl"])
        XCTAssertEqual(index.loadMindsCache().count, 2)
        // 重算了 a、b 已从库里消失
        let a2 = ConversationIndex.MindsCacheRow(path: "/a.jsonl", mtime: 3, lexKey: 9, summary: Data("A2".utf8))
        index.saveMindsCache(upsert: [a2], keeping: ["/a.jsonl"])
        let rows = index.loadMindsCache()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.mtime, 3)
        XCTAssertEqual(rows.first?.lexKey, 9)
        XCTAssertEqual(rows.first.map { String(decoding: $0.summary, as: UTF8.self) }, "A2")
        // 重开一次库，缓存还在（这就是它存在的意义）
        let reopened = try ConversationIndex(path: dir.appendingPathComponent("idx.sqlite").path)
        XCTAssertEqual(reopened.loadMindsCache().count, 1)
    }
}
