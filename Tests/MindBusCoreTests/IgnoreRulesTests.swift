import XCTest
@testable import MindBusCore

final class IgnoreRulesTests: XCTestCase {

    func testParseSkipsCommentsAndBlankAndTrailingSlash() {
        let rules = IgnoreRules.parse("""
        # 注释行
        /Users/a/dev/AutoCron

          /Users/b/auto/
        """)
        XCTAssertEqual(rules, ["/Users/a/dev/AutoCron", "/Users/b/auto"])
    }

    func testClaudeProjectDirEncoding() {
        XCTAssertEqual(IgnoreRules.claudeProjectDirName("/Users/a/dev/X"), "-Users-a-dev-X")
    }

    func testMatchesClaudeProjectDir() {
        let rules = ["/Users/a/dev/AutoCron"]
        // 项目目录精确命中
        XCTAssertTrue(IgnoreRules.matches(
            jsonlPath: "/Users/a/.claude/projects/-Users-a-dev-AutoCron/s1.jsonl", rules: rules))
        // 子目录（编码前缀 + "-"）
        XCTAssertTrue(IgnoreRules.matches(
            jsonlPath: "/Users/a/.claude/projects/-Users-a-dev-AutoCron-sub/s2.jsonl", rules: rules))
        // 相似但不同的目录不误伤
        XCTAssertFalse(IgnoreRules.matches(
            jsonlPath: "/Users/a/.claude/projects/-Users-a-dev-AutoCronshop/s3.jsonl", rules: rules))
        XCTAssertFalse(IgnoreRules.matches(
            jsonlPath: "/Users/a/.claude/projects/-Users-a-dev-mindbus/s4.jsonl", rules: rules))
    }

    func testMatchesDirectPathPrefix() {
        let rules = ["/Users/a/dev/AutoCron"]
        XCTAssertTrue(IgnoreRules.matches(
            jsonlPath: "/Users/a/dev/AutoCron/logs/x.jsonl", rules: rules))
        // 前缀必须止于路径分隔符——兄弟目录不误伤
        XCTAssertFalse(IgnoreRules.matches(
            jsonlPath: "/Users/a/dev/AutoCronshop/x.jsonl", rules: rules))
    }

    func testEmptyRulesMatchNothing() {
        XCTAssertFalse(IgnoreRules.matches(jsonlPath: "/any/path.jsonl", rules: []))
    }
}

extension IgnoreRulesTests {
    /// 排除规则新增后，存量行必须被 pruneMissing 清掉（文件存在、mtime 不变，
    /// 增量扫描永远跳过——不在 prune 里处理就是永久残留）。
    func testPruneMissingEvictsExcludedButExistingFiles() throws {
        let path = NSTemporaryDirectory() + "ig-prune-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let index = try ConversationIndex(path: path)

        let dir = NSTemporaryDirectory() + "ig-src-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let keep = URL(fileURLWithPath: dir + "keep.jsonl")
        let excl = URL(fileURLWithPath: dir + "excluded.jsonl")
        try "x".write(to: keep, atomically: true, encoding: .utf8)
        try "x".write(to: excl, atomically: true, encoding: .utf8)

        func lite(_ id: String, _ u: URL) -> ConversationLite {
            ConversationLite(id: id, source: .claudeCode, startAt: Date(), endAt: Date(),
                             cwd: "/tmp", gitBranch: nil, preview: "p", messageCount: 1, fileURL: u)
        }
        let t = [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "t")]
        try index.upsert([(lite("keep", keep), t, 1, "t"), (lite("excl", excl), t, 1, "t")])
        XCTAssertEqual(index.summary().count, 2)

        // hasArchive 必须显式注入：默认闭包会去真实 ~/.mindbus/vault 判存在性，
        // 测试不得碰用户真实数据。本用例的断言与归档状态无关，恒 false 即可。
        LoaderRuntime.pruneMissing(from: index,
                                   isExcluded: { $0.hasSuffix("excluded.jsonl") },
                                   hasArchive: { _ in false })
        XCTAssertEqual(index.summary().count, 1)
        let paths = index.knownMtimes().keys
        XCTAssertTrue(paths.contains(keep.path))
        XCTAssertFalse(paths.contains(excl.path))
    }
}
