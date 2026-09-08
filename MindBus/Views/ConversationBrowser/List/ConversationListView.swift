import SwiftUI
import MindBusCore

struct ConversationListView: View {
    /// 待确认删除的对话(非 nil 时弹统一确认;rescued 换加重文案)。
    @State private var deleteTarget: ConversationLite? = nil
    @EnvironmentObject var store: ConversationStore
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var progress = ScanProgress.shared
    private let headerH: CGFloat = 40

    /// 扫描进行中（含收尾）：标题旁转小圈
    private var scanActive: Bool {
        switch progress.phase {
        case .planning, .indexing: return true   // 只有真正在往列表里加东西时标题旁才转圈
        default: return false
        }
    }

    // MARK: - 大标题收缩状态

    /// 收缩阈值：向上滚过 40pt 后大标题让位（展开回滚用 0.6 倍迟滞带防边界抖动）。
    private static let collapseThreshold: CGFloat = 40
    @State private var headerCollapsed = false
    /// 首次读到的滚动偏移 = 静止顶部零点。glass / plain 两分支顶部 inset 不同，
    /// 用实测基线代替分支各算一套常数。
    @State private var scrollBaseline: CGFloat? = nil
    /// 哨兵（列表首行）的 preference 是否冒泡成功过。个别系统版本 AppKit-backed List
    /// 行内 preference 可能不传播——从未见过哨兵就永不收缩（降级 = 常驻大标题），绝不误收。
    @State private var sentinelSeen = false

