import XCTest
@testable import MindBusCore

/// 端到端验证 vault 的最终价值：源文件被删之后，详情读取仍然拿得到内容。
/// 直接打 `ConversationStore.loadFull` —— 它才是「先源、后副本」这条回退链路的真身，
/// 只测 VaultArchive 等于没测接线。
final class VaultRestoreReadTests: XCTestCase {

    private func makeRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vr-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 造一个最小可解析的 Claude Code 会话（一问一答），返回其源路径。
    private func makeSession() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vr-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"s1","cwd":"/tmp","timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user","content":"归档能救回来吗"}}"#,
            #"{"type":"assistant","uuid":"a1","sessionId":"s1","cwd":"/tmp","timestamp":"2026-08-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"能"}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: src)
        return src
    }

    func testLoadFullFallsBackToArchiveAfterSourceDeleted() throws {
        let root = makeRoot()
        let src = try makeSession()

        // 先确认源在时能正常解析（基线），再归档、再模拟 30 天清理
        XCTAssertNotNil(ConversationStore.loadFull(id: "s1", fileURL: src, source: .claudeCode, vaultRoot: root))
        XCTAssertTrue(VaultArchive.archive(sourcePath: src.path, root: root))
        try FileManager.default.removeItem(at: src)
        XCTAssertNil(try? ClaudeCodeLoader.loadConversation(fileURL: src))   // 源确实没了

        let conv = try XCTUnwrap(
            ConversationStore.loadFull(id: "s1", fileURL: src, source: .claudeCode, vaultRoot: root),
            "源被清理后详情读不出来——vault 白存了"
        )
        XCTAssertEqual(conv.messages.count, 2)
        XCTAssertTrue(conv.searchableText.contains("归档能救回来吗"))
    }

    /// 没有副本时必须老实返回 nil（走既有的「源文件已无法读取」失败态），不能假装成功。
    func testLoadFullReturnsNilWhenSourceGoneAndNoArchive() throws {
        let root = makeRoot()
        let src = try makeSession()
        try FileManager.default.removeItem(at: src)
        XCTAssertNil(ConversationStore.loadFull(id: "s1", fileURL: src, source: .claudeCode, vaultRoot: root))
    }
}
