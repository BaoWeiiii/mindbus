import SwiftUI
import MindBusCore

struct MessageBubbleView: View {
    let message: Message
    /// 非 nil = 该行进入执行流时间线（步骤节点 + 轴 + 缩进气泡）；nil = 现状气泡。
    var timeline: TimelineRowInfo? = nil
    /// 非空 = 搜索态：正文/时间线摘要里的命中词金色标注（与召回同拍的 highlightQuery）。
    var highlightQuery: String = ""
    /// 消息级定位的短暂强调：DetailView 滚到本条后置 true，1.3s 后置回——
    /// 行内 .animation(value:) 负责 0.3s 淡入/淡出（外层 ScrollView 掐掉了流入动画）。
    var located: Bool = false
    /// 复制范围选择（两态模型）：selectionActive = 会话内已有手动选择（所选消息模式）。
    /// 完整会话模式下轨道隐藏（hover 才显 ○）——「逻辑全选」不画全选态。
    var selectionActive: Bool = false
    var selected: Bool = false
    /// 点击选择点 / Option 点卡片时回调，参数 = 是否按着 Shift（区间选择）。
    /// nil = 选择功能不可用（加载壳等）。
    /// 收藏键("convID#msgID")。nil = 收藏不可用(加载壳/样张等)。
    var starKey: String? = nil
    var onToggleSelect: ((Bool) -> Void)? = nil
    /// 右键删除回调(nil = 菜单不显示删除项)。
    var onDelete: (() -> Void)? = nil
    @ObservedObject private var stars = StarredMessagesStore.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var hovering = false
    /// 悬停意图:hover 持续 ≥300ms 才置 true——鼠标扫过消息流时不再一路闪
    /// 操作控件(用户反馈 2026-08-11;收藏按钮与选择圆点共用同一个意图时钟,
    /// 同时浮现)。离开立即清零。已收藏/已选中的**状态标识**不受延迟影响,常显;
    /// 时间显影保持既有即时 hover。
    @State private var hoverIntent = false
    @State private var hoverIntentWork: DispatchWorkItem? = nil
    /// hover 离开的延迟隐藏（300ms 宽限）：气泡→圆点的路径擦过行间隙/空白区时
    /// 圆点不闪没——「来不及点就消失」的兜底。重新进入即取消。
    @State private var hoverHideWork: DispatchWorkItem? = nil

    /// 左侧选择轨道宽度：圆点 14 + 与卡片间距 8（短线已删，22 即可）。
    private static let railW: CGFloat = 22

