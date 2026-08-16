import SwiftUI
import MindBusCore

/// 收藏模块根视图:首页(对话聚合)⇄ 详情页(收藏内容/完整对话)的内部路由。
/// 规格(2026-08-11 用户定稿):收藏对象是单条原始消息,首页按对话聚合;
/// 不做 AI 摘要/标签/笔记——那些是 Minds 的地盘。
struct FavoritesRootView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject private var stars = StarredMessagesStore.shared

    /// 内部路由:nil = 首页;非 nil = 该会话的详情页。
    @State private var detailConversationID: String? = nil
    /// 进详情时要定位的收藏(来自「最近收藏」点击)。
    @State private var focusFavoriteKey: String? = nil

    var body: some View {
        Group {
            if let convID = detailConversationID {
                FavoriteDetailView(store: store, conversationID: convID,
                                   focusFavoriteKey: focusFavoriteKey,
                                   onBack: {
                                       detailConversationID = nil
                                       focusFavoriteKey = nil
                                   })
            } else {
                FavoritesHomeView(store: store) { convID, favKey in
                    focusFavoriteKey = favKey
                    detailConversationID = convID
                }
            }
        }
        .background(DSLight.bg)
    }
}

// MARK: - 首页

/// 收藏首页:中栏对话聚合列表 + 右栏最近收藏,各自独立滚动(规格 §6)。
struct FavoritesHomeView: View {
    @ObservedObject var store: ConversationStore
    /// 打开详情(convID, 可选的定位收藏 key)。
    var onOpen: (String, String?) -> Void

    @ObservedObject private var stars = StarredMessagesStore.shared
    @ObservedObject private var l10n = L10n.shared

    @State private var searchQuery = ""
    @State private var debouncedQuery = ""
    @State private var searchDebounce: Task<Void, Never>? = nil
    @State private var projectFilter: String? = nil     // nil = 全部项目(键=文件夹色键)
    @State private var sortMode: SortMode = .recentFavorite
    @State private var showAllRecent = false            // 右栏「查看全部收藏」态

    enum SortMode: CaseIterable {
        case recentFavorite, conversationUpdated, mostFavorites, title
    }

    var body: some View {
        if stars.summaries().isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                conversationColumn
                    .frame(width: 415)
                Rectangle().fill(DSLight.rule).frame(width: 1)
                recentColumn
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 数据

    /// 聚合行 = summary + 会话元数据(标题/项目/来源)。
    private struct Row: Identifiable {
        var id: String { summary.conversationID }
        let summary: FavoriteConversationSummary
        let lite: ConversationLite?
        var folderKey: String {
            guard let lite else { return "" }
            return FolderAliasStore.shared.resolve(
                FolderColorAssigner.colorKey(cwd: lite.cwd, sourceRawValue: lite.source.rawValue))
        }
    }

    private var rows: [Row] {
        let liteByID = Dictionary(uniqueKeysWithValues: store.allConversations.map { ($0.id, $0) })
        var out = stars.summaries().map { Row(summary: $0, lite: liteByID[$0.conversationID]) }
        // 项目筛选
        if let filter = projectFilter {
            out = out.filter { $0.folderKey == filter }
        }
        // 搜索(聚合口径:标题/项目/快照命中都算该会话命中,规格 §6.3)
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter { row in
                let title = row.lite?.title ?? ""
                let preview = row.lite?.preview ?? ""
                return title.localizedCaseInsensitiveContains(q)
                    || preview.localizedCaseInsensitiveContains(q)
                    || row.folderKey.localizedCaseInsensitiveContains(q)
                    || stars.activeRecords(conversationID: row.summary.conversationID)
                        .contains { $0.contentSnapshot.localizedCaseInsensitiveContains(q) }
            }
        }
        // 排序
        switch sortMode {
        case .recentFavorite:
            out.sort { $0.summary.lastFavoriteAt > $1.summary.lastFavoriteAt }
        case .conversationUpdated:
            out.sort { ($0.lite?.endAt ?? .distantPast) > ($1.lite?.endAt ?? .distantPast) }
        case .mostFavorites:
            out.sort { $0.summary.favoriteCount > $1.summary.favoriteCount }
        case .title:
            out.sort { rowTitle($0).localizedCompare(rowTitle($1)) == .orderedAscending }
        }
        return out
    }

