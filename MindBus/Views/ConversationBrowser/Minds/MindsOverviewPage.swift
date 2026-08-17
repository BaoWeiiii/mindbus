import SwiftUI
import Charts
import MindBusCore

/// PAGE 01 · 你的总览：核心指标 → 活跃地图 → 工作节律 → 本月 / 周末的你。
struct MindsOverviewPage: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MindsUI.moduleGap) {
            MindsSummaryMetrics(ctx: ctx)
            MindsActivityMap(ctx: ctx)
            MindsWorkRhythm(ctx: ctx)
            MindsTwoColumn {
                MindsMonthlyTrend(ctx: ctx)
            } right: {
                MindsWeekendPattern(ctx: ctx)
            }
        }
    }
}

// MARK: - A 核心指标

/// 顶部横向 Summary Card：三个指标等分，靠极淡竖线分区（粗竖线会把一张卡切成三张）。
struct MindsSummaryMetrics: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Group {
            if ctx.isLoading {
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 14) {
                            MindsSkeletonBar(width: 22, height: 22, phase: Double(i) * 0.1)
                            VStack(alignment: .leading, spacing: 7) {
                                MindsSkeletonBar(width: 96, height: 24, phase: Double(i) * 0.1)
                                MindsSkeletonBar(width: 56, height: 10, phase: Double(i) * 0.1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if i < 2 { divider }
                    }
                }
                .padding(MindsUI.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MindsUI.surface, in: RoundedRectangle(cornerRadius: MindsUI.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: MindsUI.cardRadius)
                        .stroke(MindsUI.border, lineWidth: 1)
                }
            } else if let st = ctx.viz.sanctuary, st.conversationCount > 0 {
                HStack(spacing: 0) {
                    metric(icon: "bubble.left.and.bubble.right",
                           value: "\(st.conversationCount)",
                           label: l10n.s.heroConversations,
                           delta: monthDelta)
                    divider
                    metric(icon: "internaldrive",
                           value: String(format: "%.0f MB", Double(ctx.viz.vault.bytes) / 1_048_576),
                           label: l10n.s.heroVaultCopies,
                           delta: nil)
                    divider
                    metric(icon: "calendar",
                           value: "\(libraryDays(st))",
                           label: l10n.s.heroLibraryDays,
                           delta: nil)
                }
                .padding(MindsUI.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    // 几乎不可察觉的暖调渐变——用来把这张卡和下面的白卡区分开，
                    // 不是装饰，所以两端色差控制在 1 个色阶以内
                    LinearGradient(colors: [Color(hex: 0xFBF8F1), .white],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .clipShape(RoundedRectangle(cornerRadius: MindsUI.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: MindsUI.cardRadius)
                        .stroke(MindsUI.border, lineWidth: 1)
                }
            }
        }
    }

    /// 环比只给「场对话」——本地副本与收纳天数没有历史快照，
    /// 现编一个数就违背了 counted, not generated。
    private var monthDelta: String? {
        let cur = ctx.viz.thisMonth, prev = ctx.viz.lastMonth
        guard cur > 0, prev > 0 else { return nil }
        return l10n.s.mMonthDelta(cur - prev)
    }

    private func libraryDays(_ st: ConversationIndex.SanctuaryStats) -> Int {
        st.earliest.map { max(1, Int(Date().timeIntervalSince($0) / 86_400) + 1) } ?? 1
    }

    /// 分隔线两侧必须等距。此前只有前一格尾部有 Spacer、线到下一个图标是 0，
    /// 线就贴在图标上了（真机可见）。留白给线自己带，不靠邻居的 Spacer 凑。
    private var divider: some View {
        Rectangle().fill(MindsUI.border.opacity(0.7))
            .frame(width: 1, height: 46)
            .padding(.horizontal, 22)
    }

