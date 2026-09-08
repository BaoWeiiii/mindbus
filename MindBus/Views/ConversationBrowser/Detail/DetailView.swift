import SwiftUI
import MindBusCore

struct DetailView: View {
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var copyPrefs = CopyPrefsStore.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var loadEarlier: Bool = false
    @State private var copiedNote: String? = nil
    @State private var fabCopied = false      // FAB 成功态（✓ 已复制 + 变绿）
    @State private var fabWorking = false     // FAB 渲染进行中（后台整理长会话时防重复点击）
    @State private var fabHovering = false
    @State private var moreHovering = false   // header「…」菜单 hover 提亮
    /// 消息级定位的强调目标：locateMatch 置值 → 行金描边淡入，1.3s 后置回 nil 淡出。
    @State private var locatedMessageId: String? = nil
    /// 首启欢迎页：点开过任意一条对话即永久切回常规空态
    @AppStorage("firstRunWelcomeDone") private var welcomeDone = false
    /// 首次建库是否已经跑完：跑完后欢迎页固定成「点开任意一条」，之后对话更新触发的
    /// 增量扫描只在侧栏底部状态行露面，不再把右侧翻回「正在收集」。
    @AppStorage("firstScanDone") private var firstScanDone = false
    @ObservedObject private var connector = MCPConnector.shared
    @ObservedObject private var progress = ScanProgress.shared

    // 复制范围两态（用户定案）：未选择 = 完整会话；≥1 条手动选择 = 仅所选。
    @State private var copyScope: CopyScope = .all
    /// Shift 区间选择的锚点（最近一次「选中」动作的消息）。
    @State private var selectionAnchorId: String? = nil
    /// 待确认删除的消息 id 集(单条右键或多选统一删除;非空弹确认)。
    @State private var deleteMessageIds: Set<String> = []
    @State private var showDeleteMessagesConfirm = false
    /// 首次进入所选模式的 2s 明确反馈（底部状态条短暂提示后收敛）。
    @State private var scopeSwitchHintVisible = false
    /// 成功态文案上下文：本次复制的选中条数（nil = 完整会话）。
    @State private var copiedSelectionCount: Int? = nil

    private let defaultWindow = 500
    private let detailHeaderH: CGFloat = 40   // 与列表导航条同高，两栏 header 底边同 Y

