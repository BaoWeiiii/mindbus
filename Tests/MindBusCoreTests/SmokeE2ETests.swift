import XCTest
@testable import MindBusCore

/// App 级端到端冒烟:把产品的全部核心承诺锁进一条龙——
/// 多源采集 → 索引 → 双语搜索 → 详情 → Minds → 归档 → 源亡副本活(救回) → 删除。
/// 任何一环断裂,这条测试先于用户发现。
@MainActor
final class SmokeE2ETests: XCTestCase {

    private var dir: URL!
    private var vaultRoot: URL!
    private var index: ConversationIndex!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-\(UUID().uuidString)", isDirectory: true)
        vaultRoot = dir.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = try XCTUnwrap(ConversationIndex(
            path: dir.appendingPathComponent("index.sqlite").path))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func claudeLine(uuid: String, role: String, content: String,
                            session: String, minute: Int) -> String {
        let body = role == "user" ? "\"\(content)\"" : "[{\"type\":\"text\",\"text\":\"\(content)\"}]"
        return "{\"type\":\"\(role)\",\"uuid\":\"\(uuid)\",\"cwd\":\"/proj/smoke\",\"sessionId\":\"\(session)\",\"message\":{\"role\":\"\(role)\",\"content\":\(body)},\"timestamp\":\"2026-02-01T00:\(String(format: "%02d", minute)):00Z\"}"
    }

    func testFullProductPromiseChain() async throws {
        // ── 1. 多源采集:Claude 中文场 + Claude 英文场 + Codex 场 ──
        let zhFile = dir.appendingPathComponent("zh.jsonl")
        try [claudeLine(uuid: "z1", role: "user", content: "帮我优化数据库索引的性能瓶颈", session: "smoke-zh", minute: 0),
             claudeLine(uuid: "z2", role: "assistant", content: "先看慢查询日志再定位热点表", session: "smoke-zh", minute: 1)]
            .joined(separator: "\n").write(to: zhFile, atomically: true, encoding: .utf8)

        let enFile = dir.appendingPathComponent("en.jsonl")
        try [claudeLine(uuid: "e1", role: "user", content: "please refactor the authentication middleware", session: "smoke-en", minute: 0),
             claudeLine(uuid: "e2", role: "assistant", content: "extracting the token validation into a helper", session: "smoke-en", minute: 1)]
            .joined(separator: "\n").write(to: enFile, atomically: true, encoding: .utf8)

        let cxFile = dir.appendingPathComponent("rollout-smoke.jsonl")
        try ["{\"type\":\"session_meta\",\"timestamp\":\"2026-02-01T01:00:00.000Z\",\"payload\":{\"id\":\"smoke-cx\",\"cwd\":\"/proj/codex\"}}",
             "{\"timestamp\":\"2026-02-01T01:00:01.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"deploy the staging cluster tonight\"}]}}",
             "{\"timestamp\":\"2026-02-01T01:00:02.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"staging deploy pipeline triggered\"}]}}"]
            .joined(separator: "\n").write(to: cxFile, atomically: true, encoding: .utf8)

        LoaderRuntime.indexRows(urls: [zhFile, enFile], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        LoaderRuntime.indexRows(urls: [cxFile], into: index, source: .codex,
                                makeRow: CodexLoader.indexRow)

        let all = index.allMetadata()
        XCTAssertEqual(all.count, 3, "三场全部入库")
        XCTAssertEqual(Set(all.map(\.source)), [.claudeCode, .codex], "双源共存")

        // ── 2. 双语搜索(BM25 双路):中文命中中文场、英文命中英文场 ──
        let zhHits = index.search("数据库 性能")
        XCTAssertEqual(zhHits.first, "smoke-zh", "中文检索命中中文场")
        let enHits = index.search("authentication middleware")
        XCTAssertEqual(enHits.first, "smoke-en", "英文检索命中英文场")
        let cxHits = index.search("staging cluster")
        XCTAssertEqual(cxHits.first, "smoke-cx", "Codex 内容可检索")

        // ── 3. 详情:完整消息可读 ──
        let detail = ConversationStore.loadFull(id: "smoke-zh", fileURL: zhFile,
                                                source: .claudeCode, vaultRoot: vaultRoot)
        XCTAssertEqual(detail?.messages.count, 2)
        XCTAssertTrue(detail!.messages[0].blocks.contains { $0.plainText.contains("性能瓶颈") })

        // ── 4. Minds:机械层文档产出且计数一致 ──
        MindsBuilder.build(from: index, to: dir.appendingPathComponent("minds.md"))
        let md = try String(contentsOf: dir.appendingPathComponent("minds.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("## OVERVIEW"), "minds.md 应有统计区")
        XCTAssertTrue(md.contains("3 conversations"), "OVERVIEW 计数应为 3 场")

        // ── 5. 归档:sweep 建副本 ──
        let swept = VaultArchive.sweep(paths: [zhFile.path], root: vaultRoot,
                                       now: Date().addingTimeInterval(3600))
        XCTAssertEqual(swept, 1)
        XCTAssertTrue(VaultArchive.hasArchive(sourcePath: zhFile.path, root: vaultRoot))

        // ── 6. 源亡副本活(「模型是租的,对话是你的」的硬承诺) ──
        try FileManager.default.removeItem(at: zhFile)
        let rescued = ConversationStore.loadFull(id: "smoke-zh", fileURL: zhFile,
                                                 source: .claudeCode, vaultRoot: vaultRoot)
        XCTAssertEqual(rescued?.messages.count, 2, "源文件删除后从归档副本完整读回")
        XCTAssertTrue(rescued!.messages[1].blocks.contains { $0.plainText.contains("慢查询") })

        // ── 7. 删除:从 MindBus 抹除 + 不复活 ──
        let store = ConversationStore(indexPath: dir.appendingPathComponent("index.sqlite").path)
        store.setAll(index.allMetadata())
        store.deleteConversation(id: "smoke-en", vaultRoot: vaultRoot)
        XCTAssertEqual(index.allMetadata().count, 2)
        XCTAssertTrue(index.search("authentication middleware").isEmpty, "删除后搜索不再命中")
        LoaderRuntime.indexRows(urls: [enFile], into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
        XCTAssertEqual(index.allMetadata().count, 2, "重扫不复活")
    }
}