    private func metric(icon: String, value: String, label: String, delta: String?) -> some View {
        HStack(alignment: .mindsMetricCenter, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(MindsUI.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold))
                    .kerning(-0.6)
                    .foregroundStyle(MindsUI.textPrimary)
                    .mindsTabularNumbers()
                    // 图标对齐这一行的中心，不是整块的中心
                    .alignmentGuide(.mindsMetricCenter) { $0[VerticalAlignment.center] }
                HStack(spacing: 10) {
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(MindsUI.textSecondary)
                    if let delta {
                        // 环比是另一个量，与指标名之间要有可见的断口，
                        // 否则「场对话 比上月 -3」读起来像一句话
                        Text(delta)
                            .font(.system(size: 11))
                            .foregroundStyle(MindsUI.textTertiary)
                            .mindsTabularNumbers()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(MindsUI.surfaceSoft, in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - B 活跃地图

struct MindsActivityMap: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Group {
            if ctx.isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecHeatmap, hint: l10n.s.mindsHeatmapHint)
                    MindsSkeletonGrid().mindsCard()
                }
            } else if !ctx.viz.dailyHeat.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecHeatmap, hint: l10n.s.mindsHeatmapHint)
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            MindsHeatmap(daily: ctx.viz.dailyHeat, ctx: ctx)
                            heatLegend
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(3)
                        if let a = ctx.viz.activeDays, a.active > 0 {
                            Rectangle().fill(MindsUI.border.opacity(0.8))
                                .frame(width: 1)
                                .padding(.vertical, 2)
                            VStack(alignment: .trailing, spacing: 14) {
                                stat(l10n.s.mHeatActiveDays, "\(a.active)")
                                stat(l10n.s.mHeatLongestRun, l10n.s.mSpanDays(a.longestRun))
                                stat(l10n.s.mHeatLongestGap, l10n.s.mSpanDays(a.longestGap))
                            }
                            .fixedSize()
                            // 让第一格与格子阵首行齐平:热力图顶上还压着一行月份刻度
                            .padding(.top, MindsHeatmap.axisHeight)
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }

    /// 色阶图例。库龄不满一年时格子阵撑不满 78%，与其让左下角空着，
    /// 不如放图例——这也是贡献图的标准配件。
    private var heatLegend: some View {
        HStack(spacing: 5) {
            Text(l10n.s.mHeatLegendLess)
                .font(.system(size: 10.5)).foregroundStyle(MindsUI.textTertiary)
            ForEach(Array(MindsUI.heat.enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 11, height: 11)
            }
            Text(l10n.s.mHeatLegendMore)
                .font(.system(size: 10.5)).foregroundStyle(MindsUI.textTertiary)
        }
    }

    /// 数字明显高于 Label——这三格是「读数」，不是说明文字
    private func stat(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(MindsUI.textSecondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(MindsUI.textPrimary)
                .mindsTabularNumbers()
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
}

/// GitHub 贡献图式格子阵。窗口不固定 365 天——库只有 115 天时前 250 列全空，
/// 一半的图在讲「没有数据」。
struct MindsHeatmap: View {
    let daily: [(day: String, count: Int)]
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    @State private var hovered: String?
    @State private var opened: String?

    private static let cell: CGFloat = 17
    private static let gap: CGFloat = 3
    /// 月份刻度行的高度(含与格子的间距)——右侧统计块靠它对齐到首行格子
    static let axisHeight: CGFloat = 18

    var body: some View {
        let layout = MindsHeatmapLayout(daily: daily, now: Date())
        let cols = layout.weeks
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(Array(cols.enumerated()), id: \.offset) { i, week in
                    VStack(spacing: Self.gap) {
                        Text(layout.monthLabels[i] ?? " ")
                            .font(BrandFont.mono(9))
                            .foregroundStyle(MindsUI.textTertiary)
                            .lineLimit(1).fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(week.enumerated()), id: \.offset) { _, entry in
                            cell(entry)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: CGFloat(max(cols.count, 1)) * (Self.cell + Self.gap), alignment: .leading)
        }
    }

    @ViewBuilder
    private func cell(_ entry: MindsHeatmapLayout.Cell) -> some View {
        if let day = entry.day {
            RoundedRectangle(cornerRadius: 3)
                .fill(MindsUI.heat[MindsHeatmapLayout.bucket(entry.count)])
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if hovered == day, entry.count > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(MindsUI.accentStrong, lineWidth: 1.5)
                    }
                }
                .onHover { hovered = $0 ? day : (hovered == day ? nil : hovered) }
                .onTapGesture { if entry.count > 0 { opened = day } }
                .overlay(alignment: .bottom) {
                    if hovered == day, entry.count > 0 {
                        MindsTooltip(lines: [longDay(day),
                                             l10n.s.mHeatTipConversations(entry.count)])
                            .offset(y: -Self.cell - 6)
                            .allowsHitTesting(false)
                            .zIndex(10)
                    }
                }
                .popover(isPresented: Binding(get: { opened == day },
                                              set: { if !$0 { opened = nil } })) {
                    dayPopover(day)
                }
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit)
        }
    }