    var body: some View {
        Group {
            if store.isLoadingDetail {
                loadingShell   // 框架（header/FAB）立即出现，仅消息区终端动画
            } else if let conv = store.selectedDetail {
                VStack(spacing: 0) {
                    // 救回横幅:源已被工具删除、读的是 MindBus 副本——「幸好装了」的
                    // 强确认时刻(产品价值最不可辩驳的证明,此前静默回退无人知晓)
                    if store.selectedDetailFromArchive {
                        HStack(spacing: 8) {
                            Image(systemName: "shield.checkered")
                                .font(.system(size: 11)).foregroundStyle(DSLight.gold)
                            Text(l10n.s.rescuedBanner)
                                .font(.system(size: 12)).foregroundStyle(DSLight.t1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(DSLight.goldG)
                    }
                    content(for: conv)
                }
                .transition(.opacity)
            } else if store.detailLoadFailed {
                sourceUnreadable
            } else {
                placeholder
            }
        }
        // 加载完成 → 内容纯淡入（微动画档 0.2s）；终端动画同步淡出。
        // 布局位移交给 messageScroll 的 .transaction 掐掉——否则这里的 animation
        // 会连内容布局一起驱动，翻转列表（原点在底）生长方向朝下，观感即「整块内容向下弹」。
        .animation(.easeOut(duration: 0.2), value: store.isLoadingDetail)
        // 正文来自不可信来源：链接只放行 http/https（见 SafeOpenURL.swift）
        .safeLinkOpening()
        // 切换会话重置「加载更早」窗口（滚动定位由 defaultScrollAnchor + .id 重建负责）
        // 与复制范围选择（选择不跨会话——避免看不见的旧选择静默改变复制内容）
        .onChange(of: store.selectedDetail?.id) { _ in
            if store.selectedDetail != nil { welcomeDone = true }   // 看过一条对话，欢迎页使命完成
            loadEarlier = false
            copyScope = .all
            selectionAnchorId = nil
            scopeSwitchHintVisible = false
        }
        // 消息删除统一确认(单条右键与多选删除共用;挂在两版 header 的共用根上)
        .alert(l10n.s.deleteMsgsTitle(deleteMessageIds.count),
               isPresented: $showDeleteMessagesConfirm) {
            Button(l10n.s.deleteConfirm, role: .destructive) {
                if let id = store.selectedConversationId, !deleteMessageIds.isEmpty {
                    store.deleteMessages(conversationID: id, messageIDs: deleteMessageIds)
                }
                deleteMessageIds = []
                copyScope = .all
                selectionAnchorId = nil
            }
            Button(l10n.s.deleteCancel, role: .cancel) { deleteMessageIds = [] }
        } message: {
            Text(l10n.s.deleteMsgsBody)
        }
    }

    // MARK: - 加载壳：header/FAB 先有，内容逐步加载

    /// 详情标题：官方 ai-title 优先，无则回落 cwd 尾目录名（与列表行同一优先级）。
    private func titleText(title: String?, cwd: String, id: String) -> String {
        if let t = title, !t.isEmpty { return t }
        return cwd.isEmpty ? id : URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func metaText(start: Date, count: Int, duration: TimeInterval) -> String {
        "\(Self.dateTime(start, isZh: l10n.isZh)) · \(l10n.s.msgsCount(count)) · \(durationText(duration))"
    }

    // 与 DayDivider 同族的固定 locale 日期时间（`.formatted()` 跟随系统 locale 会漂）；
    // 跨年补年份。zh_CN「M月d日 HH:mm」/ en「MMM d, HH:mm」。
    private static func dateTimeFormatter(_ locale: String, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.dateFormat = format
        return f
    }
    private static let zhDateTimeSameYear = dateTimeFormatter("zh_CN", "M月d日 HH:mm")
    private static let zhDateTimeFullYear = dateTimeFormatter("zh_CN", "yyyy年M月d日 HH:mm")
    private static let enDateTimeSameYear = dateTimeFormatter("en_US_POSIX", "MMM d, HH:mm")
    private static let enDateTimeFullYear = dateTimeFormatter("en_US_POSIX", "MMM d, yyyy, HH:mm")
    private static func dateTime(_ date: Date, isZh: Bool) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let f = isZh ? (sameYear ? zhDateTimeSameYear : zhDateTimeFullYear)
                     : (sameYear ? enDateTimeSameYear : enDateTimeFullYear)
        return f.string(from: date)
    }

    /// 选中瞬间用列表摘要（ConversationLite）渲染同款框架：标题/meta 立即可见，FAB 置灰，
    /// 中间消息区转圈——避免「先空转圈、加载完整个界面一起蹦出来」。
    @ViewBuilder
    private var loadingShell: some View {
        let lite = store.filteredConversations.first { $0.id == store.selectedConversationId }
        let t = lite.map { titleText(title: $0.title, cwd: $0.cwd, id: $0.id) } ?? " "
        let m = lite.map { metaText(start: $0.startAt, count: $0.messageCount, duration: $0.endAt.timeIntervalSince($0.startAt)) } ?? " "
        if #available(macOS 26.0, *) {
            terminalLoading(lite: lite)
                .safeAreaInset(edge: .top, spacing: 0) { floatingHeader(title: t, meta: m, conv: nil) }
                .ignoresSafeArea(.container, edges: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomCluster(for: nil)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header(title: t, meta: m, conv: nil)
                Divider()
                terminalLoading(lite: lite)
            }
            .overlay(alignment: .bottomTrailing) {
                relayFab(for: nil)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    /// 终端风加载：等宽字体逐行「输出」真实加载信息 + 闪烁块光标——像 CLI 在干活。
    private func terminalLoading(lite: ConversationLite?) -> some View {
        var lines: [String] = []
        if let lite {
            let name = titleText(title: lite.title, cwd: lite.cwd, id: lite.id)
            lines.append("$ mindbus open \(name)")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: lite.fileURL.path),
               let bytes = (attrs[.size] as? NSNumber)?.doubleValue {
                let mb = bytes / 1_048_576
                lines.append(mb >= 1
                             ? l10n.s.terminalReadMB(mb)
                             : l10n.s.terminalReadKB(bytes / 1024))
            }
            lines.append(l10n.s.terminalParsing(lite.messageCount))
        } else {
            lines.append("$ mindbus open …")
        }
        return TerminalLoading(lines: lines)
    }

    private struct TerminalLoading: View {
        let lines: [String]
        @State private var shown = 0
        @State private var cursorOn = true

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.prefix(shown).enumerated()), id: \.offset) { _, l in
                    Text(l)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DSLight.t2)
                }
                Text("█")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DSLight.gold)
                    .opacity(cursorOn ? 1 : 0.12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                for i in 1...lines.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                        if shown < i { shown = i }
                    }
                }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    cursorOn = false
                }
            }
        }
    }

    /// 不用大号 SF Symbol：通用图标（气泡/文件夹一类）是 AI 味重灾区，
    /// 且这里只需要一句指引，用排版本身承担即可。
    @ViewBuilder
    private var placeholder: some View {
        if welcomeDone {
            Text(l10n.s.detailPlaceholder)
                .font(.system(size: 13))
                .foregroundStyle(DSLight.t3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            welcomePlaceholder
        }
    }

    /// 首启欢迎页：放在右侧空态——窗口打开时视线的落点（Notes / Mail / Slack 同款位置）。
    /// 讲清只读三处目录、数据留本机，顺手给一键接入；用户点开任意一条对话后自然消失，
    /// 之后空态回到常规文案。不进侧栏、不做向导、不需要「知道了」。
    private var welcomePlaceholder: some View {
        VStack(spacing: 18) {
            if let logo = BrandLogoImage.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
            }
            Text(l10n.s.welcomeTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DSLight.t1)
            // 进度：环 + 阶段 + 预计剩余（与侧栏底部同一口径），只在首次建库时显示；
            // 扫完换成「点开任意一条」/ 空库引导并固定
            VStack(spacing: 8) {
                if showsScanProgress {
                    HStack(spacing: 8) {
                        ProgressRing(fraction: progress.fraction)
                            .frame(width: 14, height: 14)
                        Text(ScanStatus.text(progress, l10n) ?? "")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(DSLight.t2)
                            .contentTransition(.numericText())
                    }
                } else {
                    Text(store.allConversations.isEmpty ? l10n.s.welcomeEmpty : l10n.s.welcomeReady)
                        .font(.system(size: 12))
                        .foregroundStyle(DSLight.t3)
                }
            }
            .padding(.top, 6)
            .animation(.easeOut(duration: 0.3), value: showsScanProgress)
            if let host = connector.suggestedHost {
                Button {
                    connector.connect(host)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.system(size: 11, weight: .medium))
                        Text(l10n.s.welcomeConnect(host.displayName)).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(DSLight.gold)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(DSLight.goldG, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 380)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 欢迎页在场时不自动选中最新一条：让它一直停留到用户自己点开一条
        .onAppear {
            store.autoSelectsFirst = false
            // 库里已经有对话且没在扫 → 不是首次建库（老版本升级上来），直接固定
            if !store.allConversations.isEmpty, !ScanStatus.isActive(progress) { firstScanDone = true }
        }
        .onDisappear { store.autoSelectsFirst = true }
        .onChange(of: progress.phase) { phase in
            if phase == .done { firstScanDone = true }
        }
    }

    private var showsScanProgress: Bool { !firstScanDone && ScanStatus.isActive(progress) }


    /// 详情 parse 失败：源文件已被移动/删除但索引仍有行——明确告知，
    /// 而不是退回「从左侧选择一个对话」占位（明明点了一条，界面却让他去选一条）。
    /// 与 placeholder 同风格：纯排版，不用大号通用图标。
    private var sourceUnreadable: some View {
        VStack(spacing: 8) {
            Text(l10n.s.sourceUnreadableTitle)
                .font(.system(size: 13))
                .foregroundStyle(DSLight.t2)
            Text(l10n.s.sourceUnreadableDetail)
                .font(.system(size: 11))
                .foregroundStyle(DSLight.t3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 布局

    @ViewBuilder
    private func content(for conv: Conversation) -> some View {
        if #available(macOS 26.0, *) {
            glassContent(for: conv)
        } else {
            plainContent(for: conv)
        }
    }

    /// macOS 26：玻璃 header 固定在顶，对话图文从它下面滚过、被实时折射（与列表 header 同一套 lensing）。
    @available(macOS 26.0, *)
    private func glassContent(for conv: Conversation) -> some View {
        messageScroll(for: conv)
            // safeAreaInset：预留滚动空间 + 悬浮元素（与列表同款 iOS 风，无整条 bar）。
            .safeAreaInset(edge: .top, spacing: 0) {
                floatingHeader(
                    title: titleText(title: conv.title, cwd: conv.cwd, id: conv.id),
                    meta: metaText(start: conv.startAt, count: conv.messageCount, duration: conv.duration),
                    conv: conv
                )
            }
            .ignoresSafeArea(.container, edges: .top)   // 去 titlebar safe area，悬浮元素贴窗口顶
            // 底部预留区（56，与列表底部搜索区同级）：FAB 在其中上下居中、贴右，
            // 滚到底静止时最后一条停在区域上方，不与按钮重叠；滚动中消息从按钮下穿过。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomCluster(for: conv)
                    .padding(.horizontal, 14)   // 与列表底部搜索胶囊外边距一致
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
    }

    /// macOS 26 详情顶部：标题/meta 裸文字贴左 + 接力金钮贴右。
    /// 渐隐尾巴计入预留高度：滚到顶静止时第一条消息完全清晰，继续滚动才进入模糊区（与列表同款）。
    @available(macOS 26.0, *)
    private func floatingHeader(title: String, meta: String, conv: Conversation?) -> some View {
        // 只留标题居中——与左栏「N 条对话」完全同构；meta 拆到列表行（条数/时长）+ 消息流头（始于）。
        // 次动作全部收进右侧「…」菜单；FAB 仍是唯一主动作。
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 44)   // 两侧让出菜单钮宽度，长标题不与之重叠
        .frame(height: detailHeaderH + 12)   // 整个渐隐顶区（含尾巴），内容上下居中
        .frame(maxWidth: .infinity)          // 左右居中（与列表标题同风格）
        .background {
            // 0.94 实底档：详情正文会一路滚到窗口顶，0.78 半透下深色正文
            // 穿透可读、与标题糊成一团（实机截图实证）；列表顶保持 0.78 是因为
            // 行内容离 header 有 inset，这里没有。尾部留渐出带衔接滚动内容。
            LinearGradient(
                stops: [.init(color: DSLight.bg.opacity(0.94), location: 0),
                        .init(color: DSLight.bg.opacity(0.94), location: 0.72),
                        .init(color: DSLight.bg.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 8) {
                // 多选统一删除(用户定案:右上角)——选择态才出现,红色破坏动作
                if copyScope.isSelection {
                    Button(role: .destructive) {
                        deleteMessageIds = copyScope.selectedIds
                        showDeleteMessagesConfirm = true
                    } label: {
                        Label(l10n.s.deleteSelectedButton(copyScope.count), systemImage: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(DSLight.red)
                    }
                    .buttonStyle(.plain)
                }
                moreMenu(for: conv)
            }
            .padding(.trailing, 10)
        }
        .contentShape(Rectangle())
        .windowDragArea()   // 详情顶部 = 拖动带（「…」菜单是控件，优先于手势不受影响）
    }

    /// 旧系统：普通 header + 分隔 + 滚动。
    private func plainContent(for conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(
                title: titleText(title: conv.title, cwd: conv.cwd, id: conv.id),
                meta: metaText(start: conv.startAt, count: conv.messageCount, duration: conv.duration),
                conv: conv
            )
            Divider()
            messageScroll(for: conv)
        }
        .overlay(alignment: .bottom) {
            bottomCluster(for: conv)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }

    // MARK: - header / 滚动内容

    private func header(title: String, meta: String, conv: Conversation?) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 44)
            .frame(maxWidth: .infinity, minHeight: 32)
            .overlay(alignment: .trailing) {
                HStack(spacing: 6) {
                    // 引用徽章:与列表行同款——这场对话被 AI 真实用过的可见证明
                    if let id = conv?.id ?? store.selectedConversationId,
                       let n = store.refCounts[id], n > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "sparkles").font(.system(size: 10))
                            Text("\(n)").font(BrandFont.mono(11))
                        }
                        .foregroundStyle(DSLight.gold)
                        .help(l10n.s.refBadgeHelp(n))
                    }
                    if let conv {
                        // 长对话的目录:够不上 3 个节点时它自己不显示
                        OutlineButton(conversation: conv)
                        // 你可能忘了的:没把握时它自己也不显示
                        ForgottenRelatedButton(conversationID: conv.id)
                    }
                    moreMenu(for: conv)
                }
                .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
            .windowDragArea()
    }

    // MARK: - 「…」收纳菜单（header 次动作；主动作仍是 FAB）

    /// 「复制全部」与 FAB「复制接力」是同一渲染管线（ConversationCopy.render + 用户偏好），
    /// 走 copyHandoff 复用后台渲染与 FAB 成功反馈；⌘⇧C 在 ConversationBrowserView 保留不动。
    private func moreMenu(for conv: Conversation?) -> some View {
        Menu {
            Button(l10n.s.copyAll) {
                guard let conv, !fabWorking, !fabCopied else { return }
                copyHandoff(conv, forceAll: true)   // 名实相符：无视当前手选
            }
            .disabled(conv == nil || fabWorking)
            // browser 来源无本地源文件；文件已被移动/删除时也不给一个注定失败的动作
            if let conv, conv.source != .browser,
               let url = sourceFileURL(for: conv),
               FileManager.default.fileExists(atPath: url.path) {
                Button(l10n.s.revealSourceInFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(moreHovering ? DSLight.t1 : DSLight.t2)
                .frame(width: 26, height: 26)
                .background(moreHovering ? DSLight.sf2 : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(conv == nil)
        .opacity(conv == nil ? 0.4 : 1)   // 加载壳阶段占位置灰，与 FAB 同策略
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { moreHovering = h }
        }
        .help(l10n.s.moreActions)
        .accessibilityLabel(l10n.s.moreActions)
    }

    /// 详情 Conversation 不持有文件路径，从列表摘要（ConversationLite）反查。
    private func sourceFileURL(for conv: Conversation) -> URL? {
        store.allConversations.first { $0.id == conv.id }?.fileURL
    }

    // MARK: - 底部操作栏（复制范围状态 + 恢复 + FAB，用户定稿的整条落底样式）

    /// 整条落底操作栏：左 = 范围状态（选中数字金色 + ⓘ 规则提示），
    /// 右 = 「恢复完整会话」弱按钮 + 深底金字主按钮。
    /// 状态变化三处同步（消息高亮 / 范围说明 / 按钮数量），用户不需要理解隐藏规则。
    private func bottomCluster(for conv: Conversation?) -> some View {
        HStack(spacing: 14) {
            if let conv { scopeStatus(for: conv) }
            Spacer(minLength: 12)
            if copyScope.isSelection, conv != nil {
                RestoreScopeButton(title: l10n.s.restoreFullScope) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        copyScope = .all
                        selectionAnchorId = nil
                        scopeSwitchHintVisible = false
                    }
                }
            }
            relayFab(for: conv)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background {
            // 浮层级卡片双层投影：贴地细影定边缘 + 环境光大影抬升——
            // 单层微影在同色底（bg 上浮 bg）上浮不起来（用户实机反馈）。圆角 12 浮层档。
            RoundedRectangle(cornerRadius: 12)
                .fill(DSLight.bg)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        }
    }

    /// 「恢复完整会话」：直接说明结果（不是「清除选择」——那说不清清完复制什么）。
    /// 弱灰常态，hover 提亮到主文字色。
    private struct RestoreScopeButton: View {
        let title: String
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(title, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? DSLight.t1 : DSLight.t3)
                .onHover { h in
                    withAnimation(.easeOut(duration: 0.12)) { hovering = h }
                }
        }
    }

    @ViewBuilder
    private func scopeStatus(for conv: Conversation) -> some View {
        Group {
            if scopeSwitchHintVisible {
                // 首次进入所选模式的一次性明确反馈（2s 后收敛，不弹框不确认）
                Text(l10n.s.scopeSwitchHint)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.gold)
            } else if copyScope.isSelection {
                let parts = l10n.s.scopeSelectedParts(copyScope.count)
                (Text(parts.0).foregroundColor(DSLight.t1)
                    + Text(parts.1).foregroundColor(DSLight.gold)
                    + Text(parts.2).foregroundColor(DSLight.t1))
                    .font(.system(size: 12, weight: .medium))
            } else {
                // 「逻辑上全选」只在这里说明，不在消息区画全选态。
                // ⓘ 规则图标已删（用户定案）——规则说明保留在选择圆点的悬停提示里。
                Text(l10n.s.scopeFullMeta(conv.messageCount))
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.t3)
            }
        }
        .lineLimit(1)
        .animation(.easeOut(duration: 0.2), value: scopeSwitchHintVisible)
        .animation(.easeOut(duration: 0.2), value: copyScope.isSelection)
    }

    /// 选择点/Option 点卡片的统一入口。shift = 区间并入（锚点→目标）。
    /// 首次从完整会话切到所选模式时，底部状态条给一次 2s 明确反馈。
    private func toggleSelection(_ id: String, shift: Bool, order: [String]) {
        let wasAll = !copyScope.isSelection
        copyScope = shift
            ? copyScope.selectingRange(anchor: selectionAnchorId, target: id, order: order)
            : copyScope.toggling(id)
        selectionAnchorId = copyScope.selectedIds.contains(id) ? id : nil
        if wasAll, copyScope.isSelection {
            scopeSwitchHintVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.25)) { scopeSwitchHintVisible = false }
            }
        }
    }

    /// 右下角悬浮主按钮（FAB）：gold 实色胶囊 + icon + 文字——整窗最显眼的主动作。
    /// 三层反馈：hover 抬升 → 按下压缩 → 成功时按钮自身变形（✓ 已复制 + 变绿），1.4s 回弹。
    /// token 估算小字出现在按钮左侧（「省了多少」的价值可视化）。
    private func relayFab(for conv: Conversation?) -> some View {
        HStack(spacing: 8) {
            if let note = copiedNote {
                Text(note)
                    .font(BrandFont.mono(10))
                    .foregroundStyle(DSLight.green)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Button {
                guard let conv, !fabCopied, !fabWorking else { return }   // 成功态/渲染中防连点
                copyHandoff(conv)
            } label: {
                HStack(spacing: 6) {
                    if fabWorking {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                            .tint(DS.gold)   // 深底上的转圈同用暗底浅金
                    } else {
                        Image(systemName: fabCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .contentTransition(.opacity)
                    }
                    Text(fabLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.opacity)
                }
                // 深底金字（用户定稿 2026-08-03）：底 = 网站亮色 accent-primary 同值
                // 的近黑（DS.bg #09090D），字/icon = 暗底浅金 DS.gold #DDB992
                //（暗底配浅金、浅底配深金的既定 token 规则），圆角 10 按钮档。
                // 边缘定稿（2026-08-10「1+3」）：流光描边三版被否——光放轮廓上
                // 就是 RGB 灯语法。改为静态机加工边 + 文字流光（GoldShimmer）：
                // 光只出现在字形内部，按钮边缘永远清晰安静。成功态变绿。
                .modifier(GoldShimmer(running: !fabWorking && !fabCopied, hovering: fabHovering))
                .foregroundStyle(fabCopied ? DS.green : DS.gold)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    // 机加工边：内上缘 1px 受光、向下渐隐——实体材质受顶光的静态质感
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DS.bg)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                                   startPoint: .top, endPoint: .bottom),
                                    lineWidth: 1)
                        }
                }
                .scaleEffect(fabHovering && !fabCopied ? 1.04 : 1)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(conv == nil || fabWorking)
            .opacity(conv == nil ? 0.55 : 1)   // 加载中先占位置灰，加载完即点
            .onHover { h in
                withAnimation(.easeOut(duration: 0.15)) { fabHovering = h }
            }
            // 先答「这按钮干什么」（含当前复制范围），再讲「怎么调」。
            // 「接力」是品牌词（Landing 8 语言在用，不改），但对隔了两周才打开的用户
            // 它不自解释——tooltip 要补上这层意思。
            .help(fabHelpText(for: conv))
        }
        .animation(.easeOut(duration: 0.2), value: copiedNote)
    }

    /// FAB 主文案随复制范围/进行态/成功态联动（spec 三处同步之一）。
    private var fabLabel: String {
        let selCount = copyScope.isSelection ? copyScope.count : nil
        if fabCopied {
            return copiedSelectionCount.map(l10n.s.copiedCount) ?? l10n.s.copiedFull
        }
        if fabWorking {
            return selCount.map(l10n.s.fabWorkingCount) ?? l10n.s.fabWorking
        }
        return selCount.map(l10n.s.fabRelayCount) ?? l10n.s.fabRelay
    }

    private func fabHelpText(for conv: Conversation?) -> String {
        guard let conv else { return l10n.s.fabHelp }
        let scopeLine = copyScope.isSelection
            ? l10n.s.scopeSelectedMeta(copyScope.count)
            : l10n.s.fabHelpFullScope(conv.messageCount)
        return scopeLine + "\n" + l10n.s.fabHelp
    }

    /// 文字流光（「1+3」定稿的 1）：一道暖白高光带扫过金字字形内部——
    /// 光在文字上不在轮廓上，按钮面与边缘全程不动。
    /// 触发：idle 每 6s 一程 + hover 即时一程；working/成功态整个不装载；
    /// 系统「减弱动态效果」静止；窗口失焦跳过。带宽约 55% 按钮宽，0.9s 单程。
    private struct GoldShimmer: ViewModifier {
        var running: Bool
        var hovering: Bool
        @Environment(\.controlActiveState) private var activeState
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var phase: CGFloat = -0.6   // 带左缘/按钮宽：-0.6 左外 → 1.1 右外

        /// 高光暖白（比 DS.gold 亮两档）：字形被「光掠过」而不是换色。
        private static let highlight = Color(red: 1.0, green: 0.95, blue: 0.87)

        @ViewBuilder
        func body(content: Content) -> some View {
            if running, !reduceMotion {
                content
                    .overlay {
                        GeometryReader { geo in
                            let w = geo.size.width
                            LinearGradient(
                                stops: [.init(color: Self.highlight.opacity(0), location: 0),
                                        .init(color: Self.highlight.opacity(0.95), location: 0.5),
                                        .init(color: Self.highlight.opacity(0), location: 1)],
                                startPoint: .leading, endPoint: .trailing)
                            .frame(width: w * 0.55)
                            .offset(x: phase * w)
                        }
                    }
                    .mask(content)   // 高光带只在字形内可见
                    .onChange(of: hovering) { h in
                        if h { sweep() }
                    }
                    .task {   // 视图存活期驱动 idle 节拍（.task 不随 body 重算重置）
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            sweep()
                        }
                    }
            } else {
                content
            }
        }

        private func sweep() {
            guard activeState != .inactive else { return }   // 后台窗口不空扫
            phase = -0.6
            withAnimation(.easeInOut(duration: 0.9)) { phase = 1.1 }
        }
    }

    /// 按下压感（设计系统 active:scale）。
    private struct PressScaleStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    /// 翻转列表（聊天 app 标准解）：内容整体 y 翻转 + 每行翻回 + 数据倒序——
    /// 滚动原点即视觉底部，打开**天然停在最新一条**，无 scrollTo / 无 lazy 估算竞速。
    /// 搜索态例外：加载完成后定位到最新命中消息（locateMatch），非搜索态零介入。
    private func messageScroll(for conv: Conversation) -> some View {
        let all = conv.messages
        let hasMore = all.count > defaultWindow && !loadEarlier
        let showing: ArraySlice<Message> = hasMore ? all.suffix(defaultWindow) : all[...]
        // 最新在前 = 翻转后视觉底部；顺手滤掉「清洗后无内容」的消息
        //（如只有 [Image: source:] 引用文本的记录——图已在相邻消息内嵌渲染）
        let rev = Array(showing.reversed()).filter { MessageBubbleView.hasDisplayableContent($0) }
        // 执行流时间线的行级信息（run 划分/时间去重；axis/terminal 字段保留不再驱动视觉）：
        // 纯枚举 tag 扫描 O(总块数)，与上面 rev 构造同量级，无正则/全文扫描。
        let infos = TimelineLayout.rowInfos(rev: rev)

        // Shift 区间选择的顺序参照（区间跨度只看端点下标，方向无关）
        let orderIds = rev.map(\.id)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rev.enumerated()), id: \.element.id) { i, msg in
                        MessageBubbleView(message: msg, timeline: infos[i],
                                          highlightQuery: store.highlightQuery,
                                          located: locatedMessageId == msg.id,
                                          selectionActive: copyScope.isSelection,
                                          selected: copyScope.selectedIds.contains(msg.id),
                                          starKey: StarredMessagesStore.key(
                                              conversationID: conv.id, messageID: msg.id),
                                          onToggleSelect: { shift in
                                              toggleSelection(msg.id, shift: shift, order: orderIds)
                                          },
                                          onDelete: {
                                              deleteMessageIds = [msg.id]
                                              showDeleteMessagesConfirm = true
                                          })
                            .scaleEffect(x: 1, y: -1)
                            // 显式行 id：消息级定位的 scrollTo 靶点。scaleEffect 不改
                            // 布局 frame，proxy 在未翻转的布局坐标系里定位，.center 锚点
                            // 上下对称——翻转不影响「滚到视口中间」的结果。
                            .id(msg.id)
                        // 数组后向 = 视觉上方：跨天时在该天块顶插日期分隔
                        if i + 1 < rev.count,
                           !Calendar.current.isDate(msg.timestamp, inSameDayAs: rev[i + 1].timestamp) {
                            DayDivider(date: msg.timestamp, isZh: l10n.isZh)
                                .scaleEffect(x: 1, y: -1)
                        }
                    }

                    if hasMore {
                        // padding/frame 收进 label + contentShape：整行可点，不再只有文字那几十像素
                        Button(action: { loadEarlier = true }) {
                            Text(l10n.s.loadEarlier(all.count - defaultWindow))
                                .font(.system(size: 11))
                                .foregroundStyle(DSLight.t3)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .scaleEffect(x: 1, y: -1)
                    }

                    // 会话起点时间戳（视觉最顶 = 数组最后）
                    Text(l10n.s.startedAt(Self.dateTime(conv.startAt, isZh: l10n.isZh)))
                        .font(.system(size: 10))
                        .foregroundStyle(DSLight.t4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .scaleEffect(x: 1, y: -1)
                }
                .padding(12)
            }
            .scaleEffect(x: 1, y: -1)
            // 掐掉从外部流入的布局动画：切换/加载完成时消息区瞬时就位，只留外层 opacity 淡入。
            // （否则 body 上的 .animation 会驱动内容布局，翻转列表生长朝下 = 「整块向下弹」。
            //   气泡内部 hover/复制反馈是局部 @State 更新，不经过这里，微动画不受影响。
            //   定位强调环的淡入淡出走行内 .animation(value:)，同样不受影响。）
            .transaction { $0.animation = nil }
            // 定位触发的两条互斥路径：冷加载走 loadingShell → content 重挂载 = onAppear；
            // 详情 LRU 缓存命中不卸载视图、conv.id 直接变 = onChange。
            .onAppear {
                if !consumePendingLocate(in: conv, proxy: proxy) {
                    locateMatch(in: conv, proxy: proxy)
                }
            }
            .onChange(of: conv.id) { _ in
                locatedMessageId = nil   // 旧会话的强调不带进新会话
                if !consumePendingLocate(in: conv, proxy: proxy) {
                    locateMatch(in: conv, proxy: proxy)
                }
            }
        }
    }

    /// 跨模块定位(收藏「打开原对话」):消费 store.pendingLocateMessageID。
    /// 返回是否消费了——消费则跳过搜索定位(两者互斥,pending 优先)。
    @discardableResult
    private func consumePendingLocate(in conv: Conversation, proxy: ScrollViewProxy) -> Bool {
        guard let target = store.pendingLocateMessageID else { return false }
        store.pendingLocateMessageID = nil
        guard conv.messages.contains(where: { $0.id == target }) else { return false }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .center)
            locatedMessageId = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                if locatedMessageId == target { locatedMessageId = nil }
            }
        }
        return true
    }

    // MARK: - 消息级定位（搜索态点开会话 → 滚到最新命中消息）

    /// 取「最新的命中」而非最旧：搜索找回的主场景是「最近讨论到哪了」，最新命中
    /// 即续聊点；它也天然离翻转列表的默认落点（视觉底部）最近，跳动最小。
    /// 无命中（FTS 召回可能来自标题/cwd 等会话级字段，或命中在默认窗口之前的
    /// 更早消息里）则不滚不闪，保持默认落底。
    private func locateMatch(in conv: Conversation, proxy: ScrollViewProxy) {
        let q = store.highlightQuery
        // 双查：highlightQuery 与召回同拍，但清词后的 180ms 防抖窗内它仍是旧词——
        // 定位必须随 searchQuery 清空立即失效（此时点开会话回默认落底）。
        guard !q.isEmpty,
              !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // 与 messageScroll 相同的默认窗口（切换会话时 loadEarlier 已被重置，
        // 不读它——两个 onChange 的执行顺序无保证）。窗口外的更早命中不定位。
        let all = conv.messages
        let showing = all.count > defaultWindow ? Array(all.suffix(defaultWindow)) : all
        guard let target = showing.last(where: { SearchHighlight.messageMatches($0, query: q) })
        else { return }

        let id = target.id
        // 下一 runloop 再滚：等 LazyVStack 完成本帧布局，scrollTo 才有的放矢。
        // 跳转不做滚动动画（长距离动画滚动在 lazy 容器里既慢又晃），
        // 落点由强调环（0.3s 进 · 1s 停 · 0.3s 出）接手引导视线。
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .center)
            locatedMessageId = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                // 已切到别的目标（快速换会话）就不动新状态
                if locatedMessageId == id { locatedMessageId = nil }
            }
        }
    }

    // MARK: - 日期分隔（波浪线 ~~ 6月10日 ~~，跨自然日插入）

    private struct WavyLine: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let amplitude: CGFloat = 1.6
            let wavelength: CGFloat = 14
            p.move(to: CGPoint(x: 0, y: rect.midY))
            var x: CGFloat = 0
            while x <= rect.width {
                let y = rect.midY + amplitude * sin((x / wavelength) * 2 * .pi)
                p.addLine(to: CGPoint(x: x, y: y))
                x += 1
            }
            return p
        }
    }

    private struct DayDivider: View {
        let date: Date
        let isZh: Bool

        private var label: String {
            let f = DateFormatter()
            // 固定 locale：不跟系统语言漂，只跟 App 内语言
            f.locale = Locale(identifier: isZh ? "zh_CN" : "en_US_POSIX")
            let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            f.dateFormat = isZh ? (sameYear ? "M月d日" : "yyyy年M月d日")
                                : (sameYear ? "MMM d" : "MMM d, yyyy")
            return f.string(from: date)
        }

        var body: some View {
            HStack(spacing: 10) {
                WavyLine()
                    .stroke(DSLight.t3.opacity(0.3), lineWidth: 1)
                    .frame(height: 6)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DSLight.t3)
                    .fixedSize()
                WavyLine()
                    .stroke(DSLight.t3.opacity(0.3), lineWidth: 1)
                    .frame(height: 6)
            }
            .padding(.vertical, 8)
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return l10n.s.durationMinutes(s / 60) }
        return "\(l10n.s.durationHours(s / 3600)) \(l10n.s.durationMinutes((s % 3600) / 60))"
    }

    /// 渲染 + token 估算放后台（万条消息级会话在主线程渲染曾 beachball 秒级），
    /// 回主线程写剪贴板与成功态；fabWorking 期间按钮禁点防重复触发。
    /// 复制范围：有手动选择就只复制所选（copyScope.selected），否则完整会话；
    /// forceAll 供「复制全部」菜单——名实相符，无视当前选择。
    /// 成功后**不清空**局部选择（用户定案：可能连着粘给多个模型）。
    private func copyHandoff(_ conv: Conversation, forceAll: Bool = false) {
        fabWorking = true
        let prefs = copyPrefs.prefs
        let isZh = l10n.isZh   // MainActor 上取值，后台任务只拿标量
        let onlyIds: Set<String>? =
            (!forceAll && copyScope.isSelection) ? copyScope.selectedIds : nil
        Task.detached(priority: .userInitiated) {
            let text = ConversationCopy.render(conv, prefs: prefs, isZh: isZh,
                                               onlyMessageIds: onlyIds)
            let tokens = ConversationCopy.estimateTokens(text)
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                fabWorking = false
                copiedSelectionCount = onlyIds?.count
                withAnimation(.bouncy(duration: 0.35)) { fabCopied = true }
                copiedNote = "≈\(tokens) token"   // 成功语义在按钮上，这里只留数字
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {   // spec: 成功态 1.4s
                    withAnimation(.easeOut(duration: 0.25)) { fabCopied = false }
                    copiedNote = nil
                }
            }
        }
    }
}
