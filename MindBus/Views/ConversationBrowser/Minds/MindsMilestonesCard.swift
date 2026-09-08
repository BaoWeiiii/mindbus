import SwiftUI
import MindBusCore

/// 「悬着的事」——它最后问了你一个问题，你再没回过。
///
/// 这一栏与「你点头的时刻」「你拍板的时刻」构成闭环：那两栏是**做完的**和
/// **定下的**，这一栏是**还欠着的**。价值判据来自第一性原理——
/// `价值 = 遗忘度 × 相关性 × 未闭合度`，做完的事提醒你没用，悬着的才有价值。
///
/// 条数少是这一层的正常状态（真机 5 件）：悬着的事本来就该少，
/// 五件是一份可行动的清单，五十件才说明有问题。
struct MindsOpenLoopsCard: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Group {
            if ctx.isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    MindsSkeletonBody(lines: 3).mindsCard()
                }
            } else if !ctx.openLoops.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ctx.openLoops.enumerated()), id: \.offset) { i, item in
                            if i > 0 {
                                Rectangle().fill(MindsUI.border.opacity(0.55))
                                    .frame(height: 1).padding(.vertical, 9)
                            }
                            row(item)
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }

    private var header: some View {
        MindsSectionHeader(title: l10n.s.mindsSecOpenLoops, hint: l10n.s.mindsOpenLoopsHint)
    }

    /// 问题是主角、上下文是配角:只显示「要我开始吗？」说不清悬的是什么事，
    /// 但反过来把标题当主角就丢了「到底欠着什么」。
    private func row(_ item: (day: String, context: String, question: String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.day)
                .font(BrandFont.mono(11.5))
                .foregroundStyle(MindsUI.textTertiary)
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.question)
                    .font(BrandFont.text(item.question, 13))
                    .foregroundStyle(MindsUI.textPrimary)
                    .lineLimit(2)
                Text(item.context)
                    .font(BrandFont.text(item.context, 11))
                    .foregroundStyle(MindsUI.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
