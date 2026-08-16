import Foundation

/// 思脉底座 · 机械层：从索引统计生成 `minds.md`（design spec §2）。
///
/// 结构分两半（2026-08-12 重构，源于用户实锤「里面看起来有价值的信息太少」）：
/// **惊喜区在前**——信息价值 = 意外度，Top-N 频次对用户本人意外度趋零（词是他自己
/// 打的），真正值钱的是他自己没意识到的模式：断点（UNFINISHED）/ 反复回来的问题
/// （RECURRING）/ 沉睡的重投入（DORMANT）/ 本月变化（THIS MONTH）/ 你标记的重点
/// （STARRED）。**统计区在后**——原五节（OVERVIEW / PROJECT RHYTHM / TOP ENTITIES /
/// VOCABULARY / AGENT USAGE）全数保留（用户定案：看得见的也要），它们对 agent
/// 仍是高价值画像。VOCABULARY 从 v14 起按 **user 语料**数频次——全语料以 AI 输出
/// 为主，按它数出来的是 AI 的语言习惯，不是你的。
///
/// 全部零 LLM——每一行都是某条 SQL 查询结果的直接转写，"陈述可证"是这一层存在的
/// 全部理由。末节 WEAK SPOTS 是机械层证明不了的四个空位，只列出 `MindsEnrichedLog`
/// 里已经补进来的条目（宿主模型 enrich、用户 confirm/revoke），这一层本身不生成
/// 任何文字、不调用任何模型。
///
/// 重建时机：`LoaderRuntime.indexAllSources` 收尾，顺序排在词表重建
/// （`ConversationIndex.rebuildLexiconIfNeeded`）与 MCP 引用汇入
/// （`ConversationIndex.ingestRefLog`）之后——VOCABULARY 节消费前者的产出、
/// AGENT USAGE 节消费后者的产出，颠倒顺序会让本轮重建看到上一轮的旧数据。
public enum MindsBuilder {

    // MARK: - 落盘路径

    /// `~/.mindbus/minds/minds.md`。根目录解析复用 `MindsEnrichedLog.mindsRoot()`
    /// （含 `MINDBUS_MINDS_ROOT` 覆盖 + `~` 展开 + 空白 trim）——`minds.md` 与
    /// `enriched.jsonl` 同目录，解析逻辑只能有一处真相，两处各写一遍环境变量处理
    /// 迟早会在某个边界条件上漂移（比如日后 trim 规则改了，只改了一处）。
    public static var defaultMindsURL: URL {
        MindsEnrichedLog.mindsRoot().appendingPathComponent("minds.md")
    }

    /// 五节机械内容与 WEAK SPOTS 之间的固定分隔标记，独占一行。
    ///
    /// 存在理由：`enriched.jsonl` 随时可能被 MCP 进程 append（用户/宿主模型经
    /// `minds_enrich`/确认/撤销不会等下一轮扫描），而 `minds.md` 只在扫描收尾重建——
    /// 两者之间必然有窗口期，磁盘上的 WEAK SPOTS 在窗口期内是过期的。未来的
    /// `minds_read`（Task 3）读文件时以这一行为界：前半截（五节机械内容）照抄磁盘
    /// 字节，后半截丢弃，改用 `renderWeakSpots(entries: MindsEnrichedLog.entries())`
    /// 现查现渲染拼回去——磁盘文件本身仍是"上次扫描时"的快照，但读出去给外部 agent
    /// 的内容永远新鲜。公开成常量而不是让 Task 3 另外硬编码同一个字符串字面量：
    /// 分隔标记只能有一处真相。
    public static let weakSpotsMarker = "<!-- weak-spots -->"

    // MARK: - 落盘入口

    /// 查询索引统计 → 渲染六节 → 原子写 `url`。
    ///
    /// WEAK SPOTS 的条目来自 `MindsEnrichedLog.entries()`（默认路径，同样受
    /// `MINDBUS_MINDS_ROOT` 覆盖）——`enriched.jsonl` 不存在时 `entries()` 返回空数组，
    /// 四个空位落空态文案 `(empty — fill via minds_enrich)`，不是错误。
    ///
    /// 目标目录首次不存在时自动建出来（同 `MindsEnrichedLog.writeLine` 的手法），不能
    /// 指望调用方（扫描收尾）提前建好；写失败（磁盘满/权限问题）静默放弃——这只是
    /// 扫描收尾众多步骤之一，不该让 minds.md 写不出去拖垮整轮扫描，下一轮扫描收尾
    /// 会自然重试（幂等重建，没有"部分写入"的中间状态需要清理）。
    public static func build(from index: ConversationIndex, to url: URL = defaultMindsURL) {
        let now = Date()
        let overview = index.mapOverview()
        let allProjects = projectRhythms(index: index, projects: overview.byProject)
        let projects = Array(allProjects.prefix(10))
        // VOCABULARY 从 v14 起按 user 语料数 tf——「你的高频词」必须是你说过的
        // vocabFreqs 在语料拉取之后算(共享同一份,不再独立拉)
        var vocabFreqs: [String: Int] = [:]
        let refs = index.topReferenced(limit: Int.max)
        let entries = MindsEnrichedLog.entries()

        // 惊喜区数据（阈值集中在这里，渲染函数只收结果）：
        // 断点近 14 天；反复回来 ≥3 会话跨 ≥7 天、排除 Top-10 主项目词；
        // 沉睡 ≥10 会话且 >30 天没碰；本月对比自然月。
        var surprise = SurpriseData(
            unfinished: index.unfinishedThreads(since: now.addingTimeInterval(-14 * 86_400), limit: 5),
            recurring: index.recurringEntities(minConversations: 3, minSpanDays: 7,
                                               excludeTop: 10, limit: 10),
            dormant: allProjects.filter { $0.count >= 10 && $0.lastTouched < now.addingTimeInterval(-30 * 86_400) }
                .sorted { $0.count > $1.count }.prefix(5).map { $0 },
            monthCurrent: index.sourceCounts(from: monthStart(of: now), to: now.addingTimeInterval(1)),
            monthPrevious: index.sourceCounts(from: monthStart(of: monthStart(of: now).addingTimeInterval(-1)),
                                              to: monthStart(of: now)),
            newEntities: index.newEntities(since: monthStart(of: now), limit: 8))
        // 排除与项目尾名重合的实体:项目名是容器不是「反复回来的问题」
        // (「我反复聊 MindBus」零意外度——MindBus 就是本项目)
        let projectTails = Set(overview.byProject.map {
            ($0.key as NSString).lastPathComponent.lowercased()
        })
        surprise.hourQuarters = index.hourQuarterHistogram()
        surprise.busiestDay = index.busiestDay()
        surprise.switching = index.projectSwitching()
        surprise.volume = index.corpusVolume()
        surprise.marathons = index.marathons(limit: 3)
        // 语料单次拉取(内存优化):三个消费者共享同一份,map 派生零拷贝
        let corpusRows = index.userCorpusRows()
        surprise.fadedWords = fadedWords(corpus: corpusRows.map { (text: $0.text, startAt: $0.startAt) },
                                         lexicon: index.loadLexicon(), now: now, limit: 5)
        // 词表画像:tf + 跨项目数(思维词/项目词分组的数据源)
        let vocabStats = userVocabularyStats(lexicon: index.loadLexicon(),
                                             corpus: corpusRows.map { (text: $0.text, cwd: $0.cwd) })
        let corpus = corpusRows.map(\.text)
        vocabFreqs = userVocabularyFrequencies(index: index, corpus: corpus)
        let vocabulary = rankVocabulary(frequencies: vocabFreqs, limit: 20)
        surprise.catchphrases = catchphrases(corpus: corpus, limit: 5)
        surprise.politeness = politeness(corpus: corpus)
        // 窗口取 min(365, 库龄):库才 112 天时「46/365」显得懒散,真相是 41% 活跃
        let libraryDays = index.sanctuaryStats(now: now).earliest
            .map { max(1, Int(now.timeIntervalSince($0) / 86_400) + 1) } ?? 365
        surprise.activeDays = activeDays(daily: index.dailyCounts(days: 365, now: now),
                                         window: min(365, libraryDays))
        // B 批:个人史百分位 + 去年同月(多年纵深口径——数据不满一年自动 nil 不渲染)。
        // 「本周」取 weeklyCounts 的最后一个 key——SQL strftime 的周号与 Calendar 周号
        // 可能差 1,统一用 SQL 侧口径,最近的周就是本周(库里最新会话所在周)。
        let weekly = index.weeklyCounts()
        if let lastWeek = weekly.last?.week {
            surprise.weekPercentile = weekPercentile(weekly: weekly, currentWeek: lastWeek)
        }
        let ymF = DateFormatter()
        ymF.locale = Locale(identifier: "en_US_POSIX")
        ymF.timeZone = TimeZone.current
        ymF.dateFormat = "yyyy-MM"
        if let lastYear = Calendar.current.date(byAdding: .year, value: -1, to: now) {
            let n = index.monthTotal(yearMonth: ymF.string(from: lastYear))
            surprise.lastYearSameMonth = n > 0 ? n : nil
        }
        // 五批:守护状态(vault 扫描毫秒级:百级文件)
        surprise.sanctuary = index.sanctuaryStats(now: now)
        let vault = vaultFootprint()
        surprise.vaultFiles = vault.files
        surprise.vaultBytes = vault.bytes
        // 已救回:源没了、副本还在(与详情回退同口径)——145 行 stat 毫秒级
        surprise.rescuedCount = index.conversationPaths()
            .filter { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0)
                      && VaultArchive.hasArchive(sourcePath: $0) }.count
        // 观察项 A:反复交代的话(聚类毫秒级:候选千级、倒排有界)
        surprise.questionShape = questionShape(corpus: corpus)
        surprise.delegationVerbs = delegationVerbs(
            corpus: corpusRows.map { (text: $0.text, convID: $0.convID) }, limit: 10)
        surprise.researchDestinations = researchDestinations(corpus: corpus)
        surprise.repeatedBriefings = repeatedBriefings(
            corpus: corpusRows.map { (text: $0.text, convID: $0.convID) }, limit: 5)
        // 四批:结构与关系维度
        surprise.shape = index.collaborationShape()
        surprise.weekendSplit = index.weekendSplit(minCount: 2)
        surprise.projectLeverage = index.projectLeverage(minConversations: 5, limit: 5)

