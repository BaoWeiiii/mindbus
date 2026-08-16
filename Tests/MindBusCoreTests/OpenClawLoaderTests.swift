import XCTest
@testable import MindBusCore

final class OpenClawLoaderTests: XCTestCase {

    func testParseSessionLineReturnsNil() {
        let line = #"{"type":"session","id":"s1","timestamp":"2026-03-17T06:41:39.133Z","cwd":"/p"}"#
        XCTAssertNil(OpenClawLoader.parseLine(line))
    }

    func testParseModelChangeReturnsNil() {
        let line = #"{"type":"model_change","id":"m1","timestamp":"2026-03-17T06:41:39.134Z"}"#
        XCTAssertNil(OpenClawLoader.parseLine(line))
    }

    func testParseUserMessage() {
        let line = #"{"type":"message","id":"u1","timestamp":"2026-03-17T06:42:00.000Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#
        let msg = OpenClawLoader.parseLine(line)
        XCTAssertEqual(msg?.id, "u1")
        XCTAssertEqual(msg?.role, .user)
        XCTAssertEqual(msg?.blocks.count, 1)
        if case .text(let t) = msg?.blocks.first {
            XCTAssertEqual(t, "hi")
        } else {
            XCTFail("expected text")
        }
    }

    func testParseAssistantMessageWithText() {
        let line = #"{"type":"message","id":"a1","timestamp":"2026-03-17T06:42:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#
        let msg = OpenClawLoader.parseLine(line)
        XCTAssertEqual(msg?.role, .assistant)
        if case .text(let t) = msg?.blocks.first {
            XCTAssertEqual(t, "ok")
        } else {
            XCTFail("expected text block")
        }
    }

    func testLoadConversationFromTempFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("openclaw-test-\(UUID().uuidString).jsonl")
        let content = """
        {"type":"session","id":"sess-1","timestamp":"2026-03-17T06:41:39.133Z","cwd":"/Users/alice/proj"}
        {"type":"model_change","id":"mc-1","timestamp":"2026-03-17T06:41:39.134Z"}
        {"type":"message","id":"u1","timestamp":"2026-03-17T06:41:40.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
        {"type":"message","id":"a1","timestamp":"2026-03-17T06:41:42.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi back"}]}}
        """
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let conv = try OpenClawLoader.loadConversation(fileURL: tmp)
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.id, "sess-1")
        XCTAssertEqual(conv?.source, .openclaw)
        XCTAssertEqual(conv?.cwd, "/Users/alice/proj")
        XCTAssertEqual(conv?.messages.count, 2)
    }
}
