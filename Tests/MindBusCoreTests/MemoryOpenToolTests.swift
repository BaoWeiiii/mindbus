import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// L3 原文。三个必须守住的边界：
/// ①`bestSegmentFirstMessageIndex` 是**入库时**记的下标，源文件之后可能被追加或重写，
///   下标可能超出当前消息数——不 clamp 就是越界（`SegmentHit` 的文档注释明确警告过）；
/// ②整场对话可能上千条消息，全量吐出会把宿主上下文打爆，必须窗口分页；
/// ③源文件被工具删掉后从 vault 读回来这件事要**说出来**——那是产品的全部卖点。
final class MemoryOpenToolTests: XCTestCase {

    private func lite(_ id: String, messageCount: Int, path: String = "/tmp/nope.jsonl",
                      source: ConversationSource = .codex) -> ConversationLite {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 9; c.hour = 21; c.minute = 14
        let start = Calendar(identifier: .gregorian).date(from: c)!
        return ConversationLite(id: id, source: source, startAt: start,
                                endAt: start.addingTimeInterval(5_580),
                                cwd: "/p/app", gitBranch: nil, title: "归档改流式",
                                preview: "p", messageCount: messageCount,
                                fileURL: URL(fileURLWithPath: path))
    }

    private func conversation(_ id: String, messages n: Int,
                             blocksAt: [Int: [ContentBlock]] = [:]) -> Conversation {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 9; c.hour = 21; c.minute = 14
        let start = Calendar(identifier: .gregorian).date(from: c)!
        let messages = (0..<n).map { i in
            Message(id: "m\(i)", role: i % 2 == 0 ? .user : .assistant,
                    timestamp: start.addingTimeInterval(Double(i) * 60),
                    blocks: blocksAt[i] ?? [.text("message body \(i)")])
        }
        return Conversation(id: id, source: .codex, startAt: start,
                            endAt: start.addingTimeInterval(Double(n) * 60),
                            cwd: "/p/app", gitBranch: nil, title: "归档改流式", messages: messages)
    }

    private func render(_ conv: Conversation, count: Int? = nil, center: Int?, radius: Int = 6,
                        sourceMissing: Bool = false) -> String {
        MemoryOpenTool.render(lite: lite(conv.id, messageCount: count ?? conv.messages.count),
                              conversation: conv, sourceFileMissing: sourceMissing,
                              center: center, radius: radius).text
    }

    // MARK: 窗口

    func testHeaderCarriesMetadataAndWindowRange() {
        let out = render(conversation("conv-1", messages: 412), center: 20)
        XCTAssertTrue(out.contains("CONVERSATION conv-1"))
        XCTAssertTrue(out.contains("codex"))
        XCTAssertTrue(out.contains("/p/app"))
        XCTAssertTrue(out.contains("412 messages"))
        XCTAssertTrue(out.contains("Showing messages 14–26 of 412"))
        XCTAssertTrue(out.contains("--- #20 user"))
        XCTAssertTrue(out.contains("message body 20"))
    }

    func testWindowWithoutCenterStartsAtTheBeginning() {
        let out = render(conversation("conv-1", messages: 100), center: nil)
        XCTAssertTrue(out.contains("Showing messages 0–12 of 100"))
        XCTAssertTrue(out.contains("--- #0 user"))
    }

    func testNextAndPreviousWindowHandlesArePrinted() {
        let out = render(conversation("conv-1", messages: 100), center: 50)
        XCTAssertTrue(out.contains("message=57"), "缺下一窗的句柄，模型只能瞎猜下标")
        XCTAssertTrue(out.contains("message=43"))
        // 方向标签：两个裸句柄并排时，较弱的宿主模型只能靠比数字大小猜哪个往后翻
        XCTAssertTrue(out.contains("for the next window"))
        XCTAssertTrue(out.contains("for the previous window"))
    }

    func testFirstWindowOmitsPreviousHandleAndLastOmitsNext() {
        // 断言"上一窗句柄整个不存在"而不是"没有负下标"——实现里的 max(0, ...) 之类
        // 防御会把负下标折成 0，只查负号的断言在守卫被误删时照样绿（假阴性）。
        let head = render(conversation("conv-1", messages: 100), center: 0)
        XCTAssertFalse(head.contains("for the previous window"),
                       "窗口已到开头还给出上一窗句柄")
        let tail = render(conversation("conv-1", messages: 20), center: 19)
        XCTAssertFalse(tail.contains("for the next window"),
                       "窗口已到末尾还给出下一窗句柄")
        XCTAssertFalse(tail.contains("message=20"), "越界下标")
    }

