import XCTest
@testable import MindBusCore

final class ModelsTests: XCTestCase {
    func testConversationComputedDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600) // +1h
        let conv = Conversation(
            id: "s1",
            source: .claudeCode,
            startAt: start,
            endAt: end,
            cwd: "/tmp",
            gitBranch: nil,
            messages: []
        )
        XCTAssertEqual(conv.duration, 3600, accuracy: 0.01)
    }

    func testMessageFirstTextBlockReturnsFirstText() {
        let msg = Message(
            id: "m1",
            role: .user,
            timestamp: Date(),
            blocks: [
                .code(language: "swift", text: "print(1)"),
                .text("hello"),
                .text("world"),
            ]
        )
        XCTAssertEqual(msg.firstTextBlock, "hello")
    }

    func testMessageFirstTextBlockIsNilWhenNoText() {
        let msg = Message(
            id: "m1",
            role: .assistant,
            timestamp: Date(),
            blocks: [.code(language: "py", text: "x=1")]
        )
        XCTAssertNil(msg.firstTextBlock)
    }

    func testConversationPreviewTakesFirstUserTextUpTo40Chars() {
        let msg1 = Message(
            id: "m1", role: .user, timestamp: Date(),
            blocks: [.text("我想讨论一下 router.ts 的分发逻辑，特别是冷热路径切换的阈值")]
        )
        let conv = Conversation(
            id: "s1", source: .claudeCode,
            startAt: Date(), endAt: Date(),
            cwd: "/", gitBranch: nil,
            messages: [msg1]
        )
        XCTAssertEqual(conv.preview, "我想讨论一下 router.ts 的分发逻辑，特别是冷热路径切换的阈值")
    }
}
