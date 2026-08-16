import Foundation
import MindBusCore

/// 索引在哪、打不开怎么说。
///
/// 独立成型是因为"打不开"是这个进程最常见的状态（用户还没打开过 App、刚升级完
/// 版本不匹配），而这时唯一有用的产出就是一句照着做就能修的话。
public enum MCPIndexAccess {

    /// 索引路径。`MINDBUS_INDEX_PATH` 可覆盖——真机烟测与本地调试靠它，
    /// 否则只能对着用户的真实索引跑。
    ///
    /// 相对路径原样保留、不做特殊处理：它会按宿主设的 CWD 解析（Claude Code 是项目
    /// 目录），同一份配置在不同项目会解析到不同文件——这是宿主传相对路径这个选择本身
    /// 带来的行为，不是这里要修的洞。
    public static func defaultIndexPath() -> String {
        if let raw = ProcessInfo.processInfo.environment["MINDBUS_INDEX_PATH"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // `~` 展开：这个值多半来自宿主的配置文件（不经过 shell），shell 的波浪号
                // 展开不会发生在这里，原样传给 FileManager 只会被当成字面量目录名，
                // 永远命中 .indexMissing。
                return (trimmed as NSString).expandingTildeInPath
            }
            // 纯空白视同未设置——不 trim 的话会原样喂进后面的提示文案，模型看到的是
            // "No MindBus index at  ."（双空格、没路径），毫无信息量。
        }
        // 只读进程默认不该有"建目录"这个副作用，见 ConversationStore.defaultIndexPath 的注释。
        return ConversationStore.defaultIndexPath(creatingDirectory: false)
    }

    /// 每次调用都重试打开：用户"打开一次 App 建好库"之后不该还要重启宿主。
    /// `MCPServer` 不缓存连接——每次 `tools/call` 都重新调这个闭包，换来的是"这个
    /// 连接永远是刚校验过的"，详见 `MCPServer.callTool` 里的注释。
    public static func opener(path: String) -> MCPServer.IndexOpener {
        return {
            do { return .available(try ConversationIndex.openReadOnly(path: path)) }
            catch { return .unavailable(message(for: error, path: path)) }
        }
    }

    public static func message(for error: Error, path: String) -> String {
        switch error as? ConversationIndex.ReadOnlyOpenError {
        case .unopenable(let detail):
            // 实测主因是 WAL 的 -wal/-shm 两个副文件都不在（只恢复了主库的备份），
            // 次因是文件损坏。两者的修复动作相同：让 App 读写打开一次。
            // 只读进程自己不许退回读写打开——那会在 close 时 checkpoint、真的改写主库。
            return """
            The MindBus index at \(path) exists but could not be opened read-only (\(detail)). \
            This usually means its WAL sidecar files are missing (a partial backup restore) or \
            the file is damaged. Open the MindBus app once — it will rebuild the sidecars, or \
            move a damaged index aside and rescan — then retry.
            """
        case .indexMissing:
            return """
            No MindBus index at \(path). Open the MindBus app once so it can scan your \
            AI tools and build the index, then retry this tool.
            """
        case .policyMismatch(let found, let expected):
            return """
            The MindBus index is schema v\(found) but this MCP server expects v\(expected). \
            Update whichever is older (the MindBus app or the mindbus-mcp binary — they ship \
            together, so installing the latest MindBus.app fixes both), then retry.
            """
        case .incompleteSchema(let missing):
            return """
            The MindBus index is missing the '\(missing)' table — the app was interrupted while \
            building it. Open the MindBus app and let the scan finish, then retry.
            """
        case .none:
            return "Could not open the MindBus index at \(path): \(error)"
        }
    }
}