    private func longDay(_ iso: String) -> String {
        guard let d = MindsDocument.day(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: ctx.isZh ? "zh_CN" : "en_US")
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: d)
    }

    private func dayPopover(_ day: String) -> some View {
        let convs = ctx.store.conversationsOn(day: day)
        return VStack(alignment: .leading, spacing: 2) {
            Text(day).font(BrandFont.mono(11)).foregroundStyle(MindsUI.textTertiary)
                .padding(.bottom, 4)
            ForEach(convs, id: \.id) { conv in
                Button {
                    opened = nil
                    ctx.open(conversation: conv.id)
                } label: {
                    Text(conv.label).font(.system(size: 12)).foregroundStyle(MindsUI.textPrimary)
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

// MARK: - C 工作节律

struct MindsWorkRhythm: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MindsSectionHeader(title: l10n.s.mindsSecWorkRhythm, hint: l10n.s.mindsWorkRhythmHint)
            Group {
                if ctx.isLoading {
                    MindsSkeletonBody(chartHeight: 76, lines: 4, chartFirst: false)
                } else if insights.isEmpty {
                    MindsEmptyNote(text: l10n.s.mindsEmptyRhythm)
                } else {
                    MindsTwoColumn(stackedSpacing: 14) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(insights.enumerated()), id: \.offset) { _, item in
                                MindsInsightRow(icon: item.icon, title: item.title, detail: item.detail)
                            }
                            Spacer(minLength: 0)
                        }
                    } right: {
                        MindsHourBars(hours: ctx.viz.hourly24, ctx: ctx)
                    }
                }
            }
            .mindsCard()
        }
    }

    private struct Insight { let icon: String; let title: String; let detail: String }

    private var insights: [Insight] {
        var out: [Insight] = []
        let quarters = stride(from: 0, to: 24, by: 4).map { h in
            ctx.viz.hourly24.dropFirst(h).prefix(4).reduce(0, +)
        }
        let total = quarters.reduce(0, +)
        let names = ["00-04", "04-08", "08-12", "12-16", "16-20", "20-24"]
        if total > 0, let idx = quarters.indices.max(by: { quarters[$0] < quarters[$1] }) {
            out.append(Insight(icon: "clock",
                               title: l10n.s.mRhythmPeakTitle(names[idx]),
                               detail: l10n.s.mRhythmPeakDetail(quarters[idx] * 100 / total,
                                                                quarters[idx], total)))
        }
        if let b = ctx.viz.busiest, total > 0 {
            out.append(Insight(icon: "flame",
                               title: l10n.s.mRhythmBusiestTitle(b.day),
                               detail: l10n.s.mRhythmBusiestDetail(b.count, b.count * 100 / max(total, 1))))
        }
        if let peak = ctx.viz.switching.peak, ctx.viz.switching.avgPerDay > 0 {
            out.append(Insight(icon: "arrow.triangle.swap",
                               title: l10n.s.mRhythmJuggleTitle(String(format: "%.1f", ctx.viz.switching.avgPerDay)),
                               detail: l10n.s.mRhythmJuggleDetail(peak.count, peak.day)))
        }
        if let wp = ctx.viz.weekPercentile {
            out.append(Insight(icon: "chart.bar",
                               title: l10n.s.mRhythmWeekTitle(wp.thisWeek),
                               detail: l10n.s.mRhythmWeekDetail(wp.percentile, wp.median)))
        }
        return out
    }
}

