import XCTest
@testable import MindBusCore

final class ConversationLiteTests: XCTestCase {

    private func makeFullConv() -> Conversation {
        let now = Date()
        let msg1 = Message(
            id: "m1", role: .user, timestamp: now,
            blocks: [
                .text("hello world"),
                .image(mediaType: "image/png", source: .base64("BIGBASE64STRING")),
            ]
        )
        let msg2 = Message(
            id: "m2", role: .assistant, timestamp: now.addingTimeInterval(60),
            blocks: [
                .text("answer"),
                .code(language: "swift", text: "let x = 1"),
                .thinking("inner thoughts"),
            ]
        )
        return Conversation(
            id: "conv-1",
            source: .claudeCode,
            startAt: now,
            endAt: now.addingTimeInterval(60),
            cwd: "/Users/me/proj",
            gitBranch: "main",
            messages: [msg1, msg2]
        )
    }

    func testFromExtractsBasicFields() {
        let conv = makeFullConv()
        let url = URL(fileURLWithPath: "/tmp/conv-1.jsonl")
        let lite = ConversationLite.from(conv, fileURL: url)

        XCTAssertEqual(lite.id, "conv-1")
        XCTAssertEqual(lite.source, .claudeCode)
        XCTAssertEqual(lite.cwd, "/Users/me/proj")
        XCTAssertEqual(lite.gitBranch, "main")
        XCTAssertEqual(lite.messageCount, 2)
        XCTAssertEqual(lite.preview, "answer")   // 最近一条消息（assistant 的 text）
        XCTAssertEqual(lite.fileURL, url)
    }

    func testSearchableTextIncludesProseAndCodeAndThinking() {
        let conv = makeFullConv()   // searchableText 现为 Conversation 的 computed
        XCTAssertTrue(conv.searchableText.contains("hello world"))
        XCTAssertTrue(conv.searchableText.contains("answer"))
        XCTAssertTrue(conv.searchableText.contains("let x = 1"))
        XCTAssertTrue(conv.searchableText.contains("inner thoughts"))
    }

    func testSearchableTextExcludesImageBase64AndPlaceholder() {
        let conv = makeFullConv()
        XCTAssertFalse(conv.searchableText.contains("BIGBASE64STRING"))
        XCTAssertFalse(conv.searchableText.contains("[image:"))
    }

    func testPreviewTruncatesAt60Chars() {
        let now = Date()
        let longText = String(repeating: "a", count: 100)
        let msg = Message(id: "m", role: .user, timestamp: now, blocks: [.text(longText)])
        let conv = Conversation(
            id: "c", source: .claudeCode,
            startAt: now, endAt: now,
            cwd: "", gitBranch: nil,
            messages: [msg]
        )
        let lite = ConversationLite.from(conv, fileURL: URL(fileURLWithPath: "/x"))
        XCTAssertTrue(lite.preview.hasSuffix("…"))
        XCTAssertEqual(lite.preview.count, 61)  // 60 + ellipsis
    }

    func testPreviewTakesLastMessage() {
        let now = Date()
        let conv = Conversation(
            id: "c", source: .claudeCode, startAt: now, endAt: now,
            cwd: "", gitBranch: nil,
            messages: [
                Message(id: "1", role: .user, timestamp: now, blocks: [.text("最早的问题")]),
                Message(id: "2", role: .assistant, timestamp: now, blocks: [.text("最近的回复")]),
            ]
        )
        let lite = ConversationLite.from(conv, fileURL: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(lite.preview, "最近的回复")   // 取最近一条，非首条
    }
}
