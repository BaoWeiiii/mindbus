import Foundation
import MindBusCore

/// 一次工具调用的产出。`isError` 走的是 MCP 的工具结果错误（`result.isError`），
/// 不是 JSON-RPC 协议错误——后者会让宿主判定服务器故障，前者才是"把这段文字交给模型"。
public struct MCPToolOutput {
    public let text: String
    public let isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// 一个工具的完整声明加实现。用值类型注册表而不是协议，是为了让 `MCPServer`
/// 能被注入一组假工具做协议层测试（真工具要真索引，会把协议测试拖成集成测试）。
///
/// Swift 6 风险：包现在是 `swift-tools-version: 5.9`（Swift 5 语言模式），`inputSchema:
/// [String: Any]` 与 `run` 闭包捕获的 `Any`/非 Sendable 类型在这个模式下不触发并发检查、
/// 编译零警告；一旦升到 Swift 6 语言模式，`Any` 不满足 `Sendable` 会在这两处变成 error，
/// 届时需要重新设计（`inputSchema` 大概率要收窄成一个自定义的 Sendable JSON 值类型）。
public struct MCPToolSpec {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    public let run: ([String: Any], ConversationIndex) -> MCPToolOutput

    public init(name: String, description: String, inputSchema: [String: Any],
                run: @escaping ([String: Any], ConversationIndex) -> MCPToolOutput) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.run = run
    }

    /// tools/list 的一项。
    var definition: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }
}

/// V1 只读三件套（L2 搜索/L0-L1 地图切面/L3 原文，记忆层设计说明 与 §6）+
/// `memory_digest`（机械精华包，供宿主用今天的知识重新解释旧结论——"答案贬值、
/// 语境增值"的落地）+ 思脉底座 `minds_read`（机械画像只读口）。五个工具全部只读——
/// 曾经的写工具 `minds_enrich`（增补层）已随例外拆除（用户 2026-09-01 定案）。
///
/// Swift 6 风险：`all` 是非 Sendable 静态量（`MCPToolSpec` 含 `Any`），Swift 5 语言模式下
/// 全局/静态量的并发安全检查是警告级别且这里连警告都没触发；升到 Swift 6 语言模式后会
/// 变成 error，需要跟 `MCPToolSpec` 一起重新设计。
public enum MCPToolCatalog {
    public static let all: [MCPToolSpec] = [
        MemorySearchTool.spec,
        MemoryBrowseTool.spec,
        MemoryOpenTool.spec,
        MemoryDigestTool.spec,
        MindsReadTool.spec,
    ]
}
