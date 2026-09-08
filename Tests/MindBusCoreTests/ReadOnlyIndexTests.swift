import XCTest
import SQLite3
@testable import MindBusCore

/// 只读消费通道：MCP 进程与 GUI 共用一份索引，前者绝不能写。
///
/// 为什么必须有独立开库路径：`ConversationIndex.init` 会 `exec(schemaSQL)` 并跑
/// `migrateDataPolicyIfNeeded()`——后者在版本不符时 DROP 全部表，指望调用方随后
/// 全量重扫补回来。MCP 进程没有 loader，一旦走上这条路就是**把用户的索引清空且无人重建**。
final class ReadOnlyIndexTests: XCTestCase {

    /// 造一个临时路径并登记清理（含 WAL 两个副文件）。
    private func tempPath() -> String {
        let path = NSTemporaryDirectory() + "ro-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return path
    }

    private func lite(_ id: String, _ path: String) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(timeIntervalSince1970: 1_000),
                         endAt: Date(timeIntervalSince1970: 2_000), cwd: "/tmp/proj", gitBranch: nil,
                         preview: "p", messageCount: 1,
                         fileURL: URL(fileURLWithPath: path))
    }

    func testQueryOnlyOpenDoesNotCreateMissingFile() throws {
        let path = tempPath()
        XCTAssertThrowsError(try SQLiteDB(path: path, queryOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "只读开库把库建出来了——缺库会被当成空库，用户看到「一条对话都没有」而非「请先打开 App」")
    }

    func testQueryOnlyOpenRejectsWrites() throws {
        let path = tempPath()
        _ = try ConversationIndex(path: path)          // 先用正常路径建库
        let ro = try SQLiteDB(path: path, queryOnly: true)
        XCTAssertThrowsError(try ro.exec("CREATE TABLE poke (x INTEGER);"),
                            "query_only 没生效——只读进程有能力污染用户索引")
    }

    /// WAL 库在写连接**未经 checkpoint 就消失**（进程被 kill，而不是正常退出）时——
    /// `-wal` 里还有真实的、未合并进主库的已提交帧，`-shm` 缺失——只读连接必须照样
    /// 读得出来。
    ///
    /// 为什么不能像早先那版一样"写连接干净退出后删 -wal/-shm"：干净退出触发
    /// close-time checkpoint，把 `-wal` 截空；此时再删掉两个副文件，库其实已经
    /// 退回"无 WAL 残留"的平凡状态——两种开库方案在这种状态下表现一致（实测都是
    /// 能读），测不出任何区分度。这里改用趁写连接**仍然打开**（还没触发 checkpoint）
    /// 把主库 + `-wal` 拷到另一个目录的构造，模拟"写进程被杀，WAL 里还有未
    /// checkpoint 的帧"这个更接近真实故障的场景。
    func testQueryOnlyReadsWALDatabaseAfterWriterClosed() throws {
        let path = tempPath()
        let writer = try ConversationIndex(path: path)
        try writer.upsert([(lite("a", "/tmp/a.jsonl"),
                            [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "hello")],
                            1, "hello")])

        let copyDir = NSTemporaryDirectory() + "ro-copy-\(UUID().uuidString)/"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: copyDir) }
        let copyPath = copyDir + "index.sqlite"

        // withExtendedLifetime：写连接必须撑到拷贝完成那一刻。此刻 `-wal` 里是真实的、
        // 未 checkpoint 的已提交帧；写连接一旦在拷贝前提前析构，deinit 触发的
        // close-time checkpoint 会把 `-wal` 截空，构造就退化回上面注释里说的平凡场景。
        try withExtendedLifetime(writer) {
            try FileManager.default.createDirectory(atPath: copyDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: path, toPath: copyPath)
            try FileManager.default.copyItem(atPath: path + "-wal", toPath: copyPath + "-wal")
        }
        // 故意不拷 `-shm`：只读连接必须能在它缺失时自建（SQLiteDB.init 注释里
        // 已实测的事实），这正是这条测试要锁住的行为。
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyPath + "-shm"),
                       "测试前提不成立——拷贝目录不该有 -shm")

        let idx = try ConversationIndex.openReadOnly(path: copyPath)
        XCTAssertEqual(idx.summary().count, 1)
    }

    func testOpenReadOnlyRejectsMissingIndex() {
        let path = tempPath()
        XCTAssertThrowsError(try ConversationIndex.openReadOnly(path: path)) { err in
            XCTAssertEqual(err as? ConversationIndex.ReadOnlyOpenError, .indexMissing(path: path))
        }
    }

    /// 主库在、但 WAL 两个副文件都不在（只恢复了主库的备份、手工拷走单个文件）：
    /// 纯只读连接建不起读事务，SQLite 返回 SQLITE_CANTOPEN(14)。
    ///
    /// 这个状态**必须**翻成 `.unopenable` 而不是把底层 `step(14)` 递上去——MCP 会把
    /// 错误原样给模型看，`step(14)` 谁也不知道该怎么办，而正确的修复动作（让 App
    /// 读写打开一次，WAL 副文件即重建）是一句话就能说清的。
    ///
    /// 这里不退回读写打开：那会在 close 时 checkpoint、真的改写用户主库，
    /// 破掉「只读进程绝不写索引」这条不变量。宁可这一轮不可用，也不越权。
    func testOpenReadOnlyReportsUnopenableWhenBothWALSidecarsAbsent() throws {
        let path = tempPath()
        do {
            let writer = try ConversationIndex(path: path)
            try writer.upsert([(lite("a", "/tmp/a.jsonl"),
                                [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0,
                                                   text: "hello")], 1, "hello")])
        }
        for s in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }

        XCTAssertThrowsError(try ConversationIndex.openReadOnly(path: path)) { err in
            guard case .unopenable = err as? ConversationIndex.ReadOnlyOpenError else {
                return XCTFail("期望 .unopenable，实际是 \(err)——底层错误码递到用户面前了")
            }
        }
        // 只读失败没有破坏任何东西：App 读写打开一次就恢复
        XCTAssertEqual(try ConversationIndex(path: path).summary().count, 1)
    }

    func testOpenReadOnlyRejectsPolicyMismatch() throws {
        let path = tempPath()
        let index = try ConversationIndex(path: path)
        // 篡改版本号之前先塞一条真实会话——不然"行数未变"无内容可断言
        try index.upsert([(lite("a", "/tmp/a.jsonl"),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "hello")],
                           1, "hello")])
        // 篡改版本号模拟「App 比 MCP 二进制新」——不能因为查得动就照查
        do {
            let db = try SQLiteDB(path: path)
            try db.exec("PRAGMA user_version = 99;")
        }
        XCTAssertThrowsError(try ConversationIndex.openReadOnly(path: path)) { err in
            XCTAssertEqual(err as? ConversationIndex.ReadOnlyOpenError,
                           .policyMismatch(found: 99, expected: ConversationIndex.dataPolicyVersion))
        }
        // 本任务存在的全部理由就是「绝不能让 MCP 走上 DROP 全表那条路」——
        // 只断言"抛了错"不够，必须证明抛错之后库真的原封未动：用正常连接
        // （SQLiteDB.init 本身不跑任何 schema/迁移逻辑）直接查表，行数必须还是 1。
        let verify = try SQLiteDB(path: path)
        var count = 0
        try verify.query("SELECT COUNT(*) FROM conversations;",
                         row: { count = Int(sqlite3_column_int($0, 0)) })
        XCTAssertEqual(count, 1, "openReadOnly 拒绝服务后不应改动库——conversations 表行数必须原封不动")
    }

    func testOpenReadOnlyRejectsIncompleteSchema() throws {
        let path = tempPath()
        _ = try ConversationIndex(path: path)
        do {
            let db = try SQLiteDB(path: path)
            try db.exec("DROP TABLE entities;")
        }
        XCTAssertThrowsError(try ConversationIndex.openReadOnly(path: path)) { err in
            XCTAssertEqual(err as? ConversationIndex.ReadOnlyOpenError,
                           .incompleteSchema(missing: "entities"))
        }
    }
}
