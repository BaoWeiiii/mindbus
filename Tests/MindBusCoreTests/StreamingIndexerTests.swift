import XCTest
@testable import MindBusCore

/// 流式管线产物必须与旧全量路径逐字段等价——lite 元信息/段/实体文本/用户语料/
/// 收尾角色,一个都不许漂。
final class StreamingIndexerTests: XCTestCase {

    private func msg(_ role: MessageRole, _ text: String, at second: TimeInterval) -> Message {
        Message(id: UUID().uuidString, role: role,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + second),
                blocks: text.isEmpty ? [] : [.text(text)])
    }

    private func assertEquivalent(_ messages: [Message], _ note: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var indexer = StreamingIndexer()
        for m in messages { indexer.consume(m) }
        let p = indexer.finish()

        let conv = Conversation(id: "c", source: .claudeCode,
                                startAt: messages.first?.timestamp ?? Date(),
                                endAt: messages.last?.timestamp ?? Date(),
                                cwd: "/p", gitBranch: nil, title: nil, messages: messages)
        XCTAssertEqual(p.segments, Segmenter.segments(of: messages), "段:\(note)", file: file, line: line)
        XCTAssertEqual(p.preview, conv.preview, "preview:\(note)", file: file, line: line)
        XCTAssertEqual(p.messageCount, messages.count, "count:\(note)", file: file, line: line)
        XCTAssertEqual(p.entityText, Segmenter.entityText(of: messages), "entity:\(note)", file: file, line: line)
        XCTAssertEqual(p.userText, Segmenter.userText(of: messages), "user:\(note)", file: file, line: line)
        XCTAssertEqual(p.lastMeaningfulRole, Segmenter.lastMeaningfulRole(of: messages), "lastRole:\(note)", file: file, line: line)
        if !messages.isEmpty {
            XCTAssertEqual(p.startAt, messages.map(\.timestamp).min(), "startAt:\(note)", file: file, line: line)
            XCTAssertEqual(p.endAt, messages.map(\.timestamp).max(), "endAt:\(note)", file: file, line: line)
        }
    }

    func testEquivalenceMixedConversation() {
        let messages: [Message] = [
            msg(.user, "帮我修这个:\nimport Foundation", at: 0),
            msg(.assistant, String(repeating: "长回复", count: 200), at: 1),
            msg(.user, "不对,重来", at: 2),
            Message(id: "inj", role: .user, timestamp: Date(timeIntervalSince1970: 1_700_000_003),
                    blocks: [.text("Stop hook feedback: blocked")]),
            Message(id: "img", role: .user, timestamp: Date(timeIntervalSince1970: 1_700_000_004),
                    blocks: [.image(mediaType: "image/png", source: .url(""))]),
            msg(.assistant, "好的,已修复", at: 5),
        ]
        assertEquivalent(messages, "混合会话")
    }

    func testEquivalenceEmptyAndInjectionOnly() {
        assertEquivalent([], "空会话")
        assertEquivalent([Message(id: "i1", role: .user,
                                  timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                  blocks: [.text("<system-reminder>注入")])], "纯注入")
    }

    func testRelicDetectionMaterial() {
        // ≤2 条且 assistant 全部 API Error 开头 = 残骸素材
        var indexer = StreamingIndexer()
        indexer.consume(msg(.user, "你好", at: 0))
        indexer.consume(msg(.assistant, "API Error: connection failed", at: 1))
        let p = indexer.finish()
        XCTAssertEqual(p.assistantCount, 1)
        XCTAssertTrue(p.allAssistantsAPIError)

        var healthy = StreamingIndexer()
        healthy.consume(msg(.user, "你好", at: 0))
        healthy.consume(msg(.assistant, "正常回复", at: 1))
        XCTAssertFalse(healthy.finish().allAssistantsAPIError)
    }

    func testEquivalenceRandomized() {
        var seed: UInt64 = 0xABCD
        func rand(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        for round in 0..<100 {
            var messages: [Message] = []
            for i in 0..<rand(30) {
                let role: MessageRole = rand(3) == 0 ? .assistant : .user
                switch rand(5) {
                case 0: messages.append(Message(id: "\(round)-\(i)", role: role,
                                                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                                                blocks: [.image(mediaType: "image/png", source: .url(""))]))
                case 1: messages.append(msg(.user, "This session is being continued from x", at: Double(i)))
                case 2: messages.append(msg(role, String(repeating: "长", count: 300 + rand(2000)), at: Double(i)))
                default: messages.append(msg(role, "消息 \(round)-\(i)\n第二行", at: Double(i)))
                }
            }
            assertEquivalent(messages, "随机第\(round)场")
        }
    }
}
