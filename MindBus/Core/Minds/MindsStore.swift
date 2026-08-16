import Foundation

/// 思脉底座 · GUI 数据接口：把 `minds.md` 机械层与 `enriched.jsonl` 增补层合并成
/// 用户 Minds 侧栏能直接消费的两份状态（design spec §5 "GUI(用户的 Minds 侧栏)"）。
///
/// **只做数据层，不写任何 View**——渲染、确认按钮、撤销按钮都是 GUI 的工作；这里
/// 只负责「读出什么」与「确认/撤销这个数据动作本身」，与 MCP 侧的 `minds_enrich`
/// 共享同一份 `MindsEnrichedLog`，两个消费者（GUI 进程与宿主拉起的 MCP 子进程）
/// 并发写同一个文件天然安全（append-only + `O_APPEND`，见 `MindsEnrichedLog` 的
/// 类文档注释）。
///
/// 与 `MindsReadTool`（MCP 侧的等价只读消费者）刻意不同：那边是无状态 `enum`，
/// 每次调用现查现渲染成一份 merge 后的字符串给宿主模型囫囵读；这里是
/// `ObservableObject`，把机械层字符串与增补层条目（按 `MindsSpot` 分组）分别发布，
/// 因为 SwiftUI 侧要逐个 WEAK SPOT 分组渲染、给每条 `unreviewed` 配确认/撤销按钮，
/// 糅合成一份文本反而不利于逐条驱动 View。
@MainActor
public final class MindsStore: ObservableObject {
    /// `minds.md` 里 `MindsBuilder.weakSpotsMarker` 之前的五节（OVERVIEW ... AGENT USAGE），
    /// 原样保留磁盘字节，不做任何转写。WEAK SPOTS 那一节改由 `entriesBySpot` 单独承载——
    /// GUI 要按空位分组渲染、逐条挂确认/撤销按钮，不需要（也不该）再从一份拼好的
    /// Markdown 字符串里反解出条目结构。
    @Published public private(set) var mechanicalMarkdown: String = ""

    /// `enriched.jsonl` 合并后的条目，按 `MindsSpot` 分组。**只含 `unreviewed` 与
    /// `confirmed`，不含 `revoked`**——GUI 里点了撤销的条目应立即从列表消失，
    /// 底层记录仍留在 `enriched.jsonl` 里（append-only，从不物理删改），只是不再
    /// 出现在这份供渲染用的视图里。
    @Published public private(set) var entriesBySpot: [MindsSpot: [MindsEntry]] = [:]

    private let mindsURL: URL
    private let logURL: URL

    /// 默认指向生产路径（两者都尊重 `MINDBUS_MINDS_ROOT` 覆盖，见
    /// `MindsEnrichedLog.mindsRoot()`）；测试注入指向临时目录的 URL，同
    /// `MindsEnrichedLogTests`/`MindsBuilderTests` 的既有隔离手法。
    public init(mindsURL: URL = MindsBuilder.defaultMindsURL,
                logURL: URL = MindsEnrichedLog.defaultLogURL) {
        self.mindsURL = mindsURL
        self.logURL = logURL
        // 创建即加载:视图第一帧就有数据,不等 onAppear(离屏渲染也不触发 onAppear)。
        // onAppear 的 reload 保留——每次切回 Minds 页刷新到最新。
        reload()
    }

    /// 重新读盘并刷新两个 `@Published` 状态。
    ///
    /// 文件 IO 直接同步做，不挪到后台 Task：`minds.md`/`enriched.jsonl` 是用户库
    /// 量级下的小文件（几十 KB 级——六节机械统计 + 至多几十条增补条目，不是逐会话
    /// 的语料），主线程同步读不会造成可感知卡顿，与 `MindsReadTool.run()`（MCP 请求
    /// 线程上同样同步读同一份文件）的既有取舍一致。换成异步要多背一套"加载中"状态
    /// 与竞态取消逻辑，为一个当前量级下不存在的性能问题预付复杂度不值得——真到文件
    /// 大到需要异步的那天（比如 WEAK SPOTS 条目暴涨到几千条）再改。
    public func reload() {
        // entriesBySpot 与 mindsURL 是否存在无关：即便 minds.md 还没被首次扫描
        // 建出来，enriched.jsonl 里已经写入的增补条目仍应该能在 GUI 里看到。
        let live = MindsEnrichedLog.entries(from: logURL).filter { $0.status != .revoked }
        entriesBySpot = Dictionary(grouping: live, by: \.spot)

        guard let data = FileManager.default.contents(atPath: mindsURL.path) else {
            // 文件缺失（用户还没打开过 App 扫描过一轮）：空态,不是错误——GUI 据此显示
            // "先扫一遍"之类的引导,不是报错横幅。
            mechanicalMarkdown = ""
            return
        }
        // 不可失败解码：同 `MindsEnrichedLog.entries()`/`MindsReadTool.run()` 的既有理由——
        // 这份文件正常只由 `MindsBuilder.build` 写出（保证合法 UTF-8），但用户可能手改它
        // （design spec §1："用户看得见、好备份"），一个坏字节不该让整个读取判定成"文件
        // 不存在"。
        let content = String(decoding: data, as: UTF8.self)
        if let range = content.range(of: MindsBuilder.weakSpotsMarker) {
            mechanicalMarkdown = String(content[content.startIndex..<range.lowerBound])
        } else {
            // 标记找不到（旧版本遗留文件 / 被手改删掉了那一行）：整份内容当成"机械层"
            // 原样交出去，同 `MindsReadTool.merge` 的降级手法——宁可多给一点，也不能因为
            // 找不到一个分隔符就让 GUI 什么都读不到。
            mechanicalMarkdown = content
        }
    }

    /// 用户在 GUI 点"确认"：append 一条 `confirm` 记录 + 立即 reload，让状态流转
    /// （`unreviewed` → `confirmed`）对界面可见。是否存在同名 `entryID` 不在这里校验——
    /// `MindsEnrichedLog.appendConfirm` 本就不做这层校验（未知 target 在 `entries()`
    /// 合并时静默忽略），与 append-only 日志"只管写、读时合并"的既有分工一致。
    public func confirm(entryID: String) {
        MindsEnrichedLog.appendConfirm(target: entryID, to: logURL)
        reload()
    }

    /// 用户在 GUI 点"撤销"：append 一条 `revoke` 记录 + 立即 reload。`revoke` 是吸收态
    /// （`MindsEnrichedLog.entries()` 的合并规则），之后这条 id 不会再出现在
    /// `entriesBySpot` 里,但底层记录不物理删改,仍在 `enriched.jsonl` 可考古。
    public func revoke(entryID: String) {
        MindsEnrichedLog.appendRevoke(target: entryID, to: logURL)
        reload()
    }
}
