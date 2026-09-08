import SwiftUI

// MARK: - App 内语言

/// 界面语言：跟随系统 / 简体中文 / English。
///
/// 不走系统 .strings/.xcstrings：本项目零依赖、且要求「设置里切换后全界面即时生效」，
/// 系统方案只跟系统语言（App 内热切需要私有 Bundle hack）。这里用类型安全的双语文案表：
/// `Strings` 两个静态实例逐字段对照，漏译 = 编译错误，不存在缺 key 的运行时兜底问题。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"
    var id: String { rawValue }
}

/// 语言状态单一来源。视图直接 `@ObservedObject private var l10n = L10n.shared`
/// （同 CopyPrefsStore.shared 模式），切换 language 即触发全部订阅视图刷新。
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()
    private static let key = "mindbus.language"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
    }

    /// system 解析为系统首选语言：zh 系 → 简体中文，其余 → English。
    /// 首次安装（未设置过）即按系统语言呈现——覆盖「从向导到使用」全流程。
    var isZh: Bool {
        switch language {
        case .zhHans: return true
        case .en: return false
        case .system:
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }

    /// 当前文案表。用法：`l10n.s.settingsTitle`
    var s: Strings { isZh ? .zh : .en }
}

// MARK: - 文案表

/// 双语文案。字段按界面区域分组；新增文案必须同时补 zh/en 两处（编译器强制）。
/// 带参数的文案用闭包字段（英文注意单复数）。
struct Strings {

    // 向导 · 窗口与侧栏

    // 向导 · 导航按钮
    let next: String
    let done: String
    let scanningEllipsis: String   // 「扫描中…」：向导按钮 / scan 页状态行 / 托盘共用

    // 向导 · 来源页

    // 向导 · 扫描页

    // 向导 · 完成页

    // 托盘 + 状态栏菜单
    let openConversationBrowser: String
    let settingsTitle: String
    let quitMindBus: String
    let trayConversationsUnit: (Int) -> String   // 大数字旁的单位小字
    let trayLatest: (String) -> String           // 「最近对话 3 分钟前」

    // 列表 · header 与筛选
    let conversationCountTitle: (Int) -> String  // 「N 条对话」大标题
    let filterByTime: String
    let timeToday: String
    let timeThisWeek: String
    let timeThisMonth: String
    let filterAll: String                        // 时间筛选「全部」+ 侧栏「全部」共用
    let searchFilterHint: (String) -> String     // 空态提示里的「搜索「X」」
    let adjustFiltersHint: String

    // 列表 · 空态
    let emptyScanningTitle: String
    let emptyScanningDetail: String
    let emptyNoneTitle: String
    let emptyNoneDetail: String
    let emptyNoMatchTitle: String
    let clearFilters: String
    let indexErrorTitle: String
    let indexErrorDetail: String

    // 列表 · 行（右键菜单 + meta）
    let revealInFinder: String
    let copyFilePath: String
    let copyProjectPath: String
    let msgsCount: (Int) -> String        // 「42 条」/ "42 msgs"
    let durationHours: (Int) -> String    // 「1 小时」/ "1 h"
    let durationMinutes: (Int) -> String  // 「5 分」/ "5 min"
    let previewNoText: String             // 索引 preview 的「(无文字)」显示映射

    // 搜索
    let searchPlaceholder: String
    let clearSearch: String

    // 窗口 · 侧栏折叠
    let expandSidebar: String
    let collapseSidebar: String

    // 侧栏 · 工作空间分组与 Minds 模块
    let sidebarWorkspace: String
    let sidebarMinds: String
    let mindsPlaceholder: String

