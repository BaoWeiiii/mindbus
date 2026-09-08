import XCTest
@testable import MindBusCore

/// 引用回流：MCP 读过哪条对话，App 侧聚合可见。
/// 架构红线：MCP 只追加自己的 jsonl，索引表只有 App 写——只读不变量原样成立。
/// 全部用注入的临时 URL，绝不碰真实 Application Support（`MCPRefLog.append`/
/// `ingestRefLog` 都接受显式 `url`/`to` 参数，生产默认值从不在测试里触发）。
final class MCPRefLogTests: XCTestCase {
    private var logURL: URL!
    private var dbPath: String!
    private var index: ConversationIndex!

    override func setUpWithError() throws {
        logURL = URL(fileURLWithPath: NSTemporaryDirectory() + "mcprefs-\(UUID().uuidString).jsonl")
        dbPath = NSTemporaryDirectory() + "mcprefs-idx-\(UUID().uuidString).sqlite"
        index = try ConversationIndex(path: dbPath)
    }

    override func tearDown() {
        index = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        try? FileManager.default.removeItem(at: logURL)
    }

    // MARK: append

    /// append 一行 → 文件里恰好一行合法 JSON，含 ts 与 conv_id。
    func testAppendWritesOneJSONLine() throws {
        MCPRefLog.append(conversationID: "conv-a", at: Date(timeIntervalSince1970: 1_700_000_000), to: logURL)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "应恰好一行")

        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(obj["conv_id"] as? String, "conv-a")
        XCTAssertEqual(obj["ts"] as? Double, 1_700_000_000)
        // agent 字段：设计说明「被哪个 Agent 读取过」——日志 append-only 不可回填，
        // 从第一天就要在。未设置时是 "unknown"（无状态客户端可以不握手）。
        XCTAssertNotNil(obj["agent"] as? String, "缺 agent 字段——无归属的历史一天都不该多")
    }

    /// initialize 握手里的 clientInfo.name 要落到 agent 字段。
    func testAgentNameFlowsFromInitializeToLogLine() throws {
        let saved = MCPRefLog.agentName
        addTeardownBlock { MCPRefLog.agentName = saved }

        MCPRefLog.agentName = "claude-code-test"
        MCPRefLog.append(conversationID: "conv-b", to: logURL)
        let content = try String(contentsOf: logURL, encoding: .utf8)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(content.split(separator: "\n").last!.utf8)) as? [String: Any])
        XCTAssertEqual(obj["agent"] as? String, "claude-code-test")
    }

    /// 自查点①的实测：多线程模拟「两个宿主进程同时 append」并发追加同一个文件，
    /// 每一行必须仍是独立可解析的合法 JSON——不撕裂、不吞掉、不覆盖。这是
    /// `MCPRefLog.append` 选择 POSIX `open(O_APPEND)` 而不是
    /// `FileHandle(forWritingTo:) + seekToEnd()` 的全部理由，必须有一个测试真正在
    /// 并发下验证这个选择，不能只停在注释里的论证。
    ///
    /// 用线程而非真的另起进程模拟：`append` 每次调用都独立 `open`/`write`/`close`
    /// （不复用已打开的文件描述符），O_APPEND 的原子性保证发生在内核对同一 inode
    /// 的 write(2) 系统调用层面，与发起调用的是同进程的不同线程还是不同进程无关——
    /// 线程级并发足以压出同样的竞态窗口，且比真的多开子进程快得多、也更容易在
    /// CI 里稳定复现。
    func testConcurrentAppendsDoNotTearLines() throws {
        let writers = 8
        let perWriter = 50
        DispatchQueue.concurrentPerform(iterations: writers) { w in
            for i in 0..<perWriter {
                MCPRefLog.append(conversationID: "w\(w)-\(i)", to: logURL)
            }
        }
        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, writers * perWriter,
                       "行数应恰好等于总写入次数——多一行说明有撕裂，少一行说明有覆盖")
        var ids = Set<String>()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["conv_id"] as? String else {
                return XCTFail("并发写入产生了无法解析的行：\(line)")
            }
            ids.insert(id)
        }
        XCTAssertEqual(ids.count, writers * perWriter, "每一行都必须是独立完整的记录，不能有重复或合并")
    }

    // MARK: ingest

    /// 连续 append 不互相覆盖；ingest 后计数正确聚合。
    func testIngestAggregatesCounts() throws {
        MCPRefLog.append(conversationID: "id-a", to: logURL)
        MCPRefLog.append(conversationID: "id-a", to: logURL)
        MCPRefLog.append(conversationID: "id-a", to: logURL)
        MCPRefLog.append(conversationID: "id-b", to: logURL)

        index.ingestRefLog(from: logURL)

        XCTAssertEqual(index.refCount(forID: "id-a")?.count, 3)
        XCTAssertEqual(index.refCount(forID: "id-b")?.count, 1)
        XCTAssertNil(index.refCount(forID: "id-c"))
    }

    /// ingest 幂等：重复调用结果一致（全量重算不叠加）。
    func testIngestIsIdempotent() throws {
        MCPRefLog.append(conversationID: "a", to: logURL)
        MCPRefLog.append(conversationID: "a", to: logURL)

        index.ingestRefLog(from: logURL)
        XCTAssertEqual(index.refCount(forID: "a")?.count, 2)

        index.ingestRefLog(from: logURL)
        XCTAssertEqual(index.refCount(forID: "a")?.count, 2, "重复 ingest 不该让计数翻倍")
    }

    /// 坏行（半截 JSON、空行、完全非 JSON）跳过，不炸、不影响好行。
    func testIngestSkipsCorruptLines() throws {
        MCPRefLog.append(conversationID: "good-1", to: logURL)
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        handle.write(Data("{\"conv_id\": \"broken\", \"ts\":\n".utf8))   // 半截 JSON（缺值与右括号）
        handle.write(Data("\n".utf8))                                     // 空行
        handle.write(Data("not even json\n".utf8))                       // 完全不是 JSON
        try handle.close()
        MCPRefLog.append(conversationID: "good-2", to: logURL)

        index.ingestRefLog(from: logURL)

        XCTAssertEqual(index.refCount(forID: "good-1")?.count, 1)
        XCTAssertEqual(index.refCount(forID: "good-2")?.count, 1)
        XCTAssertNil(index.refCount(forID: "broken"))
    }

    /// 非法 UTF-8 字节（崩溃在 append 半途留下的截断多字节序列）只废掉所在行，
    /// 绝不能废掉整个文件。
    ///
    /// 为什么单独测：上面那条坏行测试的坏行全是**合法 UTF-8**，根本没触到解码这关。
    /// 而可失败的 `String(data:encoding:)` 遇到文件里任何一个坏字节就整体返回 nil
    /// → counts 空 → DELETE 照跑 → 聚合表清空；日志 append-only 永不修复，此后每轮
    /// ingest 都再清一次——**一个字节换全部引用历史永久归零**。审查探针抓出的洞。
    func testIngestSurvivesInvalidUTF8Byte() throws {
        MCPRefLog.append(conversationID: "before", to: logURL)
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        handle.write(Data([0x7B, 0xFF, 0xFE, 0x0A]))   // "{" + 非法 UTF-8 字节 + 换行
        try handle.close()
        MCPRefLog.append(conversationID: "after", to: logURL)

        index.ingestRefLog(from: logURL)

        XCTAssertEqual(index.refCount(forID: "before")?.count, 1,
                       "一个坏字节不该抹掉它之前的合法记录")
        XCTAssertEqual(index.refCount(forID: "after")?.count, 1,
                       "一个坏字节不该抹掉它之后的合法记录")
    }

    /// 日志文件不存在 → ingest 无操作不报错，mcp_refs 清空（约定：无日志=无引用）。
    func testIngestWithMissingFileClearsTable() throws {
        MCPRefLog.append(conversationID: "a", to: logURL)
        index.ingestRefLog(from: logURL)
        XCTAssertEqual(index.refCount(forID: "a")?.count, 1)

        let missing = URL(fileURLWithPath: NSTemporaryDirectory() + "mcprefs-missing-\(UUID().uuidString).jsonl")
        index.ingestRefLog(from: missing)
        XCTAssertNil(index.refCount(forID: "a"), "无日志=无引用，旧聚合也要被清空")
    }

    /// last_ref 取最新时间戳（不是最后一次 append，append 顺序与时间顺序刻意错开）。
    func testLastRefTracksLatestTimestamp() throws {
        MCPRefLog.append(conversationID: "a", at: Date(timeIntervalSince1970: 1_000), to: logURL)
        MCPRefLog.append(conversationID: "a", at: Date(timeIntervalSince1970: 3_000), to: logURL)
        MCPRefLog.append(conversationID: "a", at: Date(timeIntervalSince1970: 2_000), to: logURL)

        index.ingestRefLog(from: logURL)

        let ref = try XCTUnwrap(index.refCount(forID: "a"))
        XCTAssertEqual(ref.count, 3)
        XCTAssertEqual(ref.last.timeIntervalSince1970, 3_000, accuracy: 0.001)
    }
}
