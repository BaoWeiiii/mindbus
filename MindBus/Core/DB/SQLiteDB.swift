import Foundation
import SQLite3

/// 系统 sqlite3 的薄封装。串行使用（由调用方用串行队列保证）。
public final class SQLiteDB {
    public enum DBError: Error { case open(Int32), prepare(String), step(Int32) }

    /// sqlite3_bind_text 的 destructor：让 SQLite 复制字符串（避免悬垂指针）。
    public static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 绑定文本——**显式传 UTF-8 字节长度**而不是 -1：-1 让 SQLite 用 strlen 取长，
    /// 文本含 U+0000（二进制被 cat 进对话、或注入者刻意放置）时 NUL 之后的内容会被
    /// 静默截断，那一段对搜索「隐身」。全库文本绑定统一走这里。
    public static func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        _ = text.withCString { p in
            sqlite3_bind_text(stmt, index, p, Int32(clamping: text.utf8.count), transient)
        }
    }

    private var handle: OpaquePointer?

    /// - Parameter queryOnly: 只读消费者（MCP 进程）用。三点差别：
    ///   ①开库标志本身就是 `SQLITE_OPEN_READONLY`，不带 `SQLITE_OPEN_CREATE`——
    ///     缺库直接抛错，而不是造一个空库骗过调用方；
    ///   ②不设 `journal_mode` / `synchronous`（都是写操作，且盘上已是 WAL）；
    ///   ③`PRAGMA query_only=ON` 作纵深防御兜底（在只读连接上无害，但不是主防线）。
    ///
    ///   为什么用 `SQLITE_OPEN_READONLY` 而不是「读写标志 + query_only」（此前的实现）：
    ///   `query_only` 是 VDBE 层的软开关——它只拦截"执行一条写语句"这个动作，拦不住
    ///   `sqlite3_close` 触发的 close-time checkpoint（pager 层直接改写主库文件），
    ///   且同一连接随时可以 `PRAGMA query_only=OFF` 把自己翻回可写。已实测过：GUI 退出后
    ///   MCP 进程若成为最后一个连接，读写标志打开的连接在 `sqlite3_close` 时会把 WAL
    ///   checkpoint 进主库——真实改写了用户的 index.sqlite（`ReadOnlyIndexTests` 的反向
    ///   验证里实测主库文件从 4096 字节变成 86016 字节，具体涨多少取决于 WAL 里攒了
    ///   多少未 checkpoint 的帧，但"读连接关闭会改写主库"这个方向是确定的）。
    ///   `SQLITE_OPEN_READONLY` 在物理层就拒绝任何写入（含 close-time checkpoint），
    ///   是唯一硬边界。
    ///
    ///   只读标志不会丢读能力：只读连接**能自行创建 `-shm`**（已实测，在系统 SQLite
    ///   3.51.0 上验证过），不需要写权限去"造"那个文件；即便 `-wal` 非空而 `-shm`
    ///   缺失（写连接被 kill、未走干净关闭）这种更难的场景，只读连接照样能读到全部数据。
    ///   目录不可写时读写标志与只读标志同样打不开库，读写标志并没有换来任何好处。
    public init(path: String, queryOnly: Bool = false) throws {
        let flags: Int32 = queryOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let code = sqlite3_errcode(handle)
            sqlite3_close(handle)
            // 必须置空：SQLiteDB 是根类且唯一存储属性有隐式默认值（nil），
            // 因此 self 在 init 入口即视为完全初始化 —— Swift 规定这种情况下
            // init 抛错**仍会调用 deinit**。不置空就会对已释放的句柄二次 close。
            // sqlite3_close(nil) 是安全的 no-op。
            handle = nil
            throw DBError.open(code)
        }
        // busy_timeout 必须第一个设：下面的 journal_mode=WAL 切换需要排他锁，
        // 若此时超时仍为 0，另一个连接正在写就会立刻 SQLITE_BUSY 而不是等待。
        try exec("PRAGMA busy_timeout=5000;")
        if queryOnly {
            try exec("PRAGMA query_only=ON;")
        } else {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")
        }
    }

    deinit { sqlite3_close(handle) }

    /// 执行无返回的 SQL（可多条用 ; 分隔）。
    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.prepare(msg)
        }
    }

    /// 执行一条带参数的写语句。
    public func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.step(rc) }
    }

    /// 执行查询，对每行回调。
    public func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in },
                      row: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        // 必须检查循环退出时的终态码：只判 == SQLITE_ROW 的话，
        // SQLITE_CORRUPT / SQLITE_IOERR / SQLITE_BUSY 都会被当成「查完了」，
        // 结果是静默返回**截断的**数据 —— 用户看到「一部分对话不见了」却毫无提示。
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            row(stmt)
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw DBError.step(rc) }
    }

    /// 事务包裹（批量写性能）。
    ///
    /// 用 BEGIN IMMEDIATE 而非裸 BEGIN：后者是 deferred 事务，先读后写时
    /// 若另一连接在中间提交，SQLite 返回 SQLITE_BUSY_SNAPSHOT —— 这个错误码
    /// **绕过 busy handler**，busy_timeout 完全不起作用，只能整批失败。
    /// IMMEDIATE 在开始就拿写锁，可被 busy_timeout 正常重试。
    public func transaction(_ work: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do { try work(); try exec("COMMIT;") }
        catch { try? exec("ROLLBACK;"); throw error }
    }

    /// 刚插入行的 rowid。省掉「INSERT 后再 SELECT 查回来」那一次查询。
    public var lastInsertRowid: Int64 { sqlite3_last_insert_rowid(handle) }

    /// 读 TEXT 列为 String。
    public static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}