    private func rowTitle(_ row: Row) -> String {
        if let t = row.lite?.title, !t.isEmpty { return t }
        if let p = row.lite?.preview, !p.isEmpty { return p }
        return row.summary.latestPreview
    }

    private var projectOptions: [String] {
        let liteByID = Dictionary(uniqueKeysWithValues: store.allConversations.map { ($0.id, $0) })
        let keys = stars.summaries().compactMap { s -> String? in
            guard let lite = liteByID[s.conversationID] else { return nil }
            return FolderAliasStore.shared.resolve(
                FolderColorAssigner.colorKey(cwd: lite.cwd, sourceRawValue: lite.source.rawValue))
        }
        return Array(Set(keys)).sorted()
    }

    // MARK: 中栏:对话聚合列表

    private var conversationColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部(滚动时固定)
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.s.sidebarFavorites)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DSLight.t1)
                Text(l10n.s.favoritesStats(stars.summaries().count, stars.activeCount))
                    .font(.system(size: 12)).foregroundStyle(DSLight.t3)
            }
            .padding(.horizontal, 20).padding(.top, 20)

            searchField
                .padding(.horizontal, 12).padding(.top, 14)

            HStack(spacing: 8) {
                filterMenu
                sortMenu
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)

            if rows.isEmpty {
                searchEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(rows) { row in
                            conversationCard(row)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13)).foregroundStyle(DSLight.t3)
            TextField(l10n.s.favoritesSearchPlaceholder, text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchQuery.isEmpty {
                Button { searchQuery = ""; debouncedQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(DSLight.t3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: searchQuery) { q in
            // 150ms 防抖(规格 §6.3)
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                debouncedQuery = q
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button(l10n.s.favoritesAllProjects) { projectFilter = nil }
            Divider()
            ForEach(projectOptions, id: \.self) { key in
                Button(key.hasPrefix("source:") ? String(key.dropFirst(7)) : key) {
                    projectFilter = key
                }
            }
        } label: {
            pillLabel(projectFilter.map { $0.hasPrefix("source:") ? String($0.dropFirst(7)) : $0 }
                      ?? l10n.s.favoritesAllProjects)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Button(l10n.s.favoritesSortRecent) { sortMode = .recentFavorite }
            Button(l10n.s.favoritesSortUpdated) { sortMode = .conversationUpdated }
            Button(l10n.s.favoritesSortCount) { sortMode = .mostFavorites }
            Button(l10n.s.favoritesSortTitle) { sortMode = .title }
        } label: {
            pillLabel(sortLabel)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var sortLabel: String {
        switch sortMode {
        case .recentFavorite: return l10n.s.favoritesSortRecent
        case .conversationUpdated: return l10n.s.favoritesSortUpdated
        case .mostFavorites: return l10n.s.favoritesSortCount
        case .title: return l10n.s.favoritesSortTitle
        }
    }

    private func pillLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12)).foregroundStyle(DSLight.t2)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(DSLight.t3)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
    }

    /// 对话聚合卡(规格 §6.5):项目标签+时间 / 标题 / 摘要 / N 条收藏 · 来源。
    /// 不展示原对话的消息总数/时长——那是原对话属性,不是收藏页主信息。
    private func conversationCard(_ row: Row) -> some View {
        Button {
            onOpen(row.summary.conversationID, nil)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let lite = row.lite {
                        folderTag(key: row.folderKey, source: lite.source)
                    }
                    Spacer(minLength: 6)
                    Text(row.summary.lastFavoriteAt.relativeLabel(isZh: l10n.isZh))
                        .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                }
                Text(rowTitle(row))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DSLight.t1)
                    .lineLimit(1)
                Text(matchOrLatestPreview(row))
                    .font(.system(size: 12)).foregroundStyle(DSLight.t3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(favoriteMeta(row))
                    .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                    .padding(.top, 1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 搜索态优先展示命中片段(规格 §6.3),平时展示最近收藏摘要。
    private func matchOrLatestPreview(_ row: Row) -> String {
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            if let hit = stars.activeRecords(conversationID: row.summary.conversationID)
                .first(where: { $0.contentSnapshot.localizedCaseInsensitiveContains(q) }) {
                return hit.contentSnapshot
            }
        }
        return row.summary.latestPreview.isEmpty
            ? (row.lite?.preview ?? "") : row.summary.latestPreview
    }

    private func favoriteMeta(_ row: Row) -> String {
        let q = debouncedQuery.trimmingCharacters(in: .whitespaces)
        var lead = l10n.s.favoritesCardCount(row.summary.favoriteCount)
        if !q.isEmpty {
            let matches = stars.activeRecords(conversationID: row.summary.conversationID)
                .filter { $0.contentSnapshot.localizedCaseInsensitiveContains(q) }.count
            if matches > 0 { lead = l10n.s.favoritesCardMatches(matches) }
        }
        let source = row.lite?.source.displayName(isZh: l10n.isZh) ?? ""
        return source.isEmpty ? lead : "\(lead) · \(source)"
    }

    private func folderTag(key: String, source: ConversationSource) -> some View {
        let pair = FolderTagPalette.pair(for: key, assignments: store.folderColorAssignments)
        let name = key.hasPrefix("source:") ? source.displayName(isZh: l10n.isZh) : key
        return HStack(spacing: 3) {
            Image(systemName: "folder.fill").font(.system(size: 8))
            Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(pair.text)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(pair.bg, in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: 右栏:最近收藏(消息级)

    private var recentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if showAllRecent {
                    Button {
                        showAllRecent = false
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium))
                            Text(l10n.s.favoritesRecentTitle)
                        }
                        .font(.system(size: 13)).foregroundStyle(DSLight.t2)
                    }
                    .buttonStyle(.plain)
                    Text(l10n.s.favoritesAllTitle)
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(DSLight.t1)
                } else {
                    Text(l10n.s.favoritesRecentTitle)
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(DSLight.t1)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(stars.recentFavorites(limit: showAllRecent ? .max : 6)) { rec in
                        recentCard(rec)
                    }
                    if !showAllRecent, stars.activeCount > 6 {
                        Button {
                            showAllRecent = true
                        } label: {
                            Text(l10n.s.favoritesSeeAll)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DSLight.gold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }

    /// 最近收藏卡(规格 §6.6):对话/项目 · 来源 + 时间 / 摘要两行。
    /// 点击 → 详情页定位到该条并短暂高亮。
    private func recentCard(_ rec: FavoriteRecord) -> some View {
        let lite = store.allConversations.first { $0.id == rec.conversationID }
        return Button {
            onOpen(rec.conversationID, rec.key)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(recentCardHead(rec, lite: lite))
                        .font(.system(size: 12)).foregroundStyle(DSLight.t2)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(rec.favoritedAt.relativeLabel(isZh: l10n.isZh))
                        .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                }
                Text(rec.contentSnapshot.isEmpty ? l10n.s.favoritesNoSnapshot : rec.contentSnapshot)
                    .font(.system(size: 13)).foregroundStyle(DSLight.t1)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentCardHead(_ rec: FavoriteRecord, lite: ConversationLite?) -> String {
        guard let lite else { return rec.conversationID.prefix(8) + "…" }
        let key = FolderAliasStore.shared.resolve(
            FolderColorAssigner.colorKey(cwd: lite.cwd, sourceRawValue: lite.source.rawValue))
        let name = key.hasPrefix("source:") ? lite.source.displayName(isZh: l10n.isZh) : key
        return "\(name) · \(lite.source.displayName(isZh: l10n.isZh))"
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(l10n.s.favoritesEmptyTitle)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(DSLight.t1)
            Text(l10n.s.favoritesEmptyBody)
                .font(.system(size: 12)).foregroundStyle(DSLight.t3)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
            Button(l10n.s.favoritesEmptyAction) {
                store.favoritesSelected = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12)).foregroundStyle(DSLight.gold)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Text(l10n.s.favoritesSearchEmptyTitle)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(DSLight.t1)
            Text(l10n.s.favoritesSearchEmptyBody)
                .font(.system(size: 12)).foregroundStyle(DSLight.t3)
                .multilineTextAlignment(.center)
            Button(l10n.s.favoritesClearFilter) {
                searchQuery = ""; debouncedQuery = ""; projectFilter = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 12)).foregroundStyle(DSLight.gold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
