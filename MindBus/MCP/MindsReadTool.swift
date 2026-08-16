import Foundation
import MindBusCore

/// 思脉底座 · 只读暴露口：把 `MindsBuilder` 落盘的 `minds.md` 交给宿主模型，
/// WEAK SPOTS 一节现场用 `MindsEnrichedLog.entries()` 重渲染（design spec §4）。
///
/// 为什么不直接原样吐磁盘文件：`minds.md` 只在扫描收尾重建一次，而 `enriched.jsonl`
/// 随时可能被（同一个或另一个）宿主经 `minds_enrich`、未来 GUI 的确认/撤销按钮
/// append——两次重建之间必然有窗口期，磁盘上的 WEAK SPOTS 在这段窗口期内是过期的。
/// 这个工具保留磁盘文件里"机械五节"的字节（那部分只有下次扫描才会变），只把
/// WEAK SPOTS 一节换成现查现渲染的版本，保证调用方读到的增补永远新鲜。
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
        archive. The mechanical layer (OVERVIEW, PROJECT RHYTHM, TOP ENTITIES, VOCABULARY, \
        AGENT USAGE) is pure counted statistics, zero generation. WEAK SPOTS lists four gaps \
        counting alone cannot fill: spot:preferences (working preferences), spot:style \
        (collaboration style), spot:goals (current goals), spot:stack (tech stack, \
        self-reported). Entries there may carry an [unreviewed] prefix — the user has not \
        confirmed them yet; weigh accordingly.

        Takes no arguments. When a WEAK SPOT is thin or empty, look for evidence with \
        memory_search or memory_digest, then call minds_enrich with the spot id, your \
        statement, and the conversation_id(s) it came from.
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
        // 不可失败解码（同 `MindsEnrichedLog.entries()` 的既有理由）：这份文件正常只由
        // `MindsBuilder.build` 写出（保证是合法 UTF-8），但它是用户看得见、"好备份、能
        // 整体带走"的文件（design spec §1），手改或被其他工具误写入非法字节不该让
        // 整个读取直接判定成"文件不存在"——那会把一次编码事故升级成对产品承诺
        // （底座文件不存在时才给"先扫一遍"的提示）的破坏。
        let content = String(decoding: data, as: UTF8.self)
        return MCPToolOutput(merge(content: content))
    }

    /// 现场重合并：磁盘内容按 `MindsBuilder.weakSpotsMarker` 切开，标记之前的机械
    /// 五节原样保留，WEAK SPOTS 用传入的 `entries` 现渲染替换——纯函数，不碰文件，
    /// 可直接驱动测试（同 `MindsBuilder.renderDocument`/`renderWeakSpots` 的既有
    /// 拆分手法：查询/落盘与纯渲染分层，纯渲染部分才是测试主要覆盖的地方）。
    /// `entries` 默认取 `MindsEnrichedLog.entries()`（默认路径，同受
    /// `MINDBUS_MINDS_ROOT` 覆盖）——`run()` 不显式传，每次调用都现查一遍，这正是
    /// "读到的增补永远新鲜"这句承诺的落地点。
    ///
    /// 标记找不到（旧版本遗留文件 / 被用户手改删掉了那一行）：不报错、不判定"读取
    /// 失败"，把整份磁盘内容原样返回，只在末尾追加一份现算的 WEAK SPOTS——宁可让
    /// 输出里可能有一份看起来多余的内容，也不能因为找不到一个分隔符就让宿主模型
    /// 读不到任何机械层数据（降级不崩，任务简报原话）。
    static func merge(content: String, entries: [MindsEntry] = MindsEnrichedLog.entries()) -> String {
        let freshWeakSpots = MindsBuilder.renderWeakSpots(entries: entries)
        guard let range = content.range(of: MindsBuilder.weakSpotsMarker) else {
            return content + "\n\n" + freshWeakSpots
        }
        let mechanical = content[content.startIndex..<range.lowerBound]
        return mechanical + MindsBuilder.weakSpotsMarker + "\n" + freshWeakSpots
    }
}