/// 24 小时分布。自绘而不用 Swift Charts：每根柱要单独命中做 tooltip，
/// 而且 Swift Charts 在本工程里没有隐式宽度约束，曾把窗口顶穿。
struct MindsHourBars: View {
    let hours: [Int]
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared
    @State private var hovered: Int?

    var body: some View {
        let maxV = max(hours.max() ?? 1, 1)
        let total = max(hours.reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(hours.enumerated()), id: \.offset) { h, v in
                    bar(hour: h, value: v, maxV: maxV, total: total)
                }
            }
            .frame(height: 76)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MindsUI.border).frame(height: 1)
            }
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(String(format: "%02d", h))
                        .font(BrandFont.mono(9)).foregroundStyle(MindsUI.textTertiary)
                    if h != 18 { Spacer(minLength: 0) }
                }
                Spacer(minLength: 0)
                Text("24").font(BrandFont.mono(9)).foregroundStyle(MindsUI.textTertiary)
            }
        }
    }

    private func bar(hour h: Int, value v: Int, maxV: Int, total: Int) -> some View {
        // 16-20 是开场高峰段，用实金；其余淡金。深浅不按每根柱的高度渐变——
        // 高度已经在表达大小了，再叠一层明度是重复编码。
        let peak = (16...19).contains(h)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2)
                .fill(peak ? MindsUI.accent : MindsUI.chartMuted)
                // 上限 14:宽窗口下 24 根柱平分会长到 22pt 宽,那是色块不是柱子
                .frame(maxWidth: 14)
                .frame(height: max(2, 76 * CGFloat(v) / CGFloat(maxV)))
                .opacity(hovered == nil || hovered == h ? 1 : 0.55)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? h : (hovered == h ? nil : hovered) }
        .overlay(alignment: .top) {
            if hovered == h {
                MindsTooltip(lines: [l10n.s.mHourTipRange(h),
                                     l10n.s.mHourTipCount(v, String(format: "%.1f", Double(v) * 100 / Double(total)))])
                    .offset(y: -34)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
    }
}

// MARK: - D 本月

