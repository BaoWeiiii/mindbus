import XCTest
@testable import MindBusCore

/// 流式切段器的唯一正确性标准:与 `Segmenter.segments`(全量版)逐字节等价。
/// 段口径连着检索质量(R@1 评测锁定在段级),流式化不允许任何口径漂移。
final class StreamingSegmenterTests: XCTestCase {

    private func msg(_ role: MessageRole, _ text: String, at second: TimeInterval = 0) -> Message {
        Message(id: UUID().uuidString, role: role,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + second),
                blocks: text.isEmpty ? [] : [.text(text)])
    }

    private func assertEquivalent(_ messages: [Message], _ note: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let full = Segmenter.segments(of: messages)
        var streaming = StreamingSegmenter()
        for m in messages { streaming.consume(m) }
        let streamed = streaming.finish(messageCount: messages.count)
        XCTAssertEqual(streamed.count, full.count, "段数不等:\(note)", file: file, line: line)
        for (i, (s, f)) in zip(streamed, full).enumerated() {
            XCTAssertEqual(s.firstMessageIndex, f.firstMessageIndex, "段\(i) first:\(note)", file: file, line: line)
            XCTAssertEqual(s.lastMessageIndex, f.lastMessageIndex, "段\(i) last:\(note)", file: file, line: line)
            XCTAssertEqual(s.text, f.text, "段\(i) 文本:\(note)", file: file, line: line)
        }
    }

    func testEquivalenceOnStructuralEnd() {
        // 长回复(≥400)+短否定(≤60)构成结构切点,切点落在短否定之后
        let messages = [
            msg(.user, "帮我修这个 bug"),
            msg(.assistant, String(repeating: "长回复", count: 200)),
            msg(.user, "不对,重来"),
            msg(.user, "换个方案"),
            msg(.assistant, "好的"),
        ]
        assertEquivalent(messages, "结构切点")
    }

    func testEquivalenceOnTurnAndCharCaps() {
        // 轮数顶(8)与字数顶(4000)分别触发
        var byTurns: [Message] = []
        for i in 0..<20 { byTurns.append(msg(i % 2 == 0 ? .user : .assistant, "短消息\(i)")) }
        assertEquivalent(byTurns, "轮数顶")

        let byChars = [msg(.user, String(repeating: "字", count: 3000)),
                       msg(.assistant, String(repeating: "字", count: 3000)),
                       msg(.user, "尾巴")]
        assertEquivalent(byChars, "字数顶")
    }

    func testEquivalenceOnEmptySegmentFallback() {
        // 纯图片消息(无文字)不成段:下标必须并进上一段(跳转依赖)
        let messages = [
            msg(.user, String(repeating: "顶满字数", count: 1000)),   // 单条即触顶 flush
            Message(id: "img", role: .user, timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                    blocks: [.image(mediaType: "image/png", source: .url(""))]),
        ]
        assertEquivalent(messages, "空段兜底")
    }

    func testEquivalenceOnEmptyAndSingle() {
        assertEquivalent([], "空会话")
        assertEquivalent([msg(.user, "只有一条")], "单条")
        assertEquivalent([Message(id: "i", role: .user,
                                  timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                  blocks: [.image(mediaType: "image/png", source: .url(""))])],
                         "只有图片")
    }

    func testEquivalenceRandomized() {
        // 200 场随机会话:角色/长度/空文字/图片随机组合,任何口径漂移都会在这里现形
        var seed: UInt64 = 0x5EED
        func rand(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        for round in 0..<200 {
            var messages: [Message] = []
            for i in 0..<rand(40) {
                let role: MessageRole = rand(3) == 0 ? .assistant : .user
                switch rand(6) {
                case 0: messages.append(Message(id: "\(round)-\(i)", role: role,
                                                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                                                blocks: [.image(mediaType: "image/png", source: .url(""))]))
                case 1: messages.append(msg(role, "", at: Double(i)))
                case 2: messages.append(msg(role, String(repeating: "长", count: 400 + rand(3000)), at: Double(i)))
                default: messages.append(msg(role, "普通消息 \(round)-\(i) " + String(repeating: "x", count: rand(80)), at: Double(i)))
                }
            }
            assertEquivalent(messages, "随机第\(round)场")
        }
    }
}