    // Minds · 真内容页
    let mindsSubtitle: String
    let mindsSecThisMonth: String
    let mindsThisMonthHint: String
    // Minds 单语化内容模板(2026-08-13:GUI 不再直显 md 英文行)
    let mShapeTurns: (Int) -> String
    let mShapeBimodal: (Int, Int) -> String
    let mShapeAvg: (Int) -> String
    let mWeekendLine: (String) -> String
    let mWeekdayLine: (String) -> String
    let mMonthDelta: (Int) -> String
    let mMonthTools: (String) -> String
    let mMonthFirstSeen: (String) -> String
    let mLeverageLine: (String, String) -> String
    let mLeverageBooks: (Int, Int) -> String
    let mDormantMeta: (Int, String) -> String
    let mFadedMeta: (Int, Int) -> String
    let mBriefSaid: (Int, Int) -> String
    /// %d=天数:「还持续了 N 天」
    let mBriefSpan: (Int) -> String
    let mMarathonMeta: (Int, String, String) -> String
    let mSpanDays: (Int) -> String
    let mSpanHours: (Int) -> String
    let mPoliteness: (String) -> String
    let rescuedBadgeHelp: String
    let rescuedBanner: String
    let mVocabMindMeta: (Int, Int) -> String
    let mVocabWorkMeta: (Int) -> String
    let mindsSecQuestionShape: String
    let mindsQuestionShapeHint: String
    let heroConversations: String
    let heroVaultCopies: String
    let heroLibraryDays: String
    let mindsSecDelegation: String
    let mindsDelegationHint: String
    // ── Minds 三页重构(2026-08-17)
    let mindsPageOverview: String
    let mindsPageAI: String
    let mindsPageProjects: String
    /// 工作节律四条洞察:标题行 + 数据行(原来一整句挤在一行读不动)
    let mRhythmPeakTitle: (String) -> String
    let mRhythmPeakDetail: (Int, Int, Int) -> String
    let mRhythmBusiestTitle: (String) -> String
    let mRhythmBusiestDetail: (Int, Int, Int) -> String
    let mRhythmJuggleTitle: (String) -> String
    let mRhythmJuggleDetail: (Int, String) -> String
    let mRhythmWeekTitle: (Int) -> String
    let mRhythmWeekDetail: (Int, Int) -> String
    /// 最近活跃列
    let mRelToday: String
    let mRelDaysAgo: (Int) -> String
    let mMarathonLongest: (String) -> String
    /// 项目表新增列
    /// 活跃期连接词「至」
    let mSpanTo: String
    let mProjColScale: String
    let mProjColSpan: String
    let mProjColRecent: String
    /// 「你的语言」整行卡
    /// 你引用过的人
    let mindsSecPeople: String
    let mindsPeopleHint: String
    let mindsSecLanguage: String
    let mindsLanguageHint: String
    /// 空态(不显示一排 0)
    let mindsEmptyRhythm: String
    let mindsEmptyGeneric: String
    /// 图表 tooltip
    /// 单位「天」——读数表里单位单独成列，不跟数字捆在一个字符串里
    let mUnitDay: String
    let mHeatLegendLess: String
    let mHeatLegendMore: String
    let mHeatTipConversations: (Int) -> String
    let mHourTipRange: (Int) -> String
    let mHourTipCount: (Int, String) -> String
    /// 委托动词计数:%d=次数, %d=对话条数
    let mDelegCount: String
    /// 调研目的地亮点:%@=目的地, %@=点名次数
    let mDelegResearch: String
    let mQKindConfirm: String
    let mQKindHow: String
    let mQKindWhy: String
    let mQKindWhat: String
    let mQVerdictConfirm: String
    let mQVerdictHow: String
    let mQVerdictWhy: String
    let mQVerdictWhat: String
    let mindsSecBriefings: String
    let mindsBriefingsHint: String
    let mindsSecShape: String
    let mindsShapeHint: String
    /// 双峰直方两组的题头
    let mShapeDurationTitle: String
    let mShapeTurnTitle: String
    let mindsSecWeekend: String
    let mindsWeekendHint: String
    let mindsProjectsHint: String
    /// 项目总表列名:项目 / 对话数 / 杠杆
    let mProjColName: String
    let mProjColCount: String
    /// 活跃地图右侧三个小统计的标签
    let mHeatActiveDays: String
    let mHeatLongestRun: String
    let mHeatLongestGap: String
    /// 杠杆冠军脚注:%@=项目名, %d=比率
    /// %@=次数 %@=条数
    let mindsSecCatchphrases: String
    let mindsCatchphrasesHint: String
    let mindsSecTaught: String
    let mindsTaughtHint: String
    let mindsTaughtMeta: (Int, Int) -> String
    let mindsTaughtIt: String
    let mindsTaughtYou: String
    let mindsSecUnlocks: String
    let mindsUnlocksHint: String
    let mindsUnlockPhrases: (Int, Int) -> String
    let mindsUnlockContagion: (Int, Int) -> String
    let mindsUnlockRecall: (Int, Int) -> String
    let mindsUnlockOutline: (Int, Int) -> String
    let mindsSecOpenLoops: String
    let mindsOpenLoopsHint: String
    let forgottenHelp: String
    let forgottenTitle: String
    let outlineHelp: String
    let outlineGapHours: (Int) -> String
    let outlineGapDays: (Int) -> String
    let mindsSignedOffTip: String
    let mindsSecHeatmap: String
    let mindsHeatmapHint: String
    let mindsSecWorkRhythm: String
    let mindsWorkRhythmHint: String
    let mindsSecLeverage: String
    let mindsLeverageHint: String
    let mindsSecMarathons: String
    let mindsMarathonsHint: String
    let mindsSecFaded: String
    let mindsFadedHint: String
    let mindsSecProjects: String
    let mindsSecVocabulary: String
    let mindsActiveNow: String
    let mindsVocabularyHint: String
    let mindsFileMissing: String
    let emptySuggestTitle: String
    let exportSectionTitle: String
    let exportSectionBody: String
    let exportOpenFolder: String
    let refBadgeHelp: (Int) -> String      // 引用徽章 hover:「被 AI 引用过 N 次」
    let entityConvCount: (Int) -> String   // 实体页:「N 条相关对话」
    let entityCoOccurring: String          // 实体页:共现小标题
    let entityExitHelp: String             // 实体页退出按钮 hover
    let folderRenameMenu: String
    let folderRenameTitle: String
    let folderRenameSave: String
    let folderRenameMessage: (String) -> String
    let sidebarFavorites: String
    let favoritesStats: (Int, Int) -> String
    let favoritesSearchPlaceholder: String
    let favoritesAllProjects: String
    let favoritesSortRecent: String
    let favoritesSortUpdated: String
    let favoritesSortCount: String
    let favoritesSortTitle: String
    let favoritesCardCount: (Int) -> String
    let favoritesCardMatches: (Int) -> String
    let favoritesRecentTitle: String
    let favoritesAllTitle: String
    let favoritesSeeAll: String
    let favoritesNoSnapshot: String
    let favoritesEmptyTitle: String
    let favoritesEmptyBody: String
    let favoritesEmptyAction: String
    let favoritesSearchEmptyTitle: String
    let favoritesSearchEmptyBody: String
    let favoritesClearFilter: String
    let favoritesBackHelp: String
    let favoritesOpenOriginal: String
    let favoritesOpenOriginalHelp: String
    let favoritesTotalMessages: (Int) -> String
    let favoritesTabSaved: (Int) -> String
    let favoritesTabFull: String
    let favoritesNoneLeft: String
    let favoritesRoleUser: String
    let favoritesShowContext: String
    let favoritesCollapseContext: String
    let favoritesLocateInFull: String
    let favoritesCopyMessage: String
    let favoritesCopyWithContext: String
    let favoritesDeleteMessage: String
    let favoritesDeleteTitle: String
    let favoritesDeleteBody: String
    let favoritesDeleteConfirm: String
    let favoritesUnstarredToast: String
    let favoritesDeletedToast: String
    let favoritesUndo: String
    let favoritesCtxPrev: String
    let favoritesCtxCurrent: String
    let favoritesCtxNext: String
    let favoritesCtxStart: String
    let favoritesCtxSkipped: (Int) -> String
    let favoritesPosition: (Int, Int) -> String
    let favoritesPrevHelp: String
    let favoritesNextHelp: String
    let favoritesMoreHelp: String
    let favoritesOriginalUnavailable: String
    let favoritesTooltip: (Int, Int) -> String
    let starAddHelp: String
    let starRemoveHelp: String
    let cancel: String

    // 详情 · 占位与失败态
    let detailPlaceholder: String
    let sourceUnreadableTitle: String
    let sourceUnreadableDetail: String

    // 详情 · header 菜单与 FAB
    let copyAll: String
    let revealSourceInFinder: String
    let moreActions: String
    let fabRelay: String
    let fabWorking: String
    let fabHelp: String

    // 详情 · 复制范围（两态：完整会话 / 所选消息）
    let scopeFullMeta: (Int) -> String        // 「完整会话 · N 条消息」（弱文字，逻辑全选不画全选）
    let scopeSelectedMeta: (Int) -> String    // 「已选 N 条 · 仅复制所选」
    let restoreFullScope: String              // 「恢复完整会话」（比「清除选择」无歧义）
    let scopeSwitchHint: String               // 首次进入所选模式的 2s 提示
    let fabRelayCount: (Int) -> String        // 「复制接力 · N 条」
    let fabWorkingCount: (Int) -> String      // 「正在整理 N 条消息」
    let copiedCount: (Int) -> String          // 「已复制 N 条消息」
    let copiedFull: String                    // 「已复制完整会话」
    let fabHelpFullScope: (Int) -> String     // hover：「将复制完整会话 · N 条消息」
    let selectMessageHelp: String             // 选择圆点 tooltip
    /// 底栏富文本三段：前缀 / 金色数字段 / 后缀（「已选 」「N 条消息」「 · 仅复制所选」）
    let scopeSelectedParts: (Int) -> (String, String, String)

    // 详情 · 消息流
    let loadEarlier: (Int) -> String      // 「加载更早的 N 条」
    let startedAt: (String) -> String     // 「始于 X」
    let terminalReadMB: (Double) -> String
    let terminalReadKB: (Double) -> String
    let terminalParsing: (Int) -> String

    // 时间线节点主标签
    let nodeThinking: String
    let nodeResult: String
    let nodeRunCommand: String
    let nodeReadFile: String
    let nodeEditFile: String
    let nodeToolCall: String

