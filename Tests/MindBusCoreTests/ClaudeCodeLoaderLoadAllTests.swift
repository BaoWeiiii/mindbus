import XCTest
@testable import MindBusCore

final class ClaudeCodeLoaderLoadAllTests: XCTestCase {
    var tempRoot: URL!

    override func setUp() {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mb-loadall-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func writeProjectJSONL(projectName: String, fileName: String, lines: [String]) {
        let dir = tempRoot.appendingPathComponent(projectName)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testLoadAllFindsJSONLAcrossSubdirectories() {
        writeProjectJSONL(projectName: "p1", fileName: "s1.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"s1"}"#,
        ])
        writeProjectJSONL(projectName: "p2", fileName: "s2.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"hey"},"uuid":"u2","timestamp":"2026-04-08T12:00:00.000Z","sessionId":"s2"}"#,
        ])

        let result = ClaudeCodeLoader.loadAll(projectsDir: tempRoot)
        XCTAssertEqual(result.count, 2)
    }

    func testLoadAllSortsByStartAtDescending() {
        writeProjectJSONL(projectName: "p", fileName: "older.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"a"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"older"}"#,
        ])
        writeProjectJSONL(projectName: "p", fileName: "newer.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"b"},"uuid":"u2","timestamp":"2026-04-08T11:00:00.000Z","sessionId":"newer"}"#,
        ])
        let result = ClaudeCodeLoader.loadAll(projectsDir: tempRoot)
        XCTAssertEqual(result.first?.id, "newer")
        XCTAssertEqual(result.last?.id, "older")
    }

    func testLoadAllSkipsEmptyFileButKeepsValidOnes() {
        writeProjectJSONL(projectName: "p", fileName: "empty.jsonl", lines: ["garbage"])
        writeProjectJSONL(projectName: "p", fileName: "good.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"ok"},"uuid":"u","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"good"}"#,
        ])
        let result = ClaudeCodeLoader.loadAll(projectsDir: tempRoot)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "good")
    }

    func testSidechainFileIsSkipped() throws {
        // 子 agent 会话（isSidechain:true）与父会话共享 sessionId，入库会撞 id 唯一约束 → 必须跳过
        writeProjectJSONL(projectName: "p", fileName: "sidechain.jsonl", lines: [
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"sub task"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"parent-sid","cwd":"/tmp"}"#,
        ])
        let url = tempRoot.appendingPathComponent("p/sidechain.jsonl")
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: url))
    }

    func testMainSessionNotSkipped() throws {
        writeProjectJSONL(projectName: "p", fileName: "main.jsonl", lines: [
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"real chat"},"uuid":"u2","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"main-sid","cwd":"/tmp"}"#,
        ])
        let url = tempRoot.appendingPathComponent("p/main.jsonl")
        XCTAssertEqual(try ClaudeCodeLoader.loadConversation(fileURL: url)?.messages.count, 1)
    }

    func testLoadAllExcludesSidechains() {
        writeProjectJSONL(projectName: "p", fileName: "main.jsonl", lines: [
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"x"},"uuid":"m","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"s-main"}"#,
        ])
        writeProjectJSONL(projectName: "p", fileName: "side.jsonl", lines: [
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"y"},"uuid":"s","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"s-parent"}"#,
        ])
        XCTAssertEqual(ClaudeCodeLoader.loadAll(projectsDir: tempRoot).count, 1)   // 只剩主会话
    }

    func testSidechainMentionInsideNestedJSONDoesNotSkip() throws {
        // sidechain 判定必须看顶层字段——裸子串匹配曾把「讨论 JSONL 格式本身」的正常对话
        // 整个误杀（行内嵌套 JSON 里出现 "isSidechain":true 字样即中招）。
        writeProjectJSONL(projectName: "p", fileName: "meta-talk.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"解释一下 sidechain 标记"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"meta-sid","cwd":"/tmp","toolUseResult":{"isSidechain":true}}"#,
        ])
        let url = tempRoot.appendingPathComponent("p/meta-talk.jsonl")
        XCTAssertEqual(try ClaudeCodeLoader.loadConversation(fileURL: url)?.messages.count, 1)
    }

    func testLoadAllReturnsEmptyForMissingDir() {
        let fake = tempRoot.appendingPathComponent("does-not-exist")
        XCTAssertEqual(ClaudeCodeLoader.loadAll(projectsDir: fake), [])
    }

    func testLoadAllExcludesClaudeMemObserverSessions() {
        writeProjectJSONL(projectName: "-Users-me-dev-proj", fileName: "real.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"real talk"},"uuid":"u1","timestamp":"2026-04-07T11:00:00.000Z","sessionId":"real"}"#,
        ])
        // claude-mem 的观察者 agent 日志，不是用户对话——必须排除。
        writeProjectJSONL(projectName: "-Users-me--claude-mem-observer-sessions", fileName: "obs.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"You are a Claude-Mem observer"},"uuid":"u2","timestamp":"2026-04-08T11:00:00.000Z","sessionId":"obs"}"#,
        ])
        let result = ClaudeCodeLoader.loadAll(projectsDir: tempRoot)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "real")
    }

    func testEnumerateJsonlExcludesObserverSessions() {
        writeProjectJSONL(projectName: "-Users-me-dev-proj", fileName: "real.jsonl", lines: ["{}"])
        writeProjectJSONL(projectName: "-Users-me--claude-mem-observer-sessions", fileName: "obs.jsonl", lines: ["{}"])
        let names = ClaudeCodeLoader.enumerateJsonl(in: tempRoot).map { $0.lastPathComponent }
        XCTAssertTrue(names.contains("real.jsonl"))
        XCTAssertFalse(names.contains("obs.jsonl"))
    }

    // MARK: - API Error 残骸过滤

    /// ≤2 条且 assistant 全为「API Error:」开头 = 连接失败残骸，不入库；
    /// 多轮真会话中途报错不受影响。
    func testAPIErrorStubIsDropped() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"帮我看看"},"uuid":"u1","timestamp":"2026-08-01T10:00:00.000Z","cwd":"/p"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"API Error: Unable to connect to API (ConnectionRefused)"}]},"uuid":"a1","timestamp":"2026-08-01T10:00:01.000Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: tmp))
    }

    func testMidConversationAPIErrorIsKept() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mid-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"问题一"},"uuid":"u1","timestamp":"2026-08-01T10:00:00.000Z","cwd":"/p"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"正常回答"}]},"uuid":"a1","timestamp":"2026-08-01T10:00:01.000Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"API Error: Connection closed mid-response"}]},"uuid":"a2","timestamp":"2026-08-01T10:00:02.000Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        let conv = try ClaudeCodeLoader.loadConversation(fileURL: tmp)
        XCTAssertEqual(conv?.messages.count, 3)
    }

    // MARK: - 壳会话过滤

    private func writeTempJSONL(_ lines: [String], backdateBy seconds: TimeInterval? = nil) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        if let s = seconds {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -s)], ofItemAtPath: tmp.path)
        }
        return tmp
    }

    /// 单条 user、无 assistant、源文件已凉（mtime 距今 >10 分钟）
    /// = skill 跑批 / headless 调用留下的壳（真实库 467 条里攒了 318 条），不入库。
    func testStaleShellSessionIsDropped() throws {
        let tmp = try writeTempJSONL([
            #"{"type":"user","message":{"role":"user","content":"跑批指令"},"uuid":"u1","timestamp":"2026-08-01T10:00:00.000Z","cwd":"/p","sessionId":"sh-1"}"#,
        ], backdateBy: 3600)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(try ClaudeCodeLoader.loadConversation(fileURL: tmp))
    }

    /// 同样单条 user，但 mtime 距今 ≤10 分钟：可能是「刚发第一句、AI 还没答完」的
    /// 活跃会话——必须保留；AI 落盘会改 mtime，FSEvents 重扫自然转正或淘汰。
    func testFreshSingleUserMessageIsKept() throws {
        let tmp = try writeTempJSONL([
            #"{"type":"user","message":{"role":"user","content":"刚发的第一句"},"uuid":"u1","timestamp":"2026-08-01T10:00:00.000Z","cwd":"/p","sessionId":"sh-2"}"#,
        ])   // 刚写完，mtime = now
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNotNil(try ClaudeCodeLoader.loadConversation(fileURL: tmp))
    }

    /// 旧会话但 AI 回复过：不是壳，不受过滤影响。
    func testOldConversationWithReplyIsKept() throws {
        let tmp = try writeTempJSONL([
            #"{"type":"user","message":{"role":"user","content":"问题"},"uuid":"u1","timestamp":"2026-08-01T10:00:00.000Z","cwd":"/p","sessionId":"sh-3"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"回答"}]},"uuid":"a1","timestamp":"2026-08-01T10:00:01.000Z"}"#,
        ], backdateBy: 3600)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(try ClaudeCodeLoader.loadConversation(fileURL: tmp)?.messages.count, 2)
    }
}
