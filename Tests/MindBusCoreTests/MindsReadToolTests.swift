import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// 思脉底座 · `minds_read`：只读工具，读 `MindsBuilder` 落盘的 `minds.md`，现场用
/// `MindsEnrichedLog.entries()` 重渲染 WEAK SPOTS——保证读到的增补永远比磁盘快照
/// 新鲜（`build` 只在扫描收尾重建一次，两者之间必然有窗口期，本文件的核心判别
/// 测试 `testReadReflectsEnrichAppendedAfterBuild` 就是验证这条窗口期不会让
/// `minds_read` 读到过期数据）。
///
/// 架构红线：`MindsReadTool.mindsFileURL` 与 `MINDBUS_MINDS_ROOT` 双重注入，确保
/// 工具本身读的文件路径与 `merge` 内部默认调用的 `MindsEnrichedLog.entries()` 都
/// 落在每个测试独立的临时目录下——绝不碰真实 `~/.mindbus`（同 `MindsBuilderTests`
/// 的隔离手法：那边的类文档注释解释过为什么哪怕只关心机械层也必须做这层隔离）。
final class MindsReadToolTests: XCTestCase {
    /// 收藏文件隔离路径（不存在 → STARRED 空态）——build 不得读真实 ~/.mindbus。
    private let isolatedStarredURL = URL(fileURLWithPath:
        NSTemporaryDirectory() + "minds-starred-absent-\(UUID().uuidString).json")

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

    // MARK: - 现场重合并（核心判别测试）

    /// 先 build 一份 minds.md（此时 enriched.jsonl 不存在，WEAK SPOTS 四个空位全空）→
    /// 不经过 minds_enrich 工具、直接往 enriched.jsonl 追加一条 enrich 记录（模拟
    /// "两次扫描之间某个宿主写入了新的增补"）→ minds_read 必须反映这条新条目，即便
    /// 磁盘上的 minds.md 字节从未被重新 build 过。
    func testReadReflectsEnrichAppendedAfterBuild() throws {
        let index = try makeIndex()
        MindsBuilder.build(from: index, to: mindsURL)
        let builtContent = try String(contentsOf: mindsURL, encoding: .utf8)
        XCTAssertEqual(builtContent.components(separatedBy: "(empty — fill via minds_enrich)").count - 1,
                       4, "前提：build 时 enriched.jsonl 还不存在，WEAK SPOTS 应四个空位全空")

        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "FRESH-ENRICH-MARKER-TEXT", sources: ["c1"], agent: "claude-code"))

        let out = MindsReadTool.spec.run([:], index)
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.text.contains("FRESH-ENRICH-MARKER-TEXT"),
                      "minds_read 必须现算 WEAK SPOTS，不能只读磁盘上过期的 minds.md 字节")
        XCTAssertTrue(out.text.contains("[unreviewed] FRESH-ENRICH-MARKER-TEXT"))
        XCTAssertEqual(out.text.components(separatedBy: "(empty — fill via minds_enrich)").count - 1, 3,
                       "goals 已被填，读出来应只剩 3 个空位，不是磁盘快照里的 4 个")
        XCTAssertTrue(out.text.contains(MindsBuilder.weakSpotsMarker), "分隔标记应保留")
        _ = id
    }

    /// 机械五节（OVERVIEW 等）原样来自磁盘——minds_read 不重新跑一遍索引统计，
    /// 只是替换 WEAK SPOTS 那一段。
    func testReadPreservesMechanicalSectionsVerbatimFromDisk() throws {
        let index = try makeIndex()
        MindsBuilder.build(from: index, to: mindsURL)
        let out = MindsReadTool.spec.run([:], index)
        XCTAssertTrue(out.text.contains("## OVERVIEW"))
        XCTAssertTrue(out.text.contains("0 conversations across 0 tools."))
        XCTAssertTrue(out.text.contains("## AGENT USAGE"))
    }

    // MARK: - 标记缺失降级

    /// 旧版本遗留文件 / 被用户手改删掉了那一行——`weakSpotsMarker` 找不到时必须
    /// 降级而不是崩：整份内容原样返回，末尾追加现算的 WEAK SPOTS。
    func testMissingMarkerDegradesGracefullyInsteadOfCrashing() throws {
        try FileManager.default.createDirectory(at: mindsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let handMade = "# Some hand-edited Minds file\nno marker here at all\n"
        try Data(handMade.utf8).write(to: mindsURL)

        let out = MindsReadTool.spec.run([:], try makeIndex())
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.text.hasPrefix(handMade), "原有机械层内容必须原样保留，一字节不改")
        XCTAssertTrue(out.text.contains("## WEAK SPOTS"), "必须仍然追加现算的 WEAK SPOTS")
        XCTAssertEqual(out.text.components(separatedBy: "(empty — fill via minds_enrich)").count - 1, 4)
    }

    /// 空文件（存在但零字节——比如上一次写入被中断）同样按"标记找不到"降级，
    /// 不该被当成"文件不存在"报错，也不该崩在空字符串的 range(of:) 上。
    func testEmptyFileDegradesGracefully() throws {
        try FileManager.default.createDirectory(at: mindsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mindsURL.path, contents: Data())

        let out = MindsReadTool.spec.run([:], try makeIndex())
        XCTAssertFalse(out.isError)
        XCTAssertTrue(out.text.contains("## WEAK SPOTS"))
    }

    // MARK: - merge 纯函数（不落盘，直接驱动)

    func testMergeReplacesWeakSpotsSectionOnly() {
        let disk = "MECHANICAL\n\n\(MindsBuilder.weakSpotsMarker)\nSTALE WEAK SPOTS TEXT"
        let fresh = MindsEntry(id: "e1", spot: .goals, text: "FRESH-TEXT", sources: ["c1"],
                               agent: "a", createdAt: Date(), status: .unreviewed)
        let out = MindsReadTool.merge(content: disk, entries: [fresh])
        XCTAssertTrue(out.contains("MECHANICAL"), "标记之前的内容必须保留")
        XCTAssertFalse(out.contains("STALE WEAK SPOTS TEXT"), "标记之后的旧内容必须被替换掉")
        XCTAssertTrue(out.contains("FRESH-TEXT"))
    }

    // MARK: - 注册 / schema / instructions

    func testCatalogContainsMindsReadAfterDigest() {
        XCTAssertEqual(MCPToolCatalog.all.map(\.name),
                       ["memory_search", "memory_browse", "memory_open", "memory_digest",
                        "minds_read", "minds_enrich"])
    }

    func testInputSchemaIsValidJSONWithNoRequiredParams() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_read" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema))
        // 同 `MemoryBrowseTool` 的既有惯例（该工具的可选参数也是 `"required": []`，
        // 不是整个省略这个键）：无参工具的 required 列表是空数组，不是 nil。
        XCTAssertEqual(spec.inputSchema["required"] as? [String], [])
    }

    func testDescriptionMentionsEnrichLoop() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "minds_read" })
        XCTAssertTrue(spec.description.contains("minds_enrich"))
        XCTAssertTrue(spec.description.contains("memory_search") || spec.description.contains("memory_digest"))
    }

    func testInstructionsMentionMindsReadAndEnrich() {
        XCTAssertTrue(MCPServer.instructions.contains("minds_read"))
        XCTAssertTrue(MCPServer.instructions.contains("minds_enrich"))
    }
}
