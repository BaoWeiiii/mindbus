import XCTest
@testable import MindBusMCP
@testable import MindBusCore

/// L4 精华包（`memory_digest`）。"答案贬值、语境增值"的落地：机械抽出任务/辨识度实体/
/// 收尾结论/相邻会话，让宿主模型用今天的知识重新判断旧结论，而不是把它当答案照抄。
/// MindBus 自己不生成任何一个字——这里测的全是抽取与排版规则,不是生成质量。
final class MemoryDigestToolTests: XCTestCase {

    private static func baseDate() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 12; c.hour = 9; c.minute = 0
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: 构造助手

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "digest-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    /// `path` defaults to a per-id fake path (like `EntityIndexTests.lite`) — `upsertOne`
    /// dedups by `file_path` (same file re-indexed replaces the old row), so any test that
    /// upserts more than one conversation would otherwise have every later row silently
    /// evict the earlier one sharing a hard-coded default path. Tests that specifically want
    /// a shared/missing path (e.g. the unreadable-conversation cases) still pass `path:`
    /// explicitly and are unaffected.
    private func lite(_ id: String, cwd: String = "/p/app", startAt: Date = baseDate(),
                      title: String? = "归档改流式", path: String? = nil,
                      source: ConversationSource = .codex) -> ConversationLite {
        ConversationLite(id: id, source: source, startAt: startAt,
                         endAt: startAt.addingTimeInterval(300), cwd: cwd, gitBranch: nil,
                         title: title, preview: "p", messageCount: 2,
                         fileURL: URL(fileURLWithPath: path ?? "/tmp/digest-\(id).jsonl"))
    }

