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

    private static let cell: CGFloat = 10
    private static let gap: CGFloat = 3

    /// 周一为一周之首(工作语境;GitHub 用周日,本产品用户是开发者,周一直觉更顺)。
    private var weeks: [[(day: String, count: Int)?]] {
        var byDay: [String: Int] = [:]
        for d in daily { byDay[d.day] = d.count }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"

        var days: [(String, Int)?] = []
        // 起点对齐到 365 天前那周的周一,末尾到今天——首列可能有前导空格
        let start = cal.date(byAdding: .day, value: -364, to: today)!
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

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: Self.gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, entry in
                        cellView(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ entry: (day: String, count: Int)?) -> some View {
        if let entry {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: entry.count))
                .frame(width: Self.cell, height: Self.cell)
                .help("\(entry.day) · \(entry.count)")
                .onTapGesture { if entry.count > 0 { selectedDay = entry.day } }
                .popover(isPresented: Binding(
                    get: { selectedDay == entry.day },
                    set: { if !$0 { selectedDay = nil } }
                )) {
                    dayPopover(entry.day)
                }
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
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
