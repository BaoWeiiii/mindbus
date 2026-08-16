import XCTest
@testable import MindBusCore

/// loader 级流式/全量对照:同一 jsonl 文件,`streamIndexRow` 与
/// 「`loadConversation(forIndexing:true)` + `IndexRow.from`」产物逐字段相等。
/// 这是大文件分流(≥8MB 走流式)的等价性保证——阈值只决定走哪条路,
/// 两条路的产物必须无差别(有序输入下)。
final class LoaderStreamParityTests: XCTestCase {

    private func writeTemp(_ lines: [String], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(name)-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func claudeUser(_ i: Int, _ text: String) -> String {
        "{\"type\":\"user\",\"uuid\":\"u\(i)\",\"cwd\":\"/p/x\",\"sessionId\":\"sess-1\",\"gitBranch\":\"main\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"},\"timestamp\":\"2026-01-01T00:\(String(format: "%02d", i % 60)):00Z\"}"
    }
    private func claudeAssistant(_ i: Int, _ text: String) -> String {
        "{\"type\":\"assistant\",\"uuid\":\"a\(i)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]},\"timestamp\":\"2026-01-01T00:\(String(format: "%02d", i % 60)):30Z\"}"
    }

    private func assertRowsEqual(_ a: IndexRow, _ b: IndexRow, _ note: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.lite.id, b.lite.id, "id:\(note)", file: file, line: line)
        XCTAssertEqual(a.lite.startAt, b.lite.startAt, "startAt:\(note)", file: file, line: line)
        XCTAssertEqual(a.lite.endAt, b.lite.endAt, "endAt:\(note)", file: file, line: line)
        XCTAssertEqual(a.lite.cwd, b.lite.cwd, "cwd:\(note)", file: file, line: line)
        XCTAssertEqual(a.lite.title, b.lite.title, "title:\(note)", file: file, line: line)
        XCTAssertEqual(a.lite.preview, b.lite.preview, "preview:\(note)", file: file, line: line)
        XCTAssertEqual(a.lite.messageCount, b.lite.messageCount, "count:\(note)", file: file, line: line)
        XCTAssertEqual(a.segments, b.segments, "segments:\(note)", file: file, line: line)
        XCTAssertEqual(a.entityText, b.entityText, "entity:\(note)", file: file, line: line)
        XCTAssertEqual(a.userText, b.userText, "user:\(note)", file: file, line: line)
        XCTAssertEqual(a.lastRole, b.lastRole, "lastRole:\(note)", file: file, line: line)
    }

    func testClaudeCodeStreamMatchesFullParse() throws {
        var lines: [String] = []
        lines.append("{\"type\":\"ai-title\",\"aiTitle\":\"对照测试会话\"}")
        for i in 0..<30 {
            lines.append(claudeUser(i, "第 \(i) 条问题,内容足够长可以切段" + String(repeating: "字", count: 100)))
            lines.append(claudeAssistant(i, "第 \(i) 条回复" + String(repeating: "答", count: 300)))
        }
        let url = try writeTemp(lines, name: "claude")
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try ClaudeCodeLoader.streamIndexRow(fileURL: url)
        let full = try ClaudeCodeLoader.loadConversation(fileURL: url, forIndexing: true)
            .map { IndexRow.from($0, fileURL: url) }
        XCTAssertNotNil(streamed)
        XCTAssertNotNil(full)
        assertRowsEqual(streamed!, full!, "claude 30 轮")
    }

    func testClaudeCodeStreamRejectsSameFilesAsFull() throws {
        // sidechain / 残骸 / 壳会话:两条路径的拒绝判定一致
        let sidechain = try writeTemp(
            ["{\"isSidechain\":true,\"type\":\"user\",\"uuid\":\"u0\",\"message\":{\"role\":\"user\",\"content\":\"x\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}"],
            name: "sidechain")
        defer { try? FileManager.default.removeItem(at: sidechain) }
        XCTAssertNil(try ClaudeCodeLoader.streamIndexRow(fileURL: sidechain))
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: sidechain, forIndexing: true))

        let relic = try writeTemp(
            [claudeUser(0, "你好"),
             "{\"type\":\"assistant\",\"uuid\":\"a0\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"API Error: connection failed\"}]},\"timestamp\":\"2026-01-01T00:00:30Z\"}"],
            name: "relic")
        defer { try? FileManager.default.removeItem(at: relic) }
        XCTAssertNil(try ClaudeCodeLoader.streamIndexRow(fileURL: relic))
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: relic, forIndexing: true))
    }

    func testCodexStreamMatchesFullParse() throws {
        var lines: [String] = []
        lines.append("{\"type\":\"session_meta\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"payload\":{\"id\":\"codex-sess\",\"cwd\":\"/p/codex\"}}")
        for i in 0..<20 {
            lines.append("{\"timestamp\":\"2026-01-01T00:\(String(format: "%02d", i)):00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"问题 \(i) " + String(repeating: "长", count: 200) + "\"}]}}")
            lines.append("{\"timestamp\":\"2026-01-01T00:\(String(format: "%02d", i)):30.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"回答 \(i) " + String(repeating: "答", count: 200) + "\"}]}}")
        }
        let url = try writeTemp(lines, name: "codex")
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try CodexLoader.streamIndexRow(fileURL: url)
        let full = try CodexLoader.loadConversation(fileURL: url, forIndexing: true)
            .map { IndexRow.from($0, fileURL: url) }
        XCTAssertNotNil(streamed)
        XCTAssertNotNil(full)
        assertRowsEqual(streamed!, full!, "codex 20 轮")
    }
}