    var body: some View {
        if #available(macOS 26.0, *) {
            glassLensingLayout
        } else {
            plainLayout
        }
    }

    // MARK: - 布局

    /// macOS 26：玻璃 header 固定在顶，对话行从它下面滚过、被实时折射（macOS 原生 lensing）。
    /// 玻璃浮在「有滚动内容」之上才折射得出来；强度比 iOS 克制——Tahoe 玻璃本就如此。
    /// 空态作为列表区的「替换内容」放在同一布局里——header 与底部搜索胶囊保持原位，
    /// 不再整栏切换布局（曾经搜索每敲到 0 结果字符整个中栏闪跳）。
    @available(macOS 26.0, *)
    private var glassLensingLayout: some View {
        listArea
            .background(DSLight.bg)
            // safeAreaInset：同一机制既预留滚动空间又放 header，at-rest 自动夹住第一行（导航栏模式）。
            // 滚动内容仍从 header 下穿过，玻璃 lensing 照常折射。
            .safeAreaInset(edge: .top, spacing: 0) {
                glassTopBar   // 悬浮胶囊（标题 + 筛选），无整条 bar，行从四周滚过
            }
            // 搜索沉底：悬浮玻璃胶囊对话框（iOS 26 风），内容从下面滚过被折射
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SearchBar(bare: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .ignoresSafeArea(.container, edges: .top)   // 去 titlebar safe area，header 贴窗口顶（mirror 设置窗）
    }

    /// 旧系统：普通 header + 列表，无玻璃。空态同样只替换列表区，条条框框不动
    ///（搜索框必须保持可达以便清词——空态多为「搜索无结果」）。
    private var plainLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerContent.frame(height: headerH)
            Divider()
            listArea
            Divider()
            bottomSearch
        }
    }

    /// 中栏内容两态：占位（首扫/真空/无命中/搜索过短/索引失败，由 placeholderKind 分流）/ 列表。
    /// 注意占位判定只看 `filteredConversations.isEmpty`，不看 isLoading——
    /// 「索引空 + 正在首扫」时 placeholderKind 会给出 .scanning，避免空白 + 小转圈假死观感。
    @ViewBuilder
    private var listArea: some View {
        // 实体页头(L1):实体模式时置顶,列表在其下(空态也保留头,退出按钮可达)
        if store.focusedEntity != nil {
            EntityFocusHeader(store: store)
        }
        if store.filteredConversations.isEmpty {
            ListEmptyState(kind: placeholderKind, onClearFilters: clearFilters,
                           suggestions: store.searchQuery.isEmpty ? [] : store.rescueSuggestions(),
                           onSuggest: { store.searchQuery = $0 })
                .onAppear { setHeaderCollapsed(false) }   // 空态无滚动可言，标题回到大字
        } else {
            List(selection: $store.selectedConversationId) { listRows }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(DSLight.bg)
                // ⌫ 删除当前选中的对话(与右键同一确认路径)
                .onDeleteCommand {
                    if let id = store.selectedConversationId,
                       let conv = store.filteredConversations.first(where: { $0.id == id }) {
                        deleteTarget = conv
                    }
                }
                // 统一删除确认:普通对话标准文案;救回会话(源已灭失,归档是唯一
                // 副本)换加重文案+「永久删除」——最后一份的消失必须被清楚告知。
                .alert(
                    store.rescuedIDs.contains(deleteTarget?.id ?? "")
                        ? l10n.s.deleteConvRescuedTitle : l10n.s.deleteConvTitle,
                    isPresented: Binding(get: { deleteTarget != nil },
                                         set: { if !$0 { deleteTarget = nil } })
                ) {
                    Button(store.rescuedIDs.contains(deleteTarget?.id ?? "")
                               ? l10n.s.deleteRescuedConfirm : l10n.s.deleteConfirm,
                           role: .destructive) {
                        if let conv = deleteTarget { store.deleteConversation(id: conv.id) }
                        deleteTarget = nil
                    }
                    Button(l10n.s.deleteCancel, role: .cancel) { deleteTarget = nil }
                } message: {
                    Text(store.rescuedIDs.contains(deleteTarget?.id ?? "")
                             ? l10n.s.deleteConvRescuedBody : l10n.s.deleteConvBody)
                }
                .background {
                    // 容器探针：与首行哨兵作 global minY 差值 = 已滚距离。
                    // 差值法免疫窗口移动，也不赌 named coordinateSpace 在
                    // AppKit-backed List 行内的解析（macOS 13 起表现不一）。
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ListScrollProbeKey.self,
                            value: ListScrollProbe(containerMinY: g.frame(in: .global).minY))
                    }
                }
                .onPreferenceChange(ListScrollProbeKey.self) { handleScrollProbe($0) }
        }
    }

    // MARK: - 大标题收缩判定

    /// 哨兵 = 列表首行：可见时按「容器顶 − 首行顶」对基线比较阈值；
    /// 被 List 回收（nil 但出现过）说明必然已滚远 → 直接收缩；
    /// 整个 List 不在（空态分支）时交给空态 onAppear 复位，这里不动。
    private func handleScrollProbe(_ probe: ListScrollProbe) {
        guard let c = probe.containerMinY else { return }
        guard let s = probe.sentinelMinY else {
            if sentinelSeen { setHeaderCollapsed(true) }
            return
        }
        sentinelSeen = true
        let offset = c - s                     // 向上滚动为正
        let baseline: CGFloat
        if let b = scrollBaseline {
            baseline = b
        } else {
            scrollBaseline = offset            // 首读即静止顶部 = 零点；
            baseline = offset                  // 只设一次，顶部 rubber-band 过冲不会污染
        }
        let travelled = offset - baseline
        let shouldCollapse = headerCollapsed
            ? travelled > Self.collapseThreshold * 0.6   // 已收缩：回到 24pt 内才展开
            : travelled > Self.collapseThreshold         // 未收缩：过 40pt 才收
        setHeaderCollapsed(shouldCollapse)
    }

    private func setHeaderCollapsed(_ collapsed: Bool) {
        guard collapsed != headerCollapsed else { return }
        // 只动 opacity / scale：两态标题交叉淡变，header 高度恒定，不打断滚动。
        withAnimation(.easeOut(duration: 0.22)) { headerCollapsed = collapsed }
    }

    // MARK: - 行 / header / 空态

    @ViewBuilder
    /// `.tag` 是 ↑↓ 能工作的关键：List 靠它把行与 selection binding 关联起来。
    /// 此前只有 onTapGesture，行既不可聚焦也没有选中语义，方向键完全无效
    /// —— 对一个「浏览器」类产品，翻列表是最高频动作，却只能靠鼠标。
    private var listRows: some View {
        ForEach(store.filteredConversations) { conv in
            ConversationListRow(
                conversation: conv,
                isSelected: conv.id == store.selectedConversationId,
                highlightQuery: store.highlightQuery,
                // 行与行之间才有细线：末行不画（自绘分隔线，系统 separator 保持 hidden）
                showsSeparator: conv.id != store.filteredConversations.last?.id,
                folderColors: store.folderColorAssignments,
                onFolderRenamed: { store.setAll(store.allConversations) },
                refCount: store.refCounts[conv.id] ?? 0,
                rescued: store.rescuedIDs.contains(conv.id),
                onDelete: { deleteTarget = conv }
            )
            .tag(conv.id)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            // 抹掉系统选中高亮：选中态由行内 rowStateBackground 自绘（金调玻璃）。
            // listRowBackground(.clear) 只清「非焦点」态；App 真正获焦后（动态 Dock +
            // cooperative activate 修复之后 List 第一次拿到键盘焦点）NSTableView 会
            // 直接绘制 accent 蓝色整行填充——必须把宿主表格的 selectionHighlightStyle
            // 关掉（探针实现），选中视觉完全交给自绘。selection 绑定与键盘导航不受影响。
            .listRowBackground(SelectionHighlightKiller())
            .contentShape(Rectangle())
            .background {
                // 滚动哨兵：挂在首行背面（零视觉痕迹）。首行滚出可视区被 List 回收时
                // preference 随之消失——handleScrollProbe 把「哨兵失踪」直接判为已滚远。
                if conv.id == store.filteredConversations.first?.id {
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ListScrollProbeKey.self,
                            value: ListScrollProbe(sentinelMinY: g.frame(in: .global).minY))
                    }
                }
            }
        }
    }

    /// 时间筛选菜单：label 由调用处给（玻璃圆钮 / 实底圆钮）。
    /// 注意：glassEffect 必须放在 label **内部**——包在 Menu 外层会吞掉点击。
    private func filterMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            ForEach(TimeFilter.allCases, id: \.self) { f in
                Button(timeFilterLabel(f)) { store.timeFilter = f }
            }
        } label: { label() }
        .menuStyle(.button)        // 单击即开（borderlessButton 老 API 在自定义 label 下点击行为不稳）
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(l10n.s.filterByTime)   // 纯 icon 控件，VoiceOver 需要文字名
    }

    /// TimeFilter 的展示名（Core 无 UI 依赖，映射放视图层）。
    private func timeFilterLabel(_ f: TimeFilter) -> String {
        switch f {
        case .today: return l10n.s.timeToday
        case .thisWeek: return l10n.s.timeThisWeek
        case .thisMonth: return l10n.s.timeThisMonth
        case .all: return l10n.s.filterAll
        }
    }

    /// 纯 icon：筛选非「全部」时变 gold 提示激活态（icon-only 后唯一的状态线索）。
    private var filterIcon: some View {
        Image(systemName: "clock")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(store.timeFilter == .all ? DSLight.t2 : DSLight.gold)
    }

    /// macOS 26 顶部：标题裸文字居中（无胶囊底）+ 筛选玻璃圆钮贴右。
    /// 背景轻微模糊渐隐（header 实区 + 34px 尾巴）；尾巴**计入预留高度**——
    /// 滚到顶静止时第一行在尾巴之下完全清晰，继续滚动才进入模糊区（参考 ChatGPT Chats 顶部）。
    @available(macOS 26.0, *)
    private var glassTopBar: some View {
        ZStack {
            HStack(spacing: 4) {
                ListHeaderTitle(count: store.filteredConversations.count,
                                total: store.allConversations.count,
                                collapsed: headerCollapsed)
                if store.isLoading || scanActive {
                    ProgressView().controlSize(.small)
                }
            }

            HStack {
                Spacer()
                ZStack {
                    // 玻璃圆底：放在 Menu 下层（Menu label 会被压平渲染、内部 glass 不显示；
                    // 包在 Menu 外层又会吞点击——所以玻璃做底、菜单浮顶，两全）。
                    Color.clear
                        .frame(width: 34, height: 34)
                        .glassEffect(.regular, in: Circle())
                        .allowsHitTesting(false)
                    filterMenu {
                        filterIcon
                            .frame(width: 44, height: 44)      // 热区 44×44（苹果最小点击目标）
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .padding(.leading, store.sidebarCollapsed ? 124 : 12)   // 折叠时让出红绿灯 + 窗口级折叠钮
        .padding(.trailing, 12)
        .animation(.easeOut(duration: 0.2), value: store.sidebarCollapsed)
        .frame(height: headerH + 12)   // 整个渐隐顶区（含尾巴），内容上下居中
        .frame(maxWidth: .infinity)
        .background {
            // 渐隐不糊字：半透明背景（无磨砂）——顶部文字透出 78% 暖白，变淡但字形完全清晰，向下渐变到无
            LinearGradient(
                stops: [.init(color: DSLight.bg.opacity(0.78), location: 0),
                        .init(color: DSLight.bg.opacity(0.78), location: 0.8),
                        .init(color: DSLight.bg.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .windowDragArea()   // 列表顶部 = 拖动带（筛选钮是控件，优先于手势）
    }

    /// 旧系统顶部导航条（实底 bar）：标题居中，筛选贴右。
    private var headerContent: some View {
        ZStack {
            HStack(spacing: 4) {
                ListHeaderTitle(count: store.filteredConversations.count,
                                total: store.allConversations.count,
                                collapsed: headerCollapsed)
                if store.isLoading || scanActive {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Spacer()
                filterMenu {
                    filterIcon
                        .frame(width: 28, height: 28)
                        .background(DSLight.sf2, in: Circle())
                        .frame(width: 40, height: 40)          // 热区外扩
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .windowDragArea()
    }

    /// 旧系统底部搜索条（实底）。
    private var bottomSearch: some View {
        SearchBar()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    /// 判定顺序：出错 > 搜索词过短 > 首扫中 > 库里真没对话 > 被筛掉了。
    /// 前两项必须排在「没有对话 / 没有匹配」之前，否则会用「你没有」
    /// 掩盖掉「读不到」和「搜不了」两种完全不同的情况。
    private var placeholderKind: ListPlaceholderKind {
        if store.loadError != nil {
            return .failed(title: l10n.s.indexErrorTitle, detail: l10n.s.indexErrorDetail)
        }
        if store.allConversations.isEmpty {
            return store.isLoading ? .scanning : .noConversations
        }
        return .noMatch(hint: activeFilterHint)
    }

    /// 说清是什么把结果筛没了——用户常常忘了自己还开着筛选。
    private var activeFilterHint: String {
        var conditions: [String] = []
        if !store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            conditions.append(l10n.s.searchFilterHint(store.searchQuery))
        }
        if store.timeFilter != .all { conditions.append(timeFilterLabel(store.timeFilter)) }
        if let s = store.focusedSource { conditions.append(s.displayName(isZh: l10n.isZh)) }
        return conditions.isEmpty ? l10n.s.adjustFiltersHint : conditions.joined(separator: " · ")
    }

    private func clearFilters() {
        store.searchQuery = ""
        store.timeFilter = .all
        store.focusedSource = nil
    }
}

// MARK: - 列表 header 标题（两态）

/// 未滚动 = 20px 大标题（此刻它就是这一屏的主信息），滚过阈值 = 12px 小标题（让位内容）。
/// 双 Text 交叉淡变 + 轻缩放：各自按原生字号渲染（避免单 Text 光栅缩放糊字）；
/// ZStack 尺寸恒为大标题所需，两态切换不改变 header 布局，因此不打断滚动。
/// internal 而非 private：PreviewRenderer 需要离屏渲染两态校验视觉。
struct ListHeaderTitle: View {
    let count: Int
    /// 全库总数：扫描中标题显示「正在收集 · 已找到 N 场」用它，不受筛选影响
    var total: Int? = nil
    let collapsed: Bool
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var progress = ScanProgress.shared

    /// 扫描中用「数得出来的东西」说进度：Photos「正在导入 N 项」同款——
    /// 用户理解的是找到了多少，不是处理了多少 MB（进度条方案被否）。
    private var title: String {
        switch progress.phase {
        case .planning, .indexing: return l10n.s.scanCollecting(total ?? count)
        // 归档 / 画像 / 收尾是后台活动：库已可用，标题照常报数，进度与预计时间在侧栏底部状态行
        case .archiving, .profiling, .finishing, .idle, .done: return l10n.s.conversationCountTitle(count)
        }
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DSLight.t1)
                .opacity(collapsed ? 0 : 1)
                .scaleEffect(collapsed ? 0.75 : 1)
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DSLight.t1)
                .opacity(collapsed ? 1 : 0)
                .scaleEffect(collapsed ? 1 : 1.3)
        }
        .animation(.easeOut(duration: 0.25), value: title)
        .accessibilityElement(children: .ignore)   // 两个 Text 同文案，VoiceOver 只播一次
        .accessibilityLabel(title)
    }
}

// MARK: - 滚动探针

/// 压掉 NSTableView 焦点态的系统蓝色选中绘制。
/// SwiftUI 未暴露 selectionHighlightStyle；作为 listRowBackground 挂进行视图后，
/// 向上遍历找到宿主 NSTableView 关掉高亮——一次设置对整表持久生效，
/// 找不到宿主时静默（最坏退回系统蓝，不崩）。selection 绑定与键盘导航不受影响。
private struct SelectionHighlightKiller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            var cursor: NSView? = v?.superview
            while let cur = cursor, !(cur is NSTableView) { cursor = cur.superview }
            (cursor as? NSTableView)?.selectionHighlightStyle = .none
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// List 容器与列表首行的 global minY。两者差值 = 已滚距离——
/// 差值法免疫窗口移动/尺寸变化，也不依赖 named coordinateSpace 在
/// AppKit-backed List 行内的解析行为（macOS 13 起各版本表现不一）。
private struct ListScrollProbe: Equatable {
    var containerMinY: CGFloat? = nil
    var sentinelMinY: CGFloat? = nil
}

private struct ListScrollProbeKey: PreferenceKey {
    static let defaultValue = ListScrollProbe()
    static func reduce(value: inout ListScrollProbe, nextValue: () -> ListScrollProbe) {
        let n = nextValue()
        if let c = n.containerMinY { value.containerMinY = c }
        if let s = n.sentinelMinY { value.sentinelMinY = s }
    }
}
