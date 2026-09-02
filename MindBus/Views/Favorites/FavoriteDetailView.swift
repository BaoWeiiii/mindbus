import SwiftUI
import MindBusCore

/// 收藏详情页:默认「收藏内容」卡片流,可切「完整对话」只读回看。
/// 「打开原对话」才真正离开收藏模块进入可接力的标准页。
struct FavoriteDetailView: View {
    @ObservedObject var store: ConversationStore
    let conversationID: String
    /// 进入时要定位的收藏(来自首页「最近收藏」点击);nil = 不定位。
    var focusFavoriteKey: String? = nil
    var onBack: () -> Void

    @ObservedObject private var stars = StarredMessagesStore.shared
    @ObservedObject private var l10n = L10n.shared

    enum Mode { case saved, full }
    @State private var mode: Mode = .saved
    @State private var conversation: Conversation? = nil
    @State private var loadFailed = false
    /// 卡片内上下文展开(同一时间只展开一张,设计说明)。
    @State private var expandedKey: String? = nil
    /// 完整对话当前定位的收藏下标(0-based;「收藏 3/7」口径,原消息顺序)。
    @State private var focusIndex: Int = 0
    /// 「最近收藏」入场定位的短暂高亮。
    @State private var flashKey: String? = nil
    /// 撤销 Toast:(文案, 撤销动作)。
    @State private var toast: (text: String, undo: () -> Void)? = nil
    @State private var toastDismiss: DispatchWorkItem? = nil
    /// 删除确认锚点(哪条卡片的确认浮层开着)。
    @State private var confirmingDeleteKey: String? = nil

    private var lite: ConversationLite? {
        store.allConversations.first { $0.id == conversationID }
    }

    /// 有效收藏,按**原消息在对话中的顺序**（messages 可得时）;
    /// 原文不可用时退按 favoritedAt。
    private var orderedFavorites: [FavoriteRecord] {
        let recs = stars.activeRecords(conversationID: conversationID)
        guard let msgs = conversation?.messages else {
            return recs.sorted { $0.favoritedAt < $1.favoritedAt }
        }
        let order = Dictionary(uniqueKeysWithValues: msgs.enumerated().map { ($0.element.id, $0.offset) })
        return recs.sorted { (order[$0.messageID] ?? .max) < (order[$1.messageID] ?? .max) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            Rectangle().fill(DSLight.rule).frame(height: 1)
            content
        }
        .overlay(alignment: .bottom) { toastView }
        .onAppear(perform: load)
        .safeLinkOpening()
    }

