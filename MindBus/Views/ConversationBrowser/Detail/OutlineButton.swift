import SwiftUI
import MindBusCore

/// 长对话的目录入口。
///
/// 只在够得上目录的对话上出现（≥3 个节点）——短对话滚两下就到底，
/// 多一个按钮只是噪声。节点来自三处：你点头放行的时刻、你拍板的时刻、
/// 以及隔了几小时才回来的地方，判据全在 `ConversationOutline`。
struct OutlineButton: View {
    let conversation: Conversation
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var l10n = L10n.shared
    @State private var nodes: [ConversationOutline.Node] = []
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Group {
            if ConversationOutline.isWorthShowing(nodes) {
                Button { showing.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet.indent").font(.system(size: 10.5))
                        Text("\(nodes.count)").font(BrandFont.mono(11))
                    }
                    .foregroundStyle(hovering ? DSLight.t1 : DSLight.t2)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(hovering ? DSLight.sf2 : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
                .help(l10n.s.outlineHelp)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    OutlineListPreview(nodes: nodes) { id in
                        store.pendingLocateMessageID = id
                        showing = false
                    }
                }
            }
        }
        .task(id: conversation.id) { await load() }
    }

    private func load() async {
        let id = conversation.id
        let msgs = conversation.messages
        let s = store
        nodes = await Task.detached(priority: .utility) {
            s.outlineNodes(conversationID: id, messages: msgs)
        }.value
    }
}


/// 目录列表本体。抽出来是为了能离屏渲染核对——popover 里的内容截不到图，
/// 而「对不对齐」这类事不能靠想象（这一版第一次渲染就抓到了图标列没对齐）。
struct OutlineListPreview: View {
    let nodes: [ConversationOutline.Node]
    var onPick: (String) -> Void = { _ in }
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ScrollView { content }
            .frame(width: 380, height: min(460, CGFloat(nodes.count) * 46 + 24))
    }

    /// 内容与滚动容器分开:ImageRenderer 渲不出 ScrollView 里的东西
    /// （离屏预览的已知盲区），样张渲这一层才看得见。
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
                if i > 0 { Divider().opacity(0.5) }
                Button { onPick(n.messageID) } label: { row(n) }
                    .buttonStyle(.plain)
            }
        }
        .padding(10)
    }

    private func row(_ n: ConversationOutline.Node) -> some View {
        // 字体要按**实际显示的那串字**选:断点节点的 n.text 是空的,
        // 拿它去判断会让「5 小时后」走拉丁字体的度量,中文字距当场变形。
        let label = n.kind == .gap ? gapLabel(n.gap) : n.text
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(n.kind))
                .font(.system(size: 10))
                .foregroundStyle(n.kind == .gap ? DSLight.t3 : DSLight.gold)
                .frame(width: 14, alignment: .center)
            Text(label)
                .font(BrandFont.text(label, 12))
                .foregroundStyle(n.kind == .gap ? DSLight.t2 : DSLight.t1)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func icon(_ k: ConversationOutline.Node.Kind) -> String {
        switch k {
        case .milestone: return "checkmark.seal"
        case .decision:  return "arrow.triangle.branch"
        case .gap:       return "clock"
        }
    }

    /// 断点文案在展示层定，不在 Core：「5 小时后」还是「隔天」是口径问题
    private func gapLabel(_ gap: TimeInterval) -> String {
        let hours = Int(gap / 3600)
        return hours >= 24 ? l10n.s.outlineGapDays(hours / 24) : l10n.s.outlineGapHours(hours)
    }
}
