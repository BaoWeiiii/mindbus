import Foundation
import MindBusCore

/// 索引这一刻能不能用。
///
/// 为什么不用 `Result<ConversationIndex, String>`：`Result` 要求 `Failure: Error`，
/// 而让 `String` 追溯满足 `Error`（`extension String: @retroactive Error`）会把
/// 「任何字符串都能当异常抛」这条规则装进整个模块乃至所有 import 方——为了省一个类型
/// 去污染全局命名空间，代价不对等。用途明确的两态枚举更直白，也不必拆箱。
public enum MCPIndexAvailability {
    case available(ConversationIndex)
    /// 打不开时给模型看的提示文案（已由 `MCPIndexAccess.message` 加工成可执行建议）。
    case unavailable(String)
}

/// MCP over stdio 的方法分派。一行 JSON-RPC 进，一行 JSON-RPC 出（或不出）。
///
/// 整个协议表面就是 `handleLine`，所以协议行为能不起进程就测完；可执行文件
/// （`MCPMain/main.swift`）只剩一个 while 循环。
public final class MCPServer {

    /// 每次调用都可能重试打开索引；失败时返回**给模型看的**提示文案。
    public typealias IndexOpener = () -> MCPIndexAvailability

    /// 客户端没报协议版本时的回退值。2026-07-28 起规范转无状态、去掉 initialize 握手，
    /// 但 2025-11-25 及更早仍是握手制，宿主升级节奏也不一致。策略：客户端报什么回什么
    /// （tools/list 与 tools/call 的报文形状在 2024-11-05 ~ 2026-07-28 之间没变，回显安全），
    /// 没报就回这个；且**不要求**先 initialize——无状态客户端会直接发 tools/list。
    public static let fallbackProtocolVersion = "2025-11-25"

    /// 与 App 同版本发布（同一个 bundle 里），但 CLI 读不到 Info.plist，故独立常量。
    public static let serverVersion = "1.0.0"

    /// 宿主在握手时拿到的唯一一段说明。检索循环写死在这里，也写死在每个工具的
    /// description 里——在 agentic 检索里说明书是检索系统的一部分。
    static let instructions = """
    MindBus is the user's own archive of past AI conversations (Claude Code, Claude desktop, \
    ChatGPT desktop, and browser AI platforms), indexed locally. Everything here is text the \
    user already paid for once.

    RETRIEVAL LOOP — follow it in order:
    1. memory_search with words that would literally appear in the conversation.
    2. No hits? Do NOT conclude "nothing found". Call memory_browse with no arguments to get \
    the library map, then drill down with one of the facet strings it prints.
    3. Once a result looks right, call memory_open with its conversation_id to read the \
    original messages.

    When a past conversation's conclusion matters today, call memory_digest on it — it returns \
    the mechanically extracted essence (task, entities, closing) for you to re-evaluate with \
    current knowledge instead of re-reading hundreds of turns.

    Call minds_read to see the user's mechanical profile and WEAK SPOTS — working preferences, \
    collaboration style, current goals, self-reported tech stack. When you notice a gap you can \
    fill from this conversation or from retrieval evidence, call minds_enrich with the spot, \
    your statement, and the conversation_id(s) it came from.

    memory_search, memory_browse, memory_open, memory_digest, and minds_read are read-only. \
    minds_enrich is the only tool that writes, and only to a separate enrichment log — every \
    statement must cite real conversation_id(s), and the user confirms or revokes it later in \
    the MindBus app.
    """

    private let openIndex: IndexOpener
    private let tools: [MCPToolSpec]

    public init(openIndex: @escaping IndexOpener, tools: [MCPToolSpec] = MCPToolCatalog.all) {
        self.openIndex = openIndex
        self.tools = tools
    }

    /// 处理一行输入；返回要写回 stdout 的一行，nil = 按规范不该回应。
    public func handleLine(_ line: String) -> String? {
        switch JSONRPC.parse(line) {
        case .empty:
            return nil
        case .failure(let code, let message, let id):
            return JSONRPC.error(code: code, message: message, id: id)
        case .request(let request):
            // 通知没有 id，回了就是往 stdout 写客户端不认的帧
            guard let id = request.id else { return nil }
            return respond(to: request, id: id)
        }
    }

    private func respond(to request: JSONRPC.Request, id: JSONRPC.RequestID) -> String {
        switch request.method {
        case "initialize":
            let version = request.params["protocolVersion"] as? String ?? Self.fallbackProtocolVersion
            // 记下宿主名给引用日志的 agent 字段——「被哪个 Agent 读过」的唯一来源。
            // 无状态客户端不发 initialize，则保持 "unknown"。
            if let clientInfo = request.params["clientInfo"] as? [String: Any],
               let name = clientInfo["name"] as? String, !name.isEmpty {
                MCPRefLog.agentName = name
            }
            return JSONRPC.result([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "mindbus", "version": Self.serverVersion],
                "instructions": Self.instructions,
            ], id: id)

        case "tools/list":
            return JSONRPC.result(["tools": tools.map(\.definition)], id: id)

        case "ping":
            return JSONRPC.result([:], id: id)

        case "tools/call":
            return JSONRPC.result(callTool(params: request.params), id: id)

        default:
            return JSONRPC.error(code: JSONRPC.methodNotFound,
                                 message: "Method not found: \(request.method)", id: id)
        }
    }

    /// 工具层的失败一律走 `isError` 的工具结果，不升级成 JSON-RPC error——
    /// 协议级 error 让宿主判定"服务器坏了"，而这里的失败都是模型该自己处置的情况
    /// （名字写错、索引还没建好），把话说清楚交给它更有用。
    private func callTool(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return Self.toolResult(MCPToolOutput("tools/call is missing the 'name' parameter.",
                                                 isError: true))
        }
        guard let spec = tools.first(where: { $0.name == name }) else {
            let known = tools.map(\.name).joined(separator: ", ")
            return Self.toolResult(MCPToolOutput(
                "Unknown tool '\(name)'. This server exposes: \(known).", isError: true))
        }
        // 刻意不缓存连接，每次调用都重新走 openReadOnly（文件存在性 + 开库 + user_version +
        // 7 张表校验，约 1ms 量级）：`mindbus-mcp` 是宿主的长驻子进程，寿命可能跨越 App
        // 的一次升级或一次数据政策迁移。缓存住的连接会在这两种情况下继续返回过期甚至
        // 已经不存在的结果而毫无迹象——`openReadOnly` 的校验只在"打开那一刻"有效，
        // 缓存等于把这扇门在首次成功之后重新打开了。工具调用一个 session 只有几次，
        // 这点代价换来"永远是刚校验过的新连接"。
        switch openIndex() {
        case .available(let index):
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return Self.toolResult(spec.run(arguments, index))
        case .unavailable(let reason):
            return Self.toolResult(MCPToolOutput(reason, isError: true))
        }
    }

    private static func toolResult(_ output: MCPToolOutput) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": output.text]]]
        // 成功时不写 isError：省 token，也和多数实现一致
        if output.isError { result["isError"] = true }
        return result
    }
}
