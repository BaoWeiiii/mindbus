import SwiftUI
import MindBusCore

/// 「你可能忘了的」入口。
///
/// 判据来自第一性原理：人会来翻自己的对话库，根本原因只有一个——**他想不起来了**。
/// 记得的东西不需要查。所以 `价值 = 想不起来 × 现在需要它`，前者用时间逼近，
/// 后者用相关性逼近，query 就是你此刻在看的这场对话。
///
/// 与库里其他挖掘的区别：那些都是静态的（把库统计一遍摆出来，能不能撞上你
/// 需要的全看运气），这一层是动态的——它跟着你看的东西走。也因此不依赖
/// 任何交互习惯，任何人任何一场对话都算得出来。
///
/// 没有把握时**不显示**：特征词不足或没有一条命中够多特征词，这个按钮
/// 自己就不出现。给错的比不给更糟——它花的是你的注意力。
struct ForgottenRelatedButton: View {
    let conversationID: String
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var l10n = L10n.shared
    @State private var related: [ConversationIndex.RelatedConversation] = []
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Group {
            if !related.isEmpty {
                Button { showing.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 10.5))
                        Text("\(related.count)").font(BrandFont.mono(11))
                    }
                    .foregroundStyle(hovering ? DSLight.t1 : DSLight.t2)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(hovering ? DSLight.sf2 : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
                .help(l10n.s.forgottenHelp)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    ForgottenListPreview(items: related) { id in
                        store.mindsSelected = false
                        store.selectedConversationId = id
                        showing = false
                    }
                }
            }
        }
        .task(id: conversationID) {
            let s = store, id = conversationID
            related = await Task.detached(priority: .utility) { s.forgottenRelated(to: id) }.value
        }
    }
}

/// 列表本体。与滚动容器分开——ImageRenderer 渲不出 ScrollView 里的内容，
/// 分开才能离屏核对排版。
struct ForgottenListPreview: View {
    let items: [ConversationIndex.RelatedConversation]
    var onPick: (String) -> Void = { _ in }
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.s.forgottenTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DSLight.t3)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            content
        }
        .frame(width: 360)
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, r in
                if i > 0 { Divider().opacity(0.5) }
                Button { onPick(r.id) } label: { row(r) }.buttonStyle(.plain)
            }
        }
        .padding(10)
    }

    private func row(_ r: ConversationIndex.RelatedConversation) -> some View {
        let title = r.title.isEmpty ? (r.cwd as NSString).lastPathComponent : r.title
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 「N 天前」不是「N 天后」——这一层看的是过去；
            // 字体也不能用 mono:整句含中文时等宽会触发 CJK 回退,
            // 一行里两套度量,数字和「天」之间的字距当场变形。
            Text(l10n.s.mRelDaysAgo(r.daysAgo))
                .font(BrandFont.text(l10n.s.mRelDaysAgo(r.daysAgo), 11))
                .foregroundStyle(DSLight.t3)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandFont.text(title, 12))
                    .foregroundStyle(DSLight.t1)
                    .lineLimit(1)
                Text((r.cwd as NSString).lastPathComponent)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DSLight.t3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
