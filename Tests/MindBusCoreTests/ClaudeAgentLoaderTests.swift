import XCTest
@testable import MindBusCore

final class ClaudeAgentLoaderTests: XCTestCase {

    private func writeJSONL(at url: URL, lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testLoadConversationRetagsSourceAsClaudeAgent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-agent-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lines = [
            #"{"type":"user","uuid":"m1","timestamp":"2026-04-30T10:00:00.000Z","sessionId":"s-agent","cwd":"/sandbox/work","message":{"content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"assistant","uuid":"m2","timestamp":"2026-04-30T10:00:01.000Z","sessionId":"s-agent","cwd":"/sandbox/work","message":{"content":[{"type":"text","text":"hello"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let conv = try ClaudeAgentLoader.loadConversation(fileURL: tmp)
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.source, .claudeAgent)
        XCTAssertEqual(conv?.id, "s-agent")
        XCTAssertEqual(conv?.cwd, "/sandbox/work")
        XCTAssertEqual(conv?.messages.count, 2)
    }

    func testEnumerateOnlyMatchesSandboxedJsonl() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-agent-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Path that LOOKS like a sandboxed Claude Agent session
        let sandboxJsonl = root
            .appendingPathComponent("workspace")
            .appendingPathComponent("container")
            .appendingPathComponent("local_session")
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent("encoded-cwd")
            .appendingPathComponent("session-id.jsonl")
        try writeJSONL(at: sandboxJsonl, lines: ["{}"])

        // Decoy: a jsonl outside the .claude/projects path — should NOT match
        let decoy = root
            .appendingPathComponent("workspace")
            .appendingPathComponent("decoy.jsonl")
        try writeJSONL(at: decoy, lines: ["{}"])

        let urls = ClaudeAgentLoader.enumerateJsonl(in: root)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.lastPathComponent, "session-id.jsonl")
    }

    func testEnumerateMissingDirReturnsEmpty() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(ClaudeAgentLoader.enumerateJsonl(in: nonexistent).isEmpty)
    }

    func testDefaultRootDirIsLocalAgentModeSessions() {
        let path = ClaudeAgentLoader.defaultRootDir.path
        XCTAssertTrue(path.hasSuffix("/local-agent-mode-sessions"), "got: \(path)")
        XCTAssertTrue(path.contains("Application Support/Claude"))
    }
}