struct MindsMonthlyTrend: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let cur = ctx.viz.thisMonth
        return VStack(alignment: .leading, spacing: 0) {
            MindsSectionHeader(title: l10n.s.mindsSecThisMonth, hint: l10n.s.mindsThisMonthHint)
            VStack(alignment: .leading, spacing: 10) {
                if ctx.isLoading {
                    MindsSkeletonBody(chartHeight: 92, lines: 2)
                } else if cur == 0 {
                    MindsEmptyNote(text: l10n.s.mindsEmptyGeneric)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(cur)")
                            .font(.system(size: 28, weight: .semibold)).kerning(-0.5)
                            .foregroundStyle(MindsUI.textPrimary)
                            .mindsTabularNumbers()
                        Text(l10n.s.heroConversations)
                            .font(.system(size: 12)).foregroundStyle(MindsUI.textSecondary)
                        if ctx.viz.lastMonth > 0 {
                            Text(l10n.s.mMonthDelta(cur - ctx.viz.lastMonth))
                                .font(.system(size: 11)).foregroundStyle(MindsUI.textTertiary)
                                .mindsTabularNumbers()
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(MindsUI.surfaceSoft, in: Capsule())
                                .padding(.leading, 4)
                        }
                    }
                    let flow = ctx.viz.monthlyFlow
                    if flow.count >= 2 {
                        VStack(spacing: 5) {
                            MindsMonthlyArea(months: flow)
                            MindsMonthAxis(months: flow)
                        }
                    }
                    footnotes
                }
            }
            .mindsCard()
        }
    }

    @ViewBuilder
    private var footnotes: some View {
        let mo = ctx.viz.month
        VStack(alignment: .leading, spacing: 5) {
            if !mo.cur.isEmpty {
                let tools = l10n.s.mMonthTools(mo.cur.map { "\(ctx.sourceName($0.key)) \($0.count)" }
                    .joined(separator: " · "))
                Text(tools)
                    .font(.system(size: 12)).foregroundStyle(MindsUI.textSecondary)
                    .mindsTabularNumbers()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !mo.newEntities.isEmpty {
                Text(l10n.s.mMonthFirstSeen(mo.newEntities.prefix(5).joined(separator: " · ")))
                    .font(.system(size: 12)).foregroundStyle(MindsUI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 月度趋势面积图。这一张留在 Swift Charts：catmullRom 平滑曲线手绘不划算，
/// 且它没有逐点命中需求。
struct MindsMonthlyArea: View {
    let months: [(month: String, count: Int)]

    var body: some View {
        Chart {
            ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                AreaMark(x: .value("m", i), y: .value("c", m.count))
                    .foregroundStyle(LinearGradient(
                        colors: [MindsUI.accent.opacity(0.28), MindsUI.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("m", i), y: .value("c", m.count))
                    .foregroundStyle(MindsUI.accent)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            if let last = months.indices.last {
                PointMark(x: .value("m", last), y: .value("c", months[last].count))
                    .foregroundStyle(MindsUI.accent)
                    .symbolSize(38)
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("\(months[last].count)")
                            .font(BrandFont.mono(10, weight: .medium))
                            .foregroundStyle(MindsUI.accentStrong)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, to: months.count,
                                           by: max(1, months.count / 6)))) { v in
                AxisValueLabel {
                    if let i = v.as(Int.self), months.indices.contains(i) {
                        Text(String(months[i].month.suffix(2)))
                            .font(BrandFont.mono(9)).foregroundStyle(MindsUI.textTertiary)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        // 两端贴边:连续轴默认各留一段内缩,曲线会浮在图区中间
        .chartXScale(range: .plotDimension(startPadding: 0, endPadding: 0))
        .frame(height: 92).frame(maxWidth: .infinity)
    }
}

/// 月份刻度自绘。Swift Charts 的末端刻度会被绘图区裁掉，而给绘图区留尾距又会让
/// 面积图的右缘悬空——两头不讨好。标签自己排还顺带和 24 小时柱、周末柱统一成
/// 同一套做法（图归图、轴归轴）。
struct MindsMonthAxis: View {
    let months: [(month: String, count: Int)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                Text(String(m.month.suffix(2)))
                    .font(BrandFont.mono(9))
                    .foregroundStyle(MindsUI.textTertiary)
                    .frame(maxWidth: .infinity,
                           alignment: i == 0 ? .leading
                                     : (i == months.count - 1 ? .trailing : .center))
            }
        }
    }
}

// MARK: - E 周末的你

struct MindsWeekendPattern: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let split = ctx.viz.weekendSplit
        return VStack(alignment: .leading, spacing: 0) {
            MindsSectionHeader(title: l10n.s.mindsSecWeekend, hint: l10n.s.mindsWeekendHint)
            VStack(alignment: .leading, spacing: 12) {
                if ctx.isLoading {
                    MindsSkeletonBody(chartHeight: 88, lines: 2)
                } else if split.weekday.isEmpty && split.weekend.isEmpty {
                    MindsEmptyNote(text: l10n.s.mindsEmptyGeneric)
                } else {
                    weekBars
                    if !split.weekend.isEmpty {
                        MindsInsightRow(icon: "sun.max",
                                        title: l10n.s.mWeekendLine(split.weekend.prefix(3)
                                            .map { "\($0.key) \($0.count)" }.joined(separator: " · ")))
                    }
                    if !split.weekday.isEmpty {
                        MindsInsightRow(icon: "calendar",
                                        title: l10n.s.mWeekdayLine(split.weekday.prefix(3)
                                            .map { "\($0.key) \($0.count)" }.joined(separator: " · ")))
                    }
                }
            }
            .mindsCard()
        }
    }

    private var weekBars: some View {
        let days = ctx.viz.weekday7
        let maxV = max(days.max() ?? 1, 1)
        let labels = ctx.isZh ? ["一", "二", "三", "四", "五", "六", "日"]
                              : ["M", "T", "W", "T", "F", "S", "S"]
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i >= 5 ? MindsUI.accent : MindsUI.chartMuted)
                            .frame(maxWidth: 46)
                            .frame(height: max(3, 72 * CGFloat(v) / CGFloat(maxV)))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 72)
            HStack(spacing: 10) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    Text(l)
                        .font(.system(size: 11))
                        .foregroundStyle(i >= 5 ? MindsUI.accent : MindsUI.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
