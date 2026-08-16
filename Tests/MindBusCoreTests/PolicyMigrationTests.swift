import XCTest
@testable import MindBusCore

/// 数据政策升级的正面用例:旧版本库被打开时 DROP 全表重建、重扫后完整恢复。
/// (ReadOnlyIndexTests 只锁了只读进程「拒绝迁移」的一半;这里锁读写侧的另一半。)
@MainActor
final class PolicyMigrationTests: XCTestCase {

    func testStalePolicyVersionDropsAndRebuildsThenRescanRestores() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("index.sqlite").path

        // 建库并写入一场
        let file = dir.appendingPathComponent("conv.jsonl")
        try ["{\"type\":\"user\",\"uuid\":\"u1\",\"cwd\":\"/p/x\",\"sessionId\":\"mig-1\",\"message\":{\"role\":\"user\",\"content\":\"迁移前的内容\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}",
             "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"回复\"}]},\"timestamp\":\"2026-01-01T00:00:05Z\"}"]
            .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        do {
            let index = try XCTUnwrap(ConversationIndex(path: dbPath))
            LoaderRuntime.indexRows(urls: [file], into: index, source: .claudeCode,
                                    makeRow: ClaudeCodeLoader.indexRow)
            XCTAssertEqual(index.allMetadata().count, 1)
        }

        // 模拟旧库:user_version 回拨(等价于「App 升级带来新政策」)
        do {
            let db = try SQLiteDB(path: dbPath)
            try db.exec("PRAGMA user_version = \(ConversationIndex.dataPolicyVersion - 1);")
        }

        // 重开:迁移应 DROP 重建 → 库空、known 为空
        let reopened = try XCTUnwrap(ConversationIndex(path: dbPath))
        XCTAssertEqual(reopened.allMetadata().count, 0, "旧政策库应被清空重建")
        XCTAssertTrue(reopened.knownMtimes().isEmpty, "mtime 对账表应清空,否则重扫会跳过存量")

        // 重扫恢复
        LoaderRuntime.indexRows(urls: [file], into: reopened, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        XCTAssertEqual(reopened.allMetadata().count, 1, "重扫后完整恢复")
        XCTAssertEqual(reopened.search("迁移前").first, "mig-1", "恢复后可检索")
    }
}
