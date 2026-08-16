import Darwin
import Foundation

/// MCP 引用日志：`memory_open` 成功读到原文时追加一行。
///
/// 为什么是独立文件而不是写索引：MCP 进程以 `SQLITE_OPEN_READONLY` 打开索引，
/// 「绝不写索引」是物理层保证——引用记录走自己的 append-only jsonl，
/// App 进程在扫描收尾统一汇入聚合表（`ConversationIndex.ingestRefLog`）。
/// 这是 MCP 进程唯一的写路径，且只写这一个文件。
///
/// 模块位置注记：按简报本应放在 `MindBus/MCP/`（`MindBusMCP` target），但
/// `LoaderRuntime`（扫描收尾要调 `ingestRefLog(from: MCPRefLog.defaultLogURL)`）
/// 活在 `MindBusCore`，而 `MindBusMCP` 依赖 `MindBusCore`、不是反过来
/// （`Package.swift`：`MindBusMCP` 的 `dependencies: ["MindBusCore"]`）——放进
/// `MindBusMCP` 会让 `MindBusCore` 反向依赖它，编译期就是循环依赖。放进
/// `MindBus/Core/MCP/` 让 `MindBusCore`（`LoaderRuntime`）与 `MindBusMCP`
/// （`MemoryOpenTool`，本就 `import MindBusCore`）都能直接引用。
public enum MCPRefLog {

    public static var defaultLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MindBus", isDirectory: true)
            .appendingPathComponent("mcp-refs.jsonl")
    }

    /// 追加一条记录。任何失败静默——引用统计丢一条无所谓，
    /// 绝不能让 `memory_open` 因为记不上账而报错。
    ///
    /// 并发安全：两个宿主进程（如 Claude Code 与 Codex 同时挂着 MCP）可能同时
    /// 调用这个函数，都在 append 同一个文件。POSIX `open(2)` 的 `O_APPEND` 是
    /// 内核级原子保证——每次 `write` 前内核把文件偏移量移到当前末尾这一步与
    /// 写入本身是同一个原子操作（不是两次系统调用），因此并发 append 不会互相
    /// 覆盖或截断对方，只要单次 write 不超过底层文件系统的原子写上限（这里单行
    /// 是一条 `{"conv_id":...,"ts":...}` JSON，远小于 4KB，本地文件系统的原子写
    /// 边界之内）。
    ///
    /// 这里**不用** `FileHandle(forWritingTo:)` + `seekToEnd()` + `write()`：
    /// 实测 `FileHandle(forWritingTo:)` 打开文件描述符时不带 `O_APPEND`，
    /// `seekToEnd()` 与随后的 `write()` 是两次独立系统调用，中间可能被另一个
    /// 进程的 append 插入——那段「seek 到旧末尾」到「write」之间的窗口正是
    /// 竞态区间，两个进程都 seek 到同一个旧末尾后各自 write，后写者会覆盖
    /// 先写者的字节而不是接在后面，行会被撕裂或吞掉。改用 POSIX `open(2)`
    /// 直接带 `O_APPEND` 拿到内核原子性，再包一层
    /// `FileHandle(fileDescriptor:closeOnDealloc:)` 复用其 `write` API。
    ///
    /// `O_CREAT` 直接带在 `open(2)` 调用里（而不是先 `fileExists` 判断、
    /// 不存在再 `createFile`）：后者的「先查后建」两步之间同样有竞态窗口——
    /// 两个进程都查到文件不存在，都去 `createFile`，后者会把先者刚写的内容
    /// 截断清空。`O_CREAT` 由内核保证「文件不存在则创建、存在则直接打开」是
    /// 单一原子操作，天然没有这个窗口。
    /// 发起读取的宿主名（initialize 的 clientInfo.name，MCPServer 握手时设置）。
    /// spec §2.2 要的是「被**哪个 Agent** 读取过几次」——日志 append-only 不可回填，
    /// 这个字段每晚加一天，无归属的历史就多一天。无状态客户端（2026-07-28 起可以
    /// 不握手）拿不到名字时保持默认。进程级可变量在单线程 stdio 泵下安全。
    public static var agentName = "unknown"

    public static func append(conversationID: String, at date: Date = Date(),
                              to url: URL = defaultLogURL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["ts": date.timeIntervalSince1970, "conv_id": conversationID,
                             "agent": agentName],
            options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)

        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        try? handle.write(contentsOf: line)
    }
}
