import SwiftUI
import MindBusCore

/// 「你点头的时刻」——你说「继续」之前，AI 刚汇报完的那件事。
///
/// 这一栏和 Minds 其余部分的区别：别的栏目回答「你是个什么样的人」（你爱说哪些
/// 词、几点开工），这一栏回答「你做成过什么」。素材是具体的、可回溯的、
/// 被你本人点过头的，所以它按时间倒序摆——最近放行的排最前。
///
/// 信号全程机械：认可词表从你自己的语料学出来，汇报首句是原文照抄，没有模型参与。
struct MindsMilestonesCard: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Group {
            if ctx.isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    MindsSkeletonBody(lines: 5).mindsCard()
                }
            } else if !ctx.milestones.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ctx.milestones.enumerated()), id: \.offset) { i, m in
                            if i > 0 {
                                Rectangle().fill(MindsUI.border.opacity(0.55))
                                    .frame(height: 1).padding(.vertical, 9)
                            }
                            row(m)
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }

    private var header: some View {
        MindsSectionHeader(title: l10n.s.mindsSecMilestones, hint: l10n.s.mindsMilestonesHint)
    }

    /// 一行 = 日期 · 你说的那句（金色小徽章）· 它汇报的首句。
    /// 日期列定宽，几十行叠起来时左边缘才是一条直线。
    private func row(_ m: (day: String, approval: String, headline: String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(m.day)
                .font(BrandFont.mono(11.5))
                .foregroundStyle(MindsUI.textTertiary)
                .frame(width: 74, alignment: .leading)
            Text(m.approval)
                .font(BrandFont.text(m.approval, 11.5, weight: .medium))
                .foregroundStyle(MindsUI.accent)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(MindsUI.accent.opacity(0.10), in: Capsule())
                .fixedSize()
                // 徽章列定宽:认可词有长有短(继续 2 字 / 全部优化 4 字),
                // 不定宽的话首句的左边缘会跟着徽章一起参差
                .frame(width: 76, alignment: .leading)
            Text(m.headline)
                .font(BrandFont.text(m.headline, 13))
                .foregroundStyle(MindsUI.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// 「你拍板的时刻」——它把选择摆到你面前时，你说的那句原话。
///
/// 与「你点头的时刻」互补：那一栏是「你认可了什么成果」，这一栏是
/// 「你怎么做的选择」。原话照抄，不做任何加工——你当时的措辞本身就是信息。
struct MindsDecisionsCard: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Group {
            if ctx.isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    MindsSkeletonBody(lines: 4).mindsCard()
                }
            } else if !ctx.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ctx.decisions.enumerated()), id: \.offset) { i, d in
                            if i > 0 {
                                Rectangle().fill(MindsUI.border.opacity(0.55))
                                    .frame(height: 1).padding(.vertical, 9)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(d.day)
                                    .font(BrandFont.mono(11.5))
                                    .foregroundStyle(MindsUI.textTertiary)
                                    .frame(width: 74, alignment: .leading)
                                Text(d.statement)
                                    .font(BrandFont.text(d.statement, 13))
                                    .foregroundStyle(MindsUI.textPrimary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }

    private var header: some View {
        MindsSectionHeader(title: l10n.s.mindsSecDecisions, hint: l10n.s.mindsDecisionsHint)
    }
}
