import Foundation
import MindBusCore

/// 思脉底座 · 只读暴露口：把 `MindsBuilder` 落盘的 `minds.md` 交给宿主模型。
///
/// 全文件都是机械层——每一行是某条 SQL 统计的直接转写。曾经的 WEAK SPOTS 增补节
/// （宿主模型经 minds_enrich 写自陈述）已整体拆除（用户 2026-09-01 定案：不要例外），
/// 这个工具从"磁盘机械节 + 现渲染增补节"退回成纯粹的文件读取。
public enum MindsReadTool {

    /// 生产默认读取 `MindsBuilder.defaultMindsURL`（尊重 `MINDBUS_MINDS_ROOT`）；
    /// 测试替换成指向临时文件的闭包，用完在 `tearDown`/`addTeardownBlock` 里还原——
    /// 进程级共享的 static var，没有实例作用域，同 `MemoryOpenTool.refLogger` 的
    /// 注入模式与理由。
    internal static var mindsFileURL: () -> URL = { MindsBuilder.defaultMindsURL }

    public static let spec = MCPToolSpec(
        name: "minds_read",
        description: """
        CALL THIS at the START of a session (or before any personalized task) to know who \
        you are working with — preferences, active projects, vocabulary — without asking.

        Read the user's Minds base — their own persistent profile built from this local \
        archive. Every line is pure counted statistics from the conversation index \
        (counted, not generated): overview, project rhythm, top entities, vocabulary, \
        agent usage, plus mechanically surfaced patterns (unfinished threads, recurring \
        topics, dormant projects). Takes no arguments.
        """,
        inputSchema: [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String],
        ],
        run: { _, _ in run() })

    private static func run() -> MCPToolOutput {
        let url = mindsFileURL()
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return MCPToolOutput("""
            No Minds file at \(url.path) yet. Open the MindBus app once so it can scan and \
            build your Minds file, then retry.
            """, isError: true)
        }
        // 不可失败解码：这份文件正常只由 `MindsBuilder.build` 写出（保证是合法 UTF-8），
        // 但它是用户看得见、"好备份、能整体带走"的文件（design spec §1），手改或被其他
        // 工具误写入非法字节不该让整个读取直接判定成"文件不存在"——那会把一次编码事故
        // 升级成对产品承诺（底座文件不存在时才给"先扫一遍"的提示）的破坏。
        let content = String(decoding: data, as: UTF8.self)
        return MCPToolOutput(stripLegacyWeakSpots(content))
    }

    /// 旧版本 minds.md 遗留的 WEAK SPOTS 节（增补层拆除前由模型写入的条目）：按
    /// 分隔标记截掉，不把模型写的文字混进"counted, not generated"的输出里。新版
    /// build 不再写这个标记；用户装上新版后、下一轮扫描重写文件前的窗口期靠这里兜底。
    /// 标记不存在（新文件 / 用户手改）：原样返回。纯函数，供测试直接驱动。
    static func stripLegacyWeakSpots(_ content: String) -> String {
        guard let range = content.range(of: MindsBuilder.legacyWeakSpotsMarker) else {
            return content
        }
        return String(content[content.startIndex..<range.lowerBound])
    }
}