    var body: some View {
        bubbleRow
            .padding(.leading, onToggleSelect == nil ? 0 : Self.railW)
            .overlay(alignment: .leading) { selectionDot }
            // 所选模式下未选中的消息轻微退后，但保持可读
            .opacity(selectionActive && !selected ? 0.72 : 1)
            // 整行矩形都算命中区域：气泡旁的空白/轨道不再是 hover 死区，
            // 鼠标从气泡横穿到圆点全程不丢 hover
            .contentShape(Rectangle())
            .onHover { h in
                hoverHideWork?.cancel()
                hoverIntentWork?.cancel()
                if h {
                    withAnimation(.easeOut(duration: 0.12)) { hovering = true }
                    // 意图延迟 300ms:操作类 hover 控件的常见甜点区(250-400ms)——
                    // 停留才现,扫过不闪
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.12)) { hoverIntent = true }
                    }
                    hoverIntentWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                } else {
                    hoverIntent = false
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) { hovering = false }
                    }
                    hoverHideWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                }
            }
            // Option 点卡片 = 快捷选择整条（普通点击保留文本选择/链接原行为）
            .simultaneousGesture(
                TapGesture().modifiers(.option).onEnded {
                    onToggleSelect?(NSEvent.modifierFlags.contains(.shift))
                }
            )
    }

    private var timeLabel: some View {
        Text(message.timestamp.formatted(date: .omitted, time: .standard))
            .font(.system(size: 10))
            .foregroundStyle(DSLight.t4)
            .opacity(hovering ? 1 : 0)
    }

    /// 收藏控件(用户定案 2026-08-11:气泡**内**右上角,参考稿形态):
    /// hover 出现;已收藏 = bookmark.fill 金色**常显**。白底小盒浮于内容上,
    /// 叠到文字也清晰。金调与选择点/引用徽章同族——「贵重但安静」。
    @ViewBuilder
    private var starControl: some View {
        if let key = starKey {
            let isOn = stars.isStarred(key)
            if isOn || hoverIntent {
                Button {
                    if isOn {
                        stars.unstar(key)   // 软删,收藏页里可撤销
                    } else {
                        // 收藏当刻抓正文快照(≤500 字)——原消息将来不可用时的兜底展示
                        let convID = String(key.split(separator: "#", maxSplits: 1).first ?? "")
                        stars.star(conversationID: convID, messageID: message.id,
                                   role: message.role.rawValue,
                                   snapshot: Segmenter.plainTextForSearch(of: message))
                    }
                } label: {
                    Image(systemName: isOn ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 11))
                        .foregroundStyle(isOn ? DSLight.gold : DSLight.t3)
                        .frame(width: 22, height: 20)
                        .background(DSLight.bg.opacity(0.94),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle().inset(by: -3))
                }
                .buttonStyle(.plain)
                .help(isOn ? l10n.s.starRemoveHelp : l10n.s.starAddHelp)
                .padding(6)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.12), value: hoverIntent)
            }
        }
    }

    /// 左侧选择圆点：完整会话模式 hover 才现（轨道隐藏）；所选模式常显淡 ○；选中 = 金实心。
    @ViewBuilder
    private var selectionDot: some View {
        if let onToggleSelect {
            Button {
                onToggleSelect(NSEvent.modifierFlags.contains(.shift))
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? DSLight.gold : DSLight.t3.opacity(0.5), lineWidth: 1)
                    if selected {
                        Circle().fill(DSLight.gold).frame(width: 8, height: 8)
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Circle().inset(by: -6))   // 热区外扩,14px 点不难点
            }
            .buttonStyle(.plain)
            // 对齐气泡中心：行首有常驻 12px 时间行 + 4px 间距（hover 才显影但始终占位），
            // 整行中心比气泡中心高 (12+4)/2 = 8px——圆点固定下移补正。
            .offset(y: 8)
            // hover 浮现走 300ms 意图(与收藏按钮同拍);已选中/所选模式常显不受延迟
            .opacity(selected || hoverIntent || selectionActive ? (selected || hoverIntent ? 1 : 0.45) : 0)
            .animation(.easeOut(duration: 0.12), value: hoverIntent)
            .animation(.easeOut(duration: 0.12), value: selected)
            .help(l10n.s.selectMessageHelp)
            .accessibilityLabel(l10n.s.selectMessageHelp)
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // hover 才显示的发送时间（用户定案）：assistant 左上 / user 右上
                //（外层 VStack 对齐按角色分侧，时间自动落对应角；固定高防布局跳动）。
                timeLabel
                    .frame(height: 12)

                // 选中装饰只包气泡本体——不含上方隐形时间行（否则盒顶多出一截空带），
                // 短线/描边的垂直中心天然对齐气泡，与圆点的 8px 补正互相咬合。
                Group {
                    if let timeline {
                        TimelineMessageView(message: message, info: timeline,
                                            highlightQuery: highlightQuery,
                                            isZh: l10n.isZh)
                            .equatable()
                            .overlay { locateRing }
                            .overlay(alignment: .topTrailing) { starControl }
                    } else {
                        MessageBlocksView(message: message, highlightQuery: highlightQuery,
                                          isZh: l10n.isZh)
                            .equatable()
                            .padding(16)
                            .background(DSLight.sf)
                            .overlay(alignment: .topTrailing) { starControl }   // 白一级底卡片（去旧灰底/金底）
                            // 角色区分只靠位置（user 靠右 / assistant 靠左）——聊天界面最经典的信号。
                            // 曾试过金色左缘 3px 竖条：彩条贴卡缘是典型「AI 生成界面」句式，已删（用户否决，
                            // 记入 设计协作准则 的 Anti-Patterns 一并遵守）。
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { locateRing }
                    }
                }
                // 选中态两件（消息级）：浅金底 + 边缘提亮描边。
                // 金短线已删（用户定案 2026-08-03：点旁竖线多余）。
                // 描边属交互选中反馈——设计系统 border 禁令的明确例外类。
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10).fill(DSLight.gold.opacity(0.07))
                    }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(DSLight.gold.opacity(0.30), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: 600, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .contextMenu {
            Button(l10n.s.copyThisMessage) { copyPlainText() }
            if let onDelete {
                Divider()
                Button(role: .destructive) { onDelete() } label: {
                    Label(l10n.s.deleteMsgMenu, systemImage: "trash")
                }
            }
        }
    }

    /// 显示用：删掉文本里的字面图片引用——图片本体已由 .image block 内嵌渲染，
    /// `[Image: source: /path]` 与 `[Image #3]` 占位再显示一遍纯属重复（用户定案）。
    /// 仅影响展示；复制走 plainText 原文，路径完整保留（供新模型读图）。
    /// isZh 参数保留只为不动调用链（列表 preview 的「[图片]」占位仍有意义，在别处）。
    static func hideImageRefs(_ t: String, isZh: Bool = true) -> String {
        t.replacingOccurrences(
            of: #"\[[Ii]mage: source:[^\]]*\]"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\[[Ii]mage #\d+\]"#,
            with: "",
            options: .regularExpression
        )
    }

    /// 渲染层可见性：所有 text block 清洗后都为空、又没有任何其它块的消息整条隐藏
    ///（例：一条只有 `[Image: source:]` 引用文本的记录——图已在相邻消息内嵌渲染）。
    static func hasDisplayableContent(_ m: Message) -> Bool {
        m.blocks.contains { b in
            if case .text(let t) = b {
                return !hideImageRefs(t)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true   // image / code / tool / thinking 都是内容
        }
    }

    /// 定位强调环：金描边随 located 淡入淡出（进出各 0.3s，停留由 DetailView 控制）。
    /// 用 opacity 而非 if——两态同结构，动画只动透明度，不触发布局。
    private var locateRing: some View {
        RoundedRectangle(cornerRadius: 10)   // 与正文卡圆角一致
            .strokeBorder(DSLight.gold.opacity(0.65), lineWidth: 1.5)
            .opacity(located ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: located)
            .allowsHitTesting(false)
    }

    private func copyPlainText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let text = message.blocks.map(\.plainText).joined(separator: "\n\n")
        let prefix = message.role == .user ? "User:" : "Assistant:"
        pb.setString("\(prefix)\n\(text)", forType: .string)
    }
}