    private func seg(_ text: String) -> Segmenter.Segment {
        Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 1, text: text)
    }

    /// upsert 一行；`entityText` 默认与段文字同源——测试不关心实体抽取时用这个省事
    /// （与 `EntityIndexTests.row` 同一模式）。
    private func row(_ l: ConversationLite, _ text: String = "占位文字")
        -> (lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String) {
        (l, [seg(text)], 1, text)
    }

    private func conversation(_ id: String, roles: [MessageRole],
                              blocksAt: [Int: [ContentBlock]] = [:],
                              cwd: String = "/p/app", startAt: Date = baseDate()) -> Conversation {
        let messages = roles.enumerated().map { i, role in
            Message(id: "m\(i)", role: role, timestamp: startAt.addingTimeInterval(Double(i) * 60),
                    blocks: blocksAt[i] ?? [.text("\(role.rawValue) text \(i)")])
        }
        return Conversation(id: id, source: .codex, startAt: startAt,
                            endAt: startAt.addingTimeInterval(Double(max(roles.count, 1)) * 60),
                            cwd: cwd, gitBranch: nil, title: "归档改流式", messages: messages)
    }

    /// 大多数渲染测试不关心 NEIGHBOURS/引用计数：给一个只含当前会话自身
    /// （或压根没入库）的索引，`entities`/`neighbours`/`refCount` 天然都是空。
    private func render(_ conv: Conversation, index: ConversationIndex? = nil,
                        sourceMissing: Bool = false) throws -> String {
        let idx = try index ?? makeIndex()
        return MemoryDigestTool.render(lite: lite(conv.id, cwd: conv.cwd, startAt: conv.startAt),
                                       conversation: conv, sourceFileMissing: sourceMissing,
                                       index: idx).text
    }

    private func countOccurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: 头部 / vault 回退

    func testHeaderCarriesMetadataAndDayGranularity() throws {
        let out = try render(conversation("conv-1", roles: [.user, .assistant]))
        XCTAssertTrue(out.contains("DIGEST conv-1 — codex, /p/app, 2026-05-12 → 2026-05-12, 2 messages"))
    }

    func testHeaderOmitsProjectWhenCwdEmpty() throws {
        let out = try render(conversation("conv-1", roles: [.user], cwd: ""))
        XCTAssertTrue(out.contains("(no project)"), "cwd 为空不该印出裸逗号")
    }

    func testVaultFallbackUsesExactAnnouncement() throws {
        let out = try render(conversation("conv-1", roles: [.user, .assistant]), sourceMissing: true)
        XCTAssertTrue(out.contains(
            "[the tool deleted its own copy — this digest was built from your MindBus archive]"),
            "vault 回退标注必须逐字照简报给定的那句")
    }

    func testLiveSourceDoesNotClaimVaultFallback() throws {
        let out = try render(conversation("conv-1", roles: [.user, .assistant]), sourceMissing: false)
        XCTAssertFalse(out.contains("MindBus archive"))
    }

    // MARK: TASK

    func testTaskIsFirstUserMessageNotLast() throws {
        let conv = conversation("conv-1", roles: [.user, .assistant, .user, .assistant], blocksAt: [
            0: [.text("first ask")], 1: [.text("first reply")],
            2: [.text("second ask")], 3: [.text("second reply")],
        ])
        let out = try render(conv)
        XCTAssertTrue(out.contains("TASK (first user message)\nfirst ask"))
        // TASK 只取第一条 user，不该混进第二条的文字
        XCTAssertFalse(out.contains("TASK (first user message)\nsecond ask"))
    }

    func testTaskMissingWhenAllAssistant() throws {
        let conv = conversation("conv-1", roles: [.assistant, .assistant])
        let out = try render(conv)
        XCTAssertTrue(out.contains("TASK (first user message)\n(no user message)"))
    }

    /// 用 4 条消息（不是 2 条）：第一条 user（超长，落进 TASK）与最后一条 user（短，落进
    /// CLOSING）必须是不同的消息，否则同一条超长消息会在 CLOSING 里按 `closingCap`（400）
    /// 而不是 `taskCap`（300）截断，两个截断上限一旦选得让某个长度同时大于 300、
    /// 不大于 400 就会把 TASK 这边的失败错判成"没截断"——本测试第一版就是 2 条消息，
    /// 曾经因为这个重叠而假阳性通过。
    func testTaskIsSilentlyTruncatedAt300Characters() throws {
        let long = String(repeating: "任", count: MemoryDigestTool.taskCap + 100)
        let conv = conversation("conv-1", roles: [.user, .assistant, .user, .assistant], blocksAt: [
            0: [.text(long)], 2: [.text("short closing ask")],
        ])
        let out = try render(conv)
        let taskSection = try XCTUnwrap(out.range(of: "TASK (first user message)\n"))
        let afterTask = out[taskSection.upperBound...]
        XCTAssertFalse(afterTask.hasPrefix(long), "超长 TASK 必须被截断")
        XCTAssertTrue(afterTask.hasPrefix(String(repeating: "任", count: MemoryDigestTool.taskCap) + "…"))
    }

    // MARK: DISTINCTIVE ENTITIES

    func testEntitiesSectionShowsRarestFirstSeparatedByMiddleDot() throws {
        let index = try makeIndex()
        try index.upsert([
            row(lite("conv-1"), "提到 AlphaEntity 和 BetaEntity"),
            row(lite("n2", startAt: Self.baseDate().addingTimeInterval(-99_999)), "又聊 BetaEntity"),
        ])
        let out = try render(conversation("conv-1", roles: [.user, .assistant]), index: index)
        XCTAssertTrue(out.contains("DISTINCTIVE ENTITIES (rarest first)\nAlphaEntity · BetaEntity"),
                      "AlphaEntity 全库只出现 1 次，理应排在出现 2 次的 BetaEntity 之前")
    }

    func testEntitiesSectionEmptyPrintsPlaceholder() throws {
        // 空索引：conv-1 从未 upsert 过，entities 查询自然空
        let out = try render(conversation("conv-1", roles: [.user, .assistant]))
        XCTAssertTrue(out.contains("DISTINCTIVE ENTITIES (rarest first)\n(none extracted)"))
    }

    // MARK: CLOSING

    func testClosingShowsLastUserAndFollowingAssistant() throws {
        let conv = conversation("conv-1", roles: [.user, .assistant, .user, .assistant], blocksAt: [
            0: [.text("first ask")], 1: [.text("first reply")],
            2: [.text("second ask")], 3: [.text("second reply")],
        ])
        let out = try render(conv)
        // 精确的连续四行匹配本身已经锁死 CLOSING 只含第二轮——"first ask" 合法地出现在
        // TASK 里（它就是第一条 user 消息），不能拿它测"没混进 CLOSING"，否则会跟 TASK
        // 的合法内容打架；"first reply" 只可能出现在 CLOSING（TASK 只取 user 消息），
        // 用它来单独锁"第一轮 assistant 没有泄漏进来"。
        XCTAssertTrue(out.contains("CLOSING (last exchange)\n--- user\nsecond ask\n--- assistant\nsecond reply"))
        XCTAssertFalse(out.contains("first reply"), "CLOSING 不该混进第一轮的 assistant 消息")
    }

    func testClosingHasOnlyUserWhenConversationEndsOnUser() throws {
        let conv = conversation("conv-1", roles: [.user, .assistant, .user], blocksAt: [
            0: [.text("q1")], 1: [.text("a1")], 2: [.text("q2")],
        ])
        let out = try render(conv)
        XCTAssertTrue(out.contains("CLOSING (last exchange)\n--- user\nq2"))
        XCTAssertFalse(out.contains("--- assistant"), "尾部就是 user 时不该再有 assistant 块")
    }

    func testClosingFallsBackToLastTwoMessagesWhenNoUserAtAll() throws {
        let conv = conversation("conv-1", roles: [.assistant, .assistant, .assistant], blocksAt: [
            0: [.text("alpha-only")], 1: [.text("beta-trailing")], 2: [.text("gamma-trailing")],
        ])
        let out = try render(conv)
        XCTAssertTrue(out.contains("beta-trailing"))
        XCTAssertTrue(out.contains("gamma-trailing"))
        XCTAssertFalse(out.contains("alpha-only"), "全 assistant 会话的 CLOSING 只取最后两条")
    }

    func testClosingCapsAtTwoTrailingAssistantMessages() throws {
        let conv = conversation("conv-1", roles: [.user, .assistant, .assistant, .assistant], blocksAt: [
            0: [.text("ask")], 1: [.text("reply-one")], 2: [.text("reply-two")], 3: [.text("reply-three")],
        ])
        let out = try render(conv)
        XCTAssertTrue(out.contains("reply-one"))
        XCTAssertTrue(out.contains("reply-two"))
        XCTAssertFalse(out.contains("reply-three"), "尾部 assistant 超过 2 条时只保留前 2 条")
        XCTAssertEqual(countOccurrences("--- assistant", in: out), 2)
    }

    func testClosingImageBlockRendersPlaceholderWithoutBase64() throws {
        let payload = String(repeating: "B", count: 3_000)
        let conv = conversation("conv-1", roles: [.user, .assistant], blocksAt: [
            1: [.image(mediaType: "image/png", source: .base64(payload))],
        ])
        let out = try render(conv)
        XCTAssertFalse(out.contains(payload), "base64 原样进了 CLOSING 输出")
        XCTAssertTrue(out.contains("[image: image/png]"))
    }

    func testClosingMessagesAreTruncatedWithMarker() throws {
        let long = String(repeating: "字", count: MemoryDigestTool.closingCap + 200)
        let conv = conversation("conv-1", roles: [.user, .assistant], blocksAt: [1: [.text(long)]])
        let out = try render(conv)
        XCTAssertFalse(out.contains(long), "超长 CLOSING 消息必须被截断")
        XCTAssertTrue(out.contains("truncated"), "CLOSING 截断必须说出来")
    }

    // MARK: NEIGHBOURS

    func testNeighboursShowBeforeAndAfterWithRealHandles() throws {
        let index = try makeIndex()
        let cur = Self.baseDate()
        let curLite = lite("conv-1", startAt: cur)
        try index.upsert([
            row(lite("conv-0", startAt: cur.addingTimeInterval(-172_800), title: "内存峰值问题的首次排查")),
            row(curLite),
            row(lite("conv-2", startAt: cur.addingTimeInterval(259_200), title: "流式过滤的回归修复")),
        ])
        let out = MemoryDigestTool.render(lite: curLite,
                                          conversation: conversation("conv-1", roles: [.user, .assistant], startAt: cur),
                                          sourceFileMissing: false, index: index).text
        XCTAssertTrue(out.contains("NEIGHBOURS (same project)"))
        XCTAssertTrue(out.contains("before: conversation_id=\"conv-0\"  2026-05-10  内存峰值问题的首次排查"))
        XCTAssertTrue(out.contains("after:  conversation_id=\"conv-2\"  2026-05-15  流式过滤的回归修复"))
    }

    func testNeighboursOmitBeforeLineWhenCurrentIsEarliest() throws {
        let index = try makeIndex()
        let cur = Self.baseDate()
        let curLite = lite("conv-1", startAt: cur)
        try index.upsert([
            row(curLite),
            row(lite("conv-2", startAt: cur.addingTimeInterval(3_600))),
        ])
        let out = MemoryDigestTool.render(lite: curLite,
                                          conversation: conversation("conv-1", roles: [.user], startAt: cur),
                                          sourceFileMissing: false, index: index).text
        XCTAssertTrue(out.contains("NEIGHBOURS (same project)"))
        XCTAssertTrue(out.contains("after:  conversation_id=\"conv-2\""))
        XCTAssertFalse(out.contains("before:"), "没有更早的会话时不该印 before 行")
    }

    func testNeighboursSectionOmittedWhenNoneExist() throws {
        let index = try makeIndex()
        let curLite = lite("conv-1")
        try index.upsert([row(curLite)])
        let out = MemoryDigestTool.render(lite: curLite,
                                          conversation: conversation("conv-1", roles: [.user]),
                                          sourceFileMissing: false, index: index).text
        XCTAssertFalse(out.contains("NEIGHBOURS"), "同项目里孤零零一场会话，整节该省略")
    }

    func testNeighboursSectionOmittedWhenCwdEmpty() throws {
        let index = try makeIndex()
        let cur = Self.baseDate()
        let curLite = lite("conv-1", cwd: "", startAt: cur)
        // 即便另一条 browser 会话恰好也是空 cwd、时间上紧邻，也不该被当成"同项目"。
        try index.upsert([
            row(curLite),
            row(lite("conv-2", cwd: "", startAt: cur.addingTimeInterval(3_600))),
        ])
        let out = MemoryDigestTool.render(lite: curLite,
                                          conversation: conversation("conv-1", roles: [.user], cwd: "", startAt: cur),
                                          sourceFileMissing: false, index: index).text
        XCTAssertFalse(out.contains("NEIGHBOURS"), "browser 会话没有项目概念，NEIGHBOURS 整节省略")
    }

    func testNeighboursIgnoreConversationsInOtherProjects() throws {
        let index = try makeIndex()
        let cur = Self.baseDate()
        let curLite = lite("conv-1", cwd: "/p/app", startAt: cur)
        try index.upsert([
            row(curLite),
            row(lite("decoy", cwd: "/other/project", startAt: cur.addingTimeInterval(3_600))),
        ])
        let out = MemoryDigestTool.render(lite: curLite,
                                          conversation: conversation("conv-1", roles: [.user], startAt: cur),
                                          sourceFileMissing: false, index: index).text
        XCTAssertFalse(out.contains("NEIGHBOURS"), "别的项目的会话不算相邻")
    }

    // MARK: 引用计数

    func testRefCountLineShownWhenPositive() throws {
        let index = try makeIndex()
        let cur = Self.baseDate()
        let curLite = lite("conv-1", startAt: cur)
        try index.upsert([
            row(curLite),
            row(lite("conv-2", startAt: cur.addingTimeInterval(3_600))),
        ])
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory() + "digest-refs-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: logURL) }
        for _ in 0..<3 { MCPRefLog.append(conversationID: "conv-1", to: logURL) }
        index.ingestRefLog(from: logURL)

        let out = MemoryDigestTool.render(lite: curLite,
                                          conversation: conversation("conv-1", roles: [.user], startAt: cur),
                                          sourceFileMissing: false, index: index).text
        XCTAssertTrue(out.contains("(referenced 3 times by agents before)"))
    }

    func testRefCountLineHiddenWhenZero() throws {
        let index = try makeIndex()
        let cur = Self.baseDate()
        let curLite = lite("conv-1", startAt: cur)
        try index.upsert([
            row(curLite),
            row(lite("conv-2", startAt: cur.addingTimeInterval(3_600))),
        ])
        let out = MemoryDigestTool.render(lite: curLite,
                                          conversation: conversation("conv-1", roles: [.user], startAt: cur),
                                          sourceFileMissing: false, index: index).text
        XCTAssertTrue(out.contains("NEIGHBOURS"), "对照：这条应该有 NEIGHBOURS 节，只是没有引用")
        XCTAssertFalse(out.contains("referenced"), "从未被引用过不该印那一行")
    }

    // MARK: REINTERPRET

    func testReinterpretCarriesLiteralWordingAndRealHandle() throws {
        let out = try render(conversation("conv-7", roles: [.user, .assistant]))
        XCTAssertTrue(out.contains(
            "REINTERPRET — this is raw material, not the answer. The conclusions above were made " +
            "by an older model with the knowledge of that time; answers depreciate, context does not."),
            "REINTERPRET 措辞必须逐字照简报给定的那句，不能自己改写")
        XCTAssertTrue(out.contains(#"memory_open(conversation_id="conv-7")"#),
                      "句柄必须是真实 id，能原样喂回 memory_open")
    }

    // MARK: 结构顺序

    func testSectionsAppearInSpecifiedOrder() throws {
        let out = try render(conversation("conv-1", roles: [.user, .assistant]))
        let markers = ["DIGEST conv-1", "TASK (first user message)",
                       "DISTINCTIVE ENTITIES (rarest first)", "CLOSING (last exchange)", "REINTERPRET —"]
        let ranges = markers.map { out.range(of: $0) }
        XCTAssertTrue(ranges.allSatisfy { $0 != nil }, "某个必备小节缺失")
        let starts = ranges.compactMap { $0?.lowerBound }
        XCTAssertEqual(starts, starts.sorted(), "小节顺序必须是 DIGEST → TASK → ENTITIES → CLOSING → REINTERPRET")
    }

    // MARK: ConversationIndex.entities(forConversationID:) 查询口

    func testEntitiesForConversationOrdersRarestFirst() throws {
        let index = try makeIndex()
        try index.upsert([
            row(lite("c1"), "提到 AlphaEntity 和 BetaEntity"),
            row(lite("c2"), "又聊 BetaEntity"),
            row(lite("c3"), "无关内容 GammaThing"),
            row(lite("c4"), "还是无关 DeltaThing"),
        ])
        let stats = index.entities(forConversationID: "c1", limit: 10)
        XCTAssertEqual(stats.map(\.text), ["AlphaEntity", "BetaEntity"])
        XCTAssertEqual(stats.first?.conversationCount, 1)
        XCTAssertEqual(stats.last?.conversationCount, 2)
    }

    /// 样板压制：出现在超过一半会话里的实体不该进这场会话的辨识度列表——
    /// 与 `EntityIndexTests.testBoilerplateEntitiesSuppressedFromTopButStillQueryable`
    /// 同一构造，这里断言的是新查询口。
    func testEntitiesForConversationSuppressesBoilerplate() throws {
        let index = try makeIndex()
        try index.upsert([
            row(lite("c1"), "改 file_path 参数，顺便看 VaultArchive"),
            row(lite("c2"), "又是 file_path"),
            row(lite("c3"), "还是 file_path"),
        ])
        let stats = index.entities(forConversationID: "c1", limit: 10).map(\.text)
        XCTAssertFalse(stats.contains("file_path"), "样板实体不该进这场会话的辨识度列表")
        XCTAssertTrue(stats.contains("VaultArchive"))
    }

    func testEntitiesForUnknownConversationIsEmpty() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), "提到 VaultArchive")])
        XCTAssertTrue(index.entities(forConversationID: "ghost", limit: 10).isEmpty)
    }

    // MARK: run 入口

    func testUnknownConversationIDIsToolErrorWithNextStep() throws {
        let index = try makeIndex()
        let out = MemoryDigestTool.spec.run(["conversation_id": "nope"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("memory_search") || out.text.contains("memory_browse"),
                      "找不到就要指回上一层，别让模型卡死在这里")
    }

    func testMissingConversationIDIsToolError() throws {
        let index = try makeIndex()
        let out = MemoryDigestTool.spec.run([:], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("conversation_id"))
    }

    /// 索引里有行、但源文件与归档都没了：要说清"读不出来"，不能返回一个空壳
    /// （与 `MemoryOpenToolTests.testUnreadableConversationExplainsWhy` 同一构造）。
    func testUnreadableConversationExplainsWhy() throws {
        let index = try makeIndex()
        let missing = "/tmp/definitely-missing-\(UUID().uuidString).jsonl"
        try index.upsert([(lite("ghost", path: missing),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 2, text: "t")],
                           1, "t")])
        let out = MemoryDigestTool.spec.run(["conversation_id": "ghost"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains(missing))
    }

    // MARK: 引用回流记账（refLogger 接线）

    private func makeReadableSession(id: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mdt-reflog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"\#(id)","cwd":"/tmp","timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user","content":"读 digest 引用回流测试"}}"#,
            #"{"type":"assistant","uuid":"a1","sessionId":"\#(id)","cwd":"/tmp","timestamp":"2026-08-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"能"}]}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: src)
        return src
    }

    func testSuccessfulRunCallsRefLogger() throws {
        let index = try makeIndex()
        let src = try makeReadableSession(id: "digest-ok")
        try index.upsert([(lite("digest-ok", path: src.path, source: .claudeCode),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 1, text: "t")],
                           1, "t")])

        var logged: [String] = []
        let original = MemoryDigestTool.refLogger
        MemoryDigestTool.refLogger = { logged.append($0) }
        addTeardownBlock { MemoryDigestTool.refLogger = original }

        let out = MemoryDigestTool.spec.run(["conversation_id": "digest-ok"], index)
        XCTAssertFalse(out.isError)
        XCTAssertEqual(logged, ["digest-ok"], "真读到原文必须记一笔引用")
    }

    func testUnknownConversationDoesNotCallRefLogger() throws {
        let index = try makeIndex()
        var logged: [String] = []
        let original = MemoryDigestTool.refLogger
        MemoryDigestTool.refLogger = { logged.append($0) }
        addTeardownBlock { MemoryDigestTool.refLogger = original }

        let out = MemoryDigestTool.spec.run(["conversation_id": "nope"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(logged.isEmpty, "找不到会话不该记账")
    }

    func testUnreadableConversationDoesNotCallRefLogger() throws {
        let index = try makeIndex()
        let missing = "/tmp/definitely-missing-\(UUID().uuidString).jsonl"
        try index.upsert([(lite("ghost", path: missing),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 2, text: "t")],
                           1, "t")])

        var logged: [String] = []
        let original = MemoryDigestTool.refLogger
        MemoryDigestTool.refLogger = { logged.append($0) }
        addTeardownBlock { MemoryDigestTool.refLogger = original }

        let out = MemoryDigestTool.spec.run(["conversation_id": "ghost"], index)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(logged.isEmpty, "读不出原文不该记账")
    }

    // MARK: 注册 / schema / instructions

    /// 思脉底座 Task 3 起目录扩到六个：四个只读记忆工具 + `minds_read`/`minds_enrich`
    /// （思脉底座 design spec §4）。顺序固定——`minds_read`/`minds_enrich` 各自的
    /// 注册测试（`MindsReadToolTests`/`MindsEnrichToolTests`）里也各自断言过一次
    /// 完整顺序，这里保留是因为这条测试历史上就是"目录形状"的唯一断言点。
    func testCatalogHasSixToolsWithDigestFourthAndMindsToolsLast() throws {
        XCTAssertEqual(MCPToolCatalog.all.map(\.name),
                       ["memory_search", "memory_browse", "memory_open", "memory_digest",
                        "minds_read", "minds_enrich"])
    }

    func testToolIsRegisteredWithSchema() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_digest" })
        let properties = try XCTUnwrap(spec.inputSchema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["conversation_id"])
        XCTAssertEqual(spec.inputSchema["required"] as? [String], ["conversation_id"])
    }

    /// `inputSchema` 要经 `JSONSerialization` 序列化进 `tools/list` 的响应——同
    /// `MemoryOpenToolTests.testInputSchemaIsValidJSON` 的既有惯例。
    func testInputSchemaIsValidJSON() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_digest" })
        XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema))
    }

    func testDescriptionMentionsMemoryOpen() throws {
        let spec = try XCTUnwrap(MCPToolCatalog.all.first { $0.name == "memory_digest" })
        XCTAssertTrue(spec.description.contains("memory_open"))
    }

    func testInstructionsMentionDigest() {
        XCTAssertTrue(MCPServer.instructions.contains("memory_digest"))
        XCTAssertTrue(MCPServer.instructions.contains(
            "call memory_digest on it — it returns the mechanically extracted essence"),
            "追加的说明必须逐字照简报给定的那句")
    }

    /// 引用计数独立于 NEIGHBOURS：browser 会话（cwd 空、无邻居节）的引用历史也要露面。
    /// 曾按模板字面把它嵌进 NEIGHBOURS 里——无邻居时 refCount>0 也被吞掉。
    func testRefCountShowsEvenWithoutNeighbours() throws {
        let index = try makeIndex()
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory() + "digest-ref-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: logURL) }
        MCPRefLog.append(conversationID: "lonely", to: logURL)
        MCPRefLog.append(conversationID: "lonely", to: logURL)
        index.ingestRefLog(from: logURL)

        // cwd 空 → NEIGHBOURS 整节省略；引用行必须仍然出现
        let out = MemoryDigestTool.render(
            lite: lite("lonely", cwd: ""), conversation: conversation("lonely", roles: [.user, .assistant, .user]),
            sourceFileMissing: false, index: index).text
        XCTAssertFalse(out.contains("NEIGHBOURS"), "前提：cwd 空无邻居节")
        XCTAssertTrue(out.contains("(referenced 2 times by agents before)"),
                      "无邻居时引用历史被吞掉了")
    }
}
