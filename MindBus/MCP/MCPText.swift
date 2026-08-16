import Foundation

/// 各 MCP 工具共用的文字加工。
///
/// 日期一律本机时区：索引里的月份分桶用的就是 SQLite 的 `localtime`，
/// 这里换成 UTC 会让"地图说 8 月"和"条目显示 7 月 31 日"同时出现。
public enum MCPText {

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = format
        return f
    }

    // 这两个 formatter 在 mindbus-mcp 进程启动时构造一次，`TimeZone.current` 在那一刻
    // 求值并冻结在实例里；SQL 端的 `localtime` 则是每次查询都重新读当前时区。若长驻
    // 进程存活跨越一次系统时区变更（用户跨时区旅行、修改系统时区设置），行内日期可能
    // 与 SQL 分桶的口径短暂不一致。可达性极低（需要进程碰巧在时区变更期间还活着且被
    // 调用），接受此风险，不为它重建 formatter。
    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let minuteFormatter = formatter("yyyy-MM-dd HH:mm")

    public static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    public static func minute(_ date: Date) -> String { minuteFormatter.string(from: date) }

    /// 折成单行并截断。换行/制表/连续空格一律折成单个空格——
    /// 列表项里出现真换行会把对齐彻底毁掉，而模型读不出对齐就读不出结构。
    public static func oneLine(_ s: String, max: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > max else { return collapsed }
        return String(collapsed.prefix(max)) + "…"
    }

    /// 取一段以命中词为中心的片段。
    ///
    /// 为什么不能直接截段首：`SegmentHit.bestSegmentText` 是整段预览（SQL 侧截到 4000 字），
    /// 命中词可能在第 3000 字——截段首给出的片段里一个查询词都没有，读起来像检索坏了。
    ///
    /// `needle` 传多词查询时只用第一个空白分隔的词；找不到就从头取。
    public static func snippet(_ text: String, around needle: String?, max: Int) -> String {
        // 负数会让下面 `flat.index(start, offsetBy: max, limitedBy:)` 把窗口终点算到
        // `start` 之前（`limitedBy:` 只挡越过 limit 方向、也就是向右的越界，挡不住反
        // 方向越过 start 本身）——实测直接触发 "Range requires lowerBound <= upperBound"
        // 的 Fatal error，崩掉整个 mindbus-mcp 进程。`max` 是 public 入参，不能假设调用方
        // 永远传正数，这里先钳成非负。右边这个 `max` 是形参，`Swift.max` 是标准库的自由
        // 函数，用 `Swift.` 显式限定就是为了在形参也叫 `max` 时仍能调用到它——`max/4`
        // 那行同理。此后这个函数体里的 `max` 均指这个钳过的局部变量。
        let max = Swift.max(0, max)
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard flat.count > max else { return flat }

        let term = needle?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        // 大小写不敏感；CJK 与英文紧邻时 `range(of:)` 照样命中（不依赖词边界）
        let found = term.flatMap { flat.range(of: $0, options: .caseInsensitive) }

        // 命中点前留一点上文（约窗口的四分之一），读得出"在说什么"；`max` 已钳过非负，
        // 这里的除法不会再把 `lead` 算成负数。
        let lead = max / 4
        let startOffset: Int
        if let found {
            startOffset = Swift.max(0, flat.distance(from: flat.startIndex, to: found.lowerBound) - lead)
        } else {
            startOffset = 0
        }
        let start = flat.index(flat.startIndex, offsetBy: startOffset)
        let end = flat.index(start, offsetBy: max, limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[start..<end])
        if startOffset > 0 { out = "…" + out }
        if end < flat.endIndex { out += "…" }
        return out
    }
}