        let mechanical = renderDocument(overview: overview, projects: projects,
                                        vocabulary: vocabulary, vocabStats: vocabStats,
                                        refs: refs, surprise: surprise, builtAt: now)
        let full = mechanical + "\n\n" + weakSpotsMarker + "\n" + renderWeakSpots(entries: entries)

        guard let data = full.data(using: .utf8) else {
            NSLog("[minds] build failed: could not UTF-8 encode rendered document")
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[minds] build failed to write %@: %@", url.path, String(describing: error))
        }
    }

    // MARK: - CLAUDE.md 注入文本

    /// confirmed 条目全量 + 机械层紧凑版（spec §5）：OVERVIEW 一行 + TOP ENTITIES 前 10 +
    /// VOCABULARY 前 10。`unreviewed`/`revoked` 条目绝不出现——这是 CLAUDE.md 出口的
    /// 闸门，人在环红线（spec §6"闸在 CLAUDE.md 出口"）就落在下面这一行 `filter` 上，
    /// 不是靠调用方自觉只传 confirmed 条目进来（`entries` 参数本就是全量三态混合，
    /// 过滤是这个函数自己不可外包的职责）。
    public static func renderForInjection(index: ConversationIndex, entries: [MindsEntry]) -> String {
        let confirmed = entries.filter { $0.status == .confirmed }
        let overview = index.mapOverview()
        // 注入口径(2026-08-13):思维词优先——agent 该先知道跟「人」走的词
        let stats = userVocabularyStats(lexicon: index.loadLexicon(),
                                        corpus: index.userCorpusRows().map { (text: $0.text, cwd: $0.cwd) })
        let n = max(overview.conversationCount, 1)
        let mindFirst = stats
            .filter { Double($0.df) / Double(n) < stopwordDFRatio }
            .sorted {
                let a = $0.projects >= mindWordMinProjects, b = $1.projects >= mindWordMinProjects
                if a != b { return a }
                return $0.tf != $1.tf ? $0.tf > $1.tf : $0.word < $1.word
            }
        let vocabulary = mindFirst.prefix(10).map { (word: $0.word, df: $0.tf) }

        var lines = ["# Minds", ""]
        lines.append("## Confirmed")
        if confirmed.isEmpty {
            lines.append("(no confirmed entries yet)")
        } else {
            for e in confirmed {
                lines.append("- [\(e.spot.rawValue)] \(e.text) (sources: \(e.sources.joined(separator: ", ")))")
            }
        }
        lines.append("")
        lines.append("## Overview")
        lines.append(overviewHeadline(overview))
        lines.append("")
        lines.append("## Top entities")
        lines.append(compactList(Array(overview.topEntities.prefix(10))
            .map { (text: $0.text, count: $0.conversationCount) }))
        lines.append("")
        lines.append("## Vocabulary")
        lines.append(vocabulary.isEmpty ? "(none yet)" : vocabulary.map(\.word).joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    // MARK: - WEAK SPOTS（独立公共渲染入口——Task 3 的 minds_read 现场重渲染这一节）

    private static let spotDescriptions: [MindsSpot: String] = [
        .preferences: "working preferences",
        .style: "collaboration style",
        .goals: "current goals",
        .stack: "tech stack (self-reported)",
    ]

    /// WEAK SPOTS 节的独立渲染入口（spec §2 第 6 节）：纯函数，只读传入的 `entries`，
    /// 不碰索引、不碰文件——`minds_read`（Task 3）靠这一点才能在读取请求时现查
    /// `MindsEnrichedLog.entries()` 现渲染，绕开 minds.md 磁盘快照相对 `enriched.jsonl`
    /// 的过期窗口（见 `weakSpotsMarker` 的注释）。`build(from:to:)` 落盘时也调这同一份
    /// 实现，磁盘内容与"现渲染"内容在扫描那一刻是逐字节一致的。
    ///
    /// 四个空位固定顺序（`MindsSpot.allCases`，即声明顺序：preferences/style/goals/stack）。
    /// 每个空位下：`revoked` 条目整条不渲染（撤销的东西不该继续出现在给人看/给模型读
    /// 的文档里，"曾经存在过"这件事本身还留在 `enriched.jsonl` 里可考古，但不进这份
    /// 渲染）；`unreviewed` 条目带 `[unreviewed]` 前缀直出——不是不给看，是明确标出
    /// "未经确认"，读的人/模型自己判断要不要采信（与全项目"置信度而非过滤"的哲学
    /// 一致）；`confirmed` 条目直列，无前缀。空位（该 spot 下没有任何非 revoked 条目）
    /// 写死文案 `(empty — fill via minds_enrich)`——这句本身也是 `minds_enrich` 工具
    /// （Task 3）的用法提示，直接嵌在结果里比另开一段说明更醒目、更不会被跳过。
    ///
    /// 每条都带溯源与出处：`sources: id1, id2 · agent: xxx · yyyy-MM-dd`——design spec
    /// §3 的三条强制字段（溯源/模型戳/可撤销）里前两个直接体现在渲染文本里，第三个
    /// （可撤销）体现在"revoked 就从这份渲染里消失"这个行为本身。
    public static func renderWeakSpots(entries: [MindsEntry]) -> String {
        var lines = ["## WEAK SPOTS",
                     "Things the mechanical layer cannot know. Fill via minds_enrich with sources."]
        for spot in MindsSpot.allCases {
            lines.append("### \(spot.rawValue) — \(spotDescriptions[spot] ?? spot.rawValue)")
            let live = entries.filter { $0.spot == spot && $0.status != .revoked }
            if live.isEmpty {
                lines.append("(empty — fill via minds_enrich)")
            } else {
                for e in live {
                    let prefix = e.status == .unreviewed ? "[unreviewed] " : ""
                    lines.append("- \(prefix)\(e.text) (sources: \(e.sources.joined(separator: ", ")) · agent: \(e.agent) · \(day(e.createdAt)))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 惊喜区数据（build 查好注入，渲染纯函数）

    /// 惊喜区的全部数据。测试直接构造这个结构驱动渲染，不用碰索引。
    struct SurpriseData {
        var unfinished: [ConversationIndex.UnfinishedThread] = []
        var recurring: [ConversationIndex.RecurringEntity] = []
        var dormant: [ProjectRhythm] = []
        var monthCurrent: [ConversationIndex.FacetCount] = []
        var monthPrevious: [ConversationIndex.FacetCount] = []
        var newEntities: [ConversationIndex.EntityStat] = []
        // 2026-08-12 二批（继续按意外度挖掘）：作息指纹 / 杠杆率 / 马拉松 / 不再说的词
        var hourQuarters: [Int] = []                                  // 6 桶 × 4 小时
        var busiestDay: (day: String, count: Int)?
        var switching: (avgPerDay: Double, peak: (day: String, count: Int)?) = (0, nil)
        var volume: (userChars: Int, totalChars: Int) = (0, 0)
        var marathons: [ConversationIndex.Marathon] = []
        var fadedWords: [FadedWord] = []
        // 三批（行业调研 2026-08-12 落地）：那年今日 / 口头禅 / 独特性 / 活跃天数
        var onThisDay: [ConversationIndex.UnfinishedThread] = []
        var catchphrases: [(phrase: String, count: Int)] = []
        var politeness: [(word: String, count: Int)] = []
        var latestNight: (thread: ConversationIndex.UnfinishedThread, clock: String)?
        var oneOffTopics: [(text: String, at: Date)] = []
        var rareWords: [(word: String, count: Int)] = []
        var activeDays: ActiveDays = ActiveDays(active: 0, window: 0, longestRun: 0, longestGap: 0)
        // B 批:个人史百分位(本周量在自己历史的分位)与去年同月(数据不足为 nil)
        var weekPercentile: (thisWeek: Int, percentile: Int, median: Int)?
        var lastYearSameMonth: Int?
        // 四批(结构维度+关系维度,2026-08-12 抽象-发散推演落地):
        // 协作形状 / 周末人格 / 项目杠杆榜 / 知识流动
        // 五批(价值感调研落地):守护状态——免于失去的实证
        var sanctuary: ConversationIndex.SanctuaryStats?
        var vaultFiles: Int = 0
        var vaultBytes: Int64 = 0
        var rescuedCount: Int = 0
        // 观察项 A(2026-08-12):反复交代的话——「该沉淀成模板/Skill」的机械信号
        var repeatedBriefings: [RepeatedBriefing] = []
        // 2026-08-13 语料深读挖掘:提问形状(认知光谱)/项目出生句(创世叙事)
        var questionShape: [(kind: String, count: Int)] = []
        var delegationVerbs: [(verb: String, lines: Int, conversations: Int)] = []
        var researchDestinations: [(dest: String, count: Int)] = []
        var firstWords: [(project: String, quote: String, convID: String, at: Date)] = []
        var shape: ConversationIndex.CollaborationShape?
        var weekendSplit: (weekday: [ConversationIndex.FacetCount], weekend: [ConversationIndex.FacetCount]) = ([], [])
        var projectLeverage: [ConversationIndex.ProjectLeverage] = []
        var knowledgeFlows: [ConversationIndex.KnowledgeFlow] = []
    }

    /// 本周会话量在个人历史周分布里的百分位(0-100,越高=越忙)。
    /// 历史周 <4 个时返回 nil——分布太小,分位数没有意义。纯函数供测试。
    public static func weekPercentile(weekly: [(week: String, count: Int)],
                               currentWeek: String) -> (thisWeek: Int, percentile: Int, median: Int)? {
        let history = weekly.filter { $0.week != currentWeek }.map(\.count).sorted()
        guard history.count >= 4 else { return nil }
        let current = weekly.first { $0.week == currentWeek }?.count ?? 0
        let below = history.filter { $0 < current }.count
        let pct = below * 100 / history.count
        let median = history[history.count / 2]
        return (thisWeek: current, percentile: pct, median: median)
    }

    /// 委托光谱:QUESTION SHAPE 是「问」的光谱,这是「令」的光谱——你把 AI 当什么用。
    /// 真机分布:设计 215 > 验证 192 > 测试 182 > 优化 170 > … > 调研 64。
    /// 会话数同时给出:覆盖 40+ 场的动词才是稳定行为模式,不是某一天的口癖。
    static let delegationVerbList = ["设计", "验证", "测试", "优化", "检查", "分析",
                                     "修复", "开发", "调研", "审查", "对比", "重构",
                                     "整理", "总结", "部署"]

    static func delegationVerbs(corpus: [(text: String, convID: String)],
                                limit: Int) -> [(verb: String, lines: Int, conversations: Int)] {
        var lineCount: [String: Int] = [:]
        var convs: [String: Set<String>] = [:]
        for (text, cid) in corpus {
            for line in text.split(separator: "\n") {
                guard (5..<150).contains(line.count) else { continue }
                for v in delegationVerbList where line.contains(v) {
                    lineCount[v, default: 0] += 1
                    convs[v, default: []].insert(cid)
                }
            }
        }
        var out: [(verb: String, lines: Int, conversations: Int)] = []
        for (verb, lines) in lineCount {
            out.append((verb: verb, lines: lines, conversations: convs[verb]?.count ?? 0))
        }
        out.sort { $0.lines != $1.lines ? $0.lines > $1.lines : $0.verb < $1.verb }
        return Array(out.prefix(limit))
    }

    /// 调研的目的地:「调研」指令行内的平台/对象共现——「让 AI 去哪调研」。
    /// 真机:GitHub 断层第一(12/64)——用户自感「经常让去 github 调研」被数据证实。
    static let researchDestList = ["github", "论文", "竞品", "产品", "行业", "开源", "reddit", "最新"]

    static func researchDestinations(corpus: [String]) -> [(dest: String, count: Int)] {
        var counts: [String: Int] = [:]
        for text in corpus {
            for line in text.split(separator: "\n") where line.contains("调研") {
                let lower = line.lowercased()
                for d in researchDestList where lower.contains(d) {
                    counts[d, default: 0] += 1
                }
            }
        }
        return counts.map { (dest: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.dest < $1.dest }
    }

    /// 提问形状:你的问题落在哪个认知层——确认型(该不该)/方法型(怎么做)/
    /// 原因型(为什么)/定义型(是什么)。真机分布 286/206/94/89:用户最常让 AI
    /// 做判断确认,对自己的提问分布毫无自省——意外度极高的认知风格投影。
    static let questionKinds: [(kind: String, markers: [String])] = [
        ("confirm", ["是否", "要不要", "需不需要", "该不该", "能不能"]),
        ("how", ["怎么", "如何"]),
        ("why", ["为什么", "为啥"]),
        ("what", ["是什么", "什么是"]),
    ]

    static func questionShape(corpus: [String]) -> [(kind: String, count: Int)] {
        var counts: [String: Int] = [:]
        for text in corpus {
            for line in text.split(separator: "\n") {
                for (kind, markers) in questionKinds where markers.contains(where: { line.contains($0) }) {
                    counts[kind, default: 0] += 1
                }
            }
        }
        return questionKinds.map { (kind: $0.kind, count: counts[$0.kind] ?? 0) }
    }

    /// 项目出生句:从最早会话的 user 语料里取第一条像「人话」的行
    /// (5-100 字、非系统注入、非结构化粘贴——复用 briefingNoise 过滤)。
    /// enrich 管道:宿主模型 minds_read 读到这节 → 分析 → minds_enrich 写建议。
    public struct RepeatedBriefing: Equatable {
        public let sample: String        // 组内最长样本
        public let times: Int            // 讲过几遍(含同会话重复)
        public let conversations: Int    // 跨几个会话
        public init(sample: String, times: Int, conversations: Int) {
            self.sample = sample; self.times = times; self.conversations = conversations
        }
    }

    /// 噪声行:编号列表/引号/JSON 键值/markdown 标记——粘贴的结构化内容拆行后的残留,
    /// 不是「你讲的话」(2026-08-12 原型两轮过滤实证)。
    /// 三轮真机迭代:+`<`(image 占位符 120× 霸榜)、+`^[A-Za-z]\d+[:：]`(粘贴的
    /// 数据表行「L21:ACCA…」63×)、+`\w+=\S+.*\w+=\S+`(两个以上键值对=结构化数据)。
    private static let briefingNoise = try? NSRegularExpression(
        pattern: #"^\d+[.、)]|^["'{}\[<]|"\w+"\s*:|^[-*] |^#{1,6} |^[A-Za-z]\d+[:：]|\w+=\S+.*\w+=\S+"#)

    static func repeatedBriefings(corpus: [(text: String, convID: String)],
                                  limit: Int) -> [RepeatedBriefing] {
        // ① 候选行:14-80 字、含 CJK、非噪声
        var msgs: [(String, String)] = []
        for (text, cid) in corpus {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard (14...80).contains(t.count),
                      t.contains(where: { ("\u{4E00}"..."\u{9FFF}").contains($0) }) else { continue }
                if let re = briefingNoise,
                   re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { continue }
                msgs.append((t, cid))
            }
        }
        guard msgs.count >= 2 else { return [] }
        // ② 3-gram 倒排(每条前 20 个 gram 控制倒排;高频 gram 跳过=样板压制)
        func grams(_ s: String) -> Set<String> {
            let a = Array(s)
            guard a.count >= 3 else { return [] }
            return Set((0...(a.count - 3)).map { String(a[$0..<$0+3]) })
        }
        let G = msgs.map { grams($0.0) }
        var inv: [String: [Int]] = [:]
        for (i, g) in G.enumerated() {
            for x in g.prefix(20) { inv[x, default: []].append(i) }
        }
        var shared: [Int64: Int] = [:]   // (a<<32|b) → 共享 gram 数
        for (_, ids) in inv where ids.count <= 50 {
            for a in 0..<ids.count {
                for b in (a + 1)..<ids.count {
                    shared[Int64(ids[a]) << 32 | Int64(ids[b]), default: 0] += 1
                }
            }
        }
        // ③ Jaccard ≥0.5 连边 → 并查集聚类
        var parent = Array(0..<msgs.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        for (key, sh) in shared where sh >= 4 {
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            let ja = Double(G[a].intersection(G[b]).count) / Double(G[a].union(G[b]).count)
            guard ja >= 0.5, msgs[a].0 != msgs[b].0 || msgs[a].1 != msgs[b].1 else { continue }
            parent[find(a)] = find(b)
        }
        var groups: [Int: [Int]] = [:]
        for i in msgs.indices { groups[find(i), default: []].append(i) }
        // ④ 组 → 结果:≥3 遍且跨 ≥2 会话才算「反复交代」
        return groups.values.compactMap { ids -> RepeatedBriefing? in
            guard ids.count >= 3 else { return nil }
            let convs = Set(ids.map { msgs[$0].1 })
            guard convs.count >= 2 else { return nil }
            let sample = ids.map { msgs[$0].0 }.max(by: { $0.count < $1.count }) ?? ""
            return RepeatedBriefing(sample: sample, times: ids.count, conversations: convs.count)
        }
        .sorted { $0.times != $1.times ? $0.times > $1.times : $0.sample < $1.sample }
        .prefix(limit).map { $0 }
    }

    /// 词的近 N 个月出现次数序列(旧→新)——FADED 消退曲线用(「说得多→归零」的形状)。
    /// contains 计数与 segment 计数在概念词上近似等价(词不自重叠),注明近似即可。
    public static func monthlyOccurrences(corpus: [(text: String, startAt: Date)],
                                          word: String, monthsBack: Int, now: Date) -> [Int] {
        guard !word.isEmpty else { return [Int](repeating: 0, count: monthsBack) }
        let cal = Calendar.current
        var buckets = [Int](repeating: 0, count: monthsBack)
        let anchorMonth = monthStart(of: now)
        for (text, at) in corpus {
            guard let diff = cal.dateComponents([.month], from: monthStart(of: at), to: anchorMonth).month,
                  (0..<monthsBack).contains(diff) else { continue }
            var count = 0
            var searchRange = text.startIndex..<text.endIndex
            while let r = text.range(of: word, range: searchRange) {
                count += 1
                searchRange = r.upperBound..<text.endIndex
            }
            buckets[monthsBack - 1 - diff] += count
        }
        return buckets
    }

    /// 活跃天数摘要（flomo「记录天数」型中性指标——不做 Duolingo 式打卡焦虑,
    /// GitHub 2016 移除 streak 的教训:只陈述,不施压)。
    public struct ActiveDays: Equatable {
        public let active: Int        // 窗口内有对话的天数
        public let window: Int        // 窗口天数
        public let longestRun: Int    // 最长连续活跃天数
        public let longestGap: Int    // 最长间歇天数（活跃日之间）
        public init(active: Int, window: Int, longestRun: Int, longestGap: Int) {
            self.active = active; self.window = window
            self.longestRun = longestRun; self.longestGap = longestGap
        }
    }

    /// 从 `dailyCounts` 的有序日期序列算活跃摘要。纯函数供测试。
    public static func activeDays(daily: [(day: String, count: Int)], window: Int) -> ActiveDays {
        guard !daily.isEmpty else {
            return ActiveDays(active: 0, window: window, longestRun: 0, longestGap: 0)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        let dates = daily.compactMap { f.date(from: $0.day) }.sorted()
        var longestRun = 1, run = 1, longestGap = 0
        for i in 1..<dates.count {
            let gapDays = Int(round(dates[i].timeIntervalSince(dates[i - 1]) / 86_400))
            if gapDays == 1 { run += 1; longestRun = max(longestRun, run) }
            else { run = 1; longestGap = max(longestGap, gapDays - 1) }
        }
        return ActiveDays(active: daily.count, window: window,
                          longestRun: longestRun, longestGap: longestGap)
    }

    /// 口头禅：user 语料按行拆（`Segmenter.userText` 用 \n 连接,每行=一条 user 消息）,
    /// 长度 ≤ `maxLen` 的整句计数——「继续 ×47」这种短句才叫口头禅,长消息各不相同。
    /// Kapwing 给 ChatGPT 数 please/thank you 次数是同类先例。纯函数供测试。
    public static func catchphrases(corpus: [String], maxLen: Int = 8, limit: Int) -> [(phrase: String, count: Int)] {
        var counts: [String: Int] = [:]
        for text in corpus {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.count <= maxLen else { continue }
                // 首字符必须是文字(字母/CJK)——user 消息里粘贴的代码/标记拆行后,
                // 纯符号行(}, ×1106)与标记语法行(</image> ×238、```text ×113)会以
                // 百千次量级霸榜(2026-08-12 真实数据两轮现场),那是语法不是你的话。
                // 「继续」「好的」「ok」首字符都是文字;标记行首字符是 <、`、[。
                guard let first = t.first, first.isLetter else { continue }
                counts[t, default: 0] += 1
            }
        }
        return counts.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { (phrase: $0.key, count: $0.value) }
    }

    /// 礼貌与委托用语计数：包含该词的 user 消息行数。好玩、无害、机械可证。
    static let politenessMarkers = ["谢谢", "帮我", "麻烦", "please", "thanks", "thank you"]

    static func politeness(corpus: [String]) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        for text in corpus {
            for line in text.split(separator: "\n") {
                let lower = line.lowercased()
                for marker in politenessMarkers where lower.contains(marker) {
                    counts[marker, default: 0] += 1
                }
            }
        }
        // "thanks" 与 "thank you" 有包含关系:行含 "thank you" 时两者都计,
        // 展示取计数高者即可,不做互斥——口径简单可解释优先。
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (word: $0.key, count: $0.value) }
    }

    /// 不再说的词：历史上说得多（≥`fadedMinTotal` 次）、近 `fadedSilentDays` 天一次没说。
    /// 话题迁移的机械痕迹——「你 5 月满嘴协变量，之后再没提过」。
    struct FadedWord: Equatable {
        let word: String
        let totalCount: Int
        let silentDays: Int
    }

    static let fadedMinTotal = 15
    static let fadedSilentDays = 60

    /// 从带时间的 user 语料算 faded 词：对每个词表词累计 tf 与最后一次说的时间，
    /// 总 tf 达标且最后一次早于窗口起点的按 tf 降序取前 `limit`。纯函数供测试注入。
    static func fadedWords(corpus: [(text: String, startAt: Date)],
                           lexicon: Set<String>, now: Date, limit: Int) -> [FadedWord] {
        guard !lexicon.isEmpty else { return [] }
        var total: [String: Int] = [:]
        var lastSaid: [String: Date] = [:]
        for (text, at) in corpus {
            for token in PersonalLexicon.segment(text, lexicon: lexicon).split(separator: " ") {
                let w = String(token)
                guard lexicon.contains(w) else { continue }
                total[w, default: 0] += 1
                if lastSaid[w].map({ $0 < at }) ?? true { lastSaid[w] = at }
            }
        }
        let cutoff = now.addingTimeInterval(-Double(fadedSilentDays) * 86_400)
        return total.filter { $0.value >= fadedMinTotal }
            .compactMap { word, count -> FadedWord? in
                guard let last = lastSaid[word], last < cutoff else { return nil }
                let silent = Int(now.timeIntervalSince(last) / 86_400)
                return FadedWord(word: word, totalCount: count, silentDays: silent)
            }
            .sorted { $0.totalCount != $1.totalCount ? $0.totalCount > $1.totalCount
                                                     : $0.word < $1.word }
            .prefix(limit).map { $0 }
    }

    /// 自然月起点（本机时区）。
    public static func monthStart(of date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// vault 归档体量:份数与字节。百级文件的浅遍历,扫描收尾跑一次,毫秒级。
    /// `root` 可注入供测试;默认真实 vault 目录。
    public static func vaultFootprint(root: URL = VaultArchive.defaultRoot) -> (files: Int, bytes: Int64) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in e {
            guard url.pathExtension == "lzma" else { continue }
            files += 1
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files, bytes)
    }

    /// user 语料的词表词**总出现次数**（term frequency）：对每份会话级 user 语料
    /// 切词（同索引第三路的 `PersonalLexicon.segment`），累加每个词表词说过几次。
    /// 词表本身仍从全语料学（`loadLexicon`）——学词需要尽量多的语料；**数频次**
    /// 才换成 user 口径，两步分工不同。
    ///
    /// 为什么是 tf 不是 df（2026-08-12 用户实测「还是没看到第一性原理」后改）：
    /// 用户心智里的「我的高频词」是「我说了多少次」，不是「我在几个会话里提过」——
    /// 真实数据「第一性原理」说了 25 次却因 df 口径排第 10，被淹没在 chips 流里。
    /// df 防刷屏的理由在这里不成立：user 语料是用户自己说的话，自己反复说恰恰是
    /// 「真高频」本身，不是要防的噪音。
    /// 词表为空或 user 语料全空 → 空字典，VOCABULARY 落 `(none yet)`，不是错误。
    /// `lexicon` 可注入（测试隔离「数频次」与「学词」两个阶段；生产不传）。
    /// 词的完整画像:tf(说过几次)+ 跨项目数。
    /// 「思维词汇」与「项目词汇」的分界(2026-08-13,用户三问「第一性原理」定案):
    /// 跨 ≥mindWordMinProjects 个项目的词跟着**人**走(第一性原理跨 12 个项目),
    /// 只活在少数项目里的词跟着**事**走(「所有事件类型」×120 但只 1 个项目)——
    /// 纯频次榜上后者天然碾压前者,身份词永远浮不上来。
    public static let mindWordMinProjects = 5

    public struct VocabWord: Equatable {
        public let word: String
        public let tf: Int
        public let projects: Int
        /// 会话文档频率:出现在几场会话——口头语与概念词的第一性分界
        /// (真机分布:概念词 ≤15% 会话,口头语 ≥34%,中间是空沟)。
        public let df: Int
        public init(word: String, tf: Int, projects: Int, df: Int = 0) {
            self.word = word; self.tf = tf; self.projects = projects; self.df = df
        }
    }

    static func userVocabularyStats(lexicon: Set<String>,
                                    corpus: [(text: String, cwd: String)]) -> [VocabWord] {
        guard !lexicon.isEmpty else { return [] }
        var tf: [String: Int] = [:]
        var projs: [String: Set<String>] = [:]
        var df: [String: Int] = [:]
        for (text, cwd) in corpus {
            var seen = Set<String>()
            for token in PersonalLexicon.segment(text, lexicon: lexicon).split(separator: " ") {
                let w = String(token)
                guard lexicon.contains(w) else { continue }
                tf[w, default: 0] += 1
                if !cwd.isEmpty { projs[w, default: []].insert(cwd) }
                if seen.insert(w).inserted { df[w, default: 0] += 1 }
            }
        }
        return tf.map { VocabWord(word: $0.key, tf: $0.value,
                                  projects: projs[$0.key]?.count ?? 0, df: df[$0.key] ?? 0) }
    }

    static func userVocabularyFrequencies(index: ConversationIndex,
                                          lexicon injected: Set<String>? = nil,
                                          corpus injectedCorpus: [String]? = nil) -> [String: Int] {
        let lexicon = injected ?? index.loadLexicon()
        guard !lexicon.isEmpty else { return [:] }
        var tf: [String: Int] = [:]
        for text in injectedCorpus ?? index.userCorpusTexts() {
            for token in PersonalLexicon.segment(text, lexicon: lexicon).split(separator: " ") {
                let w = String(token)
                if lexicon.contains(w) { tf[w, default: 0] += 1 }
            }
        }
        return tf
    }

    // MARK: - 纯渲染（接受注入的统计数据结构，不碰索引/文件，供测试直接驱动）

    /// 惊喜区（五节）+ 统计区（五节）（不含 WEAK SPOTS——那一节走独立的
    /// `renderWeakSpots`，两者在 `build(from:to:)` 里用 `weakSpotsMarker` 拼接）。
    /// `builtAt` 显式传入而不是内部调 `Date()`：保持这个函数对给定输入的输出完全
    /// 确定，测试才能断言精确字符串。
    static func renderDocument(overview: ConversationIndex.MapOverview,
                               projects: [ProjectRhythm],
                               vocabulary: [(word: String, df: Int)],
                               vocabStats: [VocabWord] = [],
                               refs: [(id: String, count: Int, last: Date)],
                               surprise: SurpriseData = SurpriseData(),
                               builtAt: Date) -> String {
        let header = [
            "# Minds — mechanical self-description",
            "> Rebuilt automatically from the local conversation index. Statements below are",
            "> counted, not generated. (policy v\(ConversationIndex.dataPolicyVersion), rebuilt \(day(builtAt)))",
        ].joined(separator: "\n")

        // 统计区从这行开始——给用户的阅读指引：上半截是「你自己没意识到的」，
        // 下半截是「你的 AI 消费的画像」（照样给人看，用户定案：看得见的也要）。
        let statsDivider = "---\n_Below: mechanical profile — the raw counts your AI consumes (CLAUDE.md injection draws from here)._"

        let sections = [
            header,
            renderSanctuary(surprise.sanctuary, vaultFiles: surprise.vaultFiles,
                            vaultBytes: surprise.vaultBytes,
                            totalChars: surprise.volume.totalChars,
                            rescuedCount: surprise.rescuedCount, builtAt: builtAt),
            renderDormant(surprise.dormant),
            renderFaded(surprise.fadedWords),
            renderThisMonth(current: surprise.monthCurrent, previous: surprise.monthPrevious,
                            newEntities: surprise.newEntities, lastYearSameMonth: surprise.lastYearSameMonth),
            renderWorkRhythm(quarters: surprise.hourQuarters, busiest: surprise.busiestDay,
                             switching: surprise.switching, activeDays: surprise.activeDays,
                             weekPercentile: surprise.weekPercentile),
            renderShape(surprise.shape),
            renderWeekendSplit(surprise.weekendSplit),
            renderQuestionShape(surprise.questionShape),
            renderDelegation(verbs: surprise.delegationVerbs, research: surprise.researchDestinations),
            renderRepeatedBriefings(surprise.repeatedBriefings),
            renderCatchphrases(phrases: surprise.catchphrases, politeness: surprise.politeness),
            renderLeverage(surprise.volume),
            renderProjectLeverage(surprise.projectLeverage),
            renderMarathons(surprise.marathons),
            statsDivider,
            renderOverview(overview),
            renderProjectRhythm(projects),
            renderVocabulary(stats: vocabStats.isEmpty
                ? vocabulary.map { VocabWord(word: $0.word, tf: $0.df, projects: 0) } : vocabStats,
                totalConversations: overview.conversationCount),
        ]
        return sections.joined(separator: "\n\n")
    }

    // MARK: - 惊喜区渲染（五节。空态各有一句诚实文案，不装数据多）



    private static func renderDormant(_ projects: [ProjectRhythm]) -> String {
        var lines = ["## DORMANT PROJECTS",
                     "Heavy investments (≥10 conversations) untouched for 30+ days. (mechanical, \(projects.count) projects)"]
        if projects.isEmpty {
            lines.append("(none — everything heavy is still warm)")
        } else {
            for p in projects {
                lines.append("- \(friendlyProjectTail((p.cwd as NSString).lastPathComponent)) — \(p.count) conversations, last touched \(day(p.lastTouched))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderThisMonth(current: [ConversationIndex.FacetCount],
                                        previous: [ConversationIndex.FacetCount],
                                        newEntities: [ConversationIndex.EntityStat],
                                        lastYearSameMonth: Int? = nil) -> String {
        let curTotal = current.reduce(0) { $0 + $1.count }
        let prevTotal = previous.reduce(0) { $0 + $1.count }
        let delta = curTotal - prevTotal
        let deltaText = prevTotal == 0 ? "" : String(format: " (%+d vs last month)", delta)
        var lines = ["## THIS MONTH",
                     "\(curTotal) conversations so far\(deltaText). (mechanical, \(curTotal) conversations)"]
        if !current.isEmpty {
            lines.append("- tools: " + current.map { "\($0.key) \($0.count)" }.joined(separator: " · "))
        }
        if !newEntities.isEmpty {
            lines.append("- first seen this month: " + newEntities.map(\.text).joined(separator: " · "))
        }
        // 多年纵深（网易云「5 年深夜对比」思路的第一步）——数据不满一年自动隐藏
        if let ly = lastYearSameMonth {
            lines.append("- same month last year: \(ly) conversations")
        }
        if current.isEmpty && newEntities.isEmpty {
            lines.append("(no activity yet this month)")
        }
        return lines.joined(separator: "\n")
    }

    /// 6 桶的 4 小时段名（本机时区,`hourQuarterHistogram` 的桶序）。
    private static let quarterNames = ["00-04", "04-08", "08-12", "12-16", "16-20", "20-24"]

    private static func renderWorkRhythm(quarters: [Int],
                                         busiest: (day: String, count: Int)?,
                                         switching: (avgPerDay: Double, peak: (day: String, count: Int)?),
                                         activeDays: ActiveDays = ActiveDays(active: 0, window: 0, longestRun: 0, longestGap: 0),
                                         weekPercentile: (thisWeek: Int, percentile: Int, median: Int)? = nil) -> String {
        let total = quarters.reduce(0, +)
        var lines = ["## WORK RHYTHM",
                     "When and how you work — start times, peak day, project juggling. (mechanical, \(total) conversations)"]
        guard total > 0 else {
            lines.append("(no data yet)")
            return lines.joined(separator: "\n")
        }
        if let maxIdx = quarters.indices.max(by: { quarters[$0] < quarters[$1] }), quarters[maxIdx] > 0 {
            let share = quarters[maxIdx] * 100 / total
            lines.append("- most conversations start \(quarterNames[maxIdx]) — \(share)% (\(quarters[maxIdx]) of \(total))")
        }
        if let b = busiest {
            let share = b.count * 100 / max(total, 1)
            lines.append("- busiest day: \(b.day) — \(b.count) conversations (\(share)% of everything, in one day)")
        }
        if let peak = switching.peak, switching.avgPerDay > 0 {
            lines.append(String(format: "- you juggle %.1f projects per active day — peak %d on %@",
                                switching.avgPerDay, peak.count, peak.day))
        }
        // flomo「记录天数」型中性陈述:只报事实,不做打卡施压（GitHub 2016 教训）
        if activeDays.active > 0 {
            lines.append("- active \(activeDays.active) of the last \(activeDays.window) days — longest run \(activeDays.longestRun), longest break \(activeDays.longestGap)")
        }
        // 个人史百分位（Savant 滑条思路,分布只用你自己的历史周——本地产品无人群数据,
        // 「你 vs 你」是唯一也是够用的比较轴）
        if let wp = weekPercentile {
            lines.append("- this week so far: \(wp.thisWeek) conversations — P\(wp.percentile) of your own history (median \(wp.median))")
        }
        return lines.joined(separator: "\n")
    }

    /// 项目尾名展示:家目录杂谈的尾名是登录用户名——显示为 home(用户名当
    /// 项目名观感差,且导出/截图会泄漏用户名)。
    public static func friendlyProjectTail(_ tail: String) -> String {
        tail == NSUserName() ? "home" : tail
    }

    /// 中文书当量:约 30 万字符一本长篇(混合中英是粗算,文案带 ≈)。
    public static func bookEquivalent(_ chars: Int) -> Int { max(0, chars / 300_000) }

    /// 已跨过的最高里程碑档(对数间隔——Duolingo 稀缺庆祝原则:档位罕见才有分量)。
    /// 不做「距下一档还差 N」倒计时:那是打卡焦虑,与被动采集的产品性格相悖。
    public static let conversationMilestones = [100, 250, 500, 1_000, 2_500, 5_000, 10_000]
    public static let characterMilestones = [1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000]

    public static func highestMilestone(_ value: Int, in ladder: [Int]) -> Int? {
        ladder.last { value >= $0 }
    }

    private static func renderSanctuary(_ stats: ConversationIndex.SanctuaryStats?,
                                        vaultFiles: Int, vaultBytes: Int64,
                                        totalChars: Int = 0, rescuedCount: Int = 0,
                                        builtAt: Date) -> String {
        var lines = ["## SANCTUARY",
                     "What this library holds for you — kept on your disk, in duplicate. (mechanical)"]
        guard let st = stats, st.conversationCount > 0 else {
            lines.append("(empty — nothing to guard yet)")
            return lines.joined(separator: "\n")
        }
        // 状态宣言(Backblaze「You are backed up as of…」句式):常驻、现在时、可增长
        var head = "- \(st.conversationCount) conversations"
        if vaultFiles > 0 {
            let mb = Double(vaultBytes) / 1_048_576
            head += String(format: " · %d archived copies (%.0f MB)", vaultFiles, mb)
        }
        if let earliest = st.earliest {
            let days = max(1, Int(builtAt.timeIntervalSince(earliest) / 86_400) + 1)
            head += " · day \(days) of your library"
        }
        lines.append(head)
        // 已救回(最强行,置于首):源被工具删了、副本还在——0 时不渲染,
        // 第一次非零就是这个产品「不可辩驳」的那一天
        if rescuedCount > 0 {
            lines.append("- **\(rescuedCount) conversations rescued** — deleted by their tool, alive here")
        }
        // 免于失去的实证:越过源工具清理线仍在库(0 时不渲染——没有就不吹)
        if st.outlivedClaudeCode > 0 {
            lines.append("- \(st.outlivedClaudeCode) conversations have outlived Claude Code's 30-day window — here, they stay")
        }
        // 已跨过的里程碑(静态陈述,只报最高档,不催下一档)
        var passed: [String] = []
        if let m = highestMilestone(st.conversationCount, in: conversationMilestones) {
            passed.append("\(m) conversations")
        }
        if let m = highestMilestone(totalChars, in: characterMilestones) {
            passed.append("\(compactChars(m)) characters")
        }
        if !passed.isEmpty {
            lines.append("- milestones passed: " + passed.joined(separator: " · "))
        }
        if let latest = st.latestActivity {
            lines.append("- last collected \(day(latest))")
        }
        return lines.joined(separator: "\n")
    }


    private static func renderQuestionShape(_ shape: [(kind: String, count: Int)]) -> String {
        let total = shape.reduce(0) { $0 + $1.count }
        var lines = ["## QUESTION SHAPE",
                     "What kind of questions you ask — your cognitive spectrum with AI. (mechanical, \(total) questions)"]
        guard total >= 20 else {
            lines.append("(not enough questions yet)")
            return lines.joined(separator: "\n")
        }
        let names = ["confirm": "should-we", "how": "how-to", "why": "why", "what": "what-is"]
        lines.append("- " + shape.map { "\(names[$0.kind] ?? $0.kind) \($0.count)" }.joined(separator: " · "))
        if let top = shape.max(by: { $0.count < $1.count }) {
            let verdicts = ["confirm": "you ask AI to judge, more than to explain",
                            "how": "you ask AI for methods, more than judgments",
                            "why": "you dig for reasons first",
                            "what": "you start from definitions"]
            lines.append("- \(verdicts[top.kind] ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderDelegation(verbs: [(verb: String, lines: Int, conversations: Int)],
                                         research: [(dest: String, count: Int)]) -> String {
        var lines = ["## DELEGATION",
                     "What you ask AI to do — the verbs of your instructions. (mechanical, \(verbs.count) verbs)"]
        guard !verbs.isEmpty else {
            lines.append("(not enough instructions yet)")
            return lines.joined(separator: "\n")
        }
        lines.append("- " + verbs.map { "\($0.verb) \($0.lines)×/\($0.conversations)c" }.joined(separator: " · "))
        if let top = research.first, top.count >= 3 {
            lines.append("- research destination #1: \(top.dest) (\(top.count) of your 调研 orders"
                + (research.dropFirst().isEmpty ? ")" : "; then " + research.dropFirst().prefix(3)
                    .map { "\($0.dest) \($0.count)" }.joined(separator: " · ") + ")"))
        }
        return lines.joined(separator: "\n")
    }


    private static func renderRepeatedBriefings(_ briefings: [RepeatedBriefing]) -> String {
        var lines = ["## REPEATED BRIEFINGS",
                     "Things you keep explaining from scratch — worth turning into a reusable prompt or skill. "
                        + "Ask your AI to read these and suggest one via minds_enrich. (mechanical, \(briefings.count) groups)"]
        if briefings.isEmpty {
            lines.append("(none — you rarely repeat yourself)")
        } else {
            for b in briefings {
                lines.append("- \(flattened(b.sample).prefix(60)) — said \(b.times)× across \(b.conversations) conversations")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderCatchphrases(phrases: [(phrase: String, count: Int)],
                                           politeness: [(word: String, count: Int)]) -> String {
        var lines = ["## CATCHPHRASES",
                     "Short messages you send again and again — your voice, counted. (mechanical, \(phrases.count) phrases)"]
        if phrases.isEmpty && politeness.isEmpty {
            lines.append("(none yet)")
        } else {
            if !phrases.isEmpty {
                lines.append("- " + phrases.map { "\($0.phrase) ×\($0.count)" }.joined(separator: " · "))
            }
            if !politeness.isEmpty {
                lines.append("- politeness & delegation: "
                    + politeness.map { "\($0.word) ×\($0.count)" }.joined(separator: " · "))
            }
        }
        return lines.joined(separator: "\n")
    }


    private static func renderLeverage(_ volume: (userChars: Int, totalChars: Int)) -> String {
        var lines = ["## LEVERAGE",
                     "What your typing turns into. (mechanical, \(compactChars(volume.userChars)) chars typed)"]
        if volume.userChars > 0 && volume.totalChars > volume.userChars {
            let ratio = volume.totalChars / volume.userChars
            lines.append("- you typed \(compactChars(volume.userChars)) characters; the conversations hold \(compactChars(volume.totalChars)) — leverage 1:\(ratio)")
            // 具象换算(Pocket「≈14 本书」/搜狗《还珠格格》先例):你的劳动单独换算
            let userBooks = bookEquivalent(volume.userChars)
            let totalBooks = bookEquivalent(volume.totalChars)
            if totalBooks >= 1 {
                lines.append("- that's ≈ \(max(userBooks, 1) == 1 ? "a book's worth" : "\(userBooks) books") of your own writing, inside ≈ \(totalBooks) books of work")
            }
        } else {
            lines.append("(no data yet)")
        }
        return lines.joined(separator: "\n")
    }

    /// 1_308_411 → "1.3M"、45_210 → "45k"、900 → "900"。
    public static func compactChars(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return "\(n / 1_000)k"
        default:           return "\(n)"
        }
    }

    private static func renderMarathons(_ marathons: [ConversationIndex.Marathon]) -> String {
        var lines = ["## MARATHONS",
                     "Your longest conversations by message count. (mechanical, \(marathons.count) shown)"]
        if marathons.isEmpty {
            lines.append("(none yet)")
        } else {
            for m in marathons {
                let label = flattened(m.title?.isEmpty == false ? m.title! : m.preview).prefix(50)
                let span = m.spanHours >= 48
                    ? "\(Int(m.spanHours / 24)) days" : String(format: "%.0f h", m.spanHours)
                let proj = friendlyProjectTail((m.cwd as NSString).lastPathComponent)
                lines.append("- \(label) — \(m.messageCount) messages over \(span), \(proj.isEmpty ? "?" : proj) (id: \(m.id))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderFaded(_ faded: [FadedWord]) -> String {
        var lines = ["## FADED WORDS",
                     "Words you used to say a lot — silent for \(fadedSilentDays)+ days now. Topics move on. (mechanical, \(faded.count) words)"]
        if faded.isEmpty {
            lines.append("(none — your vocabulary is all still alive)")
        } else {
            for f in faded {
                lines.append("- \(f.word) — said \(f.totalCount) times, silent \(f.silentDays) days")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderShape(_ shape: ConversationIndex.CollaborationShape?) -> String {
        var lines = ["## COLLABORATION SHAPE",
                     "How you and AI actually work together — turns, session length, message size. (mechanical)"]
        guard let sh = shape, sh.turnBands.reduce(0, +) > 0 else {
            lines.append("(no data yet)")
            return lines.joined(separator: "\n")
        }
        let total = sh.turnBands.reduce(0, +)
        let deep = sh.turnBands[3] * 100 / total
        let quick = sh.durationBands[0] * 100 / max(sh.durationBands.reduce(0, +), 1)
        let marathon = sh.durationBands[3] * 100 / max(sh.durationBands.reduce(0, +), 1)
        lines.append("- \(deep)% of conversations run 16+ of your turns — you co-work, you don't just ask")
        lines.append("- sessions are two-peaked: \(quick)% under 2 min, \(marathon)% over 2 h")
        lines.append("- your average message: \(sh.avgCharsPerMessage) chars — short directives, not essays")
        return lines.joined(separator: "\n")
    }

    private static func renderWeekendSplit(_ split: (weekday: [ConversationIndex.FacetCount], weekend: [ConversationIndex.FacetCount])) -> String {
        var lines = ["## WEEKEND SELF",
                     "Which projects own your weekends. (mechanical, \(split.weekend.count) weekend projects)"]
        if split.weekend.isEmpty {
            lines.append("(weekends are quiet — no project claims them)")
        } else {
            lines.append("- weekend: " + split.weekend.prefix(3).map { "\($0.key) \($0.count)" }.joined(separator: " · "))
            if !split.weekday.isEmpty {
                lines.append("- weekdays: " + split.weekday.prefix(5).map { "\($0.key) \($0.count)" }.joined(separator: " · "))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderProjectLeverage(_ rows: [ConversationIndex.ProjectLeverage]) -> String {
        var lines = ["## LEVERAGE BY PROJECT",
                     "Which project stretches your words furthest. (mechanical, \(rows.count) projects)"]
        if rows.isEmpty {
            lines.append("(need ≥5 conversations per project)")
        } else {
            for r in rows.sorted(by: { $0.ratio > $1.ratio }) {
                lines.append("- \(r.name) — 1:\(r.ratio) (\(compactChars(r.userChars)) typed → \(compactChars(r.totalChars)), \(r.conversationCount) conversations)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 数据抓到的现场）。所有进「- 」数据行的自由文本都必须经过这里。
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func overviewHeadline(_ o: ConversationIndex.MapOverview) -> String {
        // 空库时 earliest/latest 是 nil——省掉日期区间而不是印 "? → ?"，让空库的
        // OVERVIEW 读起来仍是一句完整、诚实的话，不是半截模板露馅。
        let range: String
        if let earliest = o.earliest, let latest = o.latest {
            range = ", \(day(earliest)) → \(day(latest))"
        } else {
            range = ""
        }
        return "\(o.conversationCount) conversations across \(o.bySource.count) tools\(range). "
             + "(mechanical, \(o.conversationCount) conversations)"
    }

    private static func renderOverview(_ o: ConversationIndex.MapOverview) -> String {
        let sourceLine = o.bySource.isEmpty ? "- (none yet)"
            : "- " + o.bySource.map { "\($0.key) \($0.count)" }.joined(separator: " · ")
        return ["## OVERVIEW", overviewHeadline(o), sourceLine].joined(separator: "\n")
    }

    private static func renderProjectRhythm(_ projects: [ProjectRhythm]) -> String {
        var lines = ["## PROJECT RHYTHM",
                     "Top \(projects.count) projects by conversation count. (mechanical, \(projects.count) projects)"]
        if projects.isEmpty {
            lines.append("(none yet)")
        } else {
            for p in projects {
                lines.append("- \(p.cwd) — \(p.count) conversations, "
                            + "active \(day(p.activeStart)) → \(day(p.activeEnd)), "
                            + "last touched \(day(p.lastTouched))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// (2 字真概念词不再误伤,3 字口头语也拦得住)。
    public static let stopwordDFRatio = 0.25

    static func renderVocabulary(stats: [VocabWord], totalConversations: Int) -> String {
        guard !stats.isEmpty else {
            return ["## VOCABULARY",
                    "Your lexicon, counted in your own messages. (mechanical, 0 terms)",
                    "(none yet)"].joined(separator: "\n")
        }
        let n = max(totalConversations, 1)
        let topical = stats.filter { Double($0.df) / Double(n) < stopwordDFRatio }
        // 思维词三判据(2026-08-13 两轮真机迭代定稿):
        // ① 词长 ≥3——汉语构词法先验:复合成词即概念化(能力/理解/希望是基础词,
        //   第一性原理/产品经理是复合概念)。单用是相关性,与 ②③ 并用是先验;
        // ② df<25%(topical 已滤)——主题性证据:聚集出现,非口头语;
        // ③ 跨 ≥5 项目——随人性证据:跟人走,不跟事走。
        // 两轮教训:只删①→泛词霸榜(需要 919×);只靠②→次级泛词涌入(能力 294×,
        // 泛词 df 是连续谱无天然分界)。三判据缺一不可。
        let mind = topical.filter { $0.projects >= mindWordMinProjects && $0.word.count >= 3 }
            .sorted { $0.projects != $1.projects ? $0.projects > $1.projects
                                                 : ($0.tf != $1.tf ? $0.tf > $1.tf : $0.word < $1.word) }
            .prefix(8)
        let mindWords = Set(mind.map(\.word))
        let work = topical.filter { !mindWords.contains($0.word) }
            .sorted { $0.tf != $1.tf ? $0.tf > $1.tf : $0.word < $1.word }
            .prefix(12)
        var lines = ["## VOCABULARY",
                     "Your lexicon, counted in your own messages (not the AI's replies). "
                        + "Mind words travel with you across projects; work words live inside one. "
                        + "(mechanical, \(stats.count) terms)"]
        if !mind.isEmpty {
            // meta 分隔用「/」——「·」会与词间分隔符冲突,GUI 按「·」拆 chips 时被拆断
            lines.append("- mind: " + mind.map { "\($0.word) (\($0.tf)×/\($0.projects)p)" }.joined(separator: " · "))
        }
        if !work.isEmpty {
            lines.append("- work: " + work.map { "\($0.word) (\($0.tf))" }.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }


    private static func compactList(_ pairs: [(text: String, count: Int)]) -> String {
        guard !pairs.isEmpty else { return "(none yet)" }
        return pairs.map { "\($0.text) (\($0.count))" }.joined(separator: " · ")
    }

    // MARK: - 统计查询（触碰 ConversationIndex 的部分，与上面的纯渲染分开）

    /// 一个项目（`cwd`）的节奏：会话数 / 活跃期（首末 `startAt`）/ 最近触达。
    /// `Equatable` 只是顺手（全部字段本就是 Equatable），方便测试直接比较数组。
    struct ProjectRhythm: Equatable {
        let cwd: String
        let count: Int
        let activeStart: Date
        let activeEnd: Date
        let lastTouched: Date
    }

    /// 把 `mapOverview().byProject`（已按会话数降序、已排除空 cwd、已截前 20）里的每个
    /// 项目展开成 `ProjectRhythm`。`projects` 形参通常已经是 `.prefix(10)` 过的
    /// Top 10——这个函数本身不再截断，截断的决定权留给调用方（`build`），保持这里
    /// 是"给定一组项目、查出它们的节奏"这个单一职责。
    ///
    /// 活跃期取该项目全部会话的**首末 `startAt`**（"什么时候开始忙这个、忙到什么
    /// 时候开始了最后一场"）；`lastTouched` 取全部会话的**最大 `endAt`**——特意不
    /// 复用 `activeEnd`（同一个数字），因为 `endAt` 能覆盖"活跃期最后一场会话开始后
    /// 又聊了很久"这种场景，是比"最后一场何时**开始**"更准确的"最近碰过"定义。
    ///
    /// 用 `conversationIDs(for:limit:)` + `metadata(forIDs:)` 而不是新开一条聚合 SQL：
    /// 任务简报明确指了这条路径，且项目数至多 10 个、每个项目的会话数在个人库量级下
    /// 是几十到几百条，走 Swift 端 `min`/`max` 比新写一条 `GROUP BY cwd` 聚合 SQL
    /// 更省一次 schema 决策，性能差异在这个量级下可忽略。
    static func projectRhythms(index: ConversationIndex,
                               projects: [ConversationIndex.FacetCount]) -> [ProjectRhythm] {
        projects.compactMap { fc in
            let ids = index.conversationIDs(for: .project(fc.key), limit: Int.max)
            let metas = index.metadata(forIDs: ids)
            guard !metas.isEmpty else { return nil }
            return ProjectRhythm(cwd: fc.key, count: metas.count,
                                 activeStart: metas.map(\.startAt).min()!,
                                 activeEnd: metas.map(\.startAt).max()!,
                                 lastTouched: metas.map(\.endAt).max()!)
        }
    }

    /// VOCABULARY 排序规则（任务简报）：**≥3 字词优先**（组内按 df 降序），不足 `limit`
    /// 再用 <3 字词按 df 降序补齐；同组同 df 按词本身升序兜底，保证输出确定——
    /// `frequencies` 是字典，Swift 字典遍历顺序不稳定，SQL 点查也不保证同 df 词之间
    /// 的相对顺序，不加这个兜底会让同一份输入在不同进程/不同次运行给出不同的展示顺序。
    ///
    /// 这里的"先分组再各自排序再拼接"是判别性写法：如果哪天有人手滑把 `>` 改成 `<`
    /// （降序改升序），≥3 字组与 <3 字组各自的相对顺序都会反过来——`MindsBuilderTests`
    /// 里的变异反证测试就是靠这个直接把突变炸红，不依赖运气。
    static func rankVocabulary(frequencies: [String: Int], limit: Int) -> [(word: String, df: Int)] {
        func rank(_ dict: [String: Int]) -> [(word: String, df: Int)] {
            dict.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { (word: $0.key, df: $0.value) }
        }
        let long = rank(frequencies.filter { $0.key.count >= 3 })
        let short = rank(frequencies.filter { $0.key.count < 3 })
        return Array((long + short).prefix(limit))
    }

    // MARK: - 日期格式化

    /// `MCPText.day` 的同款格式（`yyyy-MM-dd` / `en_US_POSIX` / 本机时区），但不能
    /// 直接复用那份实现——`MCPText` 活在 `MindBusMCP` target，这里是 `MindBusCore`，
    /// 依赖方向只能反过来（`Package.swift`：`MindBusMCP` 依赖 `MindBusCore`，不是
    /// 反过来）。同款格式独立各写一份，与本仓库四个 Loader 各自持有一份
    /// `ISO8601DateFormatter` 是同一个既有先例，不是新模式。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}
