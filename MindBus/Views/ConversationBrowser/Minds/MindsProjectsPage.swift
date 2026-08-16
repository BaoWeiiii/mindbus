import SwiftUI
import MindBusCore

/// PAGE 03 · 你的项目与语言资产。
struct MindsProjectsPage: View {
    let ctx: MindsContext

    var body: some View {
        VStack(alignment: .leading, spacing: MindsUI.moduleGap) {
            MindsMarathons(ctx: ctx)
            MindsProjectRhythm(ctx: ctx)
            MindsCommonWords(ctx: ctx)
        }
    }
}

// MARK: - 马拉松对话

struct MindsMarathons: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let rows = ctx.bullets("MARATHONS").compactMap(ctx.parseWithID)
        // md 只记条数与跨度,日期得现查索引
        let dates = ctx.store.conversationEndDates(ids: rows.map(\.id))
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecMarathons, hint: l10n.s.mindsMarathonsHint)
                    VStack(spacing: 8) {
                        ForEach(rows, id: \.id) { row in
                            MindsMarathonRow(
                                title: row.label,
                                meta: ctx.marathonMeta(row.meta),
                                date: dates[row.id].map { l10n.s.mMarathonLongest(MindsContext.dayString($0)) },
                                open: { ctx.open(conversation: row.id) })
                        }
                    }
                    .mindsCard(padding: 12)
                }
            }
        }
    }
}

/// 每条是一张浅底子卡（页面 → 大卡 → 浅底行，正好两层，不再往下嵌）。
private struct MindsMarathonRow: View {
    let title: String
    let meta: String
    let date: String?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "figure.run")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(MindsUI.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(MindsUI.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MindsUI.textSecondary)
                        .mindsTabularNumbers()
                }
                Spacer(minLength: 12)
                if let date {
                    Text(date)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MindsUI.textTertiary)
                        .mindsTabularNumbers()
                        .lineLimit(1)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(hovering ? MindsUI.accent : MindsUI.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(hovering ? MindsUI.surfaceHover : MindsUI.surfaceSoft,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 只抬 1pt:再多就成了「卡片浮起来」的 Dashboard 味
        .offset(y: hovering ? -1 : 0)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - 项目节奏

struct MindsProjectRhythm: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared
    @State private var expanded: String?

    var body: some View {
        let rows = ctx.bullets("PROJECT RHYTHM").compactMap(ctx.parseProject)
        let maxCount = rows.map(\.count).max() ?? 1
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecProjects, hint: l10n.s.mindsProjectsHint)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        ForEach(rows.prefix(8), id: \.path) { row in
                            VStack(spacing: 0) {
                                MindsProjectRow(row: row, maxCount: maxCount,
                                                expanded: expanded == row.path,
                                                activeLabel: l10n.s.mindsActiveNow,
                                                recent: ctx.relativeDay(row.lastTouched)) {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        expanded = expanded == row.path ? nil : row.path
                                    }
                                }
                                if expanded == row.path {
                                    MindsProjectTimeline(ctx: ctx, cwd: row.path)
                                }
                            }
                        }
                    }
                    .mindsCard(padding: 12)
                }
            }
        }
    }

    /// 列名：不画表格线，靠列名 + 对齐把五列说清楚
    private var header: some View {
        HStack(spacing: 12) {
            Text(l10n.s.mProjColName).frame(width: 150, alignment: .leading)
            Text(l10n.s.mProjColCount).frame(width: 36, alignment: .trailing)
            Text(l10n.s.mProjColScale).frame(maxWidth: .infinity, alignment: .leading)
            Text(l10n.s.mProjColSpan).frame(width: 168, alignment: .trailing)
            Text(l10n.s.mProjColRecent).frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(MindsUI.textTertiary)
        .padding(.horizontal, 10).padding(.bottom, 8)
    }
}

private struct MindsProjectRow: View {
    let row: MindsContext.ProjectRow
    let maxCount: Int
    let expanded: Bool
    let activeLabel: String
    let recent: String
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Text(row.name)
                    .font(.system(size: 13))
                    .foregroundStyle(MindsUI.textPrimary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                Text("\(row.count)")
                    .font(.system(size: 13)).foregroundStyle(MindsUI.textSecondary)
                    .mindsTabularNumbers()
                    .frame(width: 36, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MindsUI.chartTrack)
                        Capsule().fill(MindsUI.accent)
                            .frame(width: max(5, geo.size.width * CGFloat(row.count) / CGFloat(max(maxCount, 1))))
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 18)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(row.span)
                        .font(.system(size: 11.5)).foregroundStyle(MindsUI.textSecondary)
                        .mindsTabularNumbers().lineLimit(1)
                    if row.active {
                        // 「活跃中」= 文字 + 小圆点，圆点用低饱和暖调，不用鲜绿
                        HStack(spacing: 4) {
                            Circle().fill(MindsUI.accent).frame(width: 5, height: 5)
                            Text(activeLabel)
                                .font(.system(size: 11)).foregroundStyle(MindsUI.accentStrong)
                        }
                    }
                }
                .frame(width: 168, alignment: .trailing)
                Text(recent)
                    .font(.system(size: 11.5)).foregroundStyle(MindsUI.textTertiary)
                    .mindsTabularNumbers().lineLimit(1)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hovering || expanded ? MindsUI.surfaceHover : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 行内展开：该项目历次会话——最近 5 场可点。
private struct MindsProjectTimeline: View {
    let ctx: MindsContext
    let cwd: String
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let convs = ctx.store.projectConversations(cwd: cwd)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(convs.prefix(5), id: \.id) { conv in
                Button { ctx.open(conversation: conv.id) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(MindsUI.accentSoft).frame(width: 5, height: 5)
                        Text(conv.label)
                            .font(.system(size: 12)).foregroundStyle(MindsUI.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(MindsContext.dayString(conv.endAt))
                            .font(BrandFont.mono(10)).foregroundStyle(MindsUI.textTertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 你的常用词

struct MindsCommonWords: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let chips = ctx.bullets("VOCABULARY").first
            .map { ctx.chips(from: String($0.dropFirst(2))) } ?? []
        return Group {
            if !chips.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecVocabulary,
                                       hint: l10n.s.mindsVocabularyHint)
                    FlowLayout(spacing: 8) {
                        ForEach(Array(chips.enumerated()), id: \.element.word) { i, c in
                            MindsTagChip(word: c.word, meta: ctx.vocabMeta(c.meta),
                                         emphasis: i < 3) { ctx.search(c.word) }
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }
}
