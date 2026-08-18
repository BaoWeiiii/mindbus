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
            } else if !ctx.viz.milestones.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ctx.viz.milestones.prefix(MindsBuilder.milestonesShown)
                            .enumerated()), id: \.offset) { i, item in
                            if i > 0 {
                                Rectangle().fill(MindsUI.border.opacity(0.55))
                                    .frame(height: 1).padding(.vertical, 9)
                            }
                            Button { ctx.open(conversation: item.convID,
                                              locate: item.m.messageID) } label: {
                                row(item.m)
                            }
                            .buttonStyle(.plain)
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
    private func row(_ m: MindsMilestones.Milestone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(MindsContext.dayString(m.at))
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
            } else if !ctx.viz.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ctx.viz.decisions.prefix(MindsBuilder.decisionsShown)
                            .enumerated()), id: \.offset) { i, item in
                            if i > 0 {
                                Rectangle().fill(MindsUI.border.opacity(0.55))
                                    .frame(height: 1).padding(.vertical, 9)
                            }
                            Button { ctx.open(conversation: item.convID,
                                              locate: item.d.messageID) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(MindsContext.dayString(item.d.at))
                                        .font(BrandFont.mono(11.5))
                                        .foregroundStyle(MindsUI.textTertiary)
                                        .frame(width: 74, alignment: .leading)
                                    Text(item.d.statement)
                                        .font(BrandFont.text(item.d.statement, 13))
                                        .foregroundStyle(MindsUI.textPrimary)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
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
