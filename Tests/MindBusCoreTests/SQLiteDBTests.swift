import XCTest
import SQLite3
@testable import MindBusCore

final class SQLiteDBTests: XCTestCase {
    private var dbPath: String!

    override func setUp() {
        dbPath = NSTemporaryDirectory() + "sqlitedb-test-\(UUID().uuidString).sqlite"
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testExecAndQuery() throws {
        let db = try SQLiteDB(path: dbPath)
        try db.exec("CREATE TABLE t (id TEXT, n INTEGER);")
        try db.run("INSERT INTO t (id, n) VALUES (?, ?);", bind: { stmt in
            sqlite3_bind_text(stmt, 1, "a", -1, SQLiteDB.transient)
            sqlite3_bind_int64(stmt, 2, 42)
        })
        var got: Int64 = 0
        try db.query("SELECT n FROM t WHERE id = ?;", bind: { stmt in
            sqlite3_bind_text(stmt, 1, "a", -1, SQLiteDB.transient)
        }, row: { stmt in
            got = sqlite3_column_int64(stmt, 0)
        })
        XCTAssertEqual(got, 42)
    }
}

// MARK: - init 失败路径

extension SQLiteDBTests {
    /// 打不开时必须抛错且不得二次 close。
    /// SQLiteDB 是根类且唯一存储属性有默认值 → init 抛错仍会走 deinit，
    /// 若 handle 未置空就是对已释放句柄二次 sqlite3_close（未定义行为）。
    func testOpenFailureThrowsAndDoesNotDoubleClose() {
        let bad = "/nonexistent-dir-\(UUID().uuidString)/x.sqlite"
        XCTAssertThrowsError(try SQLiteDB(path: bad)) { error in
            guard case SQLiteDB.DBError.open = error else {
                return XCTFail("应为 DBError.open，实际 \(error)")
            }
        }
        // 走到这里说明 deinit 没有因二次 close 崩溃
    }
}
