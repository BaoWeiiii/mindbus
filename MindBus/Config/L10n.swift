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
    let wizardWindowTitle: String
    let wizardSubtitle: String
    let wizardStepSources: String
    let wizardStepScan: String
    let wizardStepComplete: String

    // 向导 · 导航按钮
    let back: String
    let next: String
    let done: String
    let scanningEllipsis: String   // 「扫描中…」：向导按钮 / scan 页状态行 / 托盘共用

    // 向导 · 来源页
    let sourcesTitle: String
    let sourcesSubtitle: String
    let sourcesFootnoteLocal: String
    let sourcesFootnoteLogin: String

    // 向导 · 扫描页
    let scanTitleScanning: String
    let scanTitleDone: String
    let scanTitleBackground: String
    let scanSubtitleScanning: String
    let scanSubtitleDone: String
    let scanSubtitleBackground: String
    let scanStatusDone: String
    let scanStatusBackground: String

    // 向导 · 完成页
    let completeTitle: String
    let completeBodyScanning: String
    let completeBodyDone: String
    let completeHint: String
    let completeMenubarHint: String   // 主窗关掉后怎么回来——菜单栏 App 的关键断点

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
    let mindsTrustSuffix: String
    let mindsGroupForYou: String
    let mindsGroupForAI: String
    let mindsSecUnfinished: String
    let mindsUnfinishedHint: String
    let mindsSecRecurring: String
    let mindsRecurringHint: String
    let mindsSecDormant: String
    let mindsDormantHint: String
    let mindsSecThisMonth: String
    let mindsThisMonthHint: String
    let mindsSecStarred: String
    let mindsStarredHint: String
    let scanLiveCollected: String
    let completeSanctuaryOngoing: (Int) -> String
    let completeSanctuary: (Int) -> String
    let completeSanctuaryOutlived: (Int, Int) -> String
    // Minds 单语化内容模板(2026-08-13:GUI 不再直显 md 英文行)
    let mRhythmPeak: (String, Int, Int, Int) -> String
    let mRhythmBusiest: (String, Int, Int) -> String
    let mRhythmJuggle: (String, Int, String) -> String
    let mRhythmActive: (Int, Int, Int, Int) -> String
    let mRhythmWeek: (Int, Int, Int) -> String
    let mShapeTurns: (Int) -> String
    let mShapeBimodal: (Int, Int) -> String
    let mShapeAvg: (Int) -> String
    let mWeekendLine: (String) -> String
    let mWeekdayLine: (String) -> String
    let mMonthDelta: (Int) -> String
    let mMonthTools: (String) -> String
    let mMonthFirstSeen: (String) -> String
    let mMonthLastYear: (Int) -> String
    let mLeverageLine: (String, String) -> String
    let mLeverageBooks: (Int, Int) -> String
    let mConvSpan: (Int, String) -> String
    let mDormantMeta: (Int, String) -> String
    let mFadedMeta: (Int, Int) -> String
    let mBriefSaid: (Int, Int) -> String
    /// %d=天数:「还持续了 N 天」
    let mBriefSpan: (Int) -> String
    let mFlowShared: (Int) -> String
    let mFlowBorn: (Int, String) -> String
    let mMarathonMeta: (Int, String, String) -> String
    let mSpanDays: (Int) -> String
    let mSpanHours: (Int) -> String
    let mRaritiesNight: (String, String, String) -> String
    let mRaritiesOnce: (String) -> String
    let mRaritiesRare: (String) -> String
    let mPoliteness: (String) -> String
    let rescuedBadgeHelp: String
    let rescuedBanner: String
    let mindsMuteResurface: String
    let mVocabMindLabel: String
    let mVocabWorkLabel: String
    let mVocabMindMeta: (Int, Int) -> String
    let mVocabWorkMeta: (Int) -> String
    let mindsSecQuestionShape: String
    let mindsQuestionShapeHint: String
    let mindsGroupRhythm: String
    let mindsGroupHowYouUseAI: String
    let mindsGroupLanguage: String
    let mindsGroupProjects: String
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
    /// 委托动词计数:%d=次数, %d=对话场数
    let mDelegCount: String
    /// 调研目的地亮点:%@=目的地, %@=点名次数
    let mDelegResearch: String
    let mindsSecFirstWords: String
    let mindsFirstWordsHint: String
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
    let mindsSecSanctuary: String
    let mindsSanctuaryHint: String
    let mindsSecShape: String
    let mindsShapeHint: String
    /// 双峰直方两组的题头
    let mShapeDurationTitle: String
    let mShapeTurnTitle: String
    let mindsSecWeekend: String
    let mindsWeekendHint: String
    let mindsSecFlows: String
    let mindsFlowsHint: String
    let mindsProjectsHint: String
    /// 项目总表列名:项目 / 场数 / 杠杆
    let mProjColName: String
    let mProjColCount: String
    let mProjColLeverage: String
    /// 活跃地图右侧三个小统计的标签
    let mHeatActiveDays: String
    let mHeatLongestRun: String
    let mHeatLongestGap: String
    /// 杠杆冠军脚注:%@=项目名, %d=比率
    let mProjLeverageTop: String
    let mindsSecOnThisDay: String
    let mindsOnThisDayHint: String
    let mindsSecInvokedNames: String
    let mindsInvokedNamesHint: String
    /// %@=次数 %@=场次
    let mInvokedMeta: (Int, Int) -> String
    let mindsSecCatchphrases: String
    let mindsCatchphrasesHint: String
    let mindsSecRarities: String
    let mindsRaritiesHint: String
    let mindsSecTaught: String
    let mindsTaughtHint: String
    let mindsTaughtMeta: (Int, Int) -> String
    let mindsSecOpenLoops: String
    let mindsOpenLoopsHint: String
    let forgottenHelp: String
    let forgottenTitle: String
    let outlineHelp: String
    let outlineGapHours: (Int) -> String
    let outlineGapDays: (Int) -> String
    let mindsSignedOffTip: String
    let mindsSecDecisions: String
    let mindsDecisionsHint: String
    let mindsSecMilestones: String
    let mindsMilestonesHint: String
    let mindsMilestonesCount: String
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
    let mindsSecOverview: String
    let mindsSecProjects: String
    let mindsSecEntities: String
    let mindsSecPhrases: String
    let mindsPhrasesHint: String
    let mindsSecVocabulary: String
    let mindsSecAgentUsage: String
    let mindsSecWeakSpots: String
    let mindsConversationsUnit: String
    let mindsToolsUnit: String
    let mindsDaysUnit: String
    let mindsAllLocal: String
    let mindsActiveNow: String
    let mindsSpotPreferences: String
    let mindsSpotStyle: String
    let mindsSpotGoals: String
    let mindsSpotStack: String
    let mindsBadgeUnreviewed: String
    let mindsBadgeConfirmed: String
    let mindsConfirm: String
    let mindsRevoke: String
    let mindsSources: String
    let mindsSpotEmpty: String
    let mindsEnrichHint: String
    let mindsEntitiesHint: String
    let mindsVocabularyHint: String
    let mindsAgentUsageHint: String
    let mindsFileMissing: String
    let emptySuggestTitle: String
    let exportSectionTitle: String
    let exportSectionBody: String
    let exportOpenFolder: String
    let refBadgeHelp: (Int) -> String      // 引用徽章 hover:「被 AI 引用过 N 次」
    let entityConvCount: (Int) -> String   // 实体页:「N 场相关会话」
    let entityCoOccurring: String          // 实体页:共现小标题
    let entityExitHelp: String             // 实体页退出按钮 hover
    let mindsInjectAction: String
    let mindsInjectUpdate: String
    let mindsInjectRemove: String
    let mindsInjectDone: String
    let mindsInjectHint: (Int) -> String
    let mindsInjectConfirmTitle: String
    let mindsInjectConfirmBody: String
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
    let copied: String                    // FAB 成功态 + 气泡复制反馈共用
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
    let aboutCheckUpdates: String   // 更新卡按钮：调 Sparkle 检查（App 唯一网络功能，opt-in）
    let updateBanner: (String) -> String   // 侧栏更新行：「新版本 v1.3.0」
    let updateBannerAction: String         // 更新行右侧胶囊按钮
    let updateAutoCheck: String

    static let zh = Strings(
        wizardWindowTitle: "MindBus 设置向导",
        wizardSubtitle: "设置向导",
        wizardStepSources: "来源",
        wizardStepScan: "扫描",
        wizardStepComplete: "完成",
        back: "上一步",
        next: "下一步",
        done: "完成",
        scanningEllipsis: "扫描中…",
        sourcesTitle: "我会读取这三个地方的对话记录",
        sourcesSubtitle: "只读不改。解析与索引全部在本机完成，不会联网。",
        sourcesFootnoteLocal: "数据始终保留在本地。点「下一步」开始扫描。",
        sourcesFootnoteLogin: "MindBus 会随登录启动，保持对话库最新（可在系统设置中关闭）",
        scanTitleScanning: "正在收拢你的 AI 对话…",
        scanTitleDone: "扫描完成",
        scanTitleBackground: "扫描已在后台进行",
        scanSubtitleScanning: "扫描本地 AI 工具的对话记录",
        scanSubtitleDone: "已存进本地对话库",
        scanSubtitleBackground: "对话较多，扫描会在后台继续，完成后自动进入对话库",
        scanStatusDone: "已收进对话库",
        scanStatusBackground: "已开始扫描，稍后自动完成",
        completeTitle: "一切就绪",
        completeBodyScanning: "你的 AI 对话正在陆续收进来，完成后自动出现",
        completeBodyDone: "你散落各处的 AI 对话，现在都在这了",
        completeHint: "随时搜索、查看、一键接力到新对话",
        completeMenubarHint: "MindBus 常驻菜单栏图标，随时按 ⌘⇧H 回到对话库",
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
        mindsSubtitle: "关于你的一切，每一行都是数出来的，不是编的",
        mindsTrustSuffix: "counted, not generated",
        mindsGroupForYou: "给你的,你可能没意识到的",
        mindsGroupForAI: "给你的 AI 的,让它开口前就认识你",
        mindsSecUnfinished: "断了的线头",
        mindsUnfinishedHint: "最后一句是你说的——问了没答",
        mindsSecRecurring: "反复回来的问题",
        mindsRecurringHint: "隔着日子又来一遍的话题",
        mindsSecDormant: "沉睡的项目",
        mindsDormantHint: "聊了很多，好久没碰",
        mindsSecThisMonth: "本月",
        mindsThisMonthHint: "这个月比上个月热闹还是安静",
        mindsSecStarred: "你标记的重点",
        mindsStarredHint: "点击回到原对话",
        scanLiveCollected: "段对话已收录",
        completeSanctuaryOngoing: { "已收录 \($0) 段对话,还在继续——它们从此有了第二个家" },
        completeSanctuary: { "已收录 \($0) 段对话——从今天起,它们有了第二个家" },
        completeSanctuaryOutlived: { "已收录 \($0) 段对话·其中 \($1) 段已越过源工具的清理线" },
        mRhythmPeak: { "开场高峰 \($0)——\($1)%(\($2)/\($3) 场)" },
        mRhythmBusiest: { "最忙一天 \($0)——\($1) 场(占全部 \($2)%)" },
        mRhythmJuggle: { "平均每个活跃日跨 \($0) 个项目——峰值 \($1),\($2)" },
        mRhythmActive: { "近 \($1) 天活跃 \($0) 天——最长连续 \($2) 天,最长间歇 \($3) 天" },
        mRhythmWeek: { "本周至今 \($0) 场——处于你个人历史的 P\($1)(中位 \($2))" },
        mShapeTurns: { "\($0)% 的对话你说了 16 轮以上——你不是在问答,是在共事" },
        mShapeBimodal: { "时长双峰:\($0)% 不到 2 分钟,\($1)% 超过 2 小时" },
        mShapeAvg: { "平均每条消息 \($0) 字——短指令,不是长文" },
        mWeekendLine: { "周末:\($0)" },
        mWeekdayLine: { "工作日:\($0)" },
        mMonthDelta: { $0 >= 0 ? "比上月 +\($0)" : "比上月 \($0)" },
        mMonthTools: { "工具:\($0)" },
        mMonthFirstSeen: { "本月首见:\($0)" },
        mMonthLastYear: { "去年同月:\($0) 场" },
        mLeverageLine: { "你打了 \($0) 字,对话共有 \($1) 字" },
        mLeverageBooks: { "≈ 你亲手写下 \($0) 本书,在 \($1) 本书的工作量里" },
        mConvSpan: { "\($0) 场对话 · \($1)" },
        mDormantMeta: { "\($0) 场对话,最后一次 \($1)" },
        mFadedMeta: { "说过 \($0) 次,沉默 \($1) 天" },
        mBriefSaid: { "讲过 \($0) 遍 · 跨 \($1) 场对话" },
        mBriefSpan: { "持续 \($0) 天" },
        mFlowShared: { "共享 \($0) 个概念" },
        mFlowBorn: { " · \($0) 个先生于 \($1)" },
        mMarathonMeta: { "\($0) 条消息,跨 \($1),\($2)" },
        mSpanDays: { "\($0) 天" },
        mSpanHours: { "\($0) 小时" },
        mRaritiesNight: { "最晚的深夜:\($0) \($1),你开了「\($2)」" },
        mRaritiesOnce: { "只问过一次,再没回来:\($0)" },
        mRaritiesRare: { "你的稀有词:\($0)" },
        mPoliteness: { "礼貌与委托:\($0)" },
        rescuedBadgeHelp: "源文件已被工具清理——这份副本由 MindBus 保存,永远都在",
        rescuedBanner: "这场对话的源文件已被工具删除——你看到的是 MindBus 替你保存的副本",
        mindsMuteResurface: "不再显示这条——只影响「那年今日」,不影响列表与搜索",
        mVocabMindLabel: "思维词汇,跟着你走过 5+ 个项目",
        mVocabWorkLabel: "项目词汇",
        mVocabMindMeta: { "\($0) 次,\($1) 个项目" },
        mVocabWorkMeta: { "\($0) 次" },
        mindsSecQuestionShape: "提问的形状",
        mindsQuestionShapeHint: "你更常问哪一类问题",
        mindsGroupRhythm: "你的节奏",
        mindsGroupHowYouUseAI: "你怎么用 AI",
        mindsGroupLanguage: "你的语言",
        mindsGroupProjects: "你的项目",
        heroConversations: "场对话",
        heroVaultCopies: "本地副本",
        heroLibraryDays: "收纳天数",
        mindsSecDelegation: "你派给 AI 的活",
        mindsDelegationHint: "哪类事你最常交给 AI",
        mindsPageOverview: "你的总览",
        mindsPageAI: "你与 AI 的互动",
        mindsPageProjects: "你的项目",
        mRhythmPeakTitle: { "开场高峰 \($0) 点" },
        mRhythmPeakDetail: { "\($0)% · \($1)/\($2) 场" },
        mRhythmBusiestTitle: { "最忙一天 \($0)" },
        mRhythmBusiestDetail: { "\($0) 场 · \($1) 条消息 · 占全部 \($2)%" },
        mRhythmJuggleTitle: { "平均每个活跃日跨 \($0) 个项目" },
        mRhythmJuggleDetail: { "峰值 \($0) · \($1)" },
        mRhythmWeekTitle: { "本周至今 \($0) 场" },
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
        mHeatTipConversations: { "\($0) 场对话" },
        mHourTipRange: { String(format: "%02d:00–%02d:00", $0, ($0 + 1) % 24) },
        mHourTipCount: { "\($0) 场对话 · 占全部 \($1)%" },
        mDelegCount: "%d 次 %d 场",
        mDelegResearch: "调研的第一目的地:%@(点名 %@ 次)",
        mindsSecFirstWords: "项目的第一句话",
        mindsFirstWordsHint: "每个项目的创世句·点击回到起点",
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
        mindsSecSanctuary: "永久留底",
        mindsSanctuaryHint: "都在你自己的硬盘上，谁也拿不走",
        mindsSecShape: "一起干活的样子",
        mindsShapeHint: "不是一问一答，是一起磨活",
        mShapeDurationTitle: "每场聊多久",
        mShapeTurnTitle: "来回几轮",
        mindsSecWeekend: "周末的你",
        mindsWeekendHint: "哪个项目占据了你的周末",
        mindsSecFlows: "知识流动",
        mindsFlowsHint: "项目之间共享的概念",
        mindsProjectsHint: "点击展开历次会话",
        mProjColName: "项目",
        mProjColCount: "场数",
        mProjColLeverage: "杠杆",
        mHeatActiveDays: "活跃天数",
        mHeatLongestRun: "最长连续",
        mHeatLongestGap: "最长间歇",
        mProjLeverageTop: "最省你话的项目:%@(你写 1 个字,换回 %d 个字)",
        mindsSecOnThisDay: "那年今日",
        mindsOnThisDayHint: "同一个日期，更早的章节",
        mindsSecInvokedNames: "你搬出过的名字",
        mindsInvokedNamesHint: "你反复请出的人,如实计数",
        mInvokedMeta: { "\($0) 次,\($1) 场" },
        mindsSecCatchphrases: "口头禅",
        mindsCatchphrasesHint: "你总挂在嘴边的短句，原话照数",
        mindsSecRarities: "独一无二",
        mindsRaritiesHint: "最晚的深夜·只问过一次的话题·稀有词",
        mindsSecTaught: "它教你的词",
        mindsTaughtHint: "它先说的,你后来接过来、带着走了好几个项目",
        mindsTaughtMeta: { "\($0) 天后你开始用 · \($1) 个项目" },
        mindsSecOpenLoops: "悬着的事",
        mindsOpenLoopsHint: "它问了你、你再没回过——每条都还等着你定",
        forgottenHelp: "跟这场相关、但久到你多半忘了的旧对话",
        forgottenTitle: "你可能忘了的",
        outlineHelp: "这场对话的目录:放行、拍板、以及隔了很久才回来的地方",
        outlineGapHours: { "\($0) 小时后" },
        outlineGapDays: { "\($0) 天后" },
        mindsSignedOffTip: "你在这个项目里放行过几件事",
        mindsSecDecisions: "你拍板的时刻",
        mindsDecisionsHint: "它把选择摆到你面前时,你说的那句话",
        mindsSecMilestones: "你点头的时刻",
        mindsMilestonesHint: "你说「继续」之前,它刚汇报完的那件事",
        mindsMilestonesCount: "件放行过的成果",
        mindsSecHeatmap: "活跃地图",
        mindsHeatmapHint: "近一年每天的对话量,点击查看当天",
        mindsSecWorkRhythm: "工作节奏",
        mindsWorkRhythmHint: "几点开工、哪天最忙、同时推几个项目",
        mindsSecLeverage: "杠杆率",
        mindsLeverageHint: "你打的字换回了多少",
        mindsSecMarathons: "马拉松对话",
        mindsMarathonsHint: "最长的几场,点击回看",
        mindsSecFaded: "不再说的词",
        mindsFadedHint: "以前常说，现在不提了",
        mindsSecOverview: "概览",
        mindsSecProjects: "项目节奏",
        mindsSecEntities: "高频实体",
        mindsSecPhrases: "你反复说的话",
        mindsPhrasesHint: "跨项目带着走的说法,你未必察觉",
        mindsSecVocabulary: "你的常用词",
        mindsSecAgentUsage: "被 AI 引用过的对话",
        mindsSecWeakSpots: "数不出来的部分",
        mindsConversationsUnit: "场对话",
        mindsToolsUnit: "个工具",
        mindsDaysUnit: "天跨度",
        mindsAllLocal: "全部本地采集",
        mindsActiveNow: "活跃中",
        mindsSpotPreferences: "工作偏好",
        mindsSpotStyle: "协作风格",
        mindsSpotGoals: "当前目标",
        mindsSpotStack: "常用技术",
        mindsBadgeUnreviewed: "AI 补充,待确认",
        mindsBadgeConfirmed: "已确认",
        mindsConfirm: "确认",
        mindsRevoke: "撤销",
        mindsSources: "证据",
        mindsSpotEmpty: "还空着，等你的 AI 来补",
        mindsEnrichHint: "这四格由你的 AI 来填：在 Claude Code 里说「读一下我的 Minds，把能补的空位用 minds_enrich 补上」。每条都要注明出自哪场对话，说不出出处的不收。",
        mindsEntitiesHint: "点击查看相关会话",
        mindsVocabularyHint: "从你说过的话里数出来的,点击可搜",
        mindsAgentUsageHint: "点击打开",
        mindsFileMissing: "Minds 还没生成,完成一次扫描后自动出现",
        emptySuggestTitle: "换个词试试——你的高频实体：",
        exportSectionTitle: "导出与备份",
        exportSectionBody: "对话数据已保存在本机。打开数据文件夹后，可自行复制、备份或迁移。",
        exportOpenFolder: "打开数据文件夹",
        refBadgeHelp: { "这场对话后来帮过你 \($0) 次——过去的你,帮了现在的你" },
        entityConvCount: { "\($0) 场相关会话" },
        entityCoOccurring: "与它共现——顺着找：",
        entityExitHelp: "退出实体导航",
        mindsInjectAction: "写进 CLAUDE.md",
        mindsInjectUpdate: "更新 CLAUDE.md 里的这段",
        mindsInjectRemove: "从 CLAUDE.md 移除",
        mindsInjectDone: "已写入 ~/.claude/CLAUDE.md",
        mindsInjectHint: { "\($0) 条已确认内容可注入" },
        mindsInjectConfirmTitle: "写入全局 CLAUDE.md？",
        mindsInjectConfirmBody: "只写入受管分节（带标记，可随时移除），你自己写的内容一个字不动。所有 Claude 会话开机即懂你。",
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
        copied: "已复制",
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
        deleteConvTitle: "删除这场对话?",
        deleteConvBody: "将从 MindBus 移除并删除归档副本。不影响 Claude Code / Codex 里的原始文件。此操作不可撤销。",
        deleteConvRescuedTitle: "永久删除最后副本?",
        deleteConvRescuedBody: "源文件已被工具清理,MindBus 的归档是这场对话在世上的唯一副本——删除后将永久消失,无法恢复。",
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
        updateAutoCheck: "自动检查更新"
    )

    static let en = Strings(
        wizardWindowTitle: "MindBus Setup",
        wizardSubtitle: "Setup",
        wizardStepSources: "Sources",
        wizardStepScan: "Scan",
        wizardStepComplete: "Finish",
        back: "Back",
        next: "Next",
        done: "Done",
        scanningEllipsis: "Scanning…",
        sourcesTitle: "MindBus will read conversations from these three places",
        sourcesSubtitle: "Read-only. Parsing and indexing happen entirely on this Mac — nothing goes online.",
        sourcesFootnoteLocal: "Your data always stays local. Click “Next” to start scanning.",
        sourcesFootnoteLogin: "MindBus starts at login to keep your vault up to date (turn this off anytime in System Settings)",
        scanTitleScanning: "Gathering your AI conversations…",
        scanTitleDone: "Scan complete",
        scanTitleBackground: "Scanning continues in the background",
        scanSubtitleScanning: "Scanning conversations from local AI tools",
        scanSubtitleDone: "Saved to your local vault",
        scanSubtitleBackground: "That's a lot of conversations — scanning continues in the background and they'll appear automatically",
        scanStatusDone: "Added to your vault",
        scanStatusBackground: "Scan started — it will finish on its own",
        completeTitle: "All set",
        completeBodyScanning: "Your AI conversations are still coming in — they'll appear as scanning finishes",
        completeBodyDone: "Your scattered AI conversations are now all in one place",
        completeHint: "Search, view, and relay to a new chat in one click",
        completeMenubarHint: "MindBus lives in your menu bar — press ⌘⇧H to come back anytime",
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
        mindsTrustSuffix: "counted, not generated",
        mindsGroupForYou: "FOR YOU · patterns you might have missed",
        mindsGroupForAI: "FOR YOUR AI · the profile agents consume",
        mindsSecUnfinished: "Unfinished threads",
        mindsUnfinishedHint: "the last word was yours — asked, not answered",
        mindsSecRecurring: "Recurring questions",
        mindsRecurringHint: "topics that keep coming back",
        mindsSecDormant: "Dormant projects",
        mindsDormantHint: "heavy investment, long untouched",
        mindsSecThisMonth: "This month",
        mindsThisMonthHint: "busier or quieter than last month",
        mindsSecStarred: "Starred",
        mindsStarredHint: "click to revisit the conversation",
        scanLiveCollected: "conversations collected",
        completeSanctuaryOngoing: { "\($0) conversations so far, still collecting — they have a second home now" },
        completeSanctuary: { "\($0) conversations collected — as of today, they have a second home" },
        completeSanctuaryOutlived: { "\($0) conversations collected · \($1) already outlived their source tool's cleanup" },
        mRhythmPeak: { "most conversations start \($0) — \($1)% (\($2) of \($3))" },
        mRhythmBusiest: { "busiest day \($0) — \($1) conversations (\($2)% of everything)" },
        mRhythmJuggle: { "you juggle \($0) projects per active day — peak \($1) on \($2)" },
        mRhythmActive: { "active \($0) of the last \($1) days — longest run \($2), longest break \($3)" },
        mRhythmWeek: { "this week so far: \($0) — P\($1) of your own history (median \($2))" },
        mShapeTurns: { "\($0)% of conversations run 16+ of your turns — you co-work, you don't just ask" },
        mShapeBimodal: { "two-peaked sessions: \($0)% under 2 min, \($1)% over 2 h" },
        mShapeAvg: { "average message \($0) chars — short directives, not essays" },
        mWeekendLine: { "weekend: \($0)" },
        mWeekdayLine: { "weekdays: \($0)" },
        mMonthDelta: { $0 >= 0 ? "+\($0) vs last month" : "\($0) vs last month" },
        mMonthTools: { "tools: \($0)" },
        mMonthFirstSeen: { "first seen this month: \($0)" },
        mMonthLastYear: { "same month last year: \($0)" },
        mLeverageLine: { "you typed \($0); the conversations hold \($1)" },
        mLeverageBooks: { "≈ \($0) books of your own writing, inside ≈ \($1) books of work" },
        mConvSpan: { "\($0) conversations · \($1)" },
        mDormantMeta: { "\($0) conversations, last touched \($1)" },
        mFadedMeta: { "said \($0)× · silent \($1) days" },
        mBriefSaid: { "said \($0)× · across \($1) conversations" },
        mBriefSpan: { "over \($0) days" },
        mFlowShared: { "\($0) shared concepts" },
        mFlowBorn: { " · \($0) born in \($1) first" },
        mMarathonMeta: { "\($0) messages · over \($1) · \($2)" },
        mSpanDays: { "\($0) days" },
        mSpanHours: { "\($0) h" },
        mRaritiesNight: { "deepest night: \($0) \($1) you started \"\($2)\"" },
        mRaritiesOnce: { "asked once, never again: \($0)" },
        mRaritiesRare: { "your rare words: \($0)" },
        mPoliteness: { "politeness & delegation: \($0)" },
        rescuedBadgeHelp: "The source file was cleaned up by its tool — this copy is kept by MindBus, forever",
        rescuedBanner: "The source of this conversation was deleted by its tool — you are reading MindBus's rescued copy",
        mindsMuteResurface: "Don't resurface this — hides it from On This Day only, not from lists or search",
        mVocabMindLabel: "MIND WORDS · travel with you across 5+ projects",
        mVocabWorkLabel: "WORK WORDS",
        mVocabMindMeta: { "\($0)× · \($1) projects" },
        mVocabWorkMeta: { "\($0)×" },
        mindsSecQuestionShape: "Question Shape",
        mindsQuestionShapeHint: "which cognitive layer your questions live in",
        mindsGroupRhythm: "Your rhythm",
        mindsGroupHowYouUseAI: "How you use AI",
        mindsGroupLanguage: "Your language",
        mindsGroupProjects: "Your projects",
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
        mindsSecFirstWords: "First Words",
        mindsFirstWordsHint: "how each project began · click to revisit",
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
        mindsSecSanctuary: "Sanctuary",
        mindsSanctuaryHint: "on your disk — no one takes it without you",
        mindsSecShape: "Collaboration Shape",
        mindsShapeHint: "you co-work, you don't just ask",
        mShapeDurationTitle: "SESSION LENGTH",
        mShapeTurnTitle: "TURNS",
        mindsSecWeekend: "Weekend Self",
        mindsWeekendHint: "which project owns your weekends",
        mindsSecFlows: "Knowledge Flows",
        mindsFlowsHint: "concepts your projects share",
        mindsProjectsHint: "click to expand history",
        mProjColName: "PROJECT",
        mProjColCount: "RUNS",
        mProjColLeverage: "LEVERAGE",
        mHeatActiveDays: "ACTIVE DAYS",
        mHeatLongestRun: "LONGEST RUN",
        mHeatLongestGap: "LONGEST GAP",
        mProjLeverageTop: "your words stretch furthest in %@ — 1 char typed, %d back",
        mindsSecOnThisDay: "On This Day",
        mindsOnThisDayHint: "same date, earlier chapters",
        mindsSecInvokedNames: "Names You Invoke",
        mindsInvokedNamesHint: "the people you keep citing, counted",
        mInvokedMeta: { "\($0)x, \($1) chats" },
        mindsSecCatchphrases: "Catchphrases",
        mindsCatchphrasesHint: "short messages you send again and again",
        mindsSecRarities: "Rarities",
        mindsRaritiesHint: "deepest night · asked once · rare words",
        mindsSecTaught: "Words It Taught You",
        mindsTaughtHint: "it used them first — you picked them up and carried them on",
        mindsTaughtMeta: { "picked up \($0)d later · \($1) projects" },
        mindsSecOpenLoops: "Open Loops",
        mindsOpenLoopsHint: "it asked, you never answered — still waiting on you",
        forgottenHelp: "related work old enough that you have probably forgotten it",
        forgottenTitle: "You may have forgotten",
        outlineHelp: "outline: what you signed off, what you called, and where you came back",
        outlineGapHours: { "\($0)h later" },
        outlineGapDays: { "\($0)d later" },
        mindsSignedOffTip: "how many things you signed off in this project",
        mindsSecDecisions: "Your Calls",
        mindsDecisionsHint: "what you said when it put the options in front of you",
        mindsSecMilestones: "Signed Off",
        mindsMilestonesHint: "what it had just reported when you said OK",
        mindsMilestonesCount: "signed off",
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
        mindsSecOverview: "Overview",
        mindsSecProjects: "Project Rhythm",
        mindsSecEntities: "Top Entities",
        mindsSecPhrases: "Phrases You Repeat",
        mindsPhrasesHint: "turns of phrase you carry across projects",
        mindsSecVocabulary: "Your Concept Map",
        mindsSecAgentUsage: "Referenced by Agents",
        mindsSecWeakSpots: "What Mechanics Cannot Know",
        mindsConversationsUnit: "conversations",
        mindsToolsUnit: "tools",
        mindsDaysUnit: "days",
        mindsAllLocal: "all captured locally",
        mindsActiveNow: "active",
        mindsSpotPreferences: "Working preferences",
        mindsSpotStyle: "Collaboration style",
        mindsSpotGoals: "Current goals",
        mindsSpotStack: "Tech stack (self-reported)",
        mindsBadgeUnreviewed: "AI-added · unreviewed",
        mindsBadgeConfirmed: "Confirmed",
        mindsConfirm: "Confirm",
        mindsRevoke: "Revoke",
        mindsSources: "Sources",
        mindsSpotEmpty: "Empty — waiting to be filled",
        mindsEnrichHint: "These four slots are filled by your AI tools. In Claude Code, say: \"Read my Minds and fill what you can via minds_enrich.\" Every addition must cite source conversations — fabrication is rejected.",
        mindsEntitiesHint: "click to see related conversations",
        mindsVocabularyHint: "your personal lexicon, statistically grown · click to search",
        mindsAgentUsageHint: "click to open",
        mindsFileMissing: "Minds not built yet — it appears after the first scan",
        emptySuggestTitle: "Try one of your frequent entities:",
        exportSectionTitle: "Export & Backup",
        exportSectionBody: "Your conversation data lives on this Mac. Open the data folder to copy, back up, or migrate it yourself.",
        exportOpenFolder: "Open Data Folder",
        refBadgeHelp: { "This conversation helped you \($0) time(s) since — your past self, helping your present self" },
        entityConvCount: { "\($0) related conversation(s)" },
        entityCoOccurring: "Co-occurring — follow the thread:",
        entityExitHelp: "Exit entity navigation",
        mindsInjectAction: "Inject into CLAUDE.md",
        mindsInjectUpdate: "Update CLAUDE.md injection",
        mindsInjectRemove: "Remove injection",
        mindsInjectDone: "Written to ~/.claude/CLAUDE.md",
        mindsInjectHint: { "\($0) confirmed item(s) ready" },
        mindsInjectConfirmTitle: "Write to global CLAUDE.md?",
        mindsInjectConfirmBody: "Only a managed section is written (marked, removable anytime); your own content is untouched. Every Claude session starts knowing you.",
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
        fabRelay: "Copy & relay",
        fabWorking: "Preparing…",
        copied: "Copied",
        fabHelp: "Copies the key context of this conversation — paste it into another AI to keep going.\nAdjust how it copies in Settings; by default code is stripped and a handoff note is included.",
        scopeFullMeta: { $0 == 1 ? "Full conversation · 1 message" : "Full conversation · \($0) messages" },
        scopeSelectedMeta: { $0 == 1 ? "1 selected · copies selection only" : "\($0) selected · copies selection only" },
        restoreFullScope: "Restore full conversation",
        scopeSwitchHint: "Unselected messages won't be copied",
        fabRelayCount: { "Copy & relay · \($0)" },
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
        updateAutoCheck: "Check for updates automatically"
    )
}
