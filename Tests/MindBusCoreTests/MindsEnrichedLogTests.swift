import XCTest
@testable import MindBusCore

/// 思脉底座 · 增补层：`enriched.jsonl` 的三种 append 记录（enrich/confirm/revoke）
/// 与状态合并。架构红线：这一层只管文件读写与合并，不碰索引、不碰 LLM——
/// 全部用注入的临时 URL，绝不碰真实 `~/.mindbus`（`MindsEnrichedLog` 的每个公开
/// 函数都接受显式 `url`/`to` 参数，生产默认值只在环境变量测试里以字符串形式核对，
/// 从不实际触发文件 I/O）。
final class MindsEnrichedLogTests: XCTestCase {
    private var logURL: URL!

    override func setUpWithError() throws {
        logURL = URL(fileURLWithPath: NSTemporaryDirectory()
            + "minds-enriched-\(UUID().uuidString)/enriched.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
    }

    /// 从原始文件内容里取最后一行解析成的 JSON 字典，用于断言落盘的行形状。
    private func lastLineObject() throws -> [String: Any] {
        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        return try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(lines.last!.utf8)) as? [String: Any])
    }

    // MARK: - append：行 JSON 合法且字段齐（spec §3 三种记录 schema）

    /// 目录首次不存在（全新用户/全新临时路径）——appendEnrich 前必须先建目录，
    /// 而不是静默失败。这条测试同时验证了这个目录会被自动建出来。
    func testAppendEnrichCreatesMissingDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.deletingLastPathComponent().path))
        let id = MindsEnrichedLog.appendEnrich(spot: .goals, text: "ship v1", sources: ["conv-1"],
                                               agent: "claude-code", to: logURL)
        XCTAssertNotNil(id, "目录不存在不该导致写入失败")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testAppendEnrichWritesLineWithAllFields() throws {
        let ts = Date(timeIntervalSince1970: 1_786_000_000)
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "推 v1 发布", sources: ["conv-1", "conv-2"],
            agent: "claude-code", at: ts, to: logURL))

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "应恰好一行")

        let obj = try lastLineObject()
        XCTAssertEqual(obj["kind"] as? String, "enrich")
        XCTAssertEqual(obj["id"] as? String, id)
        XCTAssertEqual(obj["spot"] as? String, "spot:goals")
        XCTAssertEqual(obj["text"] as? String, "推 v1 发布")
        XCTAssertEqual(obj["sources"] as? [String], ["conv-1", "conv-2"])
        XCTAssertEqual(obj["agent"] as? String, "claude-code")
        XCTAssertEqual(obj["ts"] as? Double, 1_786_000_000)
    }

    func testAppendRevokeWritesLineWithTargetAndTs() throws {
        MindsEnrichedLog.appendRevoke(target: "some-id", at: Date(timeIntervalSince1970: 1_000), to: logURL)
        let obj = try lastLineObject()
        XCTAssertEqual(obj["kind"] as? String, "revoke")
        XCTAssertEqual(obj["target"] as? String, "some-id")
        XCTAssertEqual(obj["ts"] as? Double, 1_000)
    }

    func testAppendConfirmWritesLineWithTargetAndTs() throws {
        MindsEnrichedLog.appendConfirm(target: "some-id", at: Date(timeIntervalSince1970: 2_000), to: logURL)
        let obj = try lastLineObject()
        XCTAssertEqual(obj["kind"] as? String, "confirm")
        XCTAssertEqual(obj["target"] as? String, "some-id")
        XCTAssertEqual(obj["ts"] as? Double, 2_000)
    }

    /// appendRevoke/appendConfirm 报告写入成功——不是只在 appendEnrich 上验证返回值。
    func testAppendRevokeAndConfirmReturnTrueOnSuccess() {
        XCTAssertTrue(MindsEnrichedLog.appendRevoke(target: "x", to: logURL))
        XCTAssertTrue(MindsEnrichedLog.appendConfirm(target: "x", to: logURL))
    }

    // MARK: - id 唯一性

    func testAppendEnrichReturnsUniqueIDs() {
        let ids = (0..<50).compactMap { i in
            MindsEnrichedLog.appendEnrich(spot: .stack, text: "t\(i)", sources: ["c"], agent: "a", to: logURL)
        }
        XCTAssertEqual(ids.count, 50)
        XCTAssertEqual(Set(ids).count, 50, "50 次 appendEnrich 必须产生 50 个不同的 id")
    }

    // MARK: - entries：缺文件

    func testEntriesReturnsEmptyArrayWhenFileMissing() {
        XCTAssertEqual(MindsEnrichedLog.entries(from: logURL), [])
    }

    // MARK: - entries：合并三态

    func testMergeDefaultsToUnreviewed() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .preferences, text: "喜欢直接执行", sources: ["c1"], agent: "a", to: logURL))
        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, id)
        XCTAssertEqual(entries[0].status, .unreviewed)
    }

    func testMergeConfirmedAfterConfirm() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .style, text: "review 喜欢逐条过", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendConfirm(target: id, to: logURL)
        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .confirmed)
    }

    func testMergeRevokedAfterRevoke() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .stack, text: "主力 TypeScript", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendRevoke(target: id, to: logURL)
        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .revoked)
    }

    /// 合并后的其余字段（spot/text/sources/agent/createdAt）要原样带出来，
    /// 不只是 status 对——上层（GUI/minds_read）要靠这些字段渲染整条增补。
    func testMergePreservesAllFieldsAlongsideStatus() throws {
        let ts = Date(timeIntervalSince1970: 1_786_500_000)
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "在推思脉底座", sources: ["conv-a", "conv-b"],
            agent: "codex", at: ts, to: logURL))
        MindsEnrichedLog.appendConfirm(target: id, to: logURL)

        let entry = try XCTUnwrap(MindsEnrichedLog.entries(from: logURL).first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.spot, .goals)
        XCTAssertEqual(entry.text, "在推思脉底座")
        XCTAssertEqual(entry.sources, ["conv-a", "conv-b"])
        XCTAssertEqual(entry.agent, "codex")
        XCTAssertEqual(entry.createdAt.timeIntervalSince1970, 1_786_500_000, accuracy: 0.001)
        XCTAssertEqual(entry.status, .confirmed)
    }

    // MARK: - revoke 终态

    /// spec 字面例子：确认过再撤销 = 撤销。这是 revoke 终态规则的标准场景，
    /// 也是下面「变异反证」要打中的行为——见 task-1-report.md。
    func testRevokeIsTerminalAfterConfirm() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "t", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendConfirm(target: id, to: logURL)
        MindsEnrichedLog.appendRevoke(target: id, to: logURL)

        let entry = try XCTUnwrap(MindsEnrichedLog.entries(from: logURL).first)
        XCTAssertEqual(entry.status, .revoked, "confirm 后 revoke 必须终止在 revoked")
    }

    /// 反向顺序：先 revoke 再 confirm。revoke 是吸收态——不管相对顺序如何，
    /// 只要出现过 revoke，最终状态都不该被后来的 confirm 复活。spec 原文只举了
    /// 「confirm 后 revoke」的例子，这条测试把「终态」的字面意思坐实到另一个方向，
    /// 防止实现退化成「文件里最后一条记录说了算」的顺序敏感逻辑。
    func testRevokeIsTerminalBeforeConfirm() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "t", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendRevoke(target: id, to: logURL)
        MindsEnrichedLog.appendConfirm(target: id, to: logURL)

        let entry = try XCTUnwrap(MindsEnrichedLog.entries(from: logURL).first)
        XCTAssertEqual(entry.status, .revoked, "revoke 后 confirm 不能把状态翻回 confirmed")
    }

    // MARK: - 未知 target 与重复记录

    func testConfirmForUnknownTargetIsIgnored() {
        MindsEnrichedLog.appendConfirm(target: "no-such-id", to: logURL)
        XCTAssertEqual(MindsEnrichedLog.entries(from: logURL), [],
                       "未知 target 的 confirm 不该凭空造出一条")
    }

    func testRevokeForUnknownTargetIsIgnored() {
        MindsEnrichedLog.appendRevoke(target: "no-such-id", to: logURL)
        XCTAssertEqual(MindsEnrichedLog.entries(from: logURL), [],
                       "未知 target 的 revoke 不该凭空造出一条")
    }

    func testDuplicateConfirmIsIdempotent() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "t", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendConfirm(target: id, to: logURL)
        MindsEnrichedLog.appendConfirm(target: id, to: logURL)
        MindsEnrichedLog.appendConfirm(target: id, to: logURL)

        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.count, 1, "重复 confirm 不该产生多条")
        XCTAssertEqual(entries[0].status, .confirmed)
    }

    func testDuplicateRevokeIsIdempotent() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "t", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendRevoke(target: id, to: logURL)
        MindsEnrichedLog.appendRevoke(target: id, to: logURL)

        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.count, 1, "重复 revoke 不该产生多条")
        XCTAssertEqual(entries[0].status, .revoked)
    }

    // MARK: - 坏行与非法 UTF-8

    /// 坏行（半截 JSON、空行、完全非 JSON、未知 kind、非法 spot 枚举值）跳过，
    /// 不炸、不影响好行——同 `MCPRefLogTests.testIngestSkipsCorruptLines` 的构造。
    func testEntriesSkipsCorruptLines() throws {
        let idGood1 = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "good-1", sources: ["c1"], agent: "a", to: logURL))

        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        handle.write(Data("{\"kind\": \"enrich\", \"id\":\n".utf8))            // 半截 JSON
        handle.write(Data("\n".utf8))                                          // 空行
        handle.write(Data("not even json\n".utf8))                             // 完全不是 JSON
        handle.write(Data("{\"kind\":\"teleport\",\"id\":\"x\"}\n".utf8))      // 未知 kind
        handle.write(Data(
            "{\"kind\":\"enrich\",\"id\":\"bad-spot\",\"spot\":\"spot:nope\",\"text\":\"t\",\"sources\":[],\"agent\":\"a\",\"ts\":1}\n"
                .utf8))                                                        // 非法 spot 枚举值
        try handle.close()

        let idGood2 = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "good-2", sources: ["c1"], agent: "a", to: logURL))

        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.map(\.id).sorted(), [idGood1, idGood2].sorted())
        XCTAssertEqual(Set(entries.map(\.text)), ["good-1", "good-2"])
    }

    /// 非法 UTF-8 字节（比如崩溃在 append 半途留下的截断多字节序列）只废掉
    /// 所在行，绝不能废掉整个文件——同
    /// `MCPRefLogTests.testIngestSurvivesInvalidUTF8Byte` 的构造与理由：
    /// 可失败的 `String(data:encoding:)` 遇到一个坏字节就让整个文件解码为 nil，
    /// 而 append-only 日志永不自愈，此后每次合并都会把这段历史清零。
    func testEntriesSurvivesInvalidUTF8Byte() throws {
        let idBefore = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "before", sources: ["c1"], agent: "a", to: logURL))

        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        handle.write(Data([0x7B, 0xFF, 0xFE, 0x0A]))   // "{" + 非法 UTF-8 字节 + 换行
        try handle.close()

        let idAfter = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "after", sources: ["c1"], agent: "a", to: logURL))

        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.map(\.id).sorted(), [idBefore, idAfter].sorted())
        XCTAssertEqual(Set(entries.map(\.text)), ["before", "after"])
    }

    // MARK: - 并发压力

    /// 自查点：多线程模拟「GUI App 与某个宿主拉起的 MCP server 同时 append」，
    /// 每一行必须仍是独立可解析的合法 JSON——不撕裂、不吞掉、不覆盖。
    /// 这是 `writeLine` 选择 POSIX `open(O_APPEND)` 而不是
    /// `FileHandle(forWritingTo:) + seekToEnd()` 的全部理由，必须有一个测试真正在
    /// 并发下验证，不能只停在注释里的论证（照抄
    /// `MCPRefLogTests.testConcurrentAppendsDoNotTearLines` 的模式：线程级并发
    /// 压出的竞态窗口与多进程并发一致，且在 CI 里更快、更容易稳定复现）。
    func testConcurrentAppendEnrichDoesNotTearLines() throws {
        let writers = 8
        let perWriter = 50
        DispatchQueue.concurrentPerform(iterations: writers) { w in
            for i in 0..<perWriter {
                MindsEnrichedLog.appendEnrich(spot: .goals, text: "w\(w)-\(i)",
                                              sources: ["c"], agent: "a", to: logURL)
            }
        }

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, writers * perWriter,
                       "行数应恰好等于总写入次数——多一行说明有撕裂，少一行说明有覆盖")

        var texts = Set<String>()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let text = obj["text"] as? String else {
                return XCTFail("并发写入产生了无法解析的行：\(line)")
            }
            texts.insert(text)
        }
        XCTAssertEqual(texts.count, writers * perWriter, "每一行都必须是独立完整的记录，不能有重复或合并")

        // 合并层也要能在这份并发产物上正常工作：行数守恒、id 各不相同。
        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.count, writers * perWriter)
        XCTAssertEqual(Set(entries.map(\.id)).count, writers * perWriter)
    }

    /// 同一份文件上混合三种记录类型并发 append（不只是 enrich 单一路径）——
    /// 三个公开函数共用同一个 `writeLine`，这条测试确认那个共用路径在混合负载下
    /// 依然不撕裂：先串行造出已知 id，再并发对它们做 confirm/revoke，最后
    /// 检查每个 id 都恰好被处理成 revoked（每个 id 被分到 confirm 或 revoke 之一，
    /// 不会两个都收到——用 id 的奇偶分组，避免「同一个 id 同时收到 confirm 和
    /// revoke」这种依赖具体调度顺序才能判定结果的写法）。
    func testConcurrentMixedAppendKindsDoNotTearLines() throws {
        let ids = (0..<40).compactMap { i in
            MindsEnrichedLog.appendEnrich(spot: .stack, text: "seed-\(i)", sources: ["c"],
                                          agent: "a", to: logURL)
        }
        XCTAssertEqual(ids.count, 40)

        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            if i.isMultiple(of: 2) {
                MindsEnrichedLog.appendConfirm(target: ids[i], to: logURL)
            } else {
                MindsEnrichedLog.appendRevoke(target: ids[i], to: logURL)
            }
        }

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 40 + 40, "40 条 enrich + 40 条 confirm/revoke，一行都不能少或多")

        let entries = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(entries.count, 40)
        for (i, id) in ids.enumerated() {
            let entry = try XCTUnwrap(entries.first(where: { $0.id == id }))
            XCTAssertEqual(entry.status, i.isMultiple(of: 2) ? .confirmed : .revoked)
        }
    }

    // MARK: - MINDBUS_MINDS_ROOT 环境变量覆盖

    /// 照 `MCPProtocolTests.testIndexPathHonorsEnvironmentOverride` 的模式：
    /// setenv 覆盖 + addTeardownBlock 复原，断言 `defaultLogURL` 落在覆盖目录下。
    func testMindsRootEnvironmentOverride() {
        setenv("MINDBUS_MINDS_ROOT", "/tmp/mindbus-minds-root-override-test", 1)
        addTeardownBlock { unsetenv("MINDBUS_MINDS_ROOT") }
        XCTAssertEqual(MindsEnrichedLog.defaultLogURL.path,
                       "/tmp/mindbus-minds-root-override-test/enriched.jsonl")
    }

    /// `~` 必须展开——这个值多半来自宿主配置文件而非 shell，shell 的波浪号展开
    /// 不会发生，原样传给 FileManager 会被当成字面量目录名，永远解析不到真实路径。
    func testMindsRootEnvironmentOverrideExpandsTilde() {
        setenv("MINDBUS_MINDS_ROOT", "~/mindbus-minds-tilde-test", 1)
        addTeardownBlock { unsetenv("MINDBUS_MINDS_ROOT") }
        let path = MindsEnrichedLog.defaultLogURL.path
        XCTAssertFalse(path.hasPrefix("~"), "波浪号必须被展开：\(path)")
        XCTAssertTrue(path.hasSuffix("/mindbus-minds-tilde-test/enriched.jsonl"))
    }

    /// 纯空白 override 等同于未设置——不 trim 的话会原样喂进路径，产出一个
    /// 谁也解析不到的诡异目录。回落到真实默认值（只做字符串比对，不触发任何
    /// 文件 I/O，所以不会碰到真实 `~/.mindbus`）。
    func testMindsRootBlankOverrideFallsBackToDefault() {
        setenv("MINDBUS_MINDS_ROOT", "   ", 1)
        addTeardownBlock { unsetenv("MINDBUS_MINDS_ROOT") }
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("minds", isDirectory: true)
            .appendingPathComponent("enriched.jsonl")
        XCTAssertEqual(MindsEnrichedLog.defaultLogURL.path, expected.path)
    }
}
