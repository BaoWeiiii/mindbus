import XCTest
@testable import MindBusCore

final class BrowserVaultLoaderTests: XCTestCase {
    private func jsonlLine(_ text: String, source: String) -> String {
        let obj: [String: Any] = [
            "captured_at": "2026-05-29T10:00:00Z",
            "source": source,
            "url": "https://example.com",
            "messages": [["role": "user", "content": text]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    func testParseLineBasics() {
        let url = URL(fileURLWithPath: "/v/browser-chatgpt/2026-05-29.jsonl")
        let conv = BrowserVaultLoader.parseLine(jsonlLine("hello", source: "browser-chatgpt"),
                                                fileURL: url, lineIndex: 0)
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.source, .browser)
        XCTAssertEqual(conv?.cwd, "browser-chatgpt")   // sourceTag 存 cwd 供展示
        XCTAssertEqual(conv?.messageCount, 1)
    }

    /// 回归：同一天、同文件名、同行号，不同 source 目录 → id 必须不同。
    /// 否则撞 `conversations.id UNIQUE`，多平台用户的 browser 对话会整批回滚消失。
    func testIdUniqueAcrossSameDaySources() {
        let chatgpt = URL(fileURLWithPath: "/v/browser-chatgpt/2026-05-29.jsonl")
        let claude  = URL(fileURLWithPath: "/v/browser-claude/2026-05-29.jsonl")
        let c1 = BrowserVaultLoader.parseLine(jsonlLine("hi gpt", source: "browser-chatgpt"),
                                              fileURL: chatgpt, lineIndex: 0)
        let c2 = BrowserVaultLoader.parseLine(jsonlLine("hi claude", source: "browser-claude"),
                                              fileURL: claude, lineIndex: 0)
        XCTAssertNotNil(c1)
        XCTAssertNotNil(c2)
        XCTAssertNotEqual(c1?.id, c2?.id)
    }

    /// captured_at 解析不出 → 整行丢弃。兜底 Date()（=扫描那一刻）会让该行
    /// 每轮全量重载都换一次时间、永远浮在列表顶端。
    func testParseLineDropsUnparseableCapturedAt() {
        let url = URL(fileURLWithPath: "/v/browser-chatgpt/2026-05-29.jsonl")
        for ts in ["not-a-date", ""] {
            let obj: [String: Any] = [
                "captured_at": ts,
                "source": "browser-chatgpt",
                "messages": [["role": "user", "content": "hi"]],
            ]
            let line = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
            XCTAssertNil(BrowserVaultLoader.parseLine(line, fileURL: url, lineIndex: 0),
                         "captured_at=\(ts) 应整行丢弃")
        }
    }

    // MARK: - 单条取回（详情面板链路）

    /// 按索引行 id（`<source目录>/<文件名>#<行号>`）取回该行：
    /// browser 行的 file_path 是伪路径，此前详情分支直接 return nil，
    /// 点开任何 browser 对话都显示「源文件已无法读取」。
    func testLoadSingleRetrievesLineById() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("browser-chatgpt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = dir.appendingPathComponent("2026-05-29.jsonl")
        try [jsonlLine("line zero", source: "browser-chatgpt"),
             jsonlLine("line one", source: "browser-chatgpt"),
             jsonlLine("line two", source: "browser-chatgpt")]
            .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let id = "browser-chatgpt/2026-05-29.jsonl#1"
        let conv = try XCTUnwrap(BrowserVaultLoader.loadSingle(id: id, rootDir: root))
        XCTAssertEqual(conv.id, id, "parseLine 必须重新生成同一个 id")
        XCTAssertEqual(conv.messages.first?.firstTextBlock, "line one")

        // 行号越界 / 文件不存在 → nil（详情层显示失败态而不是崩）
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "browser-chatgpt/2026-05-29.jsonl#99", rootDir: root))
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "browser-gone/2026-05-29.jsonl#0", rootDir: root))
    }

    /// id 非法（无 #、行号非数字/负数、试图 .. 逃出 vault、绝对路径）一律拒绝。
    func testLoadSingleRejectsMalformedOrEscapingIds() {
        let root = FileManager.default.temporaryDirectory
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "no-hash-here", rootDir: root))
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "browser-x/f.jsonl#NaN", rootDir: root))
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "browser-x/f.jsonl#-1", rootDir: root))
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "../outside/f.jsonl#0", rootDir: root))
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "/etc/passwd#0", rootDir: root))
        XCTAssertNil(BrowserVaultLoader.loadSingle(id: "#0", rootDir: root))
    }
}
