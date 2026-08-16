import XCTest
@testable import MindBusCore

final class SegmenterTests: XCTestCase {

    private func msg(_ role: MessageRole, _ text: String, _ i: Int = 0) -> Message {
        Message(id: "m\(i)", role: role, timestamp: Date(timeIntervalSince1970: Double(i)),
                blocks: text.isEmpty ? [] : [.text(text)])
    }

    /// 短会话不该被切开——段级索引的意义是切开长会话，不是把每轮都打散。
    func testShortConversationStaysOneSegment() {
        let segs = Segmenter.segments(of: [msg(.user, "怎么改", 0), msg(.assistant, "这样改", 1)])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].firstMessageIndex, 0)
        XCTAssertEqual(segs[0].lastMessageIndex, 1)
        XCTAssertTrue(segs[0].text.contains("怎么改"))
        XCTAssertTrue(segs[0].text.contains("这样改"))
    }

    /// 结构事件（助手长回复 → 用户短否定）处切段：这一轮是「一次完整尝试」的终点。
    func testCutsAtLongAnswerThenShortRejection() {
        let long = String(repeating: "详细方案", count: 120)   // ≥400 字
        let segs = Segmenter.segments(of: [
            msg(.user, "方案给我", 0),
            msg(.assistant, long, 1),
            msg(.user, "不对", 2),          // ≤60 字 → 前一段在此结束
            msg(.assistant, "重来", 3),
        ])
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].lastMessageIndex, 2, "短否定那一轮应属于前一段（它是该段的终点）")
        XCTAssertEqual(segs[1].firstMessageIndex, 3)
    }

    /// 助手回复不够长时不算结构事件——短问短答的日常来回不该被切碎。
    func testDoesNotCutWhenAnswerIsShort() {
        let segs = Segmenter.segments(of: [
            msg(.user, "行吗", 0), msg(.assistant, "行", 1), msg(.user, "好", 2),
        ])
        XCTAssertEqual(segs.count, 1)
    }

    /// 轮数封顶：不封顶的话 257 轮的长会话会切出巨段，段级排序退化成会话级。
    func testCapsSegmentByTurnCount() {
        let messages = (0..<20).map { msg($0 % 2 == 0 ? .user : .assistant, "第\($0)轮", $0) }
        let segs = Segmenter.segments(of: messages)
        XCTAssertEqual(segs.count, 3, "20 条按每段 8 条切成 8+8+4")
        XCTAssertTrue(segs.allSatisfy { $0.lastMessageIndex - $0.firstMessageIndex + 1 <= 8 })
    }

    /// 字数封顶：单条巨长消息也不能让段无限膨胀。
    func testCapsSegmentByCharCount() {
        let huge = String(repeating: "字", count: 3000)
        let segs = Segmenter.segments(of: [
            msg(.user, huge, 0), msg(.assistant, huge, 1), msg(.user, huge, 2),
        ])
        XCTAssertGreaterThan(segs.count, 1, "累计超过 4000 字应切段")
    }

    /// 纯图片消息没有文字，不单独成段，但要计入所在段的范围（否则详情跳转会指错位置）。
    func testEmptyTextMessagesStayInRangeWithoutOwnSegment() {
        let segs = Segmenter.segments(of: [
            msg(.user, "看图", 0), msg(.user, "", 1), msg(.assistant, "收到", 2),
        ])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].lastMessageIndex, 2)
    }

    func testEmptyConversationYieldsNoSegments() {
        XCTAssertTrue(Segmenter.segments(of: []).isEmpty)
        XCTAssertTrue(Segmenter.segments(of: [msg(.user, "", 0)]).isEmpty)
    }

    /// 回归：每条消息的下标都必须被某个段覆盖，不能有空洞。
    ///
    /// 曾经的缺陷：`flush` 里 `start = end + 1` 无条件执行，即使这次没产出段。
    /// 于是「轮数刚好封顶 → 下一条是纯图片消息且满足结构事件」时，那条消息
    /// 不属于任何段——将来「从搜索结果跳到这条消息」无从可跳。
    /// 触发不刁钻：一条长回复恰好撞上第 8 轮，后面跟一张不带说明的报错截图。
    func testEveryMessageIndexIsCoveredBySomeSegment() {
        let long = String(repeating: "详细方案", count: 120)   // ≥400 字
        var messages: [Message] = (0..<7).map { msg($0 % 2 == 0 ? .user : .assistant, "第\($0)轮", $0) }
        messages.append(msg(.assistant, long, 7))   // 第 8 条：轮数恰好封顶
        messages.append(msg(.user, "", 8))          // 第 9 条：纯图片（无文字）

        let segs = Segmenter.segments(of: messages)
        let covered = Set(segs.flatMap { $0.firstMessageIndex...$0.lastMessageIndex })
        let missing = (0..<messages.count).filter { !covered.contains($0) }
        XCTAssertTrue(missing.isEmpty, "这些下标不属于任何段，将来无法跳转：\(missing)")
    }

    /// 同一空洞用字数封顶也能触发（根因是两条封顶规则共享的）。
    func testNoIndexHoleWhenCharCapCoincidesWithEmptyMessage() {
        let long = String(repeating: "字", count: 4100)   // 单条就顶穿字数封顶，且 ≥400 字
        let messages = [msg(.user, "开始", 0), msg(.assistant, long, 1), msg(.user, "", 2)]
        let segs = Segmenter.segments(of: messages)
        let covered = Set(segs.flatMap { $0.firstMessageIndex...$0.lastMessageIndex })
        XCTAssertTrue((0..<messages.count).allSatisfy { covered.contains($0) },
                      "字数封顶路径上仍有索引空洞")
    }

    /// 已知限制（当前行为，非期望行为）：assistant 单条回复就顶穿字数封顶时，
    /// 紧跟的短否定会被孤立成单条段，而不是留在前一段末尾。彻底修需要前瞻判断，
    /// 见 Segmenter 内注释。此测试锁定现状，避免将来被无意改动而无人察觉。
    func testKnownLimitationShortRejectionIsolatedWhenCharCapHitsFirst() {
        let long = String(repeating: "字", count: 4200)
        let segs = Segmenter.segments(of: [
            msg(.user, "开场白", 0), msg(.assistant, long, 1),
            msg(.user, "不对", 2), msg(.assistant, "重来", 3),
        ])
        XCTAssertEqual(segs.count, 3, "当前行为是三段（含被孤立的「不对」）")
        XCTAssertEqual(segs[1].firstMessageIndex, 2)
        XCTAssertEqual(segs[1].lastMessageIndex, 2)
    }

    /// 回归：段的文字口径必须与 `Conversation.searchableText` 一致（除图片外全要）。
    ///
    /// 曾经只取 `.text` 块，导致代码块与工具输出（报错原文在此）永久搜不到——
    /// 而这两类正是「上次那个报错怎么解的」这类高频检索的目标。
    func testSegmentTextIncludesCodeAndToolBlocks() {
        let m = Message(id: "m1", role: .assistant, timestamp: Date(), blocks: [
            .text("先看报错"),
            .code(language: "swift", text: "func brokenThing() {}"),
            .toolResult(text: "error: cannot find 'brokenThing' in scope"),
            .thinking("内部推理"),
            .image(mediaType: "image/png", source: .base64("AAAA")),
        ])
        let segs = Segmenter.segments(of: [m])
        let text = try! XCTUnwrap(segs.first).text
        XCTAssertTrue(text.contains("brokenThing"), "代码块内容必须可搜")
        XCTAssertTrue(text.contains("cannot find"), "工具输出（报错原文）必须可搜")
        XCTAssertTrue(text.contains("内部推理"), "thinking 内容必须可搜")
        XCTAssertFalse(text.contains("AAAA"), "图片 base64 不该进检索文本")
    }

    /// 回归：单条巨长消息（粘贴的大段日志）不能产出无上限的段——
    /// FTS5 trigram 对超长文本建索引会让内存飙升，这条防线在换成段级时曾被误删。
    func testSegmentTextIsHardCapped() {
        let huge = String(repeating: "日", count: 500_000)
        let segs = Segmenter.segments(of: [
            Message(id: "m", role: .user, timestamp: Date(), blocks: [.text(huge)]),
        ])
        XCTAssertFalse(segs.isEmpty)
        XCTAssertLessThanOrEqual(segs[0].text.count, Segmenter.hardTextCap)
    }

    // MARK: - entityText（实体抽取专用口径，排除 .toolUse）

    /// 回归：工具调用参数的 JSON key 不该被抽成实体（它们是日志格式的样板，
    /// 真实语料 Top-30 里曾有约 12 条是这类）；但工具**输出**里的真实路径与报错要留。
    func testEntityTextSkipsToolUseButKeepsToolResult() {
        let m = Message(id: "m", role: .assistant, timestamp: Date(), blocks: [
            .text("我改一下"),
            .toolUse(name: "Edit", input: #"{"file_path":"a/b/c.swift","old_string":"x"}"#),
            .toolResult(text: "error: SQLITE_BUSY at MindBus/Core/DB/SQLiteDB.swift"),
        ])
        let text = Segmenter.entityText(of: [m])
        let got = Set(EntityExtractor.extract(from: text).map(\.text))
        XCTAssertFalse(got.contains("file_path"), "工具调用参数名被抽成实体了")
        XCTAssertFalse(got.contains("old_string"))
        XCTAssertTrue(got.contains("SQLITE_BUSY"), "工具输出里的报错码该留")
        XCTAssertTrue(got.contains("MindBus/Core/DB/SQLiteDB.swift"), "工具输出里的路径该留")
    }

    /// 检索口径不受影响——搜 old_string 仍应能搜到（它只是不该进「值得点的实体」）。
    func testSearchTextStillIncludesToolUse() {
        let m = Message(id: "m", role: .assistant, timestamp: Date(), blocks: [
            .toolUse(name: "Edit", input: #"{"old_string":"x"}"#),
        ])
        let segs = Segmenter.segments(of: [m])
        XCTAssertTrue(segs.first?.text.contains("old_string") ?? false,
                      "检索口径不该把工具调用排除掉")
    }
}
