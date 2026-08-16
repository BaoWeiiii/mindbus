import Foundation

/// 数据格式遥测：把「静默的未知」变成「显式的未知」。
///
/// 数据源（Claude Code / Codex）是活的，随版本演化出新行类型；loader 是快照式
/// 适配——新格式出现时最危险的行为是**无声丢弃**，用户先于系统发现数据不对。
/// 各 loader 遇到白名单之外的类型时在此计数，全量扫描结束 NSLog 一行汇总：
///
///     [format] unknown types — claudeCode: {"new_thing": 42} codex: {...}
///
/// 开发者（或用户带日志求助时）一眼看到「上游出新格式了」。零 UI、零网络。
public final class FormatTelemetry: @unchecked Sendable {
    public static let shared = FormatTelemetry()
    private let lock = NSLock()
    private var counts: [String: [String: Int]] = [:]   // source → type → n

    private init() {}

    /// 已知无需上报的类型（审查清点过的全部合法元数据类型）。
    /// 新增合法类型时同步维护——否则日志会持续提示，这正是机制的意义。
    private static let known: [String: Set<String>] = [
        "claudeCode": [
            "user", "assistant", "ai-title", "attachment", "system",
            "result", "started", "mode", "permission-mode", "queue-operation",
            "last-prompt", "file-history-snapshot", "bridge-session", "summary",
        ],
        // Codex 记录的是 response_item.payload.type（顶层被字节预筛拦截，
        // 对话内容的风险面集中在 response_item 的结构演化）
        "codex": [
            "message", "reasoning", "function_call", "function_call_output",
            "custom_tool_call", "custom_tool_call_output", "web_search_call",
            "agent_message", "local_shell_call", "local_shell_call_output",
        ],
    ]

    /// loader 在解析循环里对「见过但不认识」的类型调用。热路径安全：仅字典自增。
    public func note(source: String, type: String) {
        guard !type.isEmpty, !(Self.known[source]?.contains(type) ?? false) else { return }
        lock.lock()
        counts[source, default: [:]][type, default: 0] += 1
        lock.unlock()
    }

    /// 全量扫描收尾时输出汇总并清零（LoaderRuntime.indexAllSources 调用）。
    public func flushToLog() {
        lock.lock()
        let snapshot = counts
        counts = [:]
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let desc = snapshot.map { src, types in
            let inner = types.sorted { $0.value > $1.value }
                .map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
            return "\(src): {\(inner)}"
        }.joined(separator: " ")
        NSLog("[format] unknown types — %@ （上游可能出了新格式：确认是否该渲染，合法则加入 FormatTelemetry.known）", desc)
    }
}
