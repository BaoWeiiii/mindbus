import XCTest
@testable import MindBusCore

final class ClaudeCodeLoaderLoadConversationTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mb-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeJSONL(_ lines: [String], name: String = "test.jsonl") -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadConversationExtractsMessagesAndMetadata() throws {
        let url = writeJSONL([
            #"{"type":"user","message":{"role":"user","content":"q1"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","cwd":"/tmp","sessionId":"s-A","gitBranch":"main"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a1"}]},"uuid":"a1","timestamp":"2026-04-07T11:00:05.000Z","sessionId":"s-A"}"#,
        ])
        let conv = try ClaudeCodeLoader.loadConversation(fileURL: url)
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.id, "s-A")
        XCTAssertEqual(conv?.source, .claudeCode)
        XCTAssertEqual(conv?.cwd, "/tmp")
        XCTAssertEqual(conv?.gitBranch, "main")
        XCTAssertEqual(conv?.messages.count, 2)
        XCTAssertEqual(conv?.messages.first?.role, .user)
    }

    func testLoadConversationSkipsUnparseableLinesButKeepsOthers() throws {
        let url = writeJSONL([
            "not a json line",
            "",
            #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"s-1"}"#,
        ])
        let conv = try ClaudeCodeLoader.loadConversation(fileURL: url)
        XCTAssertEqual(conv?.messages.count, 1)
    }

    func testLoadConversationReturnsNilWhenNoMessages() throws {
        let url = writeJSONL(["garbage", ""])
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: url))
    }

    func testLoadConversationFallsBackToFilenameWhenNoSessionId() throws {
        let url = writeJSONL([
            #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z"}"#,
        ], name: "abc-123.jsonl")
        let conv = try ClaudeCodeLoader.loadConversation(fileURL: url)
        XCTAssertEqual(conv?.id, "abc-123")
    }

    func testLoadConversationSortsMessagesByTimestamp() throws {
        let url = writeJSONL([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"second"}]},"uuid":"a1","timestamp":"2026-04-07T11:00:10.000Z","sessionId":"s"}"#,
            #"{"type":"user","message":{"role":"user","content":"first"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"s"}"#,
        ])
        let conv = try ClaudeCodeLoader.loadConversation(fileURL: url)
        XCTAssertEqual(conv?.messages.first?.role, .user)
        XCTAssertEqual(conv?.messages.last?.role, .assistant)
    }

    /// 同一时间戳的多条消息必须保持文件行序：sort 键 = (timestamp, 行序)。
    /// Swift sort 不稳定，纯 timestamp 键会随机互换同刻消息（工具同毫秒落多条很常见）。
    /// 首行放一条更晚的消息，逼排序真的发生位移，而不是全程原序白过。
    func testSameTimestampMessagesKeepFileOrder() throws {
        var lines = [
            #"{"type":"user","message":{"role":"user","content":"最晚"},"uuid":"z-last","timestamp":"2026-04-07T12:00:00.000Z","sessionId":"s"}"#,
        ]
        for i in 0..<24 {
            lines.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"m\(i)\"},\"uuid\":\"u\(i)\",\"timestamp\":\"2026-04-07T11:00:00.000Z\",\"sessionId\":\"s\"}")
        }
        let url = writeJSONL(lines)
        let conv = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: url))
        XCTAssertEqual(conv.messages.map(\.id), (0..<24).map { "u\($0)" } + ["z-last"])
    }

    // MARK: - 官方 ai-title

    /// {"type":"ai-title","aiTitle":"…"} 行提供官方标题；改标题会追加新行，取最后一条。
    func testAiTitleLastOneWins() throws {
        let url = writeJSONL([
            #"{"type":"user","message":{"role":"user","content":"q"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"s-T","cwd":"/tmp"}"#,
            #"{"type":"ai-title","aiTitle":"旧标题","sessionId":"s-T"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a"}]},"uuid":"a1","timestamp":"2026-04-07T11:00:05.000Z"}"#,
            #"{"type":"ai-title","aiTitle":"新标题","sessionId":"s-T"}"#,
        ])
        let conv = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: url))
        XCTAssertEqual(conv.title, "新标题")
    }

    func testNoAiTitleYieldsNilTitle() throws {
        let url = writeJSONL([
            #"{"type":"user","message":{"role":"user","content":"q"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"s-N"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a"}]},"uuid":"a1","timestamp":"2026-04-07T11:00:05.000Z"}"#,
        ])
        XCTAssertNil(try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: url)).title)
    }
}
