import XCTest
@testable import MindBusCore

final class IncrementalParseTests: XCTestCase {
    private func line(_ uuid: String, _ text: String, _ ts: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","timestamp":"\#(ts)","cwd":"/p","sessionId":"s1","message":{"role":"user","content":"\#(text)"}}"#
    }

    /// 追加写之后，增量解析的结果必须与全量解析逐条一致。
    /// 算错就是丢消息或重复消息，用户不会发现，只会觉得「记录不全」。
    func testIncrementalMatchesFullParse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.jsonl")

        try ([line("u1", "第一条", "2026-01-01T10:00:00.000Z"),
              line("u2", "第二条", "2026-01-01T10:01:00.000Z")].joined(separator: "\n") + "\n")
            .write(to: f, atomically: true, encoding: .utf8)

        let first = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: f))
        XCTAssertEqual(first.messages.count, 2)
        let boundary = try XCTUnwrap(IncrementalParseCache.lastLineBoundary(of: f.path))
        IncrementalParseCache.shared.put(path: f.path, offset: boundary, conv: first)

        // 追加两条
        let handle = try FileHandle(forWritingTo: f)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            ([line("u3", "第三条", "2026-01-01T10:02:00.000Z"),
              line("u4", "第四条", "2026-01-01T10:03:00.000Z")].joined(separator: "\n") + "\n").utf8))
        try handle.close()

        let size = UInt64((try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0)
        let base = try XCTUnwrap(IncrementalParseCache.shared.baseline(for: f.path, currentSize: size))
        let inc = try XCTUnwrap(ClaudeCodeLoader.loadConversationIncremental(
            fileURL: f, base: base.conv, baseMessages: base.conv.messages, fromOffset: base.offset))
        let full = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: f))

        XCTAssertEqual(inc.messages.map(\.id), full.messages.map(\.id), "增量与全量的消息序列必须一致")
        XCTAssertEqual(inc.messages.count, 4)
        XCTAssertEqual(inc.endAt, full.endAt)
        XCTAssertEqual(inc.cwd, full.cwd, "元数据来自基线，不能因增量丢失")
        IncrementalParseCache.shared.clear()
    }

    /// 增量合并后，同一时间戳的消息仍要保持文件行序（base 在前、fresh 在后）。
    /// Swift sort 不稳定，纯 timestamp 键在 base 尾与 fresh 头同刻时会随机互换。
    func testIncrementalStableOrderForEqualTimestamps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("stable.jsonl")

        let ts = "2026-01-01T10:00:00.000Z"   // 全部同刻
        try ([line("u1", "一", ts), line("u2", "二", ts)].joined(separator: "\n") + "\n")
            .write(to: f, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: f))
        let boundary = try XCTUnwrap(IncrementalParseCache.lastLineBoundary(of: f.path))
        IncrementalParseCache.shared.put(path: f.path, offset: boundary, conv: first)

        let handle = try FileHandle(forWritingTo: f)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            ([line("u3", "三", ts), line("u4", "四", ts)].joined(separator: "\n") + "\n").utf8))
        try handle.close()

        let size = UInt64((try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0)
        let base = try XCTUnwrap(IncrementalParseCache.shared.baseline(for: f.path, currentSize: size))
        let inc = try XCTUnwrap(ClaudeCodeLoader.loadConversationIncremental(
            fileURL: f, base: base.conv, baseMessages: base.conv.messages, fromOffset: base.offset))
        XCTAssertEqual(inc.messages.map(\.id), ["u1", "u2", "u3", "u4"])
        let full = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: f))
        XCTAssertEqual(inc.messages.map(\.id), full.messages.map(\.id), "增量与全量顺序必须一致")
        IncrementalParseCache.shared.clear()
    }

    /// 增量段里出现的 ai-title 行要被拾取（标题在会话进行中生成/更新），与全量路径一致。
    func testIncrementalPicksUpAiTitleFromFreshSegment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("title.jsonl")

        try (line("u1", "第一条", "2026-01-01T10:00:00.000Z") + "\n")
            .write(to: f, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: f))
        XCTAssertNil(first.title)
        let boundary = try XCTUnwrap(IncrementalParseCache.lastLineBoundary(of: f.path))
        IncrementalParseCache.shared.put(path: f.path, offset: boundary, conv: first)

        let handle = try FileHandle(forWritingTo: f)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            ([#"{"type":"ai-title","aiTitle":"补上的标题","sessionId":"s1"}"#,
              line("u2", "第二条", "2026-01-01T10:01:00.000Z")].joined(separator: "\n") + "\n").utf8))
        try handle.close()

        let size = UInt64((try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0)
        let base = try XCTUnwrap(IncrementalParseCache.shared.baseline(for: f.path, currentSize: size))
        let inc = try XCTUnwrap(ClaudeCodeLoader.loadConversationIncremental(
            fileURL: f, base: base.conv, baseMessages: base.conv.messages, fromOffset: base.offset))
        XCTAssertEqual(inc.title, "补上的标题")
        XCTAssertEqual(inc.messages.count, 2)
        XCTAssertEqual(inc.title, try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: f)).title,
                       "增量与全量提取的标题必须一致")
        IncrementalParseCache.shared.clear()
    }

    /// 文件被整体重写（不是追加）时必须拒绝增量，否则会把旧内容当新的接上去。
    func testRewrittenFileFallsBackToFull() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("b.jsonl")

        try (line("x1", "原始", "2026-01-01T10:00:00.000Z") + "\n").write(to: f, atomically: true, encoding: .utf8)
        let c = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: f))
        IncrementalParseCache.shared.put(
            path: f.path,
            offset: try XCTUnwrap(IncrementalParseCache.lastLineBoundary(of: f.path)), conv: c)

        // 换掉开头内容再写长一点 → 指纹变了
        try ([line("y1", "换过的开头内容要足够长以改变指纹", "2026-01-01T11:00:00.000Z"),
              line("y2", "第二条", "2026-01-01T11:01:00.000Z")].joined(separator: "\n") + "\n")
            .write(to: f, atomically: true, encoding: .utf8)

        let size = UInt64((try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0)
        XCTAssertNil(IncrementalParseCache.shared.baseline(for: f.path, currentSize: size),
                     "文件头变了就不能再增量")
        IncrementalParseCache.shared.clear()
    }
}