    private func load() {
        guard let lite else { loadFailed = true; return }
        // 后台读原文;失败仍展示快照（原对话不可用不删收藏）
        Task.detached(priority: .userInitiated) {
            let conv = ConversationStore.loadFull(id: lite.id, fileURL: lite.fileURL,
                                                  source: lite.source)
            await MainActor.run {
                conversation = conv
                loadFailed = (conv == nil)
                if let key = focusFavoriteKey {
                    flashKey = key
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if flashKey == key { flashKey = nil }
                    }
                }
            }
        }
    }

    // MARK: - 头部(吸顶)

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DSLight.t2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.s.favoritesBackHelp)

                Text(headTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DSLight.t1)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if mode == .full, orderedFavorites.count > 0 {
                    favoriteStepper
                }
                Button {
                    openOriginal()
                } label: {
                    Text(l10n.s.favoritesOpenOriginal)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(conversation == nil ? DSLight.t3 : DSLight.gold)
                }
                .buttonStyle(.plain)
                .disabled(conversation == nil)
                .help(l10n.s.favoritesOpenOriginalHelp)
            }
            Text(subTitle)
                .font(.system(size: 12)).foregroundStyle(DSLight.t3)
                .padding(.leading, 38)
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 10)
    }

    private var headTitle: String {
        if let t = lite?.title, !t.isEmpty { return t }
        if let cwd = lite?.cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return lite?.preview ?? conversationID
    }

    private var subTitle: String {
        guard let lite else { return l10n.s.favoritesOriginalUnavailable }
        let project = URL(fileURLWithPath: lite.cwd).lastPathComponent
        var parts: [String] = []
        if !project.isEmpty, !lite.cwd.isEmpty { parts.append(project) }
        parts.append(lite.source.displayName(isZh: l10n.isZh))
        parts.append(l10n.s.favoritesTotalMessages(lite.messageCount))
        return parts.joined(separator: " · ")
    }

    /// 完整对话的「收藏 3/7 ↑↓」。
    private var favoriteStepper: some View {
        HStack(spacing: 6) {
            Text(l10n.s.favoritesPosition(focusIndex + 1, orderedFavorites.count))
                .font(.system(size: 12)).foregroundStyle(DSLight.t2)
            Button { jump(to: focusIndex - 1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(focusIndex <= 0)
            .foregroundStyle(focusIndex <= 0 ? DSLight.t4 : DSLight.t2)
            .help(l10n.s.favoritesPrevHelp)
            Button { jump(to: focusIndex + 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(focusIndex >= orderedFavorites.count - 1)
            .foregroundStyle(focusIndex >= orderedFavorites.count - 1 ? DSLight.t4 : DSLight.t2)
            .help(l10n.s.favoritesNextHelp)
        }
    }

    private func jump(to index: Int) {
        guard index >= 0, index < orderedFavorites.count else { return }
        focusIndex = index
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 20) {
            tabItem(l10n.s.favoritesTabSaved(orderedFavorites.count), active: mode == .saved) {
                mode = .saved
            }
            tabItem(l10n.s.favoritesTabFull, active: mode == .full) {
                mode = .full
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func tabItem(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DSLight.gold : DSLight.t2)
                Rectangle()
                    .fill(active ? DSLight.gold : .clear)
                    .frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: active)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .saved: savedList
        case .full: fullConversation
        }
    }

    // MARK: 收藏内容模式

    private var savedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if orderedFavorites.isEmpty {
                        Text(l10n.s.favoritesNoneLeft)
                            .font(.system(size: 13)).foregroundStyle(DSLight.t3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    // 原消息时间倒序:最新的原消息在上
                    ForEach(orderedFavorites.reversed()) { rec in
                        favoriteCard(rec)
                            .id(rec.key)
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 28).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conversation == nil) { _ in
                if let key = focusFavoriteKey {
                    DispatchQueue.main.async { proxy.scrollTo(key, anchor: .center) }
                }
            }
        }
    }

    private func message(for rec: FavoriteRecord) -> Message? {
        conversation?.messages.first { $0.id == rec.messageID }
    }

    private func favoriteCard(_ rec: FavoriteRecord) -> some View {
        let msg = message(for: rec)
        return VStack(alignment: .leading, spacing: 6) {
            // 原消息时间(卡外)
            Text(cardTimestamp(rec, msg: msg))
                .font(.system(size: 11)).foregroundStyle(DSLight.t3)

            VStack(alignment: .leading, spacing: 10) {
                // 顶行:来源 + 书签(实心金,点击取消) + 菜单
                HStack(spacing: 8) {
                    Text(roleLabel(rec, msg: msg))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DSLight.t2)
                    Spacer()
                    Button {
                        unstarWithUndo(rec)
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 13)).foregroundStyle(DSLight.gold)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n.s.starRemoveHelp)
                    cardMenu(rec)
                }

                // 正文:复用原渲染器（不转纯文本）;原文不可用退快照
                if let msg {
                    MessageBlocksView(message: msg, highlightQuery: "", isZh: l10n.isZh)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(rec.contentSnapshot.isEmpty ? l10n.s.favoritesNoSnapshot
                             : rec.contentSnapshot)
                            .font(.system(size: 13)).foregroundStyle(DSLight.t1)
                        Text(l10n.s.favoritesOriginalUnavailable)
                            .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                    }
                }

                // 上下文展开
                if expandedKey == rec.key, let msg {
                    contextExpansion(around: msg)
                }

                // 底部操作行
                HStack {
                    if message(for: rec) != nil {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                expandedKey = (expandedKey == rec.key) ? nil : rec.key
                            }
                        } label: {
                            Text(expandedKey == rec.key ? l10n.s.favoritesCollapseContext
                                 : l10n.s.favoritesShowContext)
                                .font(.system(size: 12))
                                .foregroundStyle(DSLight.t2)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(DSLight.sf2, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if conversation != nil {
                        Button {
                            locateInFull(rec)
                        } label: {
                            HStack(spacing: 3) {
                                Text(l10n.s.favoritesLocateInFull)
                                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DSLight.gold)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .background(flashKey == rec.key ? DSLight.goldG : DSLight.sf,
                        in: RoundedRectangle(cornerRadius: 10))
            .animation(.easeOut(duration: 0.5), value: flashKey)
            .overlay(alignment: .top) {
                if confirmingDeleteKey == rec.key {
                    deleteConfirm(rec)
                }
            }
        }
    }

    private func cardTimestamp(_ rec: FavoriteRecord, msg: Message?) -> String {
        let date = msg?.timestamp ?? rec.favoritedAt
        let f = DateFormatter()
        f.locale = Locale(identifier: l10n.isZh ? "zh_CN" : "en_US")
        f.dateFormat = l10n.isZh ? "M 月 d 日 HH:mm" : "MMM d, HH:mm"
        return f.string(from: date)
    }

    private func roleLabel(_ rec: FavoriteRecord, msg: Message?) -> String {
        let role = msg?.role.rawValue ?? rec.role
        if role == "user" { return l10n.s.favoritesRoleUser }
        return lite?.source.displayName(isZh: l10n.isZh) ?? role
    }

    // MARK: 卡片菜单

    private func cardMenu(_ rec: FavoriteRecord) -> some View {
        Menu {
            Button(l10n.s.favoritesCopyMessage) { copyMessage(rec, withContext: false) }
            Button(l10n.s.favoritesCopyWithContext) { copyMessage(rec, withContext: true) }
            if conversation != nil {
                Button(l10n.s.favoritesLocateInFull) { locateInFull(rec) }
            }
            Button(l10n.s.starRemoveHelp) { unstarWithUndo(rec) }
            Divider()
            Button(role: .destructive) {
                confirmingDeleteKey = rec.key
            } label: {
                Text(l10n.s.favoritesDeleteMessage)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13)).foregroundStyle(DSLight.t3)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(l10n.s.favoritesMoreHelp)
    }

    private func copyMessage(_ rec: FavoriteRecord, withContext: Bool) {
        var text = message(for: rec).map { Segmenter.plainTextForSearch(of: $0) }
            ?? rec.contentSnapshot
        if withContext, let msg = message(for: rec), let ctx = contextTriple(around: msg) {
            var parts: [String] = []
            if let prev = ctx.prev { parts.append(Segmenter.plainTextForSearch(of: prev)) }
            parts.append(Segmenter.plainTextForSearch(of: msg))
            if let next = ctx.next { parts.append(Segmenter.plainTextForSearch(of: next)) }
            text = parts.joined(separator: "\n\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 删除确认:靠近卡片的小浮层,不用居中大弹窗。
    private func deleteConfirm(_ rec: FavoriteRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.s.favoritesDeleteTitle)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DSLight.t1)
            Text(l10n.s.favoritesDeleteBody)
                .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l10n.s.cancel) { confirmingDeleteKey = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(DSLight.t2)
                Button {
                    confirmingDeleteKey = nil
                    deleteWithUndo(rec)
                } label: {
                    Text(l10n.s.favoritesDeleteConfirm)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DSLight.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(DSLight.bg, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .offset(y: 34)
        .zIndex(10)
    }

    // MARK: 取消/删除 + 撤销 Toast

    private func unstarWithUndo(_ rec: FavoriteRecord) {
        stars.unstar(rec.key)
        if expandedKey == rec.key { expandedKey = nil }
        showToast(l10n.s.favoritesUnstarredToast) { stars.restore(rec.key) }
    }

    private func deleteWithUndo(_ rec: FavoriteRecord) {
        stars.unstar(rec.key)   // 先软删,撤销期内可恢复;窗口关闭时真删
        showToast(l10n.s.favoritesDeletedToast) { stars.restore(rec.key) }
        let key = rec.key
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            // 仍处软删(没被撤销)才真删
            if let r = stars.record(for: key), r.softDeletedAt != nil { stars.purge(key) }
        }
    }

    private func showToast(_ text: String, undo: @escaping () -> Void) {
        toastDismiss?.cancel()
        toast = (text, undo)
        let work = DispatchWorkItem { withAnimation { toast = nil } }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: work)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            HStack(spacing: 14) {
                Text(toast.text).font(.system(size: 12)).foregroundStyle(DSLight.t1)
                Button {
                    toast.undo()
                    withAnimation { self.toast = nil }
                } label: {
                    Text(l10n.s.favoritesUndo)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DSLight.gold)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(DSLight.bg, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
            .padding(.bottom, 18)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: 上下文

    private struct ContextTriple {
        let prev: Message?
        let skippedBefore: Int
        let next: Message?
        let skippedAfter: Int
    }

    /// 语义轮次取上下文:往前找最近一条 user;往后找下一条**有文字**的 assistant;
    /// 中间被跳过的工具/空消息折叠成计数。
    private func contextTriple(around msg: Message) -> ContextTriple? {
        guard let msgs = conversation?.messages,
              let idx = msgs.firstIndex(where: { $0.id == msg.id }) else { return nil }
        var prev: Message? = nil
        var skippedBefore = 0
        var i = idx - 1
        while i >= 0 {
            if msgs[i].role == .user { prev = msgs[i]; break }
            skippedBefore += 1
            i -= 1
        }
        var next: Message? = nil
        var skippedAfter = 0
        var j = idx + 1
        while j < msgs.count {
            let m = msgs[j]
            if m.role == .assistant, m.firstTextBlock != nil { next = m; break }
            skippedAfter += 1
            j += 1
        }
        if prev == nil && next == nil { return nil }
        return ContextTriple(prev: prev, skippedBefore: skippedBefore,
                             next: next, skippedAfter: skippedAfter)
    }

    @ViewBuilder
    private func contextExpansion(around msg: Message) -> some View {
        if let ctx = contextTriple(around: msg) {
            VStack(alignment: .leading, spacing: 0) {
                if let prev = ctx.prev {
                    contextBlock(title: l10n.s.favoritesCtxPrev, message: prev, isCurrent: false)
                    if ctx.skippedBefore > 0 { skippedLine(ctx.skippedBefore) }
                    Rectangle().fill(DSLight.rule).frame(height: 1)
                }
                contextBlock(title: l10n.s.favoritesCtxCurrent, message: msg, isCurrent: true)
                if let next = ctx.next {
                    Rectangle().fill(DSLight.rule).frame(height: 1)
                    if ctx.skippedAfter > 0 { skippedLine(ctx.skippedAfter) }
                    contextBlock(title: l10n.s.favoritesCtxNext, message: next, isCurrent: false)
                }
            }
            .background(DSLight.sf2.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        } else {
            Text(l10n.s.favoritesCtxStart)
                .font(.system(size: 11)).foregroundStyle(DSLight.t3)
        }
    }

    private func contextBlock(title: String, message: Message, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(DSLight.t3)
            Text(Segmenter.plainTextForSearch(of: message).prefix(400) + "")
                .font(.system(size: 12.5)).foregroundStyle(DSLight.t1)
                .lineLimit(6)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(DSLight.gold).frame(width: 2.5)
            }
        }
        .background(isCurrent ? DSLight.goldG.opacity(0.6) : .clear)
    }

    private func skippedLine(_ n: Int) -> some View {
        Text(l10n.s.favoritesCtxSkipped(n))
            .font(.system(size: 11)).foregroundStyle(DSLight.t3)
            .padding(.horizontal, 13).padding(.vertical, 6)
    }

    // MARK: 完整对话模式

    /// 「定位到原对话」:先切完整对话 Tab 并定位（——不立即离开收藏模块）。
    private func locateInFull(_ rec: FavoriteRecord) {
        if let i = orderedFavorites.firstIndex(where: { $0.key == rec.key }) {
            focusIndex = i
        }
        mode = .full
    }

    private var fullConversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let conv = conversation {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(conv.messages) { msg in
                            fullRow(msg)
                                .id(msg.id)
                        }
                    }
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                } else {
                    Text(loadFailed ? l10n.s.favoritesOriginalUnavailable : "…")
                        .font(.system(size: 13)).foregroundStyle(DSLight.t3)
                        .padding(.top, 60)
                }
            }
            .onChange(of: focusIndex) { _ in scrollToFocus(proxy) }
            .onChange(of: mode == .full) { isFull in
                if isFull { DispatchQueue.main.async { scrollToFocus(proxy) } }
            }
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard focusIndex < orderedFavorites.count else { return }
        let target = orderedFavorites[focusIndex].messageID
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    /// 完整对话里的一行:收藏消息带常驻标识,当前定位的强高亮。
    /// 只读回看——不给选择圈(onToggleSelect=nil)、不给收藏 starKey(避免与
    /// 定位高亮打架;收藏管理在「收藏内容」Tab 做)。
    private func fullRow(_ msg: Message) -> some View {
        let key = StarredMessagesStore.key(conversationID: conversationID, messageID: msg.id)
        let isFav = stars.isStarred(key)
        let isFocus = isFav && orderedFavorites.indices.contains(focusIndex)
            && orderedFavorites[focusIndex].messageID == msg.id
        return MessageBubbleView(message: msg)
            .padding(.leading, isFocus ? 8 : 0)
            .overlay(alignment: .topTrailing) {
                if isFav {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10)).foregroundStyle(DSLight.gold)
                        .padding(.top, 18).padding(.trailing, 6)
                }
            }
            .background(isFocus ? DSLight.goldG.opacity(0.7)
                        : (isFav ? DSLight.goldG.opacity(0.25) : .clear),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if isFocus { RoundedRectangle(cornerRadius: 2).fill(DSLight.gold).frame(width: 3) }
            }
            .animation(.easeOut(duration: 0.4), value: focusIndex)
    }

    // MARK: 打开原对话

    private func openOriginal() {
        // 定位:优先当前收藏序号对应的消息
        if orderedFavorites.indices.contains(focusIndex) {
            store.pendingLocateMessageID = orderedFavorites[focusIndex].messageID
        } else if let first = orderedFavorites.first {
            store.pendingLocateMessageID = first.messageID
        }
        store.favoritesSelected = false
        store.selectedConversationId = conversationID
    }
}
