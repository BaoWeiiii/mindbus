import SwiftUI
import MindBusCore

/// PAGE 02 · 你与 AI 的互动。
struct MindsAIPage: View {
    let ctx: MindsContext

    var body: some View {
        VStack(alignment: .leading, spacing: MindsUI.moduleGap) {
            MindsTwoColumn {
                MindsTaskRanking(ctx: ctx)
            } right: {
                MindsQuestionShape(ctx: ctx)
            }
            MindsTwoColumn {
                MindsCollaborationPattern(ctx: ctx)
            } right: {
                MindsLeverage(ctx: ctx)
            }
            MindsRepeatedPhrases(ctx: ctx)
            MindsTwoColumn {
                MindsCatchphrases(ctx: ctx)
            } right: {
                MindsFadedWords(ctx: ctx)
            }
        }
    }
}

// MARK: - 你派给 AI 的活

struct MindsTaskRanking: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let verbs = ctx.doc.delegationVerbs()
        let maxN = verbs.map(\.count).max() ?? 1
        return Group {
            if !verbs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecDelegation, hint: l10n.s.mindsDelegationHint)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(verbs.enumerated()), id: \.offset) { _, v in
                            MindsBarRow(label: v.verb, value: v.count, maxValue: maxN,
                                        trailing: String(format: l10n.s.mDelegCount, v.count, v.conversations),
                                        isTop: v.count == maxN)
                        }
                        if let dest = ctx.doc.researchDestination() {
                            Spacer(minLength: 6)
                            MindsCardFootnote(
                                text: String(format: l10n.s.mDelegResearch,
                                             dest.destination, "\(dest.count)"))
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }

}

// MARK: - 提问的形状

struct MindsQuestionShape: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let counts = ctx.doc.questionShape()
        let maxN = counts.map(\.count).max() ?? 1
        let names = ["should-we": l10n.s.mQKindConfirm, "how-to": l10n.s.mQKindHow,
                     "why": l10n.s.mQKindWhy, "what-is": l10n.s.mQKindWhat]
        let verdicts = ["should-we": l10n.s.mQVerdictConfirm, "how-to": l10n.s.mQVerdictHow,
                        "why": l10n.s.mQVerdictWhy, "what-is": l10n.s.mQVerdictWhat]
        return Group {
            if !counts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecQuestionShape,
                                       hint: l10n.s.mindsQuestionShapeHint)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(counts.enumerated()), id: \.offset) { _, kv in
                            MindsBarRow(label: names[kv.kind] ?? kv.kind, value: kv.count,
                                        maxValue: maxN, trailing: "\(kv.count)", trailingWidth: 44,
                                        isTop: kv.count == maxN)
                        }
                        if let top = counts.first, let v = verdicts[top.kind] {
                            Spacer(minLength: 6)
                            MindsCardFootnote(text: v)
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }

}

// MARK: - 一起干活的样子

struct MindsCollaborationPattern: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Group {
            if ctx.isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecShape, hint: l10n.s.mindsShapeHint)
                    MindsSkeletonBody(chartHeight: 96, lines: 3).mindsCard()
                }
            } else if let sh = ctx.viz.shape, rows(sh).isEmpty == false {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecShape, hint: l10n.s.mindsShapeHint)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 22) {
                            durationBars(sh)
                            turnsDonut(sh)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(rows(sh).enumerated()), id: \.offset) { i, r in
                                MindsInsightRow(icon: ["arrow.triangle.2.circlepath", "hourglass",
                                                       "text.alignleft"][min(i, 2)],
                                                title: r)
                            }
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }

    private func rows(_ sh: ConversationIndex.CollaborationShape) -> [String] {
        var out: [String] = []
        let tTotal = sh.turnBands.reduce(0, +), dTotal = sh.durationBands.reduce(0, +)
        if tTotal > 0 { out.append(l10n.s.mShapeTurns(sh.turnBands[3] * 100 / tTotal)) }
        if dTotal > 0 {
            out.append(l10n.s.mShapeBimodal(sh.durationBands[0] * 100 / dTotal,
                                            sh.durationBands[3] * 100 / dTotal))
        }
        if sh.avgCharsPerMessage > 0 { out.append(l10n.s.mShapeAvg(sh.avgCharsPerMessage)) }
        return out
    }

    /// 左：每场聊多久（4 桶柱）
    private func durationBars(_ sh: ConversationIndex.CollaborationShape) -> some View {
        let labels = ["<2m", "2-30m", "0.5-2h", "2h+"]
        let maxV = max(sh.durationBands.max() ?? 1, 1)
        let total = max(sh.durationBands.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(l10n.s.mShapeDurationTitle)
                .font(.system(size: 12)).foregroundStyle(MindsUI.textSecondary)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(sh.durationBands.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 4) {
                        Text("\(v * 100 / total)%")
                            .font(BrandFont.mono(9))
                            .foregroundStyle(v == maxV ? MindsUI.accentStrong : MindsUI.textTertiary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(v == maxV ? MindsUI.accent : MindsUI.chartMuted)
                            .frame(height: max(3, 66 * CGFloat(v) / CGFloat(maxV)))
                        Text(labels[i])
                            .font(BrandFont.mono(9)).foregroundStyle(MindsUI.textTertiary)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 右：来回几轮（环形 + 图例）。四段用同一金色的四级明度，不引入第二色相。
    private func turnsDonut(_ sh: ConversationIndex.CollaborationShape) -> some View {
        let labels = ["1-2", "3-5", "6-15", "16+"]
        let total = max(sh.turnBands.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(l10n.s.mShapeTurnTitle)
                .font(.system(size: 12)).foregroundStyle(MindsUI.textSecondary)
            HStack(spacing: 14) {
                MindsDonut(values: sh.turnBands, lineWidth: 15)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sh.turnBands.enumerated()), id: \.offset) { i, v in
                        HStack(spacing: 7) {
                            Circle().fill(MindsDonut.shade(i, of: 4)).frame(width: 7, height: 7)
                            Text(labels[i])
                                .font(BrandFont.mono(10)).foregroundStyle(MindsUI.textSecondary)
                                .frame(width: 30, alignment: .leading)
                            Text("\(v * 100 / total)%")
                                .font(BrandFont.mono(10)).foregroundStyle(MindsUI.textPrimary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 杠杆率

struct MindsLeverage: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let vol = ctx.viz.volume
        let ratio = vol.userChars > 0 ? vol.totalChars / vol.userChars : 0
        return Group {
            if ctx.isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecLeverage, hint: l10n.s.mindsLeverageHint)
                    MindsSkeletonBody(chartHeight: 40, lines: 2).mindsCard()
                }
            } else if ratio > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecLeverage, hint: l10n.s.mindsLeverageHint)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            // 全页最大的一个数字——其余文字都不许抢它
                            Text("1 : \(ratio)")
                                .font(.system(size: 34, weight: .semibold)).kerning(-0.5)
                                .foregroundStyle(MindsUI.accentStrong)
                                .mindsTabularNumbers()
                            Text(l10n.s.mLeverageLine(MindsBuilder.compactChars(vol.userChars),
                                                      MindsBuilder.compactChars(vol.totalChars)))
                                .font(.system(size: 12)).foregroundStyle(MindsUI.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(MindsUI.accentSoft.opacity(0.55))
                                Capsule().fill(MindsUI.accent)
                                    .frame(width: max(4, geo.size.width * CGFloat(vol.userChars)
                                                      / CGFloat(max(vol.totalChars, 1))))
                            }
                        }
                        .frame(height: 6)
                        let ub = max(MindsBuilder.bookEquivalent(vol.userChars), 1)
                        let tb = MindsBuilder.bookEquivalent(vol.totalChars)
                        if tb >= 1 {
                            MindsCardFootnote(text: l10n.s.mLeverageBooks(ub, tb))
                        }
                        Spacer(minLength: 0)
                    }
                    .mindsCard()
                }
            }
        }
    }
}

