import XCTest
import SQLite3
@testable import MindBusCore

/// user_corpus（v14）：会话级用户语料的写入 / 守恒 / 删除。
/// 「你的高频词」必须从你说的话里数（Minds 概念地图口径）；
/// 行数守恒 = user_corpus 行数恒等于 conversations 行数，空串也占行。
final class UserCorpusTests: XCTestCase {
    private var path: String!
    private var index: ConversationIndex!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "ucorp-\(UUID().uuidString).sqlite"
        index = try ConversationIndex(path: path)
    }
    override func tearDown() {
        index = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func lite(_ id: String, path p: String) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date().addingTimeInterval(-60),
                         endAt: Date(), cwd: "/tmp", gitBranch: nil, title: nil, preview: "p-\(id)",
                         messageCount: 1, fileURL: URL(fileURLWithPath: p))
    }

    private func segs(_ text: String) -> [Segmenter.Segment] {
        [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)]
    }

    /// 直查 user_corpus 行数——守恒断言不能靠 `userCorpusTexts()`（它过滤空串）。
    private func rowCount() throws -> Int {
        let db = try SQLiteDB(path: path)
        var n = 0
        try db.query("SELECT COUNT(*) FROM user_corpus;", bind: { _ in },
                     row: { n = Int(sqlite3_column_int64($0, 0)) })
        return n
    }

    func testFiveElementUpsertStoresUserText() throws {
        try index.upsert([(lite: lite("a", path: "/f/a"), segments: segs("全文含 AI 输出"),
                           mtime: 100, entityText: "", userText: "我说的第一性原理", lastRole: "user")])
        XCTAssertEqual(index.userCorpusTexts(), ["我说的第一性原理"])
    }

    func testFourElementOverloadKeepsRowConservation() throws {
        // 4 元重载（全部既有测试的调用口径）写空串行：texts 里不出现，但行数守恒。
        try index.upsert([(lite: lite("a", path: "/f/a"), segments: segs("t"),
                           mtime: 100, entityText: "")])
        XCTAssertEqual(index.userCorpusTexts(), [])
        XCTAssertEqual(try rowCount(), 1)
    }

    func testReupsertSameFilePathIsIdempotent() throws {
        try index.upsert([(lite: lite("a", path: "/f/a"), segments: segs("v1"),
                           mtime: 100, entityText: "", userText: "旧话", lastRole: "user")])
        try index.upsert([(lite: lite("a", path: "/f/a"), segments: segs("v2"),
                           mtime: 200, entityText: "", userText: "新话", lastRole: "user")])
        XCTAssertEqual(index.userCorpusTexts(), ["新话"])
        XCTAssertEqual(try rowCount(), 1)
    }

    func testPruneRemovesUserCorpusRow() throws {
        try index.upsert([(lite: lite("a", path: "/f/a"), segments: segs("t"),
                           mtime: 100, entityText: "", userText: "会被删的话", lastRole: "user")])
        index.prune(missingPaths: ["/f/a"])
        XCTAssertEqual(index.userCorpusTexts(), [])
        XCTAssertEqual(try rowCount(), 0)
    }

    func testSegmenterUserTextOnlyTakesUserRole() {
        let msgs = [
            Message(id: "m1", role: .user, timestamp: Date(), blocks: [.text("问一个第一性原理的问题")]),
            Message(id: "m2", role: .assistant, timestamp: Date(), blocks: [.text("这是 AI 的长篇回答")]),
            Message(id: "m3", role: .user, timestamp: Date(), blocks: [.text("继续追问")]),
        ]
        let t = Segmenter.userText(of: msgs)
        XCTAssertTrue(t.contains("第一性原理"))
        XCTAssertTrue(t.contains("继续追问"))
        XCTAssertFalse(t.contains("AI 的长篇回答"))
    }
}
