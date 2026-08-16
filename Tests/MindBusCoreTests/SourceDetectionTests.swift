import XCTest
@testable import MindBusCore

final class SourceDetectionTests: XCTestCase {

    private func tempDir() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory() + "srcdet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testMissingDirIsFalse() throws {
        XCTAssertFalse(SourceDetection.hasSessionFile(
            under: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
    }

    func testEmptyDirIsFalse() throws {
        XCTAssertFalse(SourceDetection.hasSessionFile(under: try tempDir()))
    }

    func testNestedJsonlIsTrue() throws {
        let d = try tempDir()
        let sub = d.appendingPathComponent("proj/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SourceDetection.hasSessionFile(under: d))
    }

    /// Claude Desktop 的会话藏在 `.claude` 隐藏目录下——枚举必须不跳隐藏。
    func testHiddenDirJsonlIsTrue() throws {
        let d = try tempDir()
        let hidden = d.appendingPathComponent("ws/.claude/projects/-a-b")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "x".write(to: hidden.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SourceDetection.hasSessionFile(under: d))
    }

    /// 只剩被排除数据（observer 元日志 / ignore 目录）的机器不该亮出工具。
    func testExcludedOnlyIsFalse() throws {
        let d = try tempDir()
        let obs = d.appendingPathComponent("claude-mem-observer-sessions")
        try FileManager.default.createDirectory(at: obs, withIntermediateDirectories: true)
        try "x".write(to: obs.appendingPathComponent("o.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertFalse(SourceDetection.hasSessionFile(
            under: d, excluding: { $0.contains("claude-mem-observer-sessions") }))
        XCTAssertTrue(SourceDetection.hasSessionFile(under: d))   // 不带排除则命中
    }
}
