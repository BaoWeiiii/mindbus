import XCTest
@testable import MindBusCore

final class VaultSweepTests: XCTestCase {

    private func makeRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-src-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 写一个文件并把 mtime 设为「距 now 多少秒前」。
    private func writeFile(in dir: URL, name: String, ageSeconds: TimeInterval, now: Date) -> URL {
        let url = dir.appendingPathComponent(name)
        try? Data("{\"type\":\"user\"}\n".utf8).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ageSeconds)],
                                              ofItemAtPath: url.path)
        return url
    }

    func testArchivesColdFilesAndSkipsActiveOnes() throws {
        let root = makeRoot(), dir = makeDir(), now = Date()
        let cold = writeFile(in: dir, name: "cold.jsonl", ageSeconds: 3600, now: now)
        let active = writeFile(in: dir, name: "active.jsonl", ageSeconds: 5, now: now)

        let archived = VaultArchive.sweep(paths: [cold.path, active.path], root: root, now: now)

        XCTAssertEqual(archived, 1)
        XCTAssertTrue(VaultArchive.hasArchive(sourcePath: cold.path, root: root))
        // 活跃会话正在被追加写，这一刻归档只会白压一遍；等它凉了下一轮扫尾再收
        XCTAssertFalse(VaultArchive.hasArchive(sourcePath: active.path, root: root))
    }

    /// 扫尾必须幂等：第二次跑不能重压一遍（否则每轮扫描都白烧 CPU）。
    func testSweepIsIdempotent() throws {
        let root = makeRoot(), dir = makeDir(), now = Date()
        let f = writeFile(in: dir, name: "a.jsonl", ageSeconds: 3600, now: now)
        XCTAssertEqual(VaultArchive.sweep(paths: [f.path], root: root, now: now), 1)
        XCTAssertEqual(VaultArchive.sweep(paths: [f.path], root: root, now: now), 0)
    }

    /// I-1 回归：源被 `--resume` 续聊追加过（源 mtime 新于既有归档）时，
    /// 扫尾必须重新压一份，否则续聊的尾部消息会在源被工具清理后随之永久消失、
    /// 且界面毫无提示——比整条会话丢失更隐蔽。
    ///
    /// 时间线设计说明：归档文件的 mtime 是真实写入时刻，测试改不了它；
    /// 所以第一次归档后立刻读回它的真实 mtime 作为锚点，「源比归档新」用
    /// 锚点 +1s 表达（不依赖两次系统调用之间的真实时钟差），「已过活跃豁免」
    /// 则通过传给 sweep 的模拟未来 now 表达——两个约束用两个独立变量满足，
    /// 不会互相冲突。
    func testSweepReArchivesWhenSourceNewerThanArchive() throws {
        let root = makeRoot(), dir = makeDir()
        let realNow = Date()
        let src = writeFile(in: dir, name: "resumed.jsonl", ageSeconds: 3600, now: realNow)

        // 第一次归档：源此刻按「冷」处理。
        XCTAssertEqual(VaultArchive.sweep(paths: [src.path], root: root, now: realNow), 1)
        let archivedAt = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: VaultArchive.archiveURL(forSourcePath: src.path, root: root).path
            )[.modificationDate] as? Date
        )

        // 模拟 --resume 续聊：向同一个 jsonl 追加内容，mtime 显式设到「归档时刻之后」。
        let existing = try String(contentsOf: src, encoding: .utf8)
        let appendedLine = "{\"type\":\"assistant\",\"text\":\"resume 之后追加的消息\"}\n"
        try (existing + appendedLine).write(to: src, atomically: true, encoding: .utf8)
        let sourceMTimeAfterResume = archivedAt.addingTimeInterval(1)
        try FileManager.default.setAttributes([.modificationDate: sourceMTimeAfterResume],
                                              ofItemAtPath: src.path)

        // 第二次扫尾传一个模拟未来的 now，让刚刷新的源相对它已过 600s 活跃豁免窗口，
        // 同时源仍新于归档（真实 mtime）——应触发重新归档。
        let simulatedNow = sourceMTimeAfterResume.addingTimeInterval(7200)
        XCTAssertEqual(VaultArchive.sweep(paths: [src.path], root: root, now: simulatedNow), 1,
                       "源比归档新（被续聊追加过）时必须重新归档，否则尾部消息会静默丢失")

        let restored: String? = VaultArchive.withRestoredCopy(sourcePath: src.path, root: root) { url in
            try? String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertTrue(restored?.contains("resume 之后追加的消息") ?? false,
                      "重新归档后应能还原出续聊追加的尾部消息")
    }

    /// 源文件已经消失的路径不该被当成失败——它可能早就归档过了，扫尾只管跳过。
    func testSweepIgnoresMissingSources() {
        let root = makeRoot()
        XCTAssertEqual(VaultArchive.sweep(paths: ["/nope/gone.jsonl"], root: root, now: Date()), 0)
    }

    /// 只认两个 Claude 系源目录下的 jsonl；别的路径（含被政策排除的 observer 会话）一律不归档。
    func testIsArchivableSourcePathGatesByDirAndPolicy() {
        let claude = ClaudeCodeLoader.defaultProjectsDir.appendingPathComponent("proj/s.jsonl").path
        let observer = ClaudeCodeLoader.defaultProjectsDir
            .appendingPathComponent("claude-mem-observer-sessions/x.jsonl").path
        XCTAssertTrue(VaultArchive.isArchivableSourcePath(claude))
        XCTAssertFalse(VaultArchive.isArchivableSourcePath(observer))
        XCTAssertFalse(VaultArchive.isArchivableSourcePath("/tmp/whatever.jsonl"))
        XCTAssertFalse(VaultArchive.isArchivableSourcePath("browser-chatgpt/2026-05-07.jsonl#3"))
        // 前缀判断必须带上分隔符 "/"：兄弟目录（同名前缀但不是子目录）不该被误判为可归档，
        // 钉住这一行为防未来重构把 `$0 + "/"` 精简掉。
        XCTAssertFalse(VaultArchive.isArchivableSourcePath(
            ClaudeCodeLoader.defaultProjectsDir.path + "-old/x.jsonl"))
    }
}
