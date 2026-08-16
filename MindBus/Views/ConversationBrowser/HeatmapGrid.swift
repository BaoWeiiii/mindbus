import SwiftUI
import MindBusCore

/// 活跃热力图:GitHub 贡献图式 365 天格子(列=周、行=周一至周日,5 档金色)。
/// 行业事实标准(Obsidian 6+ 插件/flomo/Kindle 全用这个形态);
/// 「统计是入口不是装饰」——格子可点,popover 列出当天会话,再点直达。
struct HeatmapGrid: View {
    let daily: [(day: String, count: Int)]
    let store: ConversationStore
    var onOpen: (String) -> Void

    @State private var selectedDay: String?

    /// 格子边长上限(列宽由等分算出,不超过它)
    private static let cell: CGFloat = 14
    private static let gap: CGFloat = 3

    /// 周一为一周之首(工作语境;GitHub 用周日,本产品用户是开发者,周一直觉更顺)。
    ///
    /// 窗口不固定 365 天:库只有 115 天时,前 250 列全是空格子——一半图在讲「没有数据」。
    /// 起点取「第一条有记录的那天」和「365 天前」里更晚的那个,再对齐到那周的周一。
    private var weeks: [[(day: String, count: Int)?]] {
        var byDay: [String: Int] = [:]
        for d in daily { byDay[d.day] = d.count }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"

        var start = cal.date(byAdding: .day, value: -364, to: today)!
        if let firstActive = daily.filter({ $0.count > 0 }).map(\.day).min(),
           let d = f.date(from: firstActive), d > start {
            start = cal.startOfDay(for: d)
        }
        var days: [(String, Int)?] = []
        let weekdayOffset = (cal.component(.weekday, from: start) + 5) % 7   // 周一=0
        days.append(contentsOf: Array(repeating: nil, count: weekdayOffset))
        var cursor = start
        while cursor <= today {
            let key = f.string(from: cursor)
            days.append((key, byDay[key] ?? 0))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        return stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
    }

    /// 每列取该周第一天的月份,月份变了才标——没有刻度的格子阵读不出时间。
    private func monthLabel(for week: [(day: String, count: Int)?], previous: String?) -> String? {
        guard let day = week.compactMap({ $0?.day }).first else { return nil }
        let month = String(day.prefix(7))
        guard month != previous else { return nil }
        return String(day.dropFirst(5).prefix(2))
    }

    var body: some View {
        let cols = weeks
        var seen: String?
        var labels: [String?] = []
        for w in cols {
            let l = monthLabel(for: w, previous: seen)
            if l != nil, let d = w.compactMap({ $0?.day }).first { seen = String(d.prefix(7)) }
            labels.append(l)
        }
        // 列等分宽度 + 格子正方形:窗口宽时格子长大填满卡片,窄时自己缩,
        // 上限 `cell` 拦住「只有 18 列」时格子涨成大方块。
        return HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, week in
                VStack(spacing: Self.gap) {
                    Text(labels[i] ?? " ")
                        .font(BrandFont.mono(9)).foregroundStyle(DSLight.t3)
                        .lineLimit(1).fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(week.enumerated()), id: \.offset) { _, entry in
                        cellView(entry)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: CGFloat(max(cols.count, 1)) * (Self.cell + Self.gap), alignment: .leading)
    }

    @ViewBuilder
    private func cellView(_ entry: (day: String, count: Int)?) -> some View {
        if let entry {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: entry.count))
                .aspectRatio(1, contentMode: .fit)
                .help("\(entry.day) · \(entry.count)")
                .onTapGesture { if entry.count > 0 { selectedDay = entry.day } }
                .popover(isPresented: Binding(
                    get: { selectedDay == entry.day },
                    set: { if !$0 { selectedDay = nil } }
                )) {
                    dayPopover(entry.day)
                }
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit)
        }
    }

    /// 5 档金色(0 档=底色)。阈值 1/3/6/10——个人库量级下的手感分档。
    private func color(for count: Int) -> Color {
        switch count {
        case 0: return DSLight.sf2
        case 1...2: return DSLight.gold.opacity(0.25)
        case 3...5: return DSLight.gold.opacity(0.45)
        case 6...9: return DSLight.gold.opacity(0.7)
        default: return DSLight.gold
        }
    }

    private func dayPopover(_ day: String) -> some View {
        let convs = store.conversationsOn(day: day)
        return VStack(alignment: .leading, spacing: 2) {
            Text(day).font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                .padding(.bottom, 4)
            ForEach(convs, id: \.id) { conv in
                Button {
                    selectedDay = nil
                    onOpen(conv.id)
                } label: {
                    Text(conv.label).font(.system(size: 12)).foregroundStyle(DSLight.t1)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 280)
    }
}