    // 气泡
    let copyThisMessage: String
    let deleteConvMenu: String
    let deleteConvTitle: String
    let deleteConvBody: String
    let deleteConvRescuedTitle: String
    let deleteConvRescuedBody: String
    let deleteConfirm: String
    let deleteRescuedConfirm: String
    let deleteCancel: String
    let deleteMsgMenu: String
    /// %d = 条数
    let deleteMsgsTitle: (Int) -> String
    let deleteMsgsBody: String
    /// %d = 条数
    let deleteSelectedButton: (Int) -> String
    let imagePlaceholder: String
    let imageUndecodable: String
    let imageLoadFailed: String
    let imageInvalidLink: String
    let copyImage: String
    let saveAsPNG: String

    // 代码块
    let copyCodeBlock: String
    let collapse: String
    let showMoreLines: (Int) -> String

    // 设置
    let settingsLanguage: String
    let langSystem: String
    let langZh: String
    let langEn: String
    let copyScope: String
    let scopeSmart: String
    let scopeAll: String
    let copyScopeHelp: String   // 复制范围问号浮层说明
    let aboutCheckUpdates: String   // 更新卡按钮：调 Sparkle 检查（App 唯一网络功能，默认开、设置可关）
    let updateBanner: (String) -> String   // 侧栏更新行：「新版本 v1.3.0」
    let updateBannerAction: String         // 更新行右侧胶囊按钮
    let updateAutoCheck: String
    let launchAtLoginToggle: String   // 登录项开关（向导复选框 + 设置卡共用），默认关
    let launchAtLoginHint: String
    let mcpCardTitle: String               // 设置页「AI 接入」卡
    let mcpCardBody: String
    let mcpConnect: (String) -> String        // 「接入 Claude Code」
    let mcpConnected: (String) -> String      // 设置页行：已接入 X
    let mcpConnectedShort: String             // 设置页状态
    let mcpDisconnect: String
    let mcpNotInstalled: String
    let mcpOtherTools: String
    let scanCollecting: (Int) -> String        // 列表标题：正在收集 · 已找到 N 条对话
    let scanTidying: String                    // 收尾：正在整理…
    /// 状态行的阶段文案：每 4 秒换一句（像 Claude Code 的状态那样一直在动），
    /// 每句都得是这一段真在做的事。第一句是这一段的名字。
    let scanMsgsIndexing: [String]
    let scanMsgsArchiving: [String]
    let scanMsgsProfiling: [String]
    let statusJoin: (String, String) -> String   // 「阶段文案 · 还需约 X」
    let etaSeconds: (Int) -> String
    let etaMinutes: (Int) -> String
    let etaSoon: String
    let welcomeTitle: String                   // 首启欢迎页（右侧空态）
    let welcomeEmpty: String
    let welcomeReady: String
    let welcomeConnect: (String) -> String     // 欢迎页按钮：说清方向是「让它来查」，别和左侧的对话来源混淆
    let mcpPrompt: (String) -> String      // 接入指令（参数：mindbus-mcp 路径）
    let mcpCopyPrompt: String
    let mcpPromptCopied: String
    let sourcesCardTitle: String           // 设置页「对话来源」卡
    let sourcesCardBody: String