    /// 翻页往返：照抄输出里的句柄连续翻完整场对话，必须一条不丢。
    ///
    /// 构造刻意还原真实丢消息的场景：**第一窗用户显式放大半径，后续照抄句柄时不带
    /// radius（句柄文本里本来就没有它，模型照抄自然回落默认 6）**。被修掉的简报公式
    /// `end + 1 + effectiveRadius` 正是在这种"半径缩水"时把中间几条永久跳过；而固定
    /// 半径翻页时两种公式的窗口恰好都衔接——本测试第一版就是那样写的，反向验证
    /// （故意换回坏公式）居然仍绿，才改成现在这个构造。现构造已验证：坏公式必红。
    func testPagingForwardVisitsEveryMessageWithoutGaps() {
        let conv = conversation("conv-1", messages: 60)
        var seen = Set<Int>()
        var center: Int? = 10        // 首窗：显式大半径
        var radius: Int? = 25
        for _ in 0..<60 {            // 上限防实现坏掉时死循环
            let out = radius.map { render(conv, center: center, radius: $0) }
                ?? renderDefaultRadius(conv, center: center)
            guard let match = out.range(of: #"Showing messages (\d+)–(\d+)"#,
                                        options: .regularExpression) else {
                return XCTFail("窗口范围行缺失")
            }
            let nums = out[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count == 2 else { return XCTFail("窗口范围解析失败") }
            seen.formUnion(nums[0]...nums[1])
            guard let handle = out.range(of: #"message=(\d+)\) for the next window"#,
                                         options: .regularExpression) else { break }
            center = out[handle].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
            radius = nil             // 此后每一跳都照抄句柄、回落默认半径
        }
        XCTAssertEqual(seen, Set(0..<60), "翻页有漏：缺 \(Set(0..<60).subtracting(seen).sorted())")
    }

    /// 不传 radius 的 render——走产品默认半径，模拟模型照抄句柄（句柄里没有 radius）。
    private func renderDefaultRadius(_ conv: Conversation, center: Int?) -> String {
        MemoryOpenTool.render(lite: lite(conv.id, messageCount: conv.messages.count),
                              conversation: conv, sourceFileMissing: false,
                              center: center, radius: MemoryOpenTool.defaultRadius).text
    }

    /// 入库时的下标可能大于当前消息数（源文件被重写变短），必须 clamp 而不是崩。
    func testCenterBeyondMessageCountIsClamped() {
        let out = render(conversation("conv-1", messages: 10), count: 999, center: 900)
        XCTAssertTrue(out.contains("of 10"))
        XCTAssertTrue(out.contains("--- #9"))
    }

    func testNegativeCenterIsClamped() {
        XCTAssertTrue(render(conversation("conv-1", messages: 10), center: -50).contains("--- #0"))
    }

    func testRadiusIsClampedToMax() {
        let out = render(conversation("conv-1", messages: 500), center: 250, radius: 9_999)
        // 半径封顶 30 → 窗口最多 61 条
        XCTAssertTrue(out.contains("Showing messages 220–280 of 500"))
    }

    func testEmptyConversationSaysSoInsteadOfRenderingNothing() {
        let out = render(conversation("conv-1", messages: 0), center: nil)
        XCTAssertTrue(out.contains("0 messages"))
        XCTAssertTrue(out.lowercased().contains("no messages"))
    }

    // MARK: 内容渲染

    /// 块渲染必须走 `ContentBlock.plainText`（单一真相）：图片渲染成占位符，
    /// base64 绝不能进输出——一张截图的 base64 能顶掉整个上下文窗口。
    func testImageBlocksRenderAsPlaceholderWithoutBase64() {
        let payload = String(repeating: "A", count: 5_000)
        let conv = conversation("conv-1", messages: 2, blocksAt: [
            0: [.image(mediaType: "image/png", source: .base64(payload))],
        ])
        let out = render(conv, center: 0)
        XCTAssertFalse(out.contains(payload), "base64 原样进了输出")
        XCTAssertTrue(out.contains("[image: image/png]"))
    }

    func testCodeAndToolBlocksAreIncluded() {
        let conv = conversation("conv-1", messages: 2, blocksAt: [
            0: [.code(language: "swift", text: "let x = 1"),
                .toolUse(name: "Bash", input: "ls -la")],
        ])
        let out = render(conv, center: 0)
        XCTAssertTrue(out.contains("let x = 1"))
        XCTAssertTrue(out.contains("[tool: Bash]"))
    }

    func testOverlongMessageIsTruncatedWithAnAnnouncement() {
        let long = String(repeating: "字", count: MemoryOpenTool.perMessageCap + 500)
        let conv = conversation("conv-1", messages: 2, blocksAt: [0: [.text(long)]])
        let out = render(conv, center: 0)
        XCTAssertLessThan(out.count, MemoryOpenTool.perMessageCap + 1_500)
        XCTAssertTrue(out.contains("truncated"), "截断必须说出来")
    }

    /// 窗口整体也要有上限：半径 30 × 每条 2000 字仍可能上万字。
    func testWindowStopsEarlyWhenTotalCapReached() {
        let long = String(repeating: "字", count: 1_900)
        var blocks: [Int: [ContentBlock]] = [:]
        for i in 0..<61 { blocks[i] = [.text(long)] }
        let out = render(conversation("conv-1", messages: 61, blocksAt: blocks),
                         center: 30, radius: 30)
        XCTAssertLessThan(out.count, MemoryOpenTool.totalCap + 2_000)
        XCTAssertTrue(out.contains("stopped early"), "提前收尾必须说出来，并给出继续读的句柄")
    }

    // MARK: vault 回退可见

    /// 「工具删了、你的还在」——这是 vault 存在的全部理由，读到时必须告诉模型。
    func testRestoredFromVaultIsAnnounced() {
        let out = render(conversation("conv-1", messages: 5), center: nil, sourceMissing: true)
        XCTAssertTrue(out.contains("MindBus archive"))
        XCTAssertTrue(out.lowercased().contains("deleted"))
    }

    func testLiveSourceDoesNotClaimRestoration() {
        let out = render(conversation("conv-1", messages: 5), center: nil, sourceMissing: false)
        XCTAssertFalse(out.contains("MindBus archive"))
    }

    // MARK: 入口

    func testUnknownConversationIDIsToolErrorWithNextStep() throws {
        let path = NSTemporaryDirectory() + "open-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        let index = try ConversationIndex(path: path)
        let out = MemoryOpenTool.spec.run(["conversation_id": "nope"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("memory_search") || out.text.contains("memory_browse"),
                      "找不到就要指回上一层，别让模型卡死在这里")
    }

    func testMissingConversationIDIsToolError() throws {
        let path = NSTemporaryDirectory() + "open-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        let out = MemoryOpenTool.spec.run([:], try ConversationIndex(path: path))
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("conversation_id"))
    }

    /// 索引里有行、但源文件与归档都没了：要说清"读不出来"，不能返回一个空壳。
    func testUnreadableConversationExplainsWhy() throws {
        let path = NSTemporaryDirectory() + "open-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        let index = try ConversationIndex(path: path)
        let missing = "/tmp/definitely-missing-\(UUID().uuidString).jsonl"
        try index.upsert([(lite("ghost", messageCount: 3, path: missing),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 2, text: "t")],
                           1, "t")])
        let out = MemoryOpenTool.spec.run(["conversation_id": "ghost"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains(missing))
    }

