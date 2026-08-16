import XCTest
@testable import MindBusCore

/// 删除功能全链路集成:Store 删除 → 索引/归档/墓碑/列表联动 → 扫描不复活。
/// 口径:「从 MindBus 抹除,源文件不动」——每条用例都断言源文件仍在。
@MainActor
final class DeleteFlowTests: XCTestCase {

    private var dir: URL!
    private var vaultRoot: URL!
    private var indexURL: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-flow-\(UUID().uuidString)", isDirectory: true)
        vaultRoot = dir.appendingPathComponent("vault", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeClaudeConv(id: String, messages: [(uuid: String, role: String, text: String)]) throws -> URL {
        let file = dir.appendingPathComponent("\(id).jsonl")
        var lines: [String] = []
        for (i, m) in messages.enumerated() {
            let content = m.role == "user"
                ? "\"\(m.text)\""
                : "[{\"type\":\"text\",\"text\":\"\(m.text)\"}]"
            lines.append("{\"type\":\"\(m.role)\",\"uuid\":\"\(m.uuid)\",\"cwd\":\"/p/x\",\"sessionId\":\"\(id)\",\"message\":{\"role\":\"\(m.role)\",\"content\":\(content)},\"timestamp\":\"2026-01-01T00:\(String(format: "%02d", i)):00Z\"}")
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func makeStoreWithIndexed(file: URL) throws -> (ConversationStore, ConversationIndex) {
        let index = try XCTUnwrap(ConversationIndex(path: indexURL.path))
        LoaderRuntime.indexRows(urls: [file], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        let store = ConversationStore(indexPath: indexURL.path)
        store.setAll(index.allMetadata())
        return (store, index)
    }

    // MARK: - 对话删除

    func testDeleteConversationRemovesIndexArchiveAndList() throws {
        let file = try writeClaudeConv(id: "del-conv-1", messages: [
            ("u1", "user", "要删除的对话"),
            ("a1", "assistant", "回复内容"),
        ])
        // 造一份归档副本(断言它被删)
        XCTAssertTrue(VaultArchive.archive(sourcePath: file.path, root: vaultRoot,
                                           needsFilter: { _ in false }))
        XCTAssertTrue(VaultArchive.hasArchive(sourcePath: file.path, root: vaultRoot))

        let (store, index) = try makeStoreWithIndexed(file: file)
        XCTAssertEqual(store.allConversations.count, 1)
        store.selectedConversationId = "del-conv-1"

        store.deleteConversation(id: "del-conv-1", vaultRoot: vaultRoot)

        XCTAssertTrue(store.allConversations.isEmpty, "列表应移除")
        XCTAssertNil(store.selectedConversationId, "选中应清空")
        XCTAssertEqual(index.allMetadata().count, 0, "索引行应删除")
        XCTAssertFalse(VaultArchive.hasArchive(sourcePath: file.path, root: vaultRoot),
                       "归档副本应删除")
        XCTAssertTrue(TombstoneStore.shared.isBuriedPath(file.path), "墓碑应记录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "源文件永远不动——删除语义的底线")

        // 重扫不复活
        LoaderRuntime.indexRows(urls: [file], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        XCTAssertEqual(index.allMetadata().count, 0, "重扫不许复活")
    }

    /// 同 id 换 path 的副本(Codex resume 写新 rollout 同款场景):id 级防线拦住,
    /// 且新 path 自动补进墓碑(自愈)。
    func testBuriedConversationIDBlocksReappearanceUnderNewPath() throws {
        let fileA = try writeClaudeConv(id: "del-conv-2", messages: [
            ("u1", "user", "第一个文件"),
            ("a1", "assistant", "回复"),
        ])
        let (store, index) = try makeStoreWithIndexed(file: fileA)
        store.deleteConversation(id: "del-conv-2", vaultRoot: vaultRoot)

        // 同 sessionId 出现在另一个文件(路径不同,不在 path 墓碑里)
        let fileB = dir.appendingPathComponent("del-conv-2-copy.jsonl")
        try FileManager.default.copyItem(at: fileA, to: fileB)

        LoaderRuntime.indexRows(urls: [fileB], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        XCTAssertEqual(index.allMetadata().count, 0, "同 id 换 path 不许复活")
        XCTAssertTrue(TombstoneStore.shared.isBuriedPath(fileB.path), "新 path 应自动补墓碑")
    }

    // MARK: - 消息删除

    func testDeleteMessagesFiltersDetailAndReindexes() async throws {
        let file = try writeClaudeConv(id: "del-msg-1", messages: [
            ("m-keep", "user", "保留这条消息"),
            ("m-gone", "user", "删除的敏感内容"),
            ("a1", "assistant", "回复内容"),
        ])
        let (store, index) = try makeStoreWithIndexed(file: file)
        var corpus = index.userCorpusRows()
        XCTAssertTrue(corpus[0].text.contains("敏感内容"), "删除前语料应含该消息")

        store.deleteMessages(conversationID: "del-msg-1", messageIDs: ["m-gone"])

        // 装载出口过滤立即生效
        let detail = ConversationStore.loadFull(id: "del-msg-1", fileURL: file,
                                                source: .claudeCode, vaultRoot: vaultRoot)
        XCTAssertEqual(detail?.messages.map(\.id), ["m-keep", "a1"], "详情不再含被删消息")

        // 后台索引重灌(轮询等待)
        for _ in 0..<50 {
            corpus = index.userCorpusRows()
            if corpus.count == 1, !corpus[0].text.contains("敏感内容") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(corpus[0].text.contains("敏感内容"), "语料重灌后不含被删消息")
        XCTAssertTrue(corpus[0].text.contains("保留这条消息"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "源文件不动")
    }

    func testDeleteAllMessagesEscalatesToConversationDelete() async throws {
        let file = try writeClaudeConv(id: "del-msg-2", messages: [
            ("m1", "user", "唯一一条"),
            ("a1", "assistant", "回复"),
        ])
        let (store, index) = try makeStoreWithIndexed(file: file)

        store.deleteMessages(conversationID: "del-msg-2", messageIDs: ["m1", "a1"])

        // 全删光 → 后台升级为删除整场(轮询等待)
        for _ in 0..<50 {
            if index.allMetadata().isEmpty, store.allConversations.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(index.allMetadata().isEmpty, "全删光应升级为删除整场对话")
        XCTAssertTrue(store.allConversations.isEmpty)
        XCTAssertTrue(TombstoneStore.shared.isBuriedConversation(id: "del-msg-2"))
    }

    func testLoadFullReturnsNilWhenAllMessagesBuried() throws {
        let file = try writeClaudeConv(id: "del-msg-3", messages: [
            ("m1", "user", "会被全删的"),
            ("a1", "assistant", "回复"),
        ])
        TombstoneStore.shared.buryMessages(conversationID: "del-msg-3",
                                           messageIDs: ["m1", "a1"])
        let detail = ConversationStore.loadFull(id: "del-msg-3", fileURL: file,
                                                source: .claudeCode, vaultRoot: vaultRoot)
        XCTAssertNil(detail, "全删光返回 nil——不许闪回原始消息")
    }

    // MARK: - 归档删除

    func testRemoveArchiveDeletesCopyOnly() throws {
        let file = try writeClaudeConv(id: "del-arc-1", messages: [
            ("u1", "user", "有归档的对话"),
            ("a1", "assistant", "回复"),
        ])
        XCTAssertTrue(VaultArchive.archive(sourcePath: file.path, root: vaultRoot,
                                           needsFilter: { _ in false }))
        VaultArchive.removeArchive(sourcePath: file.path, root: vaultRoot)
        XCTAssertFalse(VaultArchive.hasArchive(sourcePath: file.path, root: vaultRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "源文件不动")
    }
}