    static let zh = Strings(
        next: "下一步",
        done: "完成",
        scanningEllipsis: "扫描中…",
        openConversationBrowser: "打开聊天记录",
        settingsTitle: "设置",
        quitMindBus: "退出 MindBus",
        trayConversationsUnit: { _ in "条对话" },
        trayLatest: { "最近对话 \($0)" },
        conversationCountTitle: { "\($0) 条对话" },
        filterByTime: "按时间筛选",
        timeToday: "今天",
        timeThisWeek: "本周",
        timeThisMonth: "本月",
        filterAll: "全部",
        searchFilterHint: { "搜索「\($0)」" },
        adjustFiltersHint: "试试调整筛选条件",
        emptyScanningTitle: "正在读取本机的对话记录",
        emptyScanningDetail: "首次建立索引会久一些，之后每次打开都是秒开",
        emptyNoneTitle: "还没有找到对话",
        emptyNoneDetail: "MindBus 会读取 Claude Code、Claude 客户端\n和 ChatGPT 客户端留在本机的记录",
        emptyNoMatchTitle: "没有匹配的对话",
        clearFilters: "清除筛选",
        indexErrorTitle: "读不到对话索引",
        indexErrorDetail: "索引文件可能损坏，或磁盘空间不足。\n可尝试退出 App 后重新打开。",
        revealInFinder: "在 Finder 中显示",
        copyFilePath: "复制文件路径",
        copyProjectPath: "复制项目路径",
        msgsCount: { "\($0) 条" },
        durationHours: { "\($0) 小时" },
        durationMinutes: { "\($0) 分" },
        previewNoText: "(无文字)",
        searchPlaceholder: "搜索消息…",
        clearSearch: "清除搜索",
        expandSidebar: "展开工具栏",
        collapseSidebar: "收起工具栏",
        sidebarWorkspace: "工作区",
        sidebarMinds: "Minds",
        mindsPlaceholder: "Minds 正在准备中",
        mindsSubtitle: "你日常的一点一滴",
        mindsSecThisMonth: "本月",
        mindsThisMonthHint: "这个月比上个月热闹还是安静",
        mShapeTurns: { "\($0)% 的对话你说了 16 轮以上——你不是在问答,是在共事" },
        mShapeBimodal: { "时长双峰:\($0)% 不到 2 分钟,\($1)% 超过 2 小时" },
        mShapeAvg: { "平均每条消息 \($0) 字——短指令,不是长文" },
        mWeekendLine: { "周末:\($0)" },
        mWeekdayLine: { "工作日:\($0)" },
        mMonthDelta: { $0 >= 0 ? "比上月 +\($0)" : "比上月 \($0)" },
        mMonthTools: { "工具:\($0)" },
        mMonthFirstSeen: { "本月首见:\($0)" },
        mLeverageLine: { "你打了 \($0) 字,对话共有 \($1) 字" },
        mLeverageBooks: { "≈ 你亲手写下 \($0) 本书,在 \($1) 本书的工作量里" },
        mDormantMeta: { "\($0) 条对话,最后一次 \($1)" },
        mFadedMeta: { "说过 \($0) 次,沉默 \($1) 天" },
        mBriefSaid: { "讲过 \($0) 遍 · 跨 \($1) 条对话" },
        mBriefSpan: { "持续 \($0) 天" },
        mMarathonMeta: { "\($0) 条消息,跨 \($1),\($2)" },
        mSpanDays: { "\($0) 天" },
        mSpanHours: { "\($0) 小时" },
        mPoliteness: { "礼貌与委托:\($0)" },
        rescuedBadgeHelp: "源文件已被工具清理——这份副本由 MindBus 保存,永远都在",
        rescuedBanner: "这条对话的源文件已被工具删除——你看到的是 MindBus 替你保存的副本",
        mVocabMindMeta: { "\($0) 次,\($1) 个项目" },
        mVocabWorkMeta: { "\($0) 次" },
        mindsSecQuestionShape: "提问的形状",
        mindsQuestionShapeHint: "你更常问哪一类问题",
        heroConversations: "条对话",
        heroVaultCopies: "本地副本",
        heroLibraryDays: "收纳天数",
        mindsSecDelegation: "你派给 AI 的活",
        mindsDelegationHint: "哪类事你最常交给 AI",
        mindsPageOverview: "你的总览",
        mindsPageAI: "你与 AI 的互动",
        mindsPageProjects: "你的项目",
        mRhythmPeakTitle: { "开场高峰 \($0) 点" },
        mRhythmPeakDetail: { "\($0)% · \($1)/\($2) 条" },
        mRhythmBusiestTitle: { "最忙一天 \($0)" },
        mRhythmBusiestDetail: { "\($0) 条对话 · \($1) 条消息 · 占全部 \($2)%" },
        mRhythmJuggleTitle: { "平均每个活跃日跨 \($0) 个项目" },
        mRhythmJuggleDetail: { "峰值 \($0) · \($1)" },
        mRhythmWeekTitle: { "本周至今 \($0) 条对话" },
        mRhythmWeekDetail: { "处于你个人历史的 P\($0) · 中位 \($1)" },
        mRelToday: "今天",
        mRelDaysAgo: { "\($0) 天前" },
        mMarathonLongest: { "最长 \($0)" },
        mSpanTo: "至",
        mProjColScale: "相对规模",
        mProjColSpan: "活跃期",
        mProjColRecent: "最近活跃",
        mindsSecPeople: "你引用的人",
        mindsPeopleHint: "跨项目搬出来的名字，你想法的来处",
        mindsSecLanguage: "你的语言",
        mindsLanguageHint: "你反复说的话，跨项目带着走的说法，你未必察觉",
        mindsEmptyRhythm: "继续使用一段时间后，这里会出现你的工作节律。",
        mindsEmptyGeneric: "当前还没有足够数据计算这一项。",
        mUnitDay: "天",
        mHeatLegendLess: "少",
        mHeatLegendMore: "多",
        mHeatTipConversations: { "\($0) 条对话" },
        mHourTipRange: { String(format: "%02d:00–%02d:00", $0, ($0 + 1) % 24) },
        mHourTipCount: { "\($0) 条对话 · 占全部 \($1)%" },
        mDelegCount: "%d 次 %d 条对话",
        mDelegResearch: "调研的第一目的地:%@(点名 %@ 次)",
        mQKindConfirm: "该不该",
        mQKindHow: "怎么做",
        mQKindWhy: "为什么",
        mQKindWhat: "是什么",
        mQVerdictConfirm: "你更常让 AI 做判断,而不是解释",
        mQVerdictHow: "你更常向 AI 要方法,而不是判断",
        mQVerdictWhy: "你先挖原因",
        mQVerdictWhat: "你从定义出发",
        mindsSecBriefings: "反复交代的话",
        mindsBriefingsHint: "同一句话讲了好几遍，该存成模板了",
        mindsSecShape: "一起干活的样子",
        mindsShapeHint: "不是一问一答，是一起磨活",
        mShapeDurationTitle: "每次聊多久",
        mShapeTurnTitle: "来回几轮",
        mindsSecWeekend: "周末的你",
        mindsWeekendHint: "哪个项目占据了你的周末",
        mindsProjectsHint: "点击展开历次会话",
        mProjColName: "项目",
        mProjColCount: "对话数",
        mHeatActiveDays: "活跃天数",
        mHeatLongestRun: "最长连续",
        mHeatLongestGap: "最长间歇",
        mindsSecCatchphrases: "口头禅",
        mindsCatchphrasesHint: "你总挂在嘴边的短句，原话照数",
        mindsSecTaught: "它教你的词",
        mindsTaughtHint: "它先说的,你后来接过来、带着走了好几个项目",
        mindsTaughtMeta: { "\($0) 天后你开始用 · \($1) 个项目" },
        mindsTaughtIt: "它说",
        mindsTaughtYou: "你说",
        mindsSecUnlocks: "即将解锁",
        mindsUnlocksHint: "这些发现需要更多语料——继续用,它们会自己亮起来",
        mindsUnlockPhrases: { "你反复说的话(带原话) — 需要 \($1) 个项目,现在 \($0) 个" },
        mindsUnlockContagion: { "它教你的词 — 需要 \($1) 条对话,现在 \($0) 条" },
        mindsUnlockRecall: { "你可能忘了的 — 需要 \($1) 天库龄,现在 \($0) 天" },
        mindsUnlockOutline: { "长对话目录 — 需要一条对话有 \($1) 条消息,目前最长 \($0) 条" },
        mindsSecOpenLoops: "悬着的事",
        mindsOpenLoopsHint: "它问了你、你再没回过——每条都还等着你定",
        forgottenHelp: "跟这条相关、但久到你多半忘了的旧对话",
        forgottenTitle: "你可能忘了的",
        outlineHelp: "这条对话的目录:放行、拍板、以及隔了很久才回来的地方",
        outlineGapHours: { "\($0) 小时后" },
        outlineGapDays: { "\($0) 天后" },
        mindsSignedOffTip: "你在这个项目里放行过几件事",
        mindsSecHeatmap: "活跃地图",
        mindsHeatmapHint: "近一年每天的对话量,点击查看当天",
        mindsSecWorkRhythm: "工作节奏",
        mindsWorkRhythmHint: "几点开工、哪天最忙、同时推几个项目",
        mindsSecLeverage: "杠杆率",
        mindsLeverageHint: "你打的字换回了多少",
        mindsSecMarathons: "马拉松对话",
        mindsMarathonsHint: "最长的几条,点击回看",
        mindsSecFaded: "不再说的词",
        mindsFadedHint: "以前常说，现在不提了",
        mindsSecProjects: "项目节奏",
        mindsSecVocabulary: "你的常用词",
        mindsActiveNow: "活跃中",
        mindsVocabularyHint: "从你说过的话里数出来的,点击可搜",
        mindsFileMissing: "Minds 还没生成,完成一次扫描后自动出现",
        emptySuggestTitle: "换个词试试——你的高频实体：",
        exportSectionTitle: "导出与备份",
        exportSectionBody: "对话数据已保存在本机。打开数据文件夹后，可自行复制、备份或迁移。",
        exportOpenFolder: "打开数据文件夹",
        refBadgeHelp: { "这条对话后来帮过你 \($0) 次——过去的你,帮了现在的你" },
        entityConvCount: { "\($0) 条相关对话" },
        entityCoOccurring: "与它共现——顺着找：",
        entityExitHelp: "退出实体导航",
        folderRenameMenu: "重命名文件夹标签…",
        folderRenameTitle: "重命名文件夹标签",
        folderRenameSave: "保存",
        folderRenameMessage: { "文件夹改过名？给「\($0)」设一个新名字，新旧会话就会合流成同名同色。改回原名即撤销。" },
        sidebarFavorites: "收藏",
        favoritesStats: { "\($0) 个对话 · \($1) 条消息" },
        favoritesSearchPlaceholder: "搜索收藏内容、对话或项目…",
        favoritesAllProjects: "全部项目",
        favoritesSortRecent: "最近收藏",
        favoritesSortUpdated: "对话最近更新",
        favoritesSortCount: "收藏数量最多",
        favoritesSortTitle: "对话标题",
        favoritesCardCount: { "\($0) 条收藏" },
        favoritesCardMatches: { "\($0) 条匹配" },
        favoritesRecentTitle: "最近收藏",
        favoritesAllTitle: "全部收藏消息",
        favoritesSeeAll: "查看全部收藏 →",
        favoritesNoSnapshot: "（无快照）",
        favoritesEmptyTitle: "还没有收藏内容",
        favoritesEmptyBody: "在对话中将鼠标移到一条消息上，\n点击书签，即可在这里快速找到。",
        favoritesEmptyAction: "查看全部对话",
        favoritesSearchEmptyTitle: "没有找到相关收藏",
        favoritesSearchEmptyBody: "尝试更换关键词，或清除项目筛选。",
        favoritesClearFilter: "清除筛选",
        favoritesBackHelp: "返回收藏首页",
        favoritesOpenOriginal: "打开原对话",
        favoritesOpenOriginalHelp: "进入标准对话页，可接力与选择消息",
        favoritesTotalMessages: { "共 \($0) 条消息" },
        favoritesTabSaved: { "收藏内容 \($0)" },
        favoritesTabFull: "完整对话",
        favoritesNoneLeft: "此对话已没有收藏内容",
        favoritesRoleUser: "用户",
        favoritesShowContext: "查看上下文",
        favoritesCollapseContext: "收起上下文",
        favoritesLocateInFull: "定位到原对话",
        favoritesCopyMessage: "复制此条消息",
        favoritesCopyWithContext: "复制消息及上下文",
        favoritesDeleteMessage: "删除此条消息",
        favoritesDeleteTitle: "删除这条消息？",
        favoritesDeleteBody: "仅删除当前这一条收藏记录，不影响其他收藏内容，也不会影响 ChatGPT、Claude 等源客户端中的原会话。",
        favoritesDeleteConfirm: "删除消息",
        favoritesUnstarredToast: "已取消收藏",
        favoritesDeletedToast: "已删除收藏记录",
        favoritesUndo: "撤销",
        favoritesCtxPrev: "前一条用户消息",
        favoritesCtxCurrent: "当前收藏消息",
        favoritesCtxNext: "下一条必要回复",
        favoritesCtxStart: "已是对话开头",
        favoritesCtxSkipped: { "包含 \($0) 个工具步骤" },
        favoritesPosition: { "收藏 \($0) / \($1)" },
        favoritesPrevHelp: "上一条收藏",
        favoritesNextHelp: "下一条收藏",
        favoritesMoreHelp: "更多操作",
        favoritesOriginalUnavailable: "原对话暂不可用",
        favoritesTooltip: { "\($0) 个对话，\($1) 条收藏消息" },
        starAddHelp: "收藏这条消息",
        starRemoveHelp: "取消收藏",
        cancel: "取消",
        detailPlaceholder: "从左侧选择一个对话",
        sourceUnreadableTitle: "这条对话的源文件已无法读取",
        sourceUnreadableDetail: "源文件可能已被移动或删除",
        copyAll: "复制全部",
        revealSourceInFinder: "在 Finder 中显示源文件",
        moreActions: "更多操作",
        fabRelay: "复制接力",
        fabWorking: "整理中…",
        fabHelp: "复制这段对话的关键上下文，粘给另一个 AI 就能接着聊。\n复制方式可在设置里调整，默认剥离代码、带交接说明。",
        scopeFullMeta: { "完整会话 · \($0) 条消息" },
        scopeSelectedMeta: { "已选 \($0) 条 · 仅复制所选" },
        restoreFullScope: "恢复完整会话",
        scopeSwitchHint: "未选中的消息不会被复制",
        fabRelayCount: { "复制接力 · \($0) 条" },
        fabWorkingCount: { "正在整理 \($0) 条消息" },
        copiedCount: { "已复制 \($0) 条消息" },
        copiedFull: "已复制完整会话",
        fabHelpFullScope: { "将复制完整会话 · \($0) 条消息" },
        selectMessageHelp: "选择此消息（未选择时复制完整会话；选择后只复制所选）",
        scopeSelectedParts: { ("已选 ", "\($0) 条消息", " · 仅复制所选") },
        loadEarlier: { "加载更早的 \($0) 条" },
        startedAt: { "始于 \($0)" },
        terminalReadMB: { String(format: "→ 读取 %.1f MB jsonl…", $0) },
        terminalReadKB: { String(format: "→ 读取 %.0f KB jsonl…", $0) },
        terminalParsing: { "→ 解析 \($0) 条消息…" },
        nodeThinking: "思考中",
        nodeResult: "返回结果",
        nodeRunCommand: "执行命令",
        nodeReadFile: "读取文件",
        nodeEditFile: "编辑文件",
        nodeToolCall: "调用工具",
        copyThisMessage: "复制本条消息",
        deleteConvMenu: "删除对话…",
        deleteConvTitle: "删除这条对话?",
        deleteConvBody: "将从 MindBus 移除并删除归档副本。不影响 Claude Code / Codex 里的原始文件。此操作不可撤销。",
        deleteConvRescuedTitle: "永久删除最后副本?",
        deleteConvRescuedBody: "源文件已被工具清理,MindBus 的归档是这条对话在世上的唯一副本——删除后将永久消失,无法恢复。",
        deleteConfirm: "删除",
        deleteRescuedConfirm: "永久删除",
        deleteCancel: "取消",
        deleteMsgMenu: "删除此消息…",
        deleteMsgsTitle: { "删除 \($0) 条消息?" },
        deleteMsgsBody: "所选消息将从 MindBus 的对话、搜索与 Minds 中彻底消失,不留痕迹。原始文件不受影响。此操作不可撤销。",
        deleteSelectedButton: { "删除 \($0) 条" },
        imagePlaceholder: "[图片]",
        imageUndecodable: "[图片 · 无法解码]",
        imageLoadFailed: "[图片 · 加载失败]",
        imageInvalidLink: "[图片 · 链接无效]",
        copyImage: "复制图片",
        saveAsPNG: "另存为 PNG…",
        copyCodeBlock: "复制代码块",
        collapse: "折叠",
        showMoreLines: { "查看剩余 \($0) 行" },
        settingsLanguage: "语言",
        langSystem: "跟随系统",
        langZh: "中文",
        langEn: "English",
        copyScope: "复制范围",
        scopeSmart: "智能（推荐）",
        scopeAll: "全部",
        copyScopeHelp: "智能：自动省略代码块并附上交接说明，只保留关键上下文，适合把对话接力给下一个 AI。",
        aboutCheckUpdates: "检查更新",
        updateBanner: { "新版本 v\($0)" },
        updateBannerAction: "更新",
        updateAutoCheck: "自动检查更新",
        launchAtLoginToggle: "随登录启动 MindBus",
        launchAtLoginHint: "默认关闭。开启后随登录在后台保持对话库最新，随时可以关掉。",
        mcpCardTitle: "AI 接入",
        mcpCardBody: "一键把 mindbus 写进工具的 MCP 配置，重启该工具后生效。接入后 AI 可以自行搜索这份历史、读你的画像；五个工具全部只读。",
        mcpConnect: { "接入 \($0)" },
        mcpConnected: { "已接入 \($0)" },
        mcpConnectedShort: "已接入",
        mcpDisconnect: "移除",
        mcpNotInstalled: "未检测到",
        mcpOtherTools: "其他支持 MCP 的工具：把这句话发给它，或在它的 MCP 设置里手动添加同名服务",
        scanCollecting: { "正在收集 · 已找到 \($0) 条对话" },
        scanTidying: "正在整理…",
        scanMsgsIndexing: ["正在读取对话", "正在整理每条对话的标题", "正在按项目归类", "正在建立全文索引", "正在收集图片和附件"],
        scanMsgsArchiving: ["正在备份副本", "正在压缩归档", "正在核对已备份的文件"],
        scanMsgsProfiling: ["正在生成画像", "正在统计你的用词", "正在整理项目脉络", "正在计算工作节奏"],
        statusJoin: { "\($0) · \($1)" },
        etaSeconds: { "还需约 \($0) 秒" },
        etaMinutes: { "还需约 \($0) 分钟" },
        etaSoon: "马上就好",
        welcomeTitle: "把散落在各个 AI 工具里的对话，集中管理。",
        welcomeEmpty: "还没找到对话——先用这些工具聊几次，MindBus 会自动收进来",
        welcomeReady: "点开左侧任意一条对话开始",
        welcomeConnect: { "让 \($0) 能查这些对话" },
        mcpPrompt: { "把 \($0) 注册成名为 mindbus 的 MCP server" },
        mcpCopyPrompt: "复制接入指令",
        mcpPromptCopied: "已复制",
        sourcesCardTitle: "对话来源",
        sourcesCardBody: "关掉的工具不再扫描，已收进库里的对话会从列表移除；本地归档副本保留。",
    )

