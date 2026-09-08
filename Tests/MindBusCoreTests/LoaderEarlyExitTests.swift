import XCTest
@testable import MindBusCore

/// 早退判定:非会话文件(观察者/队列日志)与 sidechain 不必读完全文件。
/// 真机背景:claude-mem observer 轨迹 6768 个 26GB,删库首建全量白读,峰值 1.8GB。
final class LoaderEarlyExitTests: XCTestCase {
    private func tempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("early-exit-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testObserverQueueFileEarlyExitsToNil() throws {
        // 128 行全是 queue-operation:64 行判定线内无消息无标题 → nil(barren)
        let lines = (0..<128).map {
            "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"seq\":\($0)}"
        }
        let url = try tempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: url))
    }

    func testSidechainMarkerStopsReadImmediately() throws {
        var lines = ["{\"isSidechain\":true,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"x\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}"]
        lines += (0..<50).map { _ in "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"noise\"},\"timestamp\":\"2026-01-01T00:00:01Z\"}" }
        let url = try tempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: url))
    }

    func testRealConversationWithLateFirstMessageSurvives() throws {
        // 63 行元数据/未知行 + 第 64 行起真消息:64 行判定线恰好被消息打断,不误杀
        var lines = (0..<63).map { "{\"type\":\"file-history-snapshot\",\"seq\":\($0)}" }
        lines.append("{\"type\":\"user\",\"uuid\":\"u1\",\"cwd\":\"/p/x\",\"sessionId\":\"s1\",\"message\":{\"role\":\"user\",\"content\":\"你好\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}")
        lines.append("{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"回复\"}]},\"timestamp\":\"2026-01-01T00:00:05Z\"}")
        let url = try tempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let conv = try ClaudeCodeLoader.loadConversation(fileURL: url)
        XCTAssertEqual(conv?.messages.count, 2, "64 行线上出现首条消息的真会话不该被早退误杀")
    }

    // MARK: - 索引路径减重

    func testCappedForIndexingTruncatesAndStripsImages() {
        let big = String(repeating: "长", count: 600 * 1024)
        let msg = Message(id: "m", role: .assistant, timestamp: Date(), blocks: [
            .text(big), .image(mediaType: "image/png", source: .base64(big)),
        ])
        let capped = msg.cappedForIndexing(blockCap: 512 * 1024, textStripped: false)
        if case .text(let t) = capped.blocks[0] {
            XCTAssertEqual(t.count, 512 * 1024, "单 block 截到上限")
        } else { XCTFail() }
        if case .image(_, let src) = capped.blocks[1] {
            XCTAssertEqual(src, .url(""), "图片 payload 置空——索引口径不消费图片内容")
        } else { XCTFail() }
    }

    func testCappedForIndexingStrippedKeepsStructure() {
        let msg = Message(id: "m", role: .user, timestamp: Date(),
                          blocks: [.text("预算耗尽后的消息")])
        let stripped = msg.cappedForIndexing(blockCap: 512 * 1024, textStripped: true)
        XCTAssertEqual(stripped.blocks.count, 1, "结构保留(撑计数与段切分)")
        XCTAssertEqual(stripped.indexingTextCount, 0, "文本清空")
        XCTAssertEqual(stripped.role, .user)
    }

    func testIndexingBudgetStripsTailMessages() throws {
        // forIndexing 下,累积超预算的尾部消息文本清空;详情路径(默认)全量
        let big = String(repeating: "x", count: 700)
        var lines: [String] = []
        for i in 0..<3 {
            lines.append("{\"type\":\"user\",\"uuid\":\"u\(i)\",\"cwd\":\"/p\",\"sessionId\":\"s\",\"message\":{\"role\":\"user\",\"content\":\"\(big)\"},\"timestamp\":\"2026-01-01T00:0\(i):00Z\"}")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let full = try ClaudeCodeLoader.loadConversation(fileURL: url)
        XCTAssertEqual(full?.messages.filter { !$0.blocks.isEmpty }.count, 3, "详情路径全量")
        XCTAssertTrue(full!.messages.allSatisfy { $0.indexingTextCount == 700 })
    }
}
