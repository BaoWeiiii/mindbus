import XCTest
@testable import MindBusCore

/// 归档范围：只收「真的解析出了对话」的源文件。
///
/// 为什么必须区分：`knownMtimes()` 故意把 `conversations`（解析出对话的）与
/// `skipped_files`（解析过但没产出的）并起来读——对「增量跳过」而言两者等价，
/// 但对归档不等价。本机实测生产接线曾把 1062 个路径全喂给扫尾，其中约 96%
/// 是 App 永远不显示的东西（子代理轨迹 663 个/369MB、壳会话 315 个、API Error 残骸），
/// 归档 272MiB 里约 65% 是废的（存储计划预估 Claude 侧只需 ~100MiB）。
final class VaultArchiveScopeTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "scope-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    private func lite(_ id: String, _ url: URL) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(), endAt: Date(),
                         cwd: "/tmp", gitBranch: nil, preview: "p", messageCount: 1, fileURL: url)
    }

    /// `conversationPaths()` 只返回真的有对话的行，不含解析无产出的文件。
    func testConversationPathsExcludesSkippedFiles() throws {
        let index = try makeIndex()
        let real = URL(fileURLWithPath: NSTemporaryDirectory() + "scope-real-\(UUID().uuidString).jsonl")
        let barren = URL(fileURLWithPath: NSTemporaryDirectory() + "scope-barren-\(UUID().uuidString).jsonl")

        try index.upsert([(lite("real", real), [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "t")], 1, "t")])
        index.markSkipped([(barren.path, 1)])

        // 前提：knownMtimes 两张表都读（这正是缺陷来源）
        XCTAssertEqual(Set(index.knownMtimes().keys), Set([real.path, barren.path]))

        // 归档要用的是这个：只含真有对话的
        XCTAssertEqual(index.conversationPaths(), [real.path])
    }

    /// 生产接线的范围：扫尾拿到的路径里不该出现「解析无产出」的文件。
    /// 这一条守的是「归档只保护 App 真会显示的东西」这条线。
    func testArchiveScopeExcludesBarrenFilesEndToEnd() throws {
        let index = try makeIndex()
        // 用真实源目录下的**虚构**路径：archiveScope 只做「查库 + 路径前缀判断」，
        // 不碰文件系统，所以不需要（也不该）真的在用户目录里造文件。
        let dir = ClaudeCodeLoader.defaultProjectsDir
            .appendingPathComponent("scope-e2e-\(UUID().uuidString)", isDirectory: true)
        let real = dir.appendingPathComponent("real.jsonl")
        let barren = dir.appendingPathComponent("barren.jsonl")
        try index.upsert([(lite("real", real), [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "t")], 1, "t")])
        index.markSkipped([(barren.path, 1)])

        let scope = LoaderRuntime.archiveScope(of: index)
        XCTAssertTrue(scope.contains(real.path))
        XCTAssertFalse(scope.contains(barren.path),
                       "解析无产出的文件被纳入归档范围——会白占空间")
    }

    /// browser 行的 file_path 是相对伪路径，也会出现在 conversations 表里——
    /// 归档过滤器必须照旧把它挡掉（它本身已经是我们自己写的 vault）。
    func testConversationPathsStillFilteredByArchivablePredicate() throws {
        let index = try makeIndex()
        let bid = "browser-chatgpt/2026-05-07.jsonl#3"
        index.replaceBrowserVault([Conversation(
            id: bid, source: .browser, startAt: Date(), endAt: Date(),
            cwd: "browser-chatgpt", gitBranch: nil,
            messages: [Message(id: "m", role: .user, timestamp: Date(), blocks: [.text("hi")])])])

        let paths = index.conversationPaths()
        XCTAssertTrue(paths.contains(bid), "browser 行应在 conversations 表里")
        XCTAssertTrue(paths.filter(VaultArchive.isArchivableSourcePath).isEmpty,
                      "browser 伪路径不该被判为可归档")
    }
}
