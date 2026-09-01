import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// 思脉底座 · `minds_read`：只读工具，把 `MindsBuilder` 落盘的 `minds.md` 原样交给
/// 宿主模型。增补层（WEAK SPOTS / minds_enrich）已整体拆除（用户 2026-09-01 定案：
/// 不要例外）——工具退回纯文件读取，唯一的加工是截掉**旧版本文件**遗留的 WEAK SPOTS
/// 节（`stripLegacyWeakSpots`），不让拆除前模型写入的条目继续漏给宿主。
///
/// 架构红线：`MindsReadTool.mindsFileURL` 与 `MINDBUS_MINDS_ROOT` 双重注入，确保
/// 工具读的文件路径落在每个测试独立的临时目录下——绝不碰真实 `~/.mindbus`
/// （同 `MindsBuilderTests` 的隔离手法）。
final class MindsReadToolTests: XCTestCase {

    private var tempRoot: String!
    private var mindsURL: URL!
    private var originalMindsFileURL: (() -> URL)!

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "minds-read-\(UUID().uuidString)"
        setenv("MINDBUS_MINDS_ROOT", tempRoot, 1)
        mindsURL = URL(fileURLWithPath: tempRoot + "/minds.md")
        let url = mindsURL!
        originalMindsFileURL = MindsReadTool.mindsFileURL
        MindsReadTool.mindsFileURL = { url }
    }

    override func tearDown() {
        MindsReadTool.mindsFileURL = originalMindsFileURL
        unsetenv("MINDBUS_MINDS_ROOT")
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "minds-read-idx-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    // MARK: - 缺文件

    func testMissingFileReturnsActionablePrompt() throws {
        let out = MindsReadTool.spec.run([:], try makeIndex())
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.lowercased().contains("open the mindbus app"),
                      "缺文件必须给出可执行提示，照 MCPIndexAccess 的既有惯例")
    }

    // MARK: - 全文机械、无增补节

    /// build 出来的文件必须整份返回，且不再含任何 WEAK SPOTS/minds_enrich 痕迹。
    func testReadReturnsMechanicalDocumentWithoutWeakSpots() throws {
        let index = try makeIndex()
        MindsBuilder.build(from: index, to: mindsURL)
        let out = MindsReadTool.spec.run([:], index)
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.text.contains("## OVERVIEW"))
        XCTAssertTrue(out.text.contains("0 conversations across 0 tools."))
        XCTAssertTrue(out.text.contains("## VOCABULARY"))
        XCTAssertFalse(out.text.contains("WEAK SPOTS"), "增补节已拆除，build 不该再写")
        XCTAssertFalse(out.text.contains("minds_enrich"), "文档里不该再引导 enrich 管道")
    }

    /// 空文件（存在但零字节——比如上一次写入被中断）不该被当成"文件不存在"报错。
    func testEmptyFileIsNotAnError() throws {
        try FileManager.default.createDirectory(at: mindsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mindsURL.path, contents: Data())

        let out = MindsReadTool.spec.run([:], try makeIndex())
        XCTAssertFalse(out.isError)
    }

    // MARK: - 旧文件遗留 WEAK SPOTS 的截断（stripLegacyWeakSpots 纯函数）

    /// 装上新版后、下一轮扫描重写 minds.md 之前的窗口期：旧文件里模型写的条目
    /// 必须被截掉，机械层一字节不动。
    func testLegacyWeakSpotsSectionIsStrippedFromOldFiles() throws {
        try FileManager.default.createDirectory(at: mindsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let legacy = "MECHANICAL-CONTENT\n\n\(MindsBuilder.legacyWeakSpotsMarker)\n## WEAK SPOTS\n- [unreviewed] MODEL-WRITTEN-TEXT"
        try Data(legacy.utf8).write(to: mindsURL)

        let out = MindsReadTool.spec.run([:], try makeIndex())
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.text.contains("MECHANICAL-CONTENT"), "标记之前的机械层必须保留")
        XCTAssertFalse(out.text.contains("MODEL-WRITTEN-TEXT"), "拆除前模型写入的条目不得漏出")
        XCTAssertFalse(out.text.contains("WEAK SPOTS"))
    }

    /// 无标记的（新版/手改）文件：原样返回，一字节不改。
    func testFileWithoutMarkerIsReturnedVerbatim() {
        let handMade = "# Some hand-edited Minds file\nno marker here at all\n"
        XCTAssertEqual(MindsReadTool.stripLegacyWeakSpots(handMade), handMade)
    }

    // MARK: - 注册 / schema / instructions

    func testCatalogIsFiveReadOnlyTools() {
        XCTAssertEqual(MCPToolCatalog.all.map(\.name),
                       ["memory_search", "memory_browse", "memory_open", "memory_digest",
                        "minds_read"])
    }

    func testInputSchemaIsValidJSONWithNoRequiredParams() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_read" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema))
        // 同 `MemoryBrowseTool` 的既有惯例（该工具的可选参数也是 `"required": []`，
        // 不是整个省略这个键）：无参工具的 required 列表是空数组，不是 nil。
        XCTAssertEqual(spec.inputSchema["required"] as? [String], [])
    }

    /// 增补管道拆除后，工具描述与 server 自述里不得再出现 minds_enrich 的引导——
    /// 说明书是检索系统的一部分，残留的引导会让宿主模型去调一个不存在的工具。
    func testDescriptionAndInstructionsDropEnrichReferences() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_read" })
        XCTAssertFalse(spec.description.contains("minds_enrich"))
        XCTAssertTrue(MCPServer.instructions.contains("minds_read"))
        XCTAssertFalse(MCPServer.instructions.contains("minds_enrich"))
        XCTAssertTrue(MCPServer.instructions.contains("read-only"))
    }
}
