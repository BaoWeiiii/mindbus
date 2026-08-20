import Foundation
import MindBusCore

/// 图表数据快照：进入 Minds 时后台取一次，页面只读。
///
/// 存在理由（2026-08-13 内存取证）：这些查询原本直接写在 body 里，hover/滚动
/// 引发的每次 body 重算都会全量拉 1.3M 字符语料重新分配，malloc 高水位只升不降。
struct MindsViz {
    var hourly24: [Int] = []
    var weekday7: [Int] = []
    var monthlyFlow: [(month: String, count: Int)] = []
    var shape: ConversationIndex.CollaborationShape?
    var volume: (userChars: Int, totalChars: Int) = (0, 0)
    var dailyHeat: [(day: String, count: Int)] = []
    var fadedSeries: [String: [Int]] = [:]
    var earliest: Date?
    var sanctuary: ConversationIndex.SanctuaryStats?
    var vault: (files: Int, bytes: Int64) = (0, 0)
    var rescuedCount: Int = 0
    var busiest: (day: String, count: Int, messages: Int)?
    var switching: (avgPerDay: Double, peak: (day: String, count: Int)?) = (0, nil)
    var activeDays: MindsBuilder.ActiveDays?
    var weekPercentile: (thisWeek: Int, percentile: Int, median: Int)?
    var weekendSplit: (weekday: [ConversationIndex.FacetCount], weekend: [ConversationIndex.FacetCount]) = ([], [])
    var month: (cur: [ConversationIndex.FacetCount], prev: [ConversationIndex.FacetCount],
                newEntities: [String], lastYear: Int) = ([], [], [], 0)
    var latestNight: (thread: ConversationIndex.UnfinishedThread, clock: String)?
    /// 你点头/拍板的时刻。走 viz 而不是 md 文本:这一层是**特征**,
    /// UI 要拿它当入口跳回原文,必须带着会话与消息 id——md 是给人读的格式,
    /// 塞 id 进去既难看又要再解析一遍。
    /// 还没点亮的能力层(空 = 全亮,卡片隐藏)
    var pending: [MindsBuilder.PendingCapability] = []
    var milestones: [(m: MindsMilestones.Milestone, convID: String)] = []
    var decisions: [(d: MindsMilestones.Decision, convID: String)] = []

    /// 本月 / 上月对话数——总览页环比只有这一项算得出来
    var thisMonth: Int { month.cur.reduce(0) { $0 + $1.count } }
    var lastMonth: Int { month.prev.reduce(0) { $0 + $1.count } }

    /// 纯取数（后台执行）：只读 index 的 nonisolated 查询，不碰任何 @Published 状态。
    nonisolated static func build(store: ConversationStore,
                                 fadedWords: [String],
                                 rescuedCount: Int) -> MindsViz {
        var v = MindsViz()
        v.hourly24 = store.vizHourly24()
        v.weekday7 = store.vizWeekday7()
        v.monthlyFlow = store.vizMonthlyFlow()
        v.shape = store.vizShape()
        v.volume = store.vizVolume()
        v.dailyHeat = store.dailyHeat()
        v.earliest = store.vizEarliest()
        v.fadedSeries = store.vizFadedSeries(words: fadedWords)
        v.sanctuary = store.vizSanctuary()
        v.vault = store.vizVault()
        v.rescuedCount = rescuedCount
        v.busiest = store.vizBusiest()
        v.switching = store.vizSwitching()
        v.activeDays = MindsBuilder.activeDays(daily: v.dailyHeat, window: 365)
        let weekly = store.vizWeekly()
        if let lastWeek = weekly.last?.week {
            v.weekPercentile = MindsBuilder.weekPercentile(weekly: weekly, currentWeek: lastWeek)
        }
        v.weekendSplit = store.vizWeekendSplit()
        v.month = store.vizMonth()
        v.latestNight = store.vizLatestNight()
        v.pending = store.vizPendingCapabilities()
        let (stones, calls) = store.vizSignedOff()
        v.milestones = stones
        v.decisions = calls
        return v
    }
}
