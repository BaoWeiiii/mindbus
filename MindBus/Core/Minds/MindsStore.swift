import Foundation

/// 思脉底座 · GUI 数据接口：把 `minds.md` 机械层读成用户 Minds 侧栏能直接消费的
/// 字符串状态。曾经还合并 `enriched.jsonl` 增补层（宿主模型写的自陈述），增补层
/// 已整体拆除（用户 2026-09-01 定案：不要例外，Minds 全线只留代码可证的内容）。
///
/// **只做数据层，不写任何 View**——渲染是 GUI 的工作，这里只负责「读出什么」。
@MainActor
public final class MindsStore: ObservableObject {
    /// `minds.md` 的机械层内容，原样保留磁盘字节，不做任何转写。
    @Published public private(set) var mechanicalMarkdown: String = ""

    private let mindsURL: URL

    /// 默认指向生产路径（尊重 `MINDBUS_MINDS_ROOT` 覆盖，见 `MindsBuilder.mindsRoot()`）；
    /// 测试注入指向临时目录的 URL。
    public init(mindsURL: URL = MindsBuilder.defaultMindsURL) {
        self.mindsURL = mindsURL
        // 创建即加载:视图第一帧就有数据,不等 onAppear(离屏渲染也不触发 onAppear)。
        // onAppear 的 reload 保留——每次切回 Minds 页刷新到最新。
        reload()
    }

    /// 重新读盘并刷新 `mechanicalMarkdown`。
    ///
    /// 文件 IO 直接同步做，不挪到后台 Task：`minds.md` 是用户库量级下的小文件
    /// （几十 KB 级统计文本，不是逐会话的语料），主线程同步读不会造成可感知卡顿。
    public func reload() {
        guard let data = FileManager.default.contents(atPath: mindsURL.path) else {
            // 文件缺失（用户还没打开过 App 扫描过一轮）：空态,不是错误——GUI 据此显示
            // "先扫一遍"之类的引导,不是报错横幅。
            mechanicalMarkdown = ""
            return
        }
        // 不可失败解码：这份文件正常只由 `MindsBuilder.build` 写出（保证合法 UTF-8），
        // 但用户可能手改它（design spec §1："用户看得见、好备份"），一个坏字节不该让
        // 整个读取判定成"文件不存在"。
        let content = String(decoding: data, as: UTF8.self)
        if let range = content.range(of: MindsBuilder.legacyWeakSpotsMarker) {
            // 旧版本文件遗留的 WEAK SPOTS 节（增补层拆除前由模型写入的条目）：截掉，
            // 不让它以"机械层"的名义混进界面。新版 build 不再写这个标记，下一轮扫描
            // 重写 minds.md 后这个分支自然不再命中。
            mechanicalMarkdown = String(content[content.startIndex..<range.lowerBound])
        } else {
            mechanicalMarkdown = content
        }
    }
}
