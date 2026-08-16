import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// 思脉底座 · `minds_enrich`：本产品第一个写工具。四步顺序校验（spot → text →
/// sources 存在性 → 落盘），每一步失败都要把话说清；成功路径只写 `enriched.jsonl`
/// 这一个文件，`ConversationIndex` 连接照旧只读。
///
/// 架构红线：全部用 `setenv MINDBUS_MINDS_ROOT` 注入每个测试独立的临时目录
/// （同 `MindsEnrichedLogTests`/`MindsBuilderTests` 的既有隔离手法），绝不碰真实
/// `~/.mindbus`；`MCPRefLog.agentName` 是进程级共享的 static var，改动过的测试
/// 必须在 `tearDown` 里还原。
final class MindsEnrichToolTests: XCTestCase {
    private var tempRoot: String!
    private var originalAgentName: String!

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "minds-enrich-\(UUID().uuidString)"
        setenv("MINDBUS_MINDS_ROOT", tempRoot, 1)
        originalAgentName = MCPRefLog.agentName
    }

    override func tearDown() {
        MCPRefLog.agentName = originalAgentName
        unsetenv("MINDBUS_MINDS_ROOT")
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "minds-enrich-idx-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    /// 造一条最小可用的入库会话，供 `sources` 存在性校验使用（同
    /// `MindsBuilderTests.upsertConversation` 的省事写法：lite + 单段共用同一份占位文字，
    /// 这些测试不关心检索口径，只关心"这个 id 在索引里查得到"）。
    @discardableResult
    private func upsertConversation(_ index: ConversationIndex, id: String) throws -> ConversationLite {
        let lite = ConversationLite(id: id, source: .codex, startAt: Date(), endAt: Date(),
                                    cwd: "/p", gitBranch: nil, preview: "p", messageCount: 1,
                                    fileURL: URL(fileURLWithPath: "/tmp/minds-enrich-\(id).jsonl"))
        try index.upsert([(lite, [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "占位文字")],
                           1, "占位文字")])
        return lite
    }

    // MARK: - 1. spot 校验

    func testInvalidSpotListsAllValidValues() throws {
        let index = try makeIndex()
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:nope", "text": "t", "sources": ["c1"]], index)
        XCTAssertTrue(out.isError)
        for value in MindsSpot.allCases.map(\.rawValue) {
            XCTAssertTrue(out.text.contains(value), "错误信息缺 \(value)")
        }
    }

    func testMissingSpotKeyIsToolError() throws {
        let index = try makeIndex()
        let out = MindsEnrichTool.spec.run(["text": "t", "sources": ["c1"]], index)
        XCTAssertTrue(out.isError)
    }

    // MARK: - 2. text 校验

    func testEmptyTextAfterTrimIsToolError() throws {
        let index = try makeIndex()
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "   \n  ", "sources": ["c1"]], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("text"))
    }

    func testMissingTextKeyIsToolError() throws {
        let index = try makeIndex()
        let out = MindsEnrichTool.spec.run(["spot": "spot:goals", "sources": ["c1"]], index)
        XCTAssertTrue(out.isError)
    }

    func testOverlongTextIsToolError() throws {
        let index = try makeIndex()
        let long = String(repeating: "字", count: MindsEnrichTool.maxTextLength + 1)
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": long, "sources": ["c1"]], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("\(MindsEnrichTool.maxTextLength)"))
    }

    /// 恰好 2000 字（trim 之后）必须被接受——边界不是 off-by-one。
    func testExactlyMaxLengthTextIsAccepted() throws {
        let index = try makeIndex()
        let real = try upsertConversation(index, id: "c1")
        let text = String(repeating: "字", count: MindsEnrichTool.maxTextLength)
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": text, "sources": [real.id]], index)
        XCTAssertFalse(out.isError, "恰好上限字数应被接受")
    }

    // MARK: - 3. sources 校验（反幻觉守卫 + 变异反证）

    func testEmptySourcesArrayIsToolError() throws {
        let index = try makeIndex()
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "t", "sources": [] as [String]], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("sources"))
    }

    func testMissingSourcesKeyIsToolError() throws {
        let index = try makeIndex()
        let out = MindsEnrichTool.spec.run(["spot": "spot:goals", "text": "t"], index)
        XCTAssertTrue(out.isError)
    }

    func testAllSourcesMissingListsAllOfThem() throws {
        let index = try makeIndex()
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "t", "sources": ["ghost-1", "ghost-2"]], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("ghost-1"))
        XCTAssertTrue(out.text.contains("ghost-2"))
    }

    /// 变异反证核心：sources 部分存在时必须仍然整体拒绝，且明确点名不存在的那个 id
    /// （不是存在的那个）。若实现被改成"至少一个存在即可通过"，这条测试必须变红——
    /// 见 task-3-report.md 的变异反证记录。
    func testPartiallyMissingSourcesIsRejectedAndNamesOnlyTheMissingOne() throws {
        let index = try makeIndex()
        let real = try upsertConversation(index, id: "real-conv")
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "t", "sources": [real.id, "ghost-id"]], index)
        XCTAssertTrue(out.isError, "部分存在也必须整体拒绝——反幻觉守卫容不下一个假 id")
        XCTAssertTrue(out.text.contains("ghost-id"), "必须点名不存在的那个 id")
        XCTAssertFalse(out.text.contains("real-conv"), "不该把真实存在的 id 也列进缺失名单")

        // 该失败路径不能有任何副作用——没有 enrich 记录被写下。
        XCTAssertEqual(MindsEnrichedLog.entries().count, 0, "校验失败不该留下任何记录")
    }

    func testAllSourcesExistingSucceeds() throws {
        let index = try makeIndex()
        let a = try upsertConversation(index, id: "conv-a")
        let b = try upsertConversation(index, id: "conv-b")
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "t", "sources": [a.id, b.id]], index)
        XCTAssertFalse(out.isError)
    }

    // MARK: - 4. 落盘失败

    /// 让 minds 根目录路径本身已经是一个普通文件（不是目录）——`appendEnrich` 内部
    /// `createDirectory` 会失败（`try?` 吞掉），随后 POSIX `open(2)` 在这个路径下打不开
    /// 文件描述符（父路径分量不是目录，ENOTDIR），`writeLine` 返回 false、`appendEnrich`
    /// 返回 nil——这一步必须变成 isError，不能被静默吞掉（enrich 是用户可感动作，
    /// 与 `MCPRefLog.append`"引用计数丢一条无所谓"的静默吞错刻意不同，
    /// `MindsEnrichedLog` 类文档注释里明确写过这个区别）。
    func testWriteFailureIsToolError() throws {
        let blockingPath = NSTemporaryDirectory() + "minds-enrich-blocked-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: blockingPath, contents: Data("x".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: blockingPath) }
        setenv("MINDBUS_MINDS_ROOT", blockingPath, 1)   // 覆盖 setUp 里设的临时目录

        let index = try makeIndex()
        let real = try upsertConversation(index, id: "c1")
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "t", "sources": [real.id]], index)
        XCTAssertTrue(out.isError, "写盘失败必须报 isError，不能假装成功")
    }

    // MARK: - 5. 成功路径

    func testSuccessReturnsNewEntryIdUnreviewedNoteAndAppMention() throws {
        let index = try makeIndex()
        let real = try upsertConversation(index, id: "c1")
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "推 v1 发布", "sources": [real.id]], index)
        XCTAssertFalse(out.isError)

        let entries = MindsEnrichedLog.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.status, .unreviewed)
        XCTAssertEqual(entry.spot, .goals)
        XCTAssertEqual(entry.text, "推 v1 发布")
        XCTAssertEqual(entry.sources, [real.id])

        XCTAssertTrue(out.text.contains(entry.id), "回复必须带上新条目 id")
        XCTAssertTrue(out.text.lowercased().contains("unreviewed"))
        XCTAssertTrue(out.text.lowercased().contains("app"), "必须提到用户能在 MindBus app 里确认/撤销")
    }

    /// agent 字段取 `MCPRefLog.agentName`（initialize 握手时记下的宿主名）。
    func testSuccessWritesAgentFieldFromMCPRefLogAgentName() throws {
        MCPRefLog.agentName = "test-agent-xyz"
        let index = try makeIndex()
        let real = try upsertConversation(index, id: "c1")
        let out = MindsEnrichTool.spec.run(
            ["spot": "spot:style", "text": "t", "sources": [real.id]], index)
        XCTAssertFalse(out.isError)
        let entry = try XCTUnwrap(MindsEnrichedLog.entries().first)
        XCTAssertEqual(entry.agent, "test-agent-xyz")
    }

    /// text 落盘前必须是 trim 过的版本，不是带首尾空白的原始输入。
    func testStoredTextIsTrimmed() throws {
        let index = try makeIndex()
        let real = try upsertConversation(index, id: "c1")
        _ = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "  推 v1 发布  \n", "sources": [real.id]], index)
        let entry = try XCTUnwrap(MindsEnrichedLog.entries().first)
        XCTAssertEqual(entry.text, "推 v1 发布")
    }

    /// `sources` 落盘顺序与入参顺序一致（不是排序过的、也不是去重过的）。
    func testStoredSourcesPreserveInputOrder() throws {
        let index = try makeIndex()
        let a = try upsertConversation(index, id: "conv-a")
        let b = try upsertConversation(index, id: "conv-b")
        _ = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "t", "sources": [b.id, a.id]], index)
        let entry = try XCTUnwrap(MindsEnrichedLog.entries().first)
        XCTAssertEqual(entry.sources, [b.id, a.id])
    }

    // MARK: - 只写 enriched.jsonl（索引与 minds.md 都不受影响）

    func testEnrichNeverWritesMindsMdFile() throws {
        let index = try makeIndex()
        let real = try upsertConversation(index, id: "c1")
        _ = MindsEnrichTool.spec.run(
            ["spot": "spot:goals", "text": "t", "sources": [real.id]], index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MindsBuilder.defaultMindsURL.path),
                       "minds_enrich 只写 enriched.jsonl，不该顺手碰 minds.md")
    }

    // MARK: - 注册 / schema

    func testInputSchemaHasAllThreeRequiredParams() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_enrich" })
        let properties = try XCTUnwrap(spec.inputSchema["properties"] as? [String: Any])
        for key in ["spot", "text", "sources"] { XCTAssertNotNil(properties[key], "schema 缺 \(key)") }
        XCTAssertEqual(spec.inputSchema["required"] as? [String], ["spot", "text", "sources"])
    }

    func testSourcesSchemaIsAnArrayOfStrings() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_enrich" })
        let properties = try XCTUnwrap(spec.inputSchema["properties"] as? [String: Any])
        let sources = try XCTUnwrap(properties["sources"] as? [String: Any])
        XCTAssertEqual(sources["type"] as? String, "array")
        let items = try XCTUnwrap(sources["items"] as? [String: Any])
        XCTAssertEqual(items["type"] as? String, "string")
    }

    /// `inputSchema` 要经 `JSONSerialization` 序列化进 `tools/list` 的响应——同
    /// `MemoryOpenToolTests.testInputSchemaIsValidJSON` 的既有惯例。
    func testInputSchemaIsValidJSON() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_enrich" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema))
    }

    func testDescriptionMentionsMindsReadLoop() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_enrich" })
        XCTAssertTrue(spec.description.contains("minds_read"))
    }
}
