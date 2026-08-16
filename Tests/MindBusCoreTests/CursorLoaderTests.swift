import XCTest
@testable import MindBusCore

final class CursorLoaderTests: XCTestCase {

    func testParseUserLine() {
        let line = #"{"role":"user","message":{"content":[{"type":"text","text":"hi"}]}}"#
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = CursorLoader.parseLine(line, fileTimestamp: baseDate, lineIndex: 0)
        XCTAssertEqual(msg?.role, .user)
        if case .text(let t) = msg?.blocks.first {
            XCTAssertEqual(t, "hi")
        } else {
            XCTFail("expected text")
        }
    }

    func testParseAssistantLine() {
        let line = #"{"role":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = CursorLoader.parseLine(line, fileTimestamp: baseDate, lineIndex: 5)
        XCTAssertEqual(msg?.role, .assistant)
        XCTAssertEqual(msg?.timestamp, baseDate.addingTimeInterval(0.005))
    }

    func testParseInvalidRoleReturnsNil() {
        let line = #"{"role":"system","message":{"content":[{"type":"text","text":"x"}]}}"#
        XCTAssertNil(CursorLoader.parseLine(line, fileTimestamp: Date(), lineIndex: 0))
    }

    func testParseEmptyContentReturnsNil() {
        let line = #"{"role":"user","message":{"content":[]}}"#
        XCTAssertNil(CursorLoader.parseLine(line, fileTimestamp: Date(), lineIndex: 0))
    }

    func testLoadConversationFromTempFile() throws {
        let workspaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-test-\(UUID().uuidString)")
            .appendingPathComponent("agent-transcripts")
            .appendingPathComponent("chat-id")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let tmp = workspaceDir.appendingPathComponent("chat-id.jsonl")
        let content = """
        {"role":"user","message":{"content":[{"type":"text","text":"q1"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"a1"}]}}
        """
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspaceDir.deletingLastPathComponent().deletingLastPathComponent()) }

        let conv = try CursorLoader.loadConversation(fileURL: tmp)
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.source, .cursor)
        XCTAssertEqual(conv?.id, "chat-id")
        XCTAssertEqual(conv?.messages.count, 2)
    }
}