    // MARK: 引用回流记账（refLogger 接线，spec §7 第5步）

    /// 造一个最小可解析的 Claude Code 会话（一问一答）——与
    /// `VaultRestoreReadTests.makeSession` 同款最小 fixture，这里只是为了让
    /// `loadFull` 真正走到成功分支，从而验证 `refLogger` 接线本身。
    private func makeReadableSession(id: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mot-reflog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"\#(id)","cwd":"/tmp","timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user","content":"读引用回流测试"}}"#,
            #"{"type":"assistant","uuid":"a1","sessionId":"\#(id)","cwd":"/tmp","timestamp":"2026-08-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"能"}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: src)
        return src
    }

    /// 真读到原文（成功分支）必须记一笔——这是引用回流的全部前提。生产实现走
    /// `MCPRefLog.append`（写真实 Application Support 路径），测试换成断言用的
    /// 闭包，teardown 还原——`refLogger` 是进程级共享的 static var，不还原会
    /// 让后续用例带着替身闭包运行。
    func testSuccessfulOpenCallsRefLogger() throws {
        let path = NSTemporaryDirectory() + "open-reflog-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        let index = try ConversationIndex(path: path)
        let src = try makeReadableSession(id: "open-ok")
        try index.upsert([(lite("open-ok", messageCount: 2, path: src.path, source: .claudeCode),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 1, text: "t")],
                           1, "t")])

        var logged: [String] = []
        let original = MemoryOpenTool.refLogger
        MemoryOpenTool.refLogger = { logged.append($0) }
        addTeardownBlock { MemoryOpenTool.refLogger = original }

        let out = MemoryOpenTool.spec.run(["conversation_id": "open-ok"], index)
        XCTAssertFalse(out.isError)
        XCTAssertEqual(logged, ["open-ok"], "真读到原文必须记一笔引用")
    }

    /// 找不到 id（连 metadata 都查不到）——没有真的读到任何原文，绝不能记账。
    func testUnknownConversationDoesNotCallRefLogger() throws {
        let path = NSTemporaryDirectory() + "open-reflog-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        let index = try ConversationIndex(path: path)

        var logged: [String] = []
        let original = MemoryOpenTool.refLogger
        MemoryOpenTool.refLogger = { logged.append($0) }
        addTeardownBlock { MemoryOpenTool.refLogger = original }

        let out = MemoryOpenTool.spec.run(["conversation_id": "nope"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(logged.isEmpty, "找不到会话不该记账")
    }

    /// 索引里有行、但源文件与归档都读不出来——同样不算「真读到原文」，不该记账
    /// （与 `testUnreadableConversationExplainsWhy` 同一构造，这里额外断言记账侧）。
    func testUnreadableConversationDoesNotCallRefLogger() throws {
        let path = NSTemporaryDirectory() + "open-reflog-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        let index = try ConversationIndex(path: path)
        let missing = "/tmp/definitely-missing-\(UUID().uuidString).jsonl"
        try index.upsert([(lite("ghost", messageCount: 3, path: missing),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 2, text: "t")],
                           1, "t")])

        var logged: [String] = []
        let original = MemoryOpenTool.refLogger
        MemoryOpenTool.refLogger = { logged.append($0) }
        addTeardownBlock { MemoryOpenTool.refLogger = original }

        let out = MemoryOpenTool.spec.run(["conversation_id": "ghost"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(logged.isEmpty, "读不出原文不该记账")
    }

    func testToolIsRegisteredWithSchema() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_open" })
        let properties = try XCTUnwrap(spec.inputSchema["properties"] as? [String: Any])
        for key in ["conversation_id", "message", "radius"] {
            XCTAssertNotNil(properties[key], "schema 缺 \(key)")
        }
        XCTAssertEqual(spec.inputSchema["required"] as? [String], ["conversation_id"])
    }

    /// `inputSchema` 要经 `JSONSerialization` 序列化进 `tools/list` 的响应——里面任何一个
    /// 值不是合法 JSON 都会让宿主拿到的 `tools/list` 缺这个工具的完整 schema
    /// （同 `MemoryBrowseToolTests.testInputSchemaIsValidJSON`）。
    func testInputSchemaIsValidJSON() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_open" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema))
    }

    // MARK: 数值参数不崩（message / radius）

    /// JSON 数字经 `JSONSerialization` 解析后可能是 `Int` 也可能是 `Double`；`Double` 一侧
    /// 若用 `Int(someDouble)` 强转，`Double.infinity`/`1e300` 这类装不进 `Int` 位宽或非有限的
    /// 值会直接 trap，拖死整个 `mindbus-mcp` 进程——`MemoryBrowseTool.clampLimit` /
    /// `MemorySearchTool.clampLimit` 都因同一个坑改用过 `Int(exactly:)`，这里必须是同一写法。
    /// 直接测解析函数本身（而不是绕一圈 `.spec.run`）：`run` 在会话读不出来时会提前返回，
    /// 根本走不到 message/radius 这两行，函数级单测才是真的把这条路径测到。
    func testParseCenterSurvivesNonFiniteOrOutOfRangeDoubles() {
        for bad: Any in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300] {
            XCTAssertNil(MemoryOpenTool.parseCenter(bad), "message=\(bad) 不该崩，也不该解析出一个下标")
        }
        XCTAssertNil(MemoryOpenTool.parseCenter(nil))
        XCTAssertEqual(MemoryOpenTool.parseCenter(42), 42)
        XCTAssertEqual(MemoryOpenTool.parseCenter(42.0), 42)
    }

    func testParseRadiusSurvivesNonFiniteOrOutOfRangeDoubles() {
        for bad: Any in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300] {
            XCTAssertEqual(MemoryOpenTool.parseRadius(bad), MemoryOpenTool.defaultRadius,
                           "radius=\(bad) 不该崩，该回落默认值")
        }
        XCTAssertEqual(MemoryOpenTool.parseRadius(nil), MemoryOpenTool.defaultRadius)
        XCTAssertEqual(MemoryOpenTool.parseRadius(10), 10)
        XCTAssertEqual(MemoryOpenTool.parseRadius(10.0), 10)
    }

    /// 同一类输入这次走完整入口——即便某个具体会话读不出来提前返回，`run` 本身也不能崩，
    /// 这是端到端的兜底证明（上面两个函数级单测才是这条路径真正被覆盖的地方）。
    func testRunSurvivesNonFiniteOrOutOfRangeNumericArguments() throws {
        let path = NSTemporaryDirectory() + "open-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        let index = try ConversationIndex(path: path)
        for bad: Any in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300] {
            let out = MemoryOpenTool.spec.run(["conversation_id": "nope", "message": bad, "radius": bad], index)
            XCTAssertTrue(out.isError, "id 本来就找不到，应仍是那条错误，而不是进程崩溃")
        }
    }
}
