import SwiftUI
import MindBusCore

/// Minds 模块内容区。
///
/// 结构（2026-08-17 重构）：一个壳 + 三个独立页面
/// （`01 你的总览` / `02 你与 AI 的互动` / `03 你的项目与语言资产`），
/// 页面之间靠内容区顶部的分段导航切换——**不碰侧栏、不碰顶栏、不碰全局导航**。
///
/// 数据全部来自 `MindsStore`（`minds.md` 机械层）。机械层的每一行都是数出来的，
/// 这里只负责把它们摆好；页面组件统一吃 `MindsContext`，不各自持有 store。
struct MindsView: View {
    @ObservedObject var store: ConversationStore
    @StateObject private var minds = MindsStore()
    @ObservedObject private var l10n = L10n.shared

    @State private var viz = MindsViz()
    @State private var page: MindsPage = .overview

    private var ctx: MindsContext {
        MindsContext(store: store, md: minds.mechanicalMarkdown, viz: viz)
    }

    var body: some View {
        // 宽度硬约束（2026-08-16 三修）：内部组件（Swift Charts 无宽度约束、
        // FlowLayout 曾返回无限宽）会向父容器索取极大理想宽度，一路顶穿窗口——
        // 现象是「点开 Minds 一秒后侧栏与右侧按钮同时被裁」。与其逐个组件排查，
        // 不如在这里钉死：内容宽度恒等于容器宽度，谁也别想超。
        GeometryReader { geo in
            ScrollView {
                renderableContent
                    .frame(width: geo.size.width, alignment: .topLeading)
            }
        }
        .background(MindsUI.page)
        .onAppear {
            minds.reload()
            // 图表数据整串挪出主线程（2026-08-16）：十几个 SQL 同步跑在主线程，
            // 点开 Minds 要卡几秒——期间 SwiftUI 布局被冻住，侧栏动画停在中间帧。
            let fadedWords = ctx.bullets("FADED WORDS").compactMap(ctx.parseRecurring).map(\.word)
            let rescued = store.rescuedIDs.count
            let s = store
            Task {
                let v = await Task.detached(priority: .userInitiated) {
                    MindsViz.build(store: s, fadedWords: fadedWords, rescuedCount: rescued)
                }.value
                viz = v
            }
        }
    }

    /// 内容层与 ScrollView 分离：ImageRenderer 渲不出 ScrollView 内部
    ///（离屏预览三盲区之一），设计校验时直接渲这个。
    var renderableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if minds.mechanicalMarkdown.isEmpty {
                fileMissing
            } else {
                MindsPageTabs(page: $page, l10n: l10n.s)
                    .padding(.top, 26)
                    .padding(.bottom, 22)
                currentPage
            }
        }
        // 卡片底带 maxHeight .infinity（为了并排等高），整页必须锁死在内容高度上——
        // 否则外层一给确定高度，所有卡片会一起拉长把页面填满
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: MindsUI.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Minds")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(MindsUI.textPrimary)
            HStack(spacing: 12) {
                Text(l10n.s.mindsSubtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MindsUI.textSecondary)
                // 信任锚：重建时间 + counted, not generated——机械层可信度的来源
                Text("\(rebuildStamp)\(l10n.s.mindsTrustSuffix)")
                    .font(BrandFont.mono(11))
                    .foregroundStyle(MindsUI.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .overview: MindsOverviewPage(ctx: ctx)
        case .ai: MindsAIPage(ctx: ctx)
        case .projects: MindsProjectsPage(ctx: ctx)
        }
    }

    /// 从机械层首段抽 "(policy vN, rebuilt …)" 那行的日期；抽不到就只显示信任语。
    private var rebuildStamp: String {
        guard let range = minds.mechanicalMarkdown.range(
            of: #"rebuilt \d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return "" }
        return String(minds.mechanicalMarkdown[range]) + "  "
    }

    private var fileMissing: some View {
        Text(l10n.s.mindsFileMissing)
            .font(.system(size: 13)).foregroundStyle(MindsUI.textTertiary)
            .padding(.top, 60)
    }
}

/// 词条流式排列：一行放不下就换行，行内左对齐。
///
/// 自己实现而不用 `LazyVGrid`：网格要固定列宽，而词条宽度随字数变化，
/// 固定列宽会在短词后面留一大截空白。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // proposal.width 可能是 nil（无约束）也可能是 .infinity（父容器说「随你」）。
        // 只判 nil 会让 .infinity 一路传下去，返回无限宽，最终把窗口顶穿。
        let proposed = proposal.width ?? .infinity
        let width = (proposed.isFinite && proposed > 0) ? proposed : 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, usedX: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += size.width + spacing
            usedX = max(usedX, x)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: min(width, max(usedX - spacing, 0)), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