/// 气泡内容重活（MarkdownSegmenter.split / hideImageRefs 正则 / AttributedString(markdown:)）
/// 全部隔离在这个 Equatable 子视图里：父视图 hover/复制态每次翻转都重渲染，
/// 但 message 未变时 `.equatable()` 短路、整个子树跳过重算（曾经 hover 即全消息重分段重解析）。
struct MessageBlocksView: View, Equatable {
    let message: Message
    var highlightQuery: String = ""
    var isZh: Bool = true

    /// 会话内 message.id 与内容一一对应（uuid / ts-role-line 派生），O(1) 判等即可短路。
    /// 搜索词与语言纳入判等：变了要重算，hover 等父级翻转则照旧短路。
    static func == (l: Self, r: Self) -> Bool {
        l.message.id == r.message.id
            && l.message.blocks.count == r.message.blocks.count
            && l.highlightQuery == r.highlightQuery
            && l.isZh == r.isZh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    // 分段/markdown 渲染与时间线气泡条目共用
                    TextSegmentsView(text: t, highlightQuery: highlightQuery, isZh: isZh)
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                case .toolUse(let name, let input):
                    blockDisclosure(icon: "wrench.adjustable", title: name) {
                        Text(input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DSLight.t3)
                            .textSelection(.enabled)
                            .customContextMenuOnly()
                    }
                case .toolResult(let t):
                    blockDisclosure(icon: "arrow.turn.down.right", title: "result") {
                        Text(t)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DSLight.t3)
                            .textSelection(.enabled)
                            .customContextMenuOnly()
                    }
                case .thinking(let t):
                    blockDisclosure(icon: "ellipsis.bubble", title: "thinking") {
                        Text(t)
                            .font(.system(size: 12))
                            .lineSpacing(4)   // 折叠内容次级阅读面，行距略收
                            .foregroundStyle(DSLight.t3)
                            .textSelection(.enabled)
                            .customContextMenuOnly()
                    }
                case .image(let mediaType, let imgSource):
                    InlineImageView(mediaType: mediaType, source: imgSource)
                }
            }
        }
    }

    /// 折叠块标签：SF Symbol + 等宽小字（替代 emoji——设计系统反 AI 味）。
    private func blockDisclosure<C: View>(
        icon: String, title: String, @ViewBuilder content: () -> C
    ) -> some View {
        let inner = content()   // 先求值（DisclosureGroup 的 content 闭包是 escaping）
        return DisclosureGroup {
            inner
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(BrandFont.mono(11))
            }
            .foregroundStyle(DSLight.t3)
        }
    }
}
