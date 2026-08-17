import Foundation
import Combine

public enum TimeFilter: String, CaseIterable, Equatable {
    case today
    case thisWeek
    case thisMonth
    case all

    // 展示名不在 Core：由视图层用 L10n Strings 映射（timeToday / timeThisWeek / …），
    // Core 保持无 UI、无语言依赖。

    public func matches(_ date: Date, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        switch self {
        case .today: return cal.isDate(date, inSameDayAs: now)
        case .thisWeek:
            return cal.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .thisMonth:
            return cal.isDate(date, equalTo: now, toGranularity: .month)
        case .all: return true
        }
    }
}

@MainActor
public final class ConversationStore: ObservableObject {
    @Published public private(set) var allConversations: [ConversationLite] = []
    @Published public private(set) var filteredConversations: [ConversationLite] = []
    @Published public var selectedConversationId: String? = nil {
        didSet { loadDetailIfNeeded() }
    }
    @Published public private(set) var selectedDetail: Conversation? = nil
    @Published public private(set) var isLoadingDetail: Bool = false
    /// 详情 parse 失败（源文件被移动/删除后索引仍有行）：DetailView 据此显示失败态，
    /// 而不是退回「从左侧选择一个对话」占位——明明点了一条，界面却让他去选一条。
    @Published public private(set) var detailLoadFailed: Bool = false
    @Published public var timeFilter: TimeFilter = .all {
        didSet { applyFilters() }
    }
    /// 浏览器只展示这 3 个工具——聚焦器与「全部」都限定于此。
    public static let browsableSources: [ConversationSource] = [.claudeCode, .claudeAgent, .codex]

    /// 探测到「用过」的工具（数据目录有会话文件），侧栏/引导以此为准——
    /// 没装或没用过的产品不出现（用户定案）。初值 = 全集，后台探测完成后
    /// 收敛（避免首帧闪空）；每轮 refresh 重探，中途开始用新工具下一轮就出现。
    @Published public private(set) var availableSources: [ConversationSource] = ConversationStore.browsableSources

