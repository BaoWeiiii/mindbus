import XCTest
@testable import MindBusCore

final class CodexLoaderTests: XCTestCase {

    // MARK: - isAutoInjectedUserText

    func testEnvironmentContextIsAutoInjected() {
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("<environment_context>\ncwd ..."))
    }

    func testPermissionsBlockIsAutoInjected() {
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("<permissions instructions>\n..."))
    }

    func testTurnAbortedIsAutoInjected() {
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("<turn_aborted>\nuser interrupted"))
    }

    func testRealUserTextIsKept() {
        XCTAssertFalse(CodexLoader.isAutoInjectedUserText("帮我看一下这个 bug"))
        XCTAssertFalse(CodexLoader.isAutoInjectedUserText("how do I run pytest?"))
    }

    func testWhitespaceBeforePrefixStillFlags() {
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("   <environment_context>"))
    }

    // MARK: - parseLine

    private func toLine(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    func testParseUserMessage() {
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-04-30T03:54:09.347Z",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "想用 claude code 开发鸿蒙"],
                ],
            ],
        ])
        let msg = CodexLoader.parseLine(line)
        XCTAssertEqual(msg?.role, .user)
        if case .text(let t) = msg?.blocks.first {
            XCTAssertEqual(t, "想用 claude code 开发鸿蒙")
        } else {
            XCTFail("expected text block")
        }
    }

    func testParseAssistantMessage() {
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-04-30T03:54:14.698Z",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [
                    ["type": "output_text", "text": "我来分析一下"],
                ],
            ],
        ])
        XCTAssertEqual(CodexLoader.parseLine(line)?.role, .assistant)
    }

    func testDeveloperMessageIsDropped() {
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-04-30T03:54:09.347Z",
            "payload": [
                "type": "message",
                "role": "developer",
                "content": [["type": "input_text", "text": "system prompt"]],
            ],
        ])
        XCTAssertNil(CodexLoader.parseLine(line))
    }

    func testEnvironmentContextUserMessageIsDropped() {
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-04-30T03:54:09.347Z",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "<environment_context>\ncwd /tmp"]],
            ],
        ])
        XCTAssertNil(CodexLoader.parseLine(line))
    }

    func testAgentsMdInjectionIsFlagged() {
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText(
            "# AGENTS.md instructions for /Users/me/proj\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>"))
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("AGENTS.md instructions for /x"))
        XCTAssertFalse(CodexLoader.isAutoInjectedUserText("帮我看 AGENTS.md 怎么写"))   // 真实提及不误杀
    }

    func testGoalAndSubagentInjectionsFlagged() {
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("<goal_context>\nContinue working toward the active goal"))
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("<subagent_notification>\n{\"agent_path\":\"019\"}"))
    }

    func testRealUserMarkersNotFlagged() {
        // 这些以 #/< 开头但是真实内容，不能误杀
        XCTAssertFalse(CodexLoader.isAutoInjectedUserText("# 任务：对方案做对抗终审"))
        XCTAssertFalse(CodexLoader.isAutoInjectedUserText("# Files mentioned by the user:\n## a.png"))
    }

    func testParseLineDropsAgentsMdPlusEnvMessage() {
        // 一条 user 消息，两块全是 Codex 注入（AGENTS.md + environment_context）→ 整条丢
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-05-18T10:00:00.000Z",
            "payload": ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": "# AGENTS.md instructions for /x\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>"],
                ["type": "input_text", "text": "<environment_context>\n<cwd>/x</cwd>\n</environment_context>"],
            ]],
        ])
        XCTAssertNil(CodexLoader.parseLine(line))
    }

    func testParseLineKeepsRealTextDespiteInjectedBlock() {
        // 防御：注入块 + 真实文字混在一条 → 逐块剔除注入、保留真实文字
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-05-18T10:00:00.000Z",
            "payload": ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": "<environment_context>\n<cwd>/x</cwd>\n</environment_context>"],
                ["type": "input_text", "text": "帮我改这个 bug"],
            ]],
        ])
        if case .text(let t) = CodexLoader.parseLine(line)?.blocks.first {
            XCTAssertEqual(t, "帮我改这个 bug")
        } else {
            XCTFail("应保留真实文字")
        }
    }

    func testReasoningEventIsIgnored() {
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-04-30T03:54:09.347Z",
            "payload": [
                "type": "reasoning",
                "summary": [],
                "encrypted_content": "...",
            ],
        ])
        XCTAssertNil(CodexLoader.parseLine(line))
    }

    func testNonResponseItemIsIgnored() {
        for type in ["session_meta", "event_msg", "turn_context"] {
            let line = toLine(["type": type, "payload": [:]])
            XCTAssertNil(CodexLoader.parseLine(line), "type=\(type) should be ignored")
        }
    }

    /// timestamp 缺失/解析不出 → 丢行。兜底 Date()（=解析那一刻）会把这条消息
    /// 排到会话末尾、endAt 顶成「现在」，污染整条排序，不如不要。
    func testUnparseableTimestampDropsLine() {
        let bad = toLine([
            "type": "response_item",
            "timestamp": "not-a-date",
            "payload": ["type": "message", "role": "user",
                        "content": [["type": "input_text", "text": "hello"]]],
        ])
        XCTAssertNil(CodexLoader.parseLine(bad))
        let missing = toLine([
            "type": "response_item",
            "payload": ["type": "message", "role": "user",
                        "content": [["type": "input_text", "text": "hello"]]],
        ])
        XCTAssertNil(CodexLoader.parseLine(missing))
    }

    /// 同一毫秒落盘的多条消息必须保持文件行序：sort 键 = (timestamp, 行序)。
    /// Codex 同刻多条极常见，Swift sort 不稳定，纯 timestamp 键会随机互换。
    func testLoadConversationStableOrderForSameTimestamp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-stable-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var lines = [toLine(["type": "session_meta",
                             "payload": ["id": "s-stable", "cwd": "/p"]])]
        for i in 0..<30 {
            lines.append(toLine([
                "type": "response_item",
                "timestamp": "2026-04-30T03:54:09.347Z",
                "payload": ["type": "message", "role": "assistant",
                            "content": [["type": "output_text",
                                         "text": String(format: "m%02d", i)]]],
            ]))
        }
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        let conv = try XCTUnwrap(CodexLoader.loadConversation(fileURL: tmp))
        XCTAssertEqual(conv.messages.compactMap(\.firstTextBlock),
                       (0..<30).map { String(format: "m%02d", $0) })
    }

    func testMultipleContentBlocksAreJoined() {
        let line = toLine([
            "type": "response_item",
            "timestamp": "2026-04-30T03:54:09.347Z",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [
                    ["type": "output_text", "text": "line A"],
                    ["type": "output_text", "text": "line B"],
                ],
            ],
        ])
        if case .text(let t) = CodexLoader.parseLine(line)?.blocks.first {
            XCTAssertEqual(t, "line A\nline B")
        } else {
            XCTFail("expected joined text")
        }
    }

    func testGarbageLineReturnsNil() {
        XCTAssertNil(CodexLoader.parseLine(""))
        XCTAssertNil(CodexLoader.parseLine("not json"))
        XCTAssertNil(CodexLoader.parseLine("{not closed"))
    }

    // MARK: - loadConversation end-to-end

    func testLoadConversationFromTempFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-2026-04-30-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lines: [[String: Any]] = [
            // session_meta
            [
                "type": "session_meta",
                "timestamp": "2026-04-30T03:54:09.345Z",
                "payload": [
                    "id": "sess-codex-1",
                    "cwd": "/tmp/codex-project",
                    "originator": "Codex Desktop",
                ],
            ],
            // developer system prompt — ignored
            [
                "type": "response_item",
                "timestamp": "2026-04-30T03:54:09.347Z",
                "payload": [
                    "type": "message", "role": "developer",
                    "content": [["type": "input_text", "text": "<permissions instructions>"]],
                ],
            ],
            // user environment context — ignored
            [
                "type": "response_item",
                "timestamp": "2026-04-30T03:54:09.347Z",
                "payload": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "<environment_context>\ncwd /tmp"]],
                ],
            ],
            // real user
            [
                "type": "response_item",
                "timestamp": "2026-04-30T03:54:10.000Z",
                "payload": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "帮我看 bug"]],
                ],
            ],
            // reasoning — ignored
            [
                "type": "response_item",
                "timestamp": "2026-04-30T03:54:11.000Z",
                "payload": ["type": "reasoning", "summary": [], "encrypted_content": "..."],
            ],
            // assistant
            [
                "type": "response_item",
                "timestamp": "2026-04-30T03:54:14.698Z",
                "payload": [
                    "type": "message", "role": "assistant",
                    "content": [["type": "output_text", "text": "我看到了"]],
                ],
            ],
        ]
        let body = lines.map(toLine).joined(separator: "\n")
        try body.write(to: tmp, atomically: true, encoding: .utf8)

        let conv = try CodexLoader.loadConversation(fileURL: tmp)
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.source, .codex)
        XCTAssertEqual(conv?.id, "sess-codex-1")
        XCTAssertEqual(conv?.cwd, "/tmp/codex-project")
        XCTAssertEqual(conv?.messages.count, 2)
        XCTAssertEqual(conv?.messages.first?.role, .user)
        XCTAssertEqual(conv?.messages.last?.role, .assistant)
    }

    func testSameMillisecondMessagesGetDistinctIds() throws {
        // Codex 无稳定消息 id，曾用「时间戳+角色」派生——同毫秒多条消息撞 id
        //（SwiftUI ForEach 视图错乱 / 缓存去重误判）。现在拼行序号保证唯一。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-samems-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let item: [String: Any] = [
            "type": "response_item",
            "timestamp": "2026-04-30T03:54:14.698Z",
            "payload": [
                "type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "第一段"]],
            ],
        ]
        var item2 = item
        item2["payload"] = [
            "type": "message", "role": "assistant",
            "content": [["type": "output_text", "text": "第二段"]],
        ]
        let body = [item, item2].map(toLine).joined(separator: "\n")
        try body.write(to: tmp, atomically: true, encoding: .utf8)

        let conv = try CodexLoader.loadConversation(fileURL: tmp)
        XCTAssertEqual(conv?.messages.count, 2)
        XCTAssertEqual(Set(conv?.messages.map(\.id) ?? []).count, 2)
    }

    func testLoadConversationSkipsOversizedLine() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-big-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let normal = toLine([
            "type": "response_item",
            "timestamp": "2026-04-28T01:00:00.000Z",
            "payload": ["type": "message", "role": "user",
                        "content": [["type": "input_text", "text": "hello"]]],
        ])
        // 模拟 compaction/截图巨行：超大 response_item（> cap），不该被解析进对话。
        let huge = String(repeating: "x", count: 5000)
        let oversized = toLine([
            "type": "response_item",
            "timestamp": "2026-04-28T01:01:00.000Z",
            "payload": ["type": "message", "role": "assistant",
                        "content": [["type": "output_text", "text": huge]]],
        ])
        try (normal + "\n" + oversized + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let conv = try CodexLoader.loadConversation(fileURL: tmp, maxLineBytes: 2000)
        XCTAssertEqual(conv?.messages.count, 1)          // 超大行被跳过
        XCTAssertEqual(conv?.messages.first?.role, .user)
    }

    func testLoadEmptyFileReturnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-empty-\(UUID().uuidString).jsonl")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(try CodexLoader.loadConversation(fileURL: tmp))
    }

    func testEnumerateFiltersByPrefix() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString)")
            .appendingPathComponent("2026/04/30")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let good = dir.appendingPathComponent("rollout-2026-04-30-abc.jsonl")
        let bad = dir.appendingPathComponent("other.jsonl")
        try "{}".write(to: good, atomically: true, encoding: .utf8)
        try "{}".write(to: bad, atomically: true, encoding: .utf8)

        let urls = CodexLoader.enumerateJsonl(in: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let names = urls.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["rollout-2026-04-30-abc.jsonl"])
    }

    // MARK: - 多 agent 子会话与新注入

    /// session_meta 带 parent_thread_id = 主会话派出的子 agent 工作日志：
    /// 整文件跳过（用户视角曾是「同名重复会话、点开全是注入垃圾」）。
    func testSubagentRunIsSkippedEntirely() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-subagent-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lines = [
            #"{"type":"session_meta","payload":{"id":"child-1","session_id":"parent-1","parent_thread_id":"parent-1","forked_from_id":"parent-1","cwd":"/tmp/x"}}"#,
            #"{"type":"response_item","timestamp":"2026-07-31T04:16:51.002Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"真实问题"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)

        XCTAssertNil(try CodexLoader.loadConversation(fileURL: tmp))
    }

    /// compact / fork 延续（forked_from_id 有、parent_thread_id 无）是同一线程的
    /// 正经延续，必须正常入库——别把用户的续聊当子 agent 杀掉。
    func testForkContinuationIsKept() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-fork-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lines = [
            #"{"type":"session_meta","payload":{"id":"cont-1","session_id":"parent-1","forked_from_id":"parent-1","cwd":"/tmp/x"}}"#,
            #"{"type":"response_item","timestamp":"2026-07-31T10:18:56.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续聊"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let conv = try CodexLoader.loadConversation(fileURL: tmp)
        XCTAssertEqual(conv?.messages.count, 1)
        XCTAssertEqual(conv?.id, "cont-1")
    }

    func testRecommendedPluginsIsAutoInjected() {
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("<recommended_plugins>\nHere is a list of plugins"))
        XCTAssertTrue(CodexLoader.isAutoInjectedUserText("<multi_agent_mode>Proactive multi-agent delegation"))
    }

    // MARK: - 同线程快照收敛

    /// 同 session_id 的多个 rollout（compact/fork 中间快照）只保 mtime 最新；
    /// 子 agent 在枚举层即淘汰；读不出 meta 的文件保守放行。
    func testCollapseThreadsKeepsNewestPerSession() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collapse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, meta: String) throws -> URL {
            let u = dir.appendingPathComponent(name)
            try (meta + "\n").write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let old = try write("rollout-a-old.jsonl",
            meta: #"{"type":"session_meta","payload":{"id":"t1-old","session_id":"t1","cwd":"/x"}}"#)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let new = try write("rollout-a-new.jsonl",
            meta: #"{"type":"session_meta","payload":{"id":"t1-new","session_id":"t1","forked_from_id":"t1","cwd":"/x"}}"#)
        let sub = try write("rollout-sub.jsonl",
            meta: #"{"type":"session_meta","payload":{"id":"s1","session_id":"t1","parent_thread_id":"t1","cwd":"/x"}}"#)
        let noMeta = try write("rollout-nometa.jsonl", meta: #"{"type":"event_msg"}"#)

        let (kept, superseded) = CodexLoader.collapseThreads([old, new, sub, noMeta])
        XCTAssertEqual(Set(kept.map(\.lastPathComponent)), ["rollout-a-new.jsonl", "rollout-nometa.jsonl"])
        XCTAssertEqual(Set(superseded.map(\.lastPathComponent)), ["rollout-a-old.jsonl", "rollout-sub.jsonl"])
    }
}