// MARK: - 你的语言（整行）

struct MindsRepeatedPhrases: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let chips = ctx.doc.chipRow("PHRASES YOU REPEAT")
        return Group {
            if !chips.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecLanguage, hint: l10n.s.mindsLanguageHint)
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

// MARK: - 口头禅

struct MindsCatchphrases: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let phrases = ctx.doc.catchphrases()
        return Group {
            if !phrases.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecCatchphrases,
                                       hint: l10n.s.mindsCatchphrasesHint)
                    VStack(alignment: .leading, spacing: 12) {
                        FlowLayout(spacing: 8) {
                            ForEach(Array(phrases.enumerated()), id: \.offset) { i, c in
                                MindsTagChip(word: c.phrase,
                                             meta: l10n.s.mVocabWorkMeta(c.count),
                                             emphasis: i < 3) { ctx.search(c.phrase) }
                            }
                        }
                        Spacer(minLength: 6)
                        if let list = ctx.doc.politenessLine() {
                            MindsCardFootnote(text: l10n.s.mPoliteness(list))
                        }
                    }
                    .mindsCard()
                }
            }
        }
    }
}

// MARK: - 不再说的词

struct MindsFadedWords: View {
    let ctx: MindsContext
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let rows = ctx.bullets("FADED WORDS").compactMap(ctx.parseRecurring)
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MindsSectionHeader(title: l10n.s.mindsSecFaded, hint: l10n.s.mindsFadedHint)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows, id: \.word) { row in
                            MindsFadedRow(ctx: ctx, word: row.word, detail: row.detail)
                        }
                        Spacer(minLength: 0)
                    }
                    .mindsCard()
                }
            }
        }
    }
}

private struct MindsFadedRow: View {
    let ctx: MindsContext
    let word: String
    let detail: String
    @State private var hovering = false

    var body: some View {
        Button { ctx.search(word) } label: {
            HStack(spacing: 10) {
                Text(word)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MindsUI.accent)
                Text(ctx.fadedMeta(detail))
                    .font(.system(size: 11.5))
                    .foregroundStyle(MindsUI.textSecondary)
                    .mindsTabularNumbers()
                Spacer(minLength: 8)
                // 消退曲线:说得多 → 归零的形状。没有序列时退回一条沉默条,
                // 两者宽度一致,右缘才对得齐。
                if let sr = ctx.viz.fadedSeries[word], sr.contains(where: { $0 > 0 }) {
                    MindsMiniSparkline(series: sr)
                } else if let days = ctx.firstInt(after: "silent ", in: detail) {
                    silence(days)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovering ? MindsUI.surfaceHover : MindsUI.surfaceSoft,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func silence(_ days: Int) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Capsule().fill(MindsUI.chartTrack).frame(height: 3)
                Capsule().fill(MindsUI.textTertiary.opacity(0.5))
                    .frame(width: max(4, geo.size.width * CGFloat(min(days, 365)) / 365), height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 60, height: 20)
    }
}
