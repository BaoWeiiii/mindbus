import XCTest
@testable import MindBusCore

/// 墓碑表:用户删除记录。核心约束——**必须存活于索引策略升级**
/// (index.sqlite 会被 DROP 重建,墓碑在里面就等于删除记录随升级蒸发、全部复活)。
final class TombstoneStoreTests: XCTestCase {

    private func tempStore() -> (TombstoneStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-\(UUID().uuidString).json")
        return (TombstoneStore(fileURL: url), url)
    }

    func testBuryConversationBlocksPathAndID() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(store.isBuriedPath("/p/a.jsonl"))
        store.buryConversation(id: "conv-1", path: "/p/a.jsonl")
        XCTAssertTrue(store.isBuriedPath("/p/a.jsonl"))
        XCTAssertTrue(store.isBuriedConversation(id: "conv-1"))
        XCTAssertFalse(store.isBuriedPath("/p/b.jsonl"))
    }

    func testBuryMessagesAccumulates() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(store.hasBuriedMessages(conversationID: "c1"))
        store.buryMessages(conversationID: "c1", messageIDs: ["m1", "m2"])
        store.buryMessages(conversationID: "c1", messageIDs: ["m3"])
        XCTAssertEqual(store.buriedMessages(conversationID: "c1"), ["m1", "m2", "m3"])
        XCTAssertTrue(store.hasBuriedMessages(conversationID: "c1"))
        XCTAssertEqual(store.buriedMessages(conversationID: "c2"), [])
    }

    func testPersistsAcrossInstances() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.buryConversation(id: "conv-1", path: "/p/a.jsonl")
        store.buryMessages(conversationID: "c1", messageIDs: ["m1"])

        let reloaded = TombstoneStore(fileURL: url)
        XCTAssertTrue(reloaded.isBuriedPath("/p/a.jsonl"), "墓碑必须跨进程存活")
        XCTAssertEqual(reloaded.buriedMessages(conversationID: "c1"), ["m1"])
    }
}

// MARK: - 扫描侧防线(删后不复活)

extension TombstoneStoreTests {

    /// 墓碑 path 在 LoaderRuntime 扫描层被拦——删除的对话不因源文件仍在而复活。
    func testBuriedPathNeverReindexed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("conv.jsonl")
        let lines = [
            "{\"type\":\"user\",\"uuid\":\"u1\",\"cwd\":\"/p/x\",\"sessionId\":\"bury-scan-1\",\"message\":{\"role\":\"user\",\"content\":\"你好世界\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}",
            "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"回复\"}]},\"timestamp\":\"2026-01-01T00:00:05Z\"}",
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        let index = try XCTUnwrap(ConversationIndex(path: indexURL.path))

        // 首扫入库
        LoaderRuntime.indexRows(urls: [file], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        XCTAssertEqual(index.allMetadata().count, 1, "首扫应入库")

        // 删除:墓碑 + prune
        TombstoneStore.shared.buryConversation(id: "bury-scan-1", path: file.path)
        index.prune(missingPaths: [file.path])
        XCTAssertEqual(index.allMetadata().count, 0, "prune 后库空")

        // 重扫(源文件还在、mtime 未入 known)——墓碑必须拦住
        LoaderRuntime.indexRows(urls: [file], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        XCTAssertEqual(index.allMetadata().count, 0, "删除的对话不许复活")
    }

    /// 消息墓碑会话在扫描重灌时被过滤——被删消息不再进段/语料。
    func testBuriedMessagesFilteredOnRescan() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-msg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("conv.jsonl")
        let lines = [
            "{\"type\":\"user\",\"uuid\":\"m-keep\",\"cwd\":\"/p/x\",\"sessionId\":\"bury-msg-1\",\"message\":{\"role\":\"user\",\"content\":\"保留的这条\"},\"timestamp\":\"2026-01-01T00:00:00Z\"}",
            "{\"type\":\"user\",\"uuid\":\"m-gone\",\"message\":{\"role\":\"user\",\"content\":\"删除的敏感内容\"},\"timestamp\":\"2026-01-01T00:00:03Z\"}",
            "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"回复\"}]},\"timestamp\":\"2026-01-01T00:00:05Z\"}",
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-idx2-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        let index = try XCTUnwrap(ConversationIndex(path: indexURL.path))

        TombstoneStore.shared.buryMessages(conversationID: "bury-msg-1", messageIDs: ["m-gone"])
        LoaderRuntime.indexRows(urls: [file], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)

        let corpus = index.userCorpusRows()
        XCTAssertEqual(corpus.count, 1)
        XCTAssertTrue(corpus[0].text.contains("保留的这条"))
        XCTAssertFalse(corpus[0].text.contains("敏感内容"), "被删消息不许进语料")
        let meta = index.allMetadata()
        XCTAssertEqual(meta.count, 1)
    }
}
