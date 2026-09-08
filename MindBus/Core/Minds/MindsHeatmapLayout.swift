import Foundation

/// 活跃地图的格子排布。纯计算，抽出来是为了能测——
/// 「窗口按库龄裁剪」「首列前导空格」「月份刻度只在月份变化时出现」这三条规则
/// 原本埋在 View 的 `private var weeks` 里，只能靠肉眼看渲染图验证。
public struct MindsHeatmapLayout: Sendable {

    /// 一格。`day == nil` 表示首列的前导空位（那一周的周一在窗口之前）。
    public struct Cell: Equatable, Sendable {
        public let day: String?
        public let count: Int

        public static let blank = Cell(day: nil, count: 0)
    }

    /// 列 = 周（周一在上），行 = 周一…周日
    public let weeks: [[Cell]]
    /// 与 `weeks` 一一对应；月份变化的那一列给月份两位数，其余 nil
    public let monthLabels: [String?]

    /// - Parameters:
    ///   - daily: 每日对话数（`yyyy-MM-dd`）
    ///   - now: 「今天」由调用方给，测试才能固定时钟
    ///   - maxDays: 最长回看窗口
    public init(daily: [(day: String, count: Int)], now: Date,
                maxDays: Int = 365, calendar: Calendar = .current) {
        var byDay: [String: Int] = [:]
        for d in daily { byDay[d.day] = d.count }

        let today = calendar.startOfDay(for: now)
        var start = calendar.date(byAdding: .day, value: -(maxDays - 1), to: today)!
        // 窗口按真实库龄裁剪:库只有 115 天时，画满 365 列意味着前 250 列全是空格子，
        // 一半的图在讲「没有数据」。
        if let firstActive = daily.filter({ $0.count > 0 }).map(\.day).min(),
           let d = MindsDocument.day(from: firstActive), d > start {
            start = calendar.startOfDay(for: d)
        }

        var cells: [Cell] = []
        // 周一 = 0（工作语境；GitHub 用周日，本产品用户是开发者）
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        cells.append(contentsOf: Array(repeating: .blank, count: offset))

        var cursor = start
        while cursor <= today {
            let key = MindsDocument.dayString(cursor)
            cells.append(Cell(day: key, count: byDay[key] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let cols = stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }
        self.weeks = cols

        var seen: String?
        var labels: [String?] = []
        for w in cols {
            guard let day = w.compactMap(\.day).first else { labels.append(nil); continue }
            let month = String(day.prefix(7))
            if month != seen {
                seen = month
                labels.append(String(day.dropFirst(5).prefix(2)))
            } else {
                labels.append(nil)
            }
        }
        self.monthLabels = labels
    }

    /// 5 档色阶的档位（0 = 那天没有对话，不是「浅金」）。
    /// 阈值 1/3/6/10 是个人库量级下的手感分档。
    public static func bucket(_ count: Int) -> Int {
        switch count {
        case ..<1: return 0
        case 1...2: return 1
        case 3...5: return 2
        case 6...9: return 3
        default: return 4
        }
    }
}