    /// nil =「全部」（仅含 browsableSources）；非 nil = 只看该工具。
    @Published public var focusedSource: ConversationSource? = nil {
        didSet { applyFilters() }
    }
    @Published public var searchQuery: String = "" {
        didSet {
            // 与实体页互斥:开始打字即退出实体模式(两个过滤维度不叠加)
            if !searchQuery.isEmpty, focusedEntity != nil { focusedEntity = nil }
            // 防抖：搜索框是逐字符 binding，不节流的话打 5 个字就是 5 次
            // 完整搜索链路（FTS 扫描 + 全量 applyFilters）。
            searchDebounce?.cancel()
            let token = UUID(); searchToken = token
            searchDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                await self?.runSearch(token: token)
            }
        }
    }
    private var searchDebounce: Task<Void, Never>?

    /// 与搜索结果同拍的命中高亮词：runSearch 落定时更新（不跟随逐字符输入），
    /// 列表/详情的金色标注与「哪些行被召回」永远一致——防抖窗内不闪半拍高亮。
    /// 空 = 无高亮；清词后随下一次 runSearch 自动清空，消息级定位随之失效。
    @Published public private(set) var highlightQuery: String = ""

    @Published public private(set) var isLoading: Bool = false

    /// 加载失败原因。此前全 App 零错误 UI：索引损坏、磁盘满、目录无权限，
    /// 一律表现为「还没有找到对话」——与「你确实没有对话」完全无法区分。
    @Published public private(set) var loadError: LoadError? = nil

    public enum LoadError: Equatable {
        case indexUnavailable
        // 文案不在 Core：视图层用 L10n Strings 的 indexErrorTitle / indexErrorDetail。
    }

    /// 搜索词过短（trigram 索引最小 3 字符）。用于把「搜不到」和「搜不了」分开。

    /// 侧栏折叠状态（自绘折叠钮共享：侧栏内收起 / 列表 header 展开）。
    /// 持久化：习惯收起侧栏的用户不该每次重启都重新收一次。
    @Published public var sidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: kSidebarCollapsed) {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Self.kSidebarCollapsed) }
    }
    private static let kSidebarCollapsed = "browser.sidebarCollapsed"

    /// 侧栏 Minds 模块选中：true = 主区整体换成 Minds 缺省页。与工作空间聚焦互斥，
    /// 点回任一工具行即清除。不持久化：Minds 还没有内容，重启落回工作空间更合理。
    @Published public var mindsSelected: Bool = false {
        didSet { if mindsSelected { favoritesSelected = false } }
    }

    /// 跨模块消息定位通道:收藏「打开原对话」设置,DetailView 加载完成后消费并清空。
    @Published public var pendingLocateMessageID: String? = nil

    /// 侧栏收藏模块选中(规格 §5:与 Minds 同级、跨项目全局)。与 Minds/工具聚焦互斥。
    @Published public var favoritesSelected: Bool = false {
        didSet { if favoritesSelected { mindsSelected = false } }
    }

    /// 实体导航(L1 实体页):非 nil 时列表只显示提到该实体的会话,顶部长出实体页头
    /// (共现实体可跳)。与全文搜索互斥——设实体清搜索、设搜索清实体,两个过滤维度
    /// 叠加会让「为什么列表是这几条」变得不可解释。
    @Published public var focusedEntity: String? = nil {
        didSet {
            guard focusedEntity != oldValue else { return }
            if focusedEntity != nil {
                searchQuery = ""
                mindsSelected = false
                favoritesSelected = false
            }
            applyFilters()
        }
    }

    /// 实体页数据:与 focusedEntity 共现的实体(顺着找的主力)。
    public func coOccurringEntities() -> [(text: String, count: Int)] {
        guard let entity = focusedEntity else { return [] }
        return index?.coOccurring(with: entity, limit: 12)
            .map { ($0.text, $0.conversationCount) } ?? []
    }

    private var detailLoadToken: UUID? = nil
    private var detailTask: Task<Void, Never>? = nil     // 详情解析任务句柄：新选中先 cancel 旧任务
    private var loadingDetailId: String? = nil           // 正在 parse 的会话 id（防同 id 重复 parse）
    /// 最近看过的详情（LRU，切回零等待）。entry 记着解析时源文件的 mtime：
    /// 命中时 stat 对比，不一致即弃缓存重解析——活跃会话切走再切回不再看到旧快照。
    private var detailCache: [String: (conv: Conversation, mtime: Double?, cost: Int)] = [:]
    private var detailCacheOrder: [String] = []
    private let detailCacheCap = 4
    /// 缓存字节预算(以文本字符量近似):此前只限「4 条」——单场马拉松会话源文件
    /// 519MB,parse 后的对象几十上百 MB,点开一次切走就常驻,App「有时候 100MB」
    /// 的主因(2026-08-13 footprint 取证)。预算制下大会话可进缓存但会把别人挤光,
    /// 超预算的独占一格,切走即成唯一驱逐候选。
    private let detailCacheBudget = 6_000_000   // ≈ 6M 字符 ≈ 18MB 中文文本
    private var searchToken = UUID()
    private var searchMatchIds: Set<String>? = nil   // nil = 无全文查询，不按搜索过滤
    /// id → 相关度名次（0 最相关）。ConversationIndex.search 现在返回 BM25 三路 RRF 排序，
    /// 而列表默认按 endAt 倒序 —— 不把名次带过来，排序就在这一层被丢掉了。
    private var searchRank: [String: Int] = [:]
    private let indexPath: String

    /// `~/Library/Application Support/MindBus/index.sqlite`；测试进程改用临时路径。
    ///
    /// 事故记录（一）：曾有测试链路触发 ConversationIndex.shared → 在**生产库**上跑了
    /// 数据政策迁移（清库+写版本号），随后旧版 App 按旧政策把数据扫回——新版启动
    /// 看到版本号已就位便跳过迁移，新政策永远没机会清场。测试进程一律隔离。
    ///
    /// 事故记录（二）：上述隔离只查 `XCTestConfigurationFilePath`，而那是 **Xcode**
    /// 测试运行器才注入的变量；命令行 `swift test` 根本不设它，于是隔离整体失效，
    /// 又一次在生产库上跑了迁移（v7→v8 清库）。现改为同时探测 XCTest 运行时是否
    /// 已加载 —— 这个信号对 Xcode 与 SwiftPM 两条链路都成立，且不依赖任何约定。
    public nonisolated static func isRunningTests() -> Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains { $0.hasSuffix(".xctest") }
    }

    /// `creatingDirectory`：GUI 侧读写打开索引前必须确保目录存在，默认 `true` 保持原行为
    /// 一字不变、所有既有调用点不用改。MCP 只读进程传 `false`——一个自称只读的进程不该有
    /// "建目录"这个副作用（`~/Library/Application Support/MindBus/` 平白多出来一个空目录）。
    public nonisolated static func defaultIndexPath(creatingDirectory: Bool = true) -> String {
        if isRunningTests() {
            return NSTemporaryDirectory() + "mindbus-test-index.sqlite"
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MindBus", isDirectory: true)
        if creatingDirectory {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent("index.sqlite").path
    }

    /// 走默认路径时复用全局共享连接（避免与启动预热并发双写）；
    /// 传入自定义路径时单独开一个 —— 测试靠这条注入临时库，
    /// 不能为了收敛连接把可测试性一起收掉。
    private let index: ConversationIndex?

    public init(indexPath: String = ConversationStore.defaultIndexPath()) {
        self.indexPath = indexPath
        self.index = indexPath == ConversationStore.defaultIndexPath()
            ? ConversationIndex.shared
            : try? ConversationIndex(path: indexPath)
        refreshAvailableSources()
    }

    /// 文件夹标签的活跃色分配:最近活跃的前 8 个项目保证互不撞色(用户定案),
    /// 其余项目行内走裸哈希回落。列表刷新时重算。
    @Published public private(set) var folderColorAssignments: [String: Int] = [:]

    private func refreshFolderColors() {
        // allConversations 已按 endAt 降序——顺序取前 8 个不同色键即活跃集
        var seen = Set<String>()
        var active: [String] = []
        for lite in allConversations {
            // 键过别名:改名过的项目,新旧两批会话解析成同一个键 → 同色且共占一个活跃位
            let key = FolderAliasStore.shared.resolve(
                FolderColorAssigner.colorKey(cwd: lite.cwd,
                                             sourceRawValue: lite.source.rawValue))
            if seen.insert(key).inserted {
                active.append(key)
                if active.count >= FolderColorAssigner.poolSize { break }
            }
        }
        folderColorAssignments = FolderColorAssigner.resolve(activeKeysInOrder: active)
    }

    /// 已救回集合:源文件被工具清理、仅存于 MindBus 副本的会话 id。
    /// 「工具删它的,你的还在」的强确认——这是产品价值最不可辩驳的证明时刻,
    /// 此前静默发生(详情无感回退),现在列表金盾/详情横幅/SANCTUARY 三处可见。
    @Published public private(set) var rescuedIDs: Set<String> = []
    /// 当前详情是否读自副本(源已删)——DetailView 顶部横幅依据。
    @Published public private(set) var selectedDetailFromArchive: Bool = false

    /// 纯函数可注入(测试):absolute 路径、源不存在、有归档 = 救回。
    nonisolated static func computeRescued(rows: [(id: String, path: String)],
                                           exists: (String) -> Bool,
                                           hasArchive: (String) -> Bool) -> Set<String> {
        Set(rows.filter { $0.path.hasPrefix("/") && !exists($0.path) && hasArchive($0.path) }
            .map(\.id))
    }

    public func refreshRescued() {
        let rows = allConversations.map { (id: $0.id, path: $0.fileURL.path) }
        rescuedIDs = Self.computeRescued(
            rows: rows,
            exists: { FileManager.default.fileExists(atPath: $0) },
            hasArchive: { VaultArchive.hasArchive(sourcePath: $0) })
    }

    /// 引用徽章数据:conv_id → 被 agent 读取次数。扫描收尾后刷新;量级极小整表缓存。
    /// 「被 Claude Code 引用过 N 次」是中枢价值可见化的第一块(spec §3.6)。
    @Published public private(set) var refCounts: [String: Int] = [:]

    public func refreshRefCounts() {
        refCounts = index?.allRefCounts() ?? [:]
    }

    /// 活跃热力图数据:近 365 天每日会话数(本机时区)。Minds 页展示时拉取。
    public nonisolated func dailyHeat() -> [(day: String, count: Int)] {
        index?.dailyCounts(days: 365, now: Date()) ?? []
    }

    /// 按 id 批量取结束时间——马拉松对话行右侧的「最长 YYYY-MM-DD」要用。
    /// md 里只有条数与跨度,没有日期,所以这一项现查索引。
    public nonisolated func conversationEndDates(ids: [String]) -> [String: Date] {
        guard let index, !ids.isEmpty else { return [:] }
        var out: [String: Date] = [:]
        for m in index.metadata(forIDs: ids) { out[m.id] = m.endAt }
        return out
    }

    /// 热力图格子下钻:某天的全部会话(id+标题),点击可打开。
    public func conversationsOn(day: String) -> [(id: String, label: String)] {
        (index?.conversationsOn(day: day) ?? []).map {
            (id: $0.id, label: $0.title?.isEmpty == false ? $0.title! : $0.preview)
        }
    }

    // MARK: - Minds 可视化数据口(图表直查 store,文字行走 minds.md——两层并存)

    public nonisolated func vizHourly24() -> [Int] {
        index?.hourHistogram24() ?? [Int](repeating: 0, count: 24)
    }
    public nonisolated func vizWeekday7() -> [Int] {
        index?.weekdayHistogram() ?? [Int](repeating: 0, count: 7)
    }
    public nonisolated func vizMonthlyFlow() -> [(month: String, count: Int)] {
        (index?.mapOverview().byMonth ?? []).map { (month: $0.key, count: $0.count) }
    }
    public nonisolated func vizShape() -> ConversationIndex.CollaborationShape? {
        index?.collaborationShape()
    }
    public nonisolated func vizVolume() -> (userChars: Int, totalChars: Int) {
        index?.corpusVolume() ?? (0, 0)
    }
    /// FADED 消退曲线:词的近 12 月出现序列(词 ≤5 个,千级文本扫描几十 ms)。
    public nonisolated func vizFadedSeries(words: [String]) -> [String: [Int]] {
        guard let index, !words.isEmpty else { return [:] }
        let corpus = index.userCorpusWithDates()
        var out: [String: [Int]] = [:]
        for w in words {
            out[w] = MindsBuilder.monthlyOccurrences(corpus: corpus, word: w, monthsBack: 12, now: Date())
        }
        return out
    }

    // Minds 单语化:整行陈述节直查数据(GUI 用 L10n 模板渲染,不再显 md 英文行)
    public nonisolated func vizSanctuary() -> ConversationIndex.SanctuaryStats? {
        index?.sanctuaryStats(now: Date())
    }
    public nonisolated func vizVault() -> (files: Int, bytes: Int64) { MindsBuilder.vaultFootprint() }
    public nonisolated func vizBusiest() -> (day: String, count: Int, messages: Int)? {
        index?.busiestDay()
    }
    public nonisolated func vizSwitching() -> (avgPerDay: Double, peak: (day: String, count: Int)?) {
        index?.projectSwitching() ?? (0, nil)
    }
    public nonisolated func vizWeekly() -> [(week: String, count: Int)] { index?.weeklyCounts() ?? [] }
    public nonisolated func vizWeekendSplit() -> (weekday: [ConversationIndex.FacetCount], weekend: [ConversationIndex.FacetCount]) {
        index?.weekendSplit(minCount: 2) ?? ([], [])
    }
    public nonisolated func vizMonth() -> (cur: [ConversationIndex.FacetCount], prev: [ConversationIndex.FacetCount],
                               newEntities: [String], lastYear: Int) {
        guard let index else { return ([], [], [], 0) }
        let now = Date()
        let mStart = MindsBuilder.monthStart(of: now)
        let prevStart = MindsBuilder.monthStart(of: mStart.addingTimeInterval(-1))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM"
        let ly = Calendar.current.date(byAdding: .year, value: -1, to: now)
            .map { index.monthTotal(yearMonth: f.string(from: $0)) } ?? 0
        return (index.sourceCounts(from: mStart, to: now.addingTimeInterval(1)),
                index.sourceCounts(from: prevStart, to: mStart),
                index.newEntities(since: mStart, limit: 8).map(\.text),
                ly)
    }
    public nonisolated func vizLatestNight() -> (thread: ConversationIndex.UnfinishedThread, clock: String)? {
        index?.latestNightConversation()
    }

    public func wrappedSwitchingAvg() -> Double {
        index?.projectSwitching().avgPerDay ?? 0
    }
    public nonisolated func vizEarliest() -> Date? {
        index?.sanctuaryStats(now: Date()).earliest
    }

    /// 项目历次会话(Strava Matched Runs 思路——同一条路线的历史成绩对齐):
    /// 按最近在前,供 PROJECT RHYTHM 行内展开的时间线。
    public func projectConversations(cwd: String) -> [(id: String, label: String, endAt: Date)] {
        guard let index else { return [] }
        let ids = index.conversationIDs(for: .project(cwd), limit: Int.max)
        return index.metadata(forIDs: ids).map {
            (id: $0.id, label: $0.title?.isEmpty == false ? $0.title! : $0.preview, endAt: $0.endAt)
        }.sorted { $0.endAt > $1.endAt }
    }

    /// CLAUDE.md 注入文本(spec §5 闸门):confirmed 条目全量 + 机械紧凑版。
    /// 只做文本组装;写入动作由 GUI 按钮触发(人在环)。
    public func mindsInjectionText() -> String {
        guard let index else { return "" }
        return MindsBuilder.renderForInjection(index: index,
                                               entries: MindsEnrichedLog.entries())
    }

    /// 搜索空结果时的救援建议:全库高频实体,可直接当下一次搜索词。
    /// spec §3.5「空结果救援——不返回空白页,给出切面建议」的 GUI 面;MCP 侧同款已上线。
    public func rescueSuggestions() -> [String] {
        index?.topEntities(limit: 6).map(\.text) ?? []
    }

    /// 后台探测已使用的工具集；变化才发布。聚焦的工具消失时回落「全部」。
    public func refreshAvailableSources() {
        Task.detached(priority: .utility) { [weak self] in
            let detected = SourceDetection.detectAvailable()
            await MainActor.run { [weak self] in
                guard let self else { return }
                let avail = Self.browsableSources.filter(detected.contains)
                guard avail != self.availableSources else { return }
                self.availableSources = avail
                if let f = self.focusedSource, !avail.contains(f) {
                    self.focusedSource = nil
                }
            }
        }
    }

    public func setAll(_ lites: [ConversationLite]) {
        self.allConversations = lites
        refreshRefCounts()   // 列表刷新与徽章数据同步——扫描收尾 ingest 后这里跟着新
        refreshRescued()     // 救回集合同拍刷新(145 行 stat 毫秒级)
        refreshFolderColors()
        applyFilters()
    }

    /// 打开窗口立即出列表：先读现有索引（启动 warm-up 已建好，allMetadata 仅读 SQLite，毫秒级），
    /// 再后台增量扫描 7 源、扫完刷新（新增/变更补进来）。避免列表等全量扫描那几秒空白。
    public func loadAsync() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            guard let index = self.index else {
                // 索引打不开（磁盘满 / 权限 / 文件损坏）。此前这里静默 return，
                // 界面显示「还没有找到对话」—— 和「你确实没有对话」一字不差。
                await MainActor.run {
                    self.isLoading = false
                    self.loadError = .indexUnavailable
                }
                return
            }
            await MainActor.run { self.loadError = nil }
            // 1. 先读现有索引 → 列表立刻显示
            let existing = index.allMetadata()
            await MainActor.run {
                self.setAll(existing)
                if !existing.isEmpty { self.isLoading = false }   // 已有内容就撤掉加载态，后台静默刷新
            }
            // 2. 后台增量扫描 → 扫完刷新
            await LoaderRuntime.indexAllSources(into: index)
            let fresh = index.allMetadata()
            await MainActor.run {
                self.setAll(fresh)
                self.isLoading = false
            }
        }
    }

    /// 增量刷新：窗口重新获得焦点 / 用户手动触发时调用。
    ///
    /// 此前 `loadAsync()` 在整个 App 生命周期只会执行一次 —— 窗口是单例且
    /// `isReleasedWhenClosed = false`，`show()` 发现窗口已存在就直接 return，
    /// 永远走不到那行 `loadAsync()`。于是这个常驻菜单栏、被设计成开机启动
    /// 几周不退出的 App，列表从启动那刻起就是一张冻结的快照：用户当天在
    /// Claude Code 里产生的新对话，不重启 App 一条都看不到。
    /// 开始监听来源目录，有新对话写入就自动刷新。
    ///
    /// 有了它，「App 激活 + 30 秒节流」退化为兜底：文件没变时一次扫描都不跑，
    /// 变了则 2 秒内送达（FSEvents 的 latency 负责合并一次回答产生的大量追加写）。
    public func startWatching() {
        guard watcher == nil else { return }
        let w = VaultWatcher { [weak self] in
            self?.refresh(minInterval: 2)   // 事件已被 FSEvents 合并过，这里只防抖动
        }
        w.start(paths: VaultWatcher.watchedPaths)
        watcher = w
    }

    private var watcher: VaultWatcher?

    /// - Parameter minInterval: 距上次刷新的最小间隔。App 激活会频繁触发
    ///   （每次从别的窗口切回来），不节流会让增量扫描空转。手动刷新传 0 强制执行。
    public func refresh(minInterval: TimeInterval = 30) {
        refreshAvailableSources()
        guard !isLoading else { return }   // 扫描进行中就不叠加（indexAllSources 内部也会合流）
        if minInterval > 0, let last = lastRefreshAt,
           Date().timeIntervalSince(last) < minInterval { return }
        lastRefreshAt = Date()
        loadAsync()
    }

    private var lastRefreshAt: Date?

    /// 异步全文搜索：≥3 字符走 FTS5 三路 BM25 + RRF（自适应查询扩展），<3 走 segments 表 LIKE
    ///（见 ConversationIndex.search）。detached 查 index 避免阻塞主线程；
    /// token 丢弃过期结果，防快速输入乱序。
    func runSearch(token: UUID? = nil) async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // 复用共享连接：此前每敲一个字符都 sqlite3_open + 建表检查 + 三条 pragma，
        // 用完即弃，还要和首次建库的写者争锁。
        // .adaptive：命中充足（≥40 段）时零损失不动结果；命中稀少才做 RM3 扩展
        // 补词汇鸿沟（spec §7.60）——GUI 场景优先保排序不漂移，只在真正搜不到时才扩。
        let ranked: [String]? = q.isEmpty ? nil : await Task.detached(priority: .userInitiated) {
            self.index?.search(q, expansion: .adaptive) ?? []
        }.value
        if let token, token != searchToken { return }   // 已有更新查询，丢弃本次结果
        searchMatchIds = ranked.map(Set.init)
        searchRank = [:]
        for (i, id) in (ranked ?? []).enumerated() { searchRank[id] = i }
        highlightQuery = q   // 与 searchMatchIds 同拍：高亮/定位永远对应当前召回结果
        applyFilters()
    }

    // MARK: - 删除(2026-08-15 用户定案:「从 MindBus 抹除,源文件不动」)

    /// 删除整场对话:索引行 + 归档副本 + 墓碑(防扫描复活)。源文件不碰——
    /// 用户真要彻底销毁,去工具里删源;届时这里已无副本,链路自洽。
    public func deleteConversation(id: String, vaultRoot: URL = VaultArchive.defaultRoot) {
        guard let lite = allConversations.first(where: { $0.id == id }) else { return }
        let path = lite.fileURL.path
        TombstoneStore.shared.buryConversation(id: id, path: path)
        VaultArchive.removeArchive(sourcePath: path, root: vaultRoot)
        index?.prune(missingPaths: [path])
        detailCache[id] = nil
        detailCacheOrder.removeAll { $0 == id }
        if selectedConversationId == id { selectedConversationId = nil }
        allConversations.removeAll { $0.id == id }
        applyFilters()
        refreshRescued()
    }

    /// 删除单条/多条消息:全链路墓碑——详情、检索、语料、Minds 都不再见到。
    /// 全部消息都被删光时升级为删除整场对话。
    public func deleteMessages(conversationID: String, messageIDs: Set<String>) {
        guard !messageIDs.isEmpty else { return }
        guard let lite = allConversations.first(where: { $0.id == conversationID }) else { return }
        TombstoneStore.shared.buryMessages(conversationID: conversationID, messageIDs: messageIDs)
        detailCache[conversationID] = nil
        detailCacheOrder.removeAll { $0 == conversationID }

        // 详情立即重载(装载出口的墓碑过滤生效,被删消息即刻消失)
        if selectedConversationId == conversationID {
            selectedDetail = nil
            loadingDetailId = nil
            loadDetailIfNeeded()
        }

        // 索引重灌(不等下轮扫描):检索/语料立刻干净。重扫幂等——
        // LoaderRuntime 对有消息墓碑的会话同样走过滤重建。
        let fileURL = lite.fileURL
        let source = lite.source
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let conv = LoaderRuntime.fullParse(url: fileURL, source: source) else { return }
            let buried = TombstoneStore.shared.buriedMessages(conversationID: conversationID)
            let kept = conv.messages.filter { !buried.contains($0.id) }
            if kept.isEmpty {
                // 全删光=整场消失
                await MainActor.run { self.deleteConversation(id: conversationID) }
                return
            }
            let filtered = Conversation(id: conv.id, source: conv.source,
                                        startAt: kept.first!.timestamp, endAt: kept.last!.timestamp,
                                        cwd: conv.cwd, gitBranch: conv.gitBranch,
                                        title: conv.title, messages: kept)
            let row = IndexRow.from(filtered, fileURL: fileURL)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)
                .flatMap { $0 }?.timeIntervalSince1970 ?? 0
            _ = try? self.index?.upsert([(row.lite, row.segments, mtime, row.entityText, row.userText, row.lastRole)])
            await MainActor.run {
                // 列表行的 preview/计数可能变了,就地替换
                if let i = self.allConversations.firstIndex(where: { $0.id == conversationID }) {
                    self.allConversations[i] = row.lite
                    self.applyFilters()
                }
            }
        }
    }

    private func loadDetailIfNeeded() {
        guard let id = selectedConversationId else {
            detailTask?.cancel()
            detailTask = nil
            selectedDetail = nil
            isLoadingDetail = false
            detailLoadFailed = false
            detailLoadToken = nil
            loadingDetailId = nil
            return
        }
        if selectedDetail?.id == id { return }
        if loadingDetailId == id { return }              // 同 id 正在加载——didSet 同值重触发时别再 parse 一遍
        guard let lite = allConversations.first(where: { $0.id == id }) else {
            selectedDetail = nil
            isLoadingDetail = false
            detailLoadFailed = false
            return
        }
        // 缓存命中：切回最近看过的会话零等待。
        // 但源文件 mtime 变了（活跃会话又被追加写了）就弃缓存重解析——只 stat，微秒级。
        if let cached = detailCache[id] {
            if cached.mtime == Self.sourceMtime(id: id, fileURL: lite.fileURL, source: lite.source) {
                detailTask?.cancel()
                detailTask = nil
                selectedDetail = cached.conv
                selectedDetailFromArchive = Self.isFromArchive(fileURL: lite.fileURL, source: lite.source)
                isLoadingDetail = false
                detailLoadFailed = false
                loadingDetailId = nil
                touchCache(id)
                return
            }
            detailCache[id] = nil
            detailCacheOrder.removeAll { $0 == id }
        }

        // 新选中先取消旧解析：JSONLReader 每 chunk 检查 Task 取消，
        // 几十 MB 级旧文件不再白解析到底（快速切换时并发有了上界）。
        detailTask?.cancel()

        let token = UUID()
        detailLoadToken = token
        loadingDetailId = id
        isLoadingDetail = true
        detailLoadFailed = false
        let fileURL = lite.fileURL
        let source = lite.source

        detailTask = Task.detached(priority: .userInitiated) {
            let t0 = Date()
            // mtime 取在解析前：解析中若文件又被追加，存前值会让下次命中判定为
            // 「已过期→重解析」，宁可多解析一次也不给用户糊一版中间态。
            let mtime = Self.sourceMtime(id: id, fileURL: fileURL, source: source)
            let fromArchive = Self.isFromArchive(fileURL: fileURL, source: source)
            let conv = Self.loadFull(id: id, fileURL: fileURL, source: source)
            NSLog("[detail] parse %@ msgs=%d in %.0fms",
                  fileURL.lastPathComponent, conv?.messages.count ?? -1,
                  Date().timeIntervalSince(t0) * 1000)
            await MainActor.run {
                if let conv { self.putCache(id: id, conv, mtime: mtime) }   // 即便已切走也入缓存——切回零等待
                guard self.detailLoadToken == token else { return }
                self.loadingDetailId = nil
                self.selectedDetail = conv
                self.selectedDetailFromArchive = (conv != nil) && fromArchive
                self.isLoadingDetail = false
                self.detailLoadFailed = (conv == nil)   // parse 失败：源文件已无法读取
            }
        }
    }

    // MARK: - 详情 LRU 缓存

    private func putCache(id: String, _ conv: Conversation, mtime: Double?) {
        // 文本量 O(n) 累加(不拼接字符串——searchableText 会再分配一整份)
        let cost = conv.messages.reduce(0) { acc, m in
            acc + m.blocks.reduce(0) { $0 + $1.plainText.count }
        }
        detailCache[id] = (conv, mtime, cost)
        detailCacheOrder.removeAll { $0 == id }
        detailCacheOrder.append(id)
        // 双重上限:条数(既有)+ 字节预算(新)——驱逐到两者都满足,
        // 刚放入的这条永远保留(哪怕单条超预算:当前正在看,逐出等于没缓存)
        var total = detailCache.values.reduce(0) { $0 + $1.cost }
        while detailCacheOrder.count > 1,
              detailCacheOrder.count > detailCacheCap || total > detailCacheBudget {
            let evict = detailCacheOrder.removeFirst()
            total -= detailCache[evict]?.cost ?? 0
            detailCache[evict] = nil
        }
    }

    private func touchCache(_ id: String) {
        detailCacheOrder.removeAll { $0 == id }
        detailCacheOrder.append(id)
    }

    /// 详情源文件的当前 mtime（缓存失效判定用）。browser 行的 fileURL 是伪路径，
    /// 从 id 反解出 vault 里真正的 jsonl 再 stat；文件消失/不可读返回 nil
    /// （nil ≠ 已存 mtime → 弃缓存重解析 → 走「源文件已无法读取」失败态，与列表 prune 一致）。
    nonisolated private static func sourceMtime(id: String, fileURL: URL, source: ConversationSource) -> Double? {
        let path: String
        if source == .browser {
            guard let resolved = BrowserVaultLoader.resolve(id: id) else { return nil }
            path = resolved.fileURL.path
        } else {
            path = fileURL.path
        }
        return ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970
    }

    /// 详情读取：先源文件，源没了再退到 MindBus 自己的副本。
    ///
    /// public 且 `vaultRoot` 可注入，有两个理由：①这条回退链路是 vault 存在的全部理由，
    /// 必须能被自动化测试覆盖，不能只靠手工验证守着；②MCP 的 `memory_open` 是它的第二个
    /// 消费者（跨模块，故不能停在 internal）——GUI 与 MCP 读原文必须走同一条链路，
    /// 否则"工具删了、你的还在"这条承诺只在 GUI 里成立。
    public nonisolated static func loadFull(id: String,
                                            fileURL: URL,
                                            source: ConversationSource,
                                            vaultRoot: URL = VaultArchive.defaultRoot) -> Conversation? {
        let conv: Conversation?
        if let fromSource = loadFromSource(id: id, fileURL: fileURL, source: source) {
            conv = fromSource
        } else if VaultArchive.shouldArchive(source) {
            // 源文件已被工具清理（Claude Code 默认 30 天静默删除）——从副本读。
            // 工具删它的，用户的还在。
            conv = VaultArchive.withRestoredCopy(sourcePath: fileURL.path, root: vaultRoot) { url in
                loadFromSource(id: id, fileURL: url, source: source)
            }
        } else {
            conv = nil
        }
        // 消息墓碑统一在装载出口过滤(用户删过的单条彻底消失,不留占位)——
        // 缓存里存的也是过滤后版本,所有展示路径天然一致。
        guard let conv else { return nil }
        let buried = TombstoneStore.shared.buriedMessages(conversationID: id)
        guard !buried.isEmpty else { return conv }
        let kept = conv.messages.filter { !buried.contains($0.id) }
        // 全部消息都被删光:返回 nil 而不是原 conv——返回原文会让「删光瞬间」
        // 闪回全部消息(升级删除整场的后台任务还没跑完的窗口期)。
        guard let first = kept.first, let last = kept.last else { return nil }
        return Conversation(id: conv.id, source: conv.source,
                            startAt: first.timestamp, endAt: last.timestamp,
                            cwd: conv.cwd, gitBranch: conv.gitBranch,
                            title: conv.title, messages: kept)
    }

    /// 详情是否读自副本:与 loadFull 的回退条件同一口径(源不在+有归档)。
    nonisolated static func isFromArchive(fileURL: URL, source: ConversationSource) -> Bool {
        source != .browser
            && !FileManager.default.fileExists(atPath: fileURL.path)
            && VaultArchive.hasArchive(sourcePath: fileURL.path)
    }

    nonisolated private static func loadFromSource(id: String, fileURL: URL, source: ConversationSource) -> Conversation? {
        switch source {
        case .claudeCode:    return try? ClaudeCodeLoader.loadConversation(fileURL: fileURL)
        case .cursor:        return try? CursorLoader.loadConversation(fileURL: fileURL)
        case .openclaw:      return try? OpenClawLoader.loadConversation(fileURL: fileURL)
        case .vscodeCopilot: return try? CopilotLoader.loadConversation(fileURL: fileURL)
        case .codex:         return try? CodexLoader.loadConversation(fileURL: fileURL)
        case .claudeAgent:   return try? ClaudeAgentLoader.loadConversation(fileURL: fileURL)
        case .browser:
            // browser 是「1 文件 N 对话」，file_path 是伪路径（= conv.id）——
            // 按 id 反解 vault 文件 + 行号取回该条。
            return BrowserVaultLoader.loadSingle(id: id)
        }
    }

    private func applyFilters() {
        let focus = focusedSource
        let time = timeFilter
        let matchIds = searchMatchIds   // nil = 无全文查询
        // 实体页:提到该实体的会话 id 集(索引返回已按最近活跃降序,集合过滤后
        // 下面的 endAt 兜底排序与之同序)
        let entityIds = focusedEntity.map { Set(index?.conversations(withEntity: $0) ?? []) }
        filteredConversations = allConversations.filter { lite in
            if let ids = entityIds {
                guard ids.contains(lite.id) else { return false }
            }
            if let f = focus {
                guard lite.source == f else { return false }
            } else {
                guard Self.browsableSources.contains(lite.source) else { return false }
            }
            guard time.matches(lite.endAt) else { return false }
            if let ids = matchIds { return ids.contains(lite.id) }
            return true
        }
        // 有查询时按相关度排，没查询时按时间倒序。
        //
        // 此前无论如何都按 endAt 排 —— 即使索引层给出了相关度，也在这里被抹平：
        // 用户搜到的第一条永远是「最近的那条」而不是「最相关的那条」。
        // 保留 endAt 兜底：短词 LIKE 路径本就无相关度，且名次缺失时（理论上不该
        // 发生，但 allConversations 与 searchRank 是两次异步的产物）不能乱序。
        //
        // 无查询时仍要排：allMetadata() 的 SQL 虽已 ORDER BY end_at DESC，
        // 但 setAll 是 public API，不能假设调用方传进来的就是有序的。
        .sorted { a, b in
            if matchIds != nil {
                let ra = searchRank[a.id] ?? Int.max
                let rb = searchRank[b.id] ?? Int.max
                if ra != rb { return ra < rb }
            }
            return a.endAt > b.endAt
        }

        // 只在「从没选过」时补选最新一条。
        //
        // 原逻辑还会在「选中项落榜」时改选首条 —— 搜索是逐字符触发的，于是
        // 输入「r」→「re」→「red」每一击都会切到一个不同的对话，并**真的去
        // 解析它的完整 jsonl**（实测最大的一个文件 519MB、解析 50 秒）。
        // 右侧详情在打字过程中疯狂闪动，还白烧 I/O。
        // 现在筛选变化时保持当前详情不动，用户自己点或用 ↑↓ 选。
        if selectedConversationId == nil {
            selectedConversationId = filteredConversations.first?.id
        }
    }
}