    static let en = Strings(
        next: "Next",
        done: "Done",
        scanningEllipsis: "Scanning…",
        openConversationBrowser: "Open Conversation Browser",
        settingsTitle: "Settings",
        quitMindBus: "Quit MindBus",
        trayConversationsUnit: { $0 == 1 ? "conversation" : "conversations" },
        trayLatest: { "Last conversation \($0)" },
        conversationCountTitle: { $0 == 1 ? "1 conversation" : "\($0) conversations" },
        filterByTime: "Filter by time",
        timeToday: "Today",
        timeThisWeek: "This week",
        timeThisMonth: "This month",
        filterAll: "All",
        searchFilterHint: { "search “\($0)”" },
        adjustFiltersHint: "Try adjusting your filters",
        emptyScanningTitle: "Reading conversations on this Mac",
        emptyScanningDetail: "The first index takes a while — after that, every launch opens instantly",
        emptyNoneTitle: "No conversations found yet",
        emptyNoneDetail: "MindBus reads what Claude Code, Claude Desktop,\nand ChatGPT Desktop leave on this Mac",
        emptyNoMatchTitle: "No matching conversations",
        clearFilters: "Clear filters",
        indexErrorTitle: "Can't read the conversation index",
        indexErrorDetail: "The index file may be damaged, or the disk is full.\nTry quitting and reopening the app.",
        revealInFinder: "Reveal in Finder",
        copyFilePath: "Copy File Path",
        copyProjectPath: "Copy Project Path",
        msgsCount: { $0 == 1 ? "1 msg" : "\($0) msgs" },
        durationHours: { "\($0) h" },
        durationMinutes: { "\($0) min" },
        previewNoText: "(no text)",
        searchPlaceholder: "Search messages…",
        clearSearch: "Clear search",
        expandSidebar: "Show sidebar",
        collapseSidebar: "Hide sidebar",
        sidebarWorkspace: "Workspace",
        sidebarMinds: "Minds",
        mindsPlaceholder: "Minds is coming soon",
        mindsSubtitle: "Your mechanical self-description — every line is counted, not generated",
        mindsSecThisMonth: "This month",
        mindsThisMonthHint: "busier or quieter than last month",
        mShapeTurns: { "\($0)% of conversations run 16+ of your turns — you co-work, you don't just ask" },
        mShapeBimodal: { "two-peaked sessions: \($0)% under 2 min, \($1)% over 2 h" },
        mShapeAvg: { "average message \($0) chars — short directives, not essays" },
        mWeekendLine: { "weekend: \($0)" },
        mWeekdayLine: { "weekdays: \($0)" },
        mMonthDelta: { $0 >= 0 ? "+\($0) vs last month" : "\($0) vs last month" },
        mMonthTools: { "tools: \($0)" },
        mMonthFirstSeen: { "first seen this month: \($0)" },
        mLeverageLine: { "you typed \($0); the conversations hold \($1)" },
        mLeverageBooks: { "≈ \($0) books of your own writing, inside ≈ \($1) books of work" },
        mDormantMeta: { "\($0) conversations, last touched \($1)" },
        mFadedMeta: { "said \($0)× · silent \($1) days" },
        mBriefSaid: { "said \($0)× · across \($1) conversations" },
        mBriefSpan: { "over \($0) days" },
        mMarathonMeta: { "\($0) messages · over \($1) · \($2)" },
        mSpanDays: { "\($0) days" },
        mSpanHours: { "\($0) h" },
        mPoliteness: { "politeness & delegation: \($0)" },
        rescuedBadgeHelp: "The source file was cleaned up by its tool — this copy is kept by MindBus, forever",
        rescuedBanner: "The source of this conversation was deleted by its tool — you are reading MindBus's rescued copy",
        mVocabMindMeta: { "\($0)× · \($1) projects" },
        mVocabWorkMeta: { "\($0)×" },
        mindsSecQuestionShape: "Question Shape",
        mindsQuestionShapeHint: "which cognitive layer your questions live in",
        heroConversations: "conversations",
        heroVaultCopies: "local copies",
        heroLibraryDays: "days of library",
        mindsSecDelegation: "Delegation",
        mindsDelegationHint: "what you most often ask AI to do",
        mindsPageOverview: "Your Overview",
        mindsPageAI: "You and AI",
        mindsPageProjects: "Your Projects",
        mRhythmPeakTitle: { "most conversations start \($0)" },
        mRhythmPeakDetail: { "\($0)% (\($1) of \($2))" },
        mRhythmBusiestTitle: { "busiest day \($0)" },
        mRhythmBusiestDetail: { "\($0) conversations · \($1) messages · \($2)% of all" },
        mRhythmJuggleTitle: { "\($0) projects per active day" },
        mRhythmJuggleDetail: { "peak \($0) on \($1)" },
        mRhythmWeekTitle: { "\($0) so far this week" },
        mRhythmWeekDetail: { "P\($0) of your own history (median \($1))" },
        mRelToday: "today",
        mRelDaysAgo: { "\($0)d ago" },
        mMarathonLongest: { "longest \($0)" },
        mSpanTo: "→",
        mProjColScale: "SCALE",
        mProjColSpan: "ACTIVE PERIOD",
        mProjColRecent: "LAST TOUCHED",
        mindsSecPeople: "People You Cite",
        mindsPeopleHint: "names you bring up across projects — where your ideas come from",
        mindsSecLanguage: "Your Language",
        mindsLanguageHint: "phrases you carry from project to project, probably without noticing",
        mindsEmptyRhythm: "Keep using it for a while — your work rhythm will show up here.",
        mindsEmptyGeneric: "Not enough data for this one yet.",
        mUnitDay: "d",
        mHeatLegendLess: "less",
        mHeatLegendMore: "more",
        mHeatTipConversations: { "\($0) conversations" },
        mHourTipRange: { String(format: "%02d:00–%02d:00", $0, ($0 + 1) % 24) },
        mHourTipCount: { "\($0) conversations · \($1)% of all" },
        mDelegCount: "%d× %dc",
        mDelegResearch: "research destination #1: %@ (named %@ times)",
        mQKindConfirm: "should-we",
        mQKindHow: "how-to",
        mQKindWhy: "why",
        mQKindWhat: "what-is",
        mQVerdictConfirm: "you ask AI to judge, more than to explain",
        mQVerdictHow: "you ask AI for methods, more than judgments",
        mQVerdictWhy: "you dig for reasons first",
        mQVerdictWhat: "you start from definitions",
        mindsSecBriefings: "Repeated Briefings",
        mindsBriefingsHint: "worth turning into a reusable prompt or skill",
        mindsSecShape: "Collaboration Shape",
        mindsShapeHint: "you co-work, you don't just ask",
        mShapeDurationTitle: "SESSION LENGTH",
        mShapeTurnTitle: "TURNS",
        mindsSecWeekend: "Weekend Self",
        mindsWeekendHint: "which project owns your weekends",
        mindsProjectsHint: "click to expand history",
        mProjColName: "PROJECT",
        mProjColCount: "RUNS",
        mHeatActiveDays: "ACTIVE DAYS",
        mHeatLongestRun: "LONGEST RUN",
        mHeatLongestGap: "LONGEST GAP",
        mindsSecCatchphrases: "Catchphrases",
        mindsCatchphrasesHint: "short messages you send again and again",
        mindsSecTaught: "Words It Taught You",
        mindsTaughtHint: "it used them first — you picked them up and carried them on",
        mindsTaughtMeta: { "picked up \($0)d later · \($1) projects" },
        mindsTaughtIt: "it",
        mindsTaughtYou: "you",
        mindsSecUnlocks: "Coming Up",
        mindsUnlocksHint: "these need more history — keep going and they light up",
        mindsUnlockPhrases: { "Phrases you repeat — needs \($1) projects, you have \($0)" },
        mindsUnlockContagion: { "Words it taught you — needs \($1) conversations, you have \($0)" },
        mindsUnlockRecall: { "You may have forgotten — needs \($1) days of history, you have \($0)" },
        mindsUnlockOutline: { "Long-conversation outline — needs a \($1)-message conversation, longest is \($0)" },
        mindsSecOpenLoops: "Open Loops",
        mindsOpenLoopsHint: "it asked, you never answered — still waiting on you",
        forgottenHelp: "related work old enough that you have probably forgotten it",
        forgottenTitle: "You may have forgotten",
        outlineHelp: "outline: what you signed off, what you called, and where you came back",
        outlineGapHours: { "\($0)h later" },
        outlineGapDays: { "\($0)d later" },
        mindsSignedOffTip: "how many things you signed off in this project",
        mindsSecHeatmap: "Activity Map",
        mindsHeatmapHint: "a year of conversations · click any day",
        mindsSecWorkRhythm: "Work Rhythm",
        mindsWorkRhythmHint: "start times · peak day · juggling",
        mindsSecLeverage: "Leverage",
        mindsLeverageHint: "what your typing turned into",
        mindsSecMarathons: "Marathons",
        mindsMarathonsHint: "longest conversations · click to revisit",
        mindsSecFaded: "Faded Words",
        mindsFadedHint: "once-frequent, topics moved on",
        mindsSecProjects: "Project Rhythm",
        mindsSecVocabulary: "Your Concept Map",
        mindsActiveNow: "active",
        mindsVocabularyHint: "your personal lexicon, statistically grown · click to search",
        mindsFileMissing: "Minds not built yet — it appears after the first scan",
        emptySuggestTitle: "Try one of your frequent entities:",
        exportSectionTitle: "Export & Backup",
        exportSectionBody: "Your conversation data lives on this Mac. Open the data folder to copy, back up, or migrate it yourself.",
        exportOpenFolder: "Open Data Folder",
        refBadgeHelp: { "This conversation helped you \($0) time(s) since — your past self, helping your present self" },
        entityConvCount: { "\($0) related conversation(s)" },
        entityCoOccurring: "Co-occurring — follow the thread:",
        entityExitHelp: "Exit entity navigation",
        folderRenameMenu: "Rename Folder Tag…",
        folderRenameTitle: "Rename Folder Tag",
        folderRenameSave: "Save",
        folderRenameMessage: { "Renamed the folder on disk? Give \"\($0)\" its new name and old and new conversations merge into one tag and color. Enter the original name to undo." },
        sidebarFavorites: "Favorites",
        favoritesStats: { "\($0) conversation(s) · \($1) message(s)" },
        favoritesSearchPlaceholder: "Search favorites, conversations, projects…",
        favoritesAllProjects: "All projects",
        favoritesSortRecent: "Recently starred",
        favoritesSortUpdated: "Conversation updated",
        favoritesSortCount: "Most favorites",
        favoritesSortTitle: "Conversation title",
        favoritesCardCount: { "\($0) starred" },
        favoritesCardMatches: { "\($0) match(es)" },
        favoritesRecentTitle: "Recent",
        favoritesAllTitle: "All starred messages",
        favoritesSeeAll: "See all favorites →",
        favoritesNoSnapshot: "(no snapshot)",
        favoritesEmptyTitle: "No favorites yet",
        favoritesEmptyBody: "Hover over any message in a conversation\nand click the bookmark to find it here.",
        favoritesEmptyAction: "Browse conversations",
        favoritesSearchEmptyTitle: "No matching favorites",
        favoritesSearchEmptyBody: "Try different keywords, or clear the project filter.",
        favoritesClearFilter: "Clear filters",
        favoritesBackHelp: "Back to favorites",
        favoritesOpenOriginal: "Open Original",
        favoritesOpenOriginalHelp: "Standard conversation page with relay & selection",
        favoritesTotalMessages: { "\($0) messages total" },
        favoritesTabSaved: { "Saved \($0)" },
        favoritesTabFull: "Full Conversation",
        favoritesNoneLeft: "No favorites left in this conversation",
        favoritesRoleUser: "User",
        favoritesShowContext: "Show Context",
        favoritesCollapseContext: "Hide Context",
        favoritesLocateInFull: "Locate in conversation",
        favoritesCopyMessage: "Copy Message",
        favoritesCopyWithContext: "Copy with Context",
        favoritesDeleteMessage: "Delete This Message",
        favoritesDeleteTitle: "Delete this message?",
        favoritesDeleteBody: "Removes only this favorite record. Other favorites — and the original session in ChatGPT, Claude, etc. — are untouched.",
        favoritesDeleteConfirm: "Delete",
        favoritesUnstarredToast: "Removed from favorites",
        favoritesDeletedToast: "Favorite record deleted",
        favoritesUndo: "Undo",
        favoritesCtxPrev: "Previous user message",
        favoritesCtxCurrent: "Starred message",
        favoritesCtxNext: "Next essential reply",
        favoritesCtxStart: "Start of conversation",
        favoritesCtxSkipped: { "\($0) tool step(s) collapsed" },
        favoritesPosition: { "Favorite \($0) / \($1)" },
        favoritesPrevHelp: "Previous favorite",
        favoritesNextHelp: "Next favorite",
        favoritesMoreHelp: "More actions",
        favoritesOriginalUnavailable: "Original conversation unavailable",
        favoritesTooltip: { "\($0) conversation(s), \($1) starred message(s)" },
        starAddHelp: "Star this message",
        starRemoveHelp: "Unstar",
        cancel: "Cancel",
        detailPlaceholder: "Select a conversation to view it",
        sourceUnreadableTitle: "This conversation's source file can't be read",
        sourceUnreadableDetail: "The source file may have been moved or deleted",
        copyAll: "Copy All",
        revealSourceInFinder: "Reveal Source File in Finder",
        moreActions: "More actions",
        fabRelay: "Copy Handoff",
        fabWorking: "Preparing…",
        fabHelp: "Copies the key context of this conversation — paste it into another AI to keep going.\nAdjust how it copies in Settings; by default code is stripped and a handoff note is included.",
        scopeFullMeta: { $0 == 1 ? "Full conversation · 1 message" : "Full conversation · \($0) messages" },
        scopeSelectedMeta: { $0 == 1 ? "1 selected · copies selection only" : "\($0) selected · copies selection only" },
        restoreFullScope: "Restore full conversation",
        scopeSwitchHint: "Unselected messages won't be copied",
        fabRelayCount: { "Copy Handoff · \($0)" },
        fabWorkingCount: { $0 == 1 ? "Preparing 1 message…" : "Preparing \($0) messages…" },
        copiedCount: { $0 == 1 ? "Copied 1 message" : "Copied \($0) messages" },
        copiedFull: "Copied full conversation",
        fabHelpFullScope: { $0 == 1 ? "Copies the full conversation · 1 message" : "Copies the full conversation · \($0) messages" },
        selectMessageHelp: "Select this message (nothing selected = full conversation; with a selection, only selected messages are copied)",
        scopeSelectedParts: { ("Selected ", $0 == 1 ? "1 message" : "\($0) messages", " · copies selection only") },
        loadEarlier: { $0 == 1 ? "Load 1 earlier message" : "Load \($0) earlier messages" },
        startedAt: { "Started \($0)" },
        terminalReadMB: { String(format: "→ reading %.1f MB jsonl…", $0) },
        terminalReadKB: { String(format: "→ reading %.0f KB jsonl…", $0) },
        terminalParsing: { "→ parsing \($0) messages…" },
        nodeThinking: "Thinking",
        nodeResult: "Result",
        nodeRunCommand: "Run command",
        nodeReadFile: "Read file",
        nodeEditFile: "Edit file",
        nodeToolCall: "Tool call",
        copyThisMessage: "Copy Message",
        deleteConvMenu: "Delete Conversation…",
        deleteConvTitle: "Delete this conversation?",
        deleteConvBody: "Removes it from MindBus and deletes the archived copy. The original file in Claude Code / Codex is not affected. This cannot be undone.",
        deleteConvRescuedTitle: "Permanently delete the last copy?",
        deleteConvRescuedBody: "The source file was already cleaned up by the tool — MindBus's archive is the only copy left. Deleting it means this conversation is gone forever.",
        deleteConfirm: "Delete",
        deleteRescuedConfirm: "Delete Forever",
        deleteCancel: "Cancel",
        deleteMsgMenu: "Delete This Message…",
        deleteMsgsTitle: { "Delete \($0) message\($0 == 1 ? "" : "s")?" },
        deleteMsgsBody: "Selected messages disappear completely from MindBus — conversation, search, and Minds. The original file is not affected. This cannot be undone.",
        deleteSelectedButton: { "Delete \($0)" },
        imagePlaceholder: "[Image]",
        imageUndecodable: "[Image · can't decode]",
        imageLoadFailed: "[Image · failed to load]",
        imageInvalidLink: "[Image · broken link]",
        copyImage: "Copy Image",
        saveAsPNG: "Save as PNG…",
        copyCodeBlock: "Copy code block",
        collapse: "Collapse",
        showMoreLines: { $0 == 1 ? "Show 1 more line" : "Show \($0) more lines" },
        settingsLanguage: "Language",
        langSystem: "System",
        langZh: "中文",
        langEn: "English",
        copyScope: "Copy scope",
        scopeSmart: "Smart",
        scopeAll: "All",
        copyScopeHelp: "Smart: strips code blocks and adds a handoff note — key context only, ideal for relaying to another AI.",
        aboutCheckUpdates: "Check for Updates",
        updateBanner: { "Version \($0)" },
        updateBannerAction: "Update",
        updateAutoCheck: "Check for updates automatically",
        launchAtLoginToggle: "Launch MindBus at login",
        launchAtLoginHint: "Off by default. When on, MindBus starts at login to keep your vault current; switch it off anytime.",
        mcpCardTitle: "Connect your AI",
        mcpCardBody: "One click writes mindbus into the tool's MCP config; restart the tool to take effect. The AI can then search this history and read your profile on its own. All five tools are read-only.",
        mcpConnect: { "Connect \($0)" },
        mcpConnected: { "\($0) connected" },
        mcpConnectedShort: "Connected",
        mcpDisconnect: "Remove",
        mcpNotInstalled: "Not detected",
        mcpOtherTools: "Other MCP-capable tools: send this sentence, or add a server with the same name in their MCP settings",
        scanCollecting: { "Collecting · \($0) found" },
        scanTidying: "Tidying up…",
        scanMsgsIndexing: ["Reading conversations", "Titling each conversation", "Grouping by project", "Building the search index", "Collecting images and attachments"],
        scanMsgsArchiving: ["Backing up copies", "Compressing archives", "Checking existing backups"],
        scanMsgsProfiling: ["Building your profile", "Counting your vocabulary", "Tracing project threads", "Measuring your rhythm"],
        statusJoin: { "\($0) · \($1)" },
        etaSeconds: { "about \($0)s left" },
        etaMinutes: { "about \($0) min left" },
        etaSoon: "almost done",
        welcomeTitle: "All your AI conversations, managed in one place.",
        welcomeEmpty: "Nothing found yet. Chat a few times in those tools and MindBus picks them up automatically",
        welcomeReady: "Pick any conversation on the left to begin",
        welcomeConnect: { "Let \($0) search these conversations" },
        mcpPrompt: { "Register \($0) as an MCP server named mindbus" },
        mcpCopyPrompt: "Copy setup prompt",
        mcpPromptCopied: "Copied",
        sourcesCardTitle: "Sources",
        sourcesCardBody: "A tool you switch off is no longer scanned and its conversations leave the list; local archive copies are kept.",
    )
}
