import Foundation
import NaturalLanguage

/// 思脉底座 · 机械层：从索引统计生成 `minds.md`。
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
/// 全部理由。曾有的 WEAK SPOTS 增补层（宿主模型经 minds_enrich 写自陈述）已整体
/// 拆除（用户 2026-09-01 定案：不要例外，Minds 全线只留代码可证的内容）。
///
/// 重建时机：`LoaderRuntime.indexAllSources` 收尾，顺序排在词表重建
/// （`ConversationIndex.rebuildLexiconIfNeeded`）与 MCP 引用汇入
/// （`ConversationIndex.ingestRefLog`）之后——VOCABULARY 节消费前者的产出、
/// AGENT USAGE 节消费后者的产出，颠倒顺序会让本轮重建看到上一轮的旧数据。
public enum MindsBuilder {

    // MARK: - 落盘路径

    /// minds 根目录：`~/.mindbus/minds`。`MINDBUS_MINDS_ROOT` 可覆盖——
    /// trim 后为空视同未设置（不 trim 的话纯空白会被当成合法目录名，后续操作在一个
    /// 诡异路径上悄悄失败）；`~` 手工展开——这个值多半来自宿主配置文件、不经过
    /// shell，原样传给 `FileManager` 只会被当成字面量目录名，路径永远不存在。
    ///（原 `MindsEnrichedLog.mindsRoot()`——增补层拆除后解析逻辑的唯一真相挪到这里。）
    static func mindsRoot() -> URL {
        if let raw = ProcessInfo.processInfo.environment["MINDBUS_MINDS_ROOT"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mindbus", isDirectory: true)
            .appendingPathComponent("minds", isDirectory: true)
    }

    /// `~/.mindbus/minds/minds.md`。
    public static var defaultMindsURL: URL {
        mindsRoot().appendingPathComponent("minds.md")
    }

    /// 旧版本 minds.md 里机械五节与已拆除的 WEAK SPOTS 节之间的分隔标记。
    ///
    /// 增补层拆掉后 build 不再写这一行，常量仅供读取方（`MindsStore`/`MindsReadTool`）
    /// 截断**旧文件**遗留的 WEAK SPOTS 内容——用户装上新版后、下一轮扫描重写 minds.md
    /// 之前的窗口期里，读到的旧文件不该再把模型写的条目漏给界面或宿主模型。
    public static let legacyWeakSpotsMarker = "<!-- weak-spots -->"

    // MARK: - 落盘入口

    /// 查询索引统计 → 渲染 → 原子写 `url`。
    ///
    /// 目标目录首次不存在时自动建出来，不能
    /// 指望调用方（扫描收尾）提前建好；写失败（磁盘满/权限问题）静默放弃——这只是
    /// 扫描收尾众多步骤之一，不该让 minds.md 写不出去拖垮整轮扫描，下一轮扫描收尾
    /// 会自然重试（幂等重建，没有"部分写入"的中间状态需要清理）。
    public static func build(from index: ConversationIndex, to url: URL = defaultMindsURL) {
        // 零变化短路：索引指纹与上次成功构建一致且产物仍在 → 整轮跳过。
        // 此前每次扫描收尾都无条件全量重建，活跃会话期间 FSEvents 每 2s 触发一轮。
        let fingerprint = index.changeFingerprint()
        let fingerprintURL = url.deletingLastPathComponent().appendingPathComponent(".minds-fingerprint")
        if FileManager.default.fileExists(atPath: url.path),
           let previous = try? String(contentsOf: fingerprintURL, encoding: .utf8),
           previous == fingerprint {
            return
        }
        let now = Date()
        let overview = index.mapOverview()
        // 项目的**产出量**：这个项目里你放行过几件事。场数和消息数量的是
        // 「花了多少时间」，这一项量的是「产出了什么」——两者常常不同向
        // （真机上消息最多的项目并不是放行最多的那个）。
        let byProject = index.milestoneCandidatesByProject()
        let projectApprovals = MindsMilestones.learnApprovals(candidates: byProject.map(\.candidate))
        var signedOffByProject: [String: Int] = [:]
        for row in byProject where row.candidate.headline != nil
            && MindsMilestones.isApproval(row.candidate.approval, approvals: projectApprovals) {
            signedOffByProject[row.cwd, default: 0] += 1
        }
        let allProjects = projectRhythms(index: index,
                                         projects: overview.byProject.filter { isRealProject($0.key) },
                                         signedOff: signedOffByProject)
        let projects = Array(allProjects.prefix(10))
        // VOCABULARY 从 v14 起按 user 语料数 tf——「你的高频词」必须是你说过的
        // vocabFreqs 在语料拉取之后算(共享同一份,不再独立拉)
        var vocabFreqs: [String: Int] = [:]
        let refs = index.topReferenced(limit: Int.max)

        // 惊喜区数据（阈值集中在这里，渲染函数只收结果）：
        // 断点近 14 天；反复回来 ≥3 会话跨 ≥7 天、排除 Top-10 主项目词；
        // 沉睡 ≥10 会话且 >30 天没碰；本月对比自然月。
        var surprise = SurpriseData(
            // 90 天而不是 14 天：悬着的事**越久越该提醒**——你早忘了它。
            // 14 天的窗口恰好把最该被想起的那些滤掉了（真机 5 件里 4 件超过 14 天）。
            // 也不设成无限：超过一个季度没碰的，多半已经自然作废。
            unfinished: index.unfinishedThreads(since: now.addingTimeInterval(-90 * 86_400), limit: 8),
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
        // 下面三项此前从没被赋值(定义了、渲染函数也写好了,就是没人调):
        // projectLeverage 空 → 项目表的「杠杆」列永久隐藏;
        // shape/weekendSplit 空 → 界面靠直查 store 还有内容,但 MCP 交给 AI 的
        // md 里这两节是空的,等于「用户看到的」和「AI 拿到的」不是同一份。
        surprise.projectLeverage = index.projectLeverage(minConversations: 2, limit: 5)
        surprise.shape = index.collaborationShape()
        surprise.weekendSplit = index.weekendSplit(minCount: 2)
        // 语料单次拉取(内存优化):三个消费者共享同一份,map 派生零拷贝
        let corpusRows = index.userCorpusRows()
        surprise.fadedWords = fadedWords(corpus: corpusRows.map { (text: $0.text, startAt: $0.startAt) },
                                         lexicon: index.loadLexicon(), now: now, limit: 5)
        // 词表画像:tf + 跨项目数。展示词表 ≠ 检索词表(2026-08-16 用户定案:
        // 「不要管这是什么类型的词,只要被反复提及就有用」)——检索那份必须严
        // (边界熵 1.2 防碎片污染倒排),展示这份可以宽(说了 17 次的「宫本茂」
        // 总在固定搭配里、邻字单一,严格口径永远学不到,但它显然是有用的信号)。
        let displayLexicon = index.loadLexicon().union(
            PersonalLexicon.build(corpus: corpusRows.map(\.text),
                                  thresholds: displayLexiconThresholds))
        // 语法位置过滤:把「类似/更好/复杂/情况」这类汉语通用词剔掉,留你的实词
        let grammar = grammarProfiles(lexicon: displayLexicon, corpus: corpusRows.map(\.text))
        let posContent = contentWordByPOS(corpus: corpusRows.map(\.text))
        let vocabStats = userVocabularyStats(lexicon: displayLexicon,
                                             corpus: corpusRows.map { (text: $0.text, cwd: $0.cwd) })
            .filter { isContentWord(grammar[$0.word] ?? GrammarProfile()) }
            // 第二道:系统词性标注剔虚词。查不到词性的保留(分词器的局限不该
            // 让「大模型」这类词出局)
            .filter { posContent[$0.word] ?? true }
            // 技术名词走单独一路(中文词表挖不到拉丁词,见 technicalTerms 注释)
            + technicalTerms(candidates: index.crossProjectIdentifiers(minProjects: 3, limit: 60),
                             corpus: corpusRows.map { (text: $0.text, cwd: $0.cwd) },
                             excluding: projectTails, minTF: 15, minProjects: 3)
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
            corpus: corpusRows.map { (text: $0.text, convID: $0.convID) }, limit: 8)
        surprise.researchDestinations = researchDestinations(corpus: corpus)
        surprise.citedPeople = citedPeople(corpus: corpusRows.map { (text: $0.text, cwd: $0.cwd) })
        // 反复交代的话:同一句规矩讲了好几遍,该沉淀成模板。
        // 这一项此前也从没被赋值(渲染函数写好了、GUI 也读它,就是没人调 build)
        surprise.repeatedBriefings = repeatedBriefings(
            corpus: corpusRows.map { (text: $0.text, convID: $0.convID, startAt: $0.startAt) },
            limit: 5)
        // 你点头的时刻:素材是扫描时攒的,判据在这里——认可词表要看过全部
        // 对话才学得出来(单场里看不出「继续」说了 242 次)。
        let candidates = index.milestoneCandidates()
        let approvals = MindsMilestones.learnApprovals(candidates: candidates)
        let stones = MindsMilestones.milestones(candidates: candidates, approvals: approvals)
        surprise.milestones = stones
        surprise.milestonesTotal = stones.count
        let calls = MindsMilestones.decisions(candidates: index.decisionCandidates())
        surprise.decisions = calls
        surprise.decisionsTotal = calls.count

        let pos = posProfile(corpus: corpusRows.map(\.text))
        surprise.phrases = repeatedPhrases(
            corpus: corpusRows.map { (text: $0.text, cwd: $0.cwd) }, limit: 24,
            pronouns: Set(pos.compactMap { $0.value == "Pronoun" ? $0.key : nil }),
            functionWords: Set(pos.compactMap {
                functionWordClasses.contains($0.value) ? $0.key.lowercased() : nil
            }))
        // 把锚点展开成原话。锚点本身已由短语层验证(跨项目复现),
        // 这一步不做新判断,只是把压缩的价值还原成完整表达。
        let quoteRows = corpusRows.map { (text: $0.text, cwd: $0.cwd) }
        for p in surprise.phrases.prefix(phrasesWithQuotes) {
            let qs = phraseQuotes(corpus: quoteRows, phrase: p.phrase, limit: quotesPerPhrase)
            if !qs.isEmpty { surprise.quotesByPhrase[p.phrase] = qs }
        }

        // 词汇的传染方向。要角色和时间戳,索引里的段是合并的,只能回原文件解析。
        // 逐会话流式解析并按 (路径, mtime, 词表) 缓存每场的中间结果：此前把全库完整
        // 消息同时驻留在一个数组里再统计，绕过了 loader 层全部峰值防线，而且活跃会话
        // 期间每轮刷新都全量重解析。现在只有变过的会话才重新解析。
        surprise.contagion = contagionAcrossLibrary(
            metadata: index.allMetadata(),
            lexicon: index.loadLexicon(),
            limit: contagionShown,
            functionWords: Set(pos.compactMap {
                functionWordClasses.contains($0.value) ? $0.key.lowercased() : nil
            }))

        let full = renderDocument(overview: overview, projects: projects,
                                  vocabulary: vocabulary, vocabStats: vocabStats,
                                  refs: refs, surprise: surprise, builtAt: now)

        guard let data = full.data(using: .utf8) else {
            NSLog("[minds] build failed: could not UTF-8 encode rendered document")
            return
        }
        try? MindBusHome.ensureDirectory(url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: .atomic)
            MindBusHome.restrict(url)
            try? fingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
            MindBusHome.restrict(fingerprintURL)
        } catch {
            NSLog("[minds] build failed to write %@: %@", url.lastPathComponent, String(describing: error))
        }
    }

    // MARK: - CLAUDE.md 注入文本

    /// 机械层紧凑版：OVERVIEW 一行 + TOP ENTITIES 前 10 + VOCABULARY 前 10。
    /// 全部数出来的——增补层（模型写的 confirmed 条目）已随例外拆除，注入文本
    /// 与页面同一条纪律：只有代码可证的内容。
    public static func renderForInjection(index: ConversationIndex) -> String {
        let overview = index.mapOverview()
        // 注入口径与展示同源(2026-08-16):说得多 + 不是口水词,不判断类型
        let corpusRows = index.userCorpusRows()
        let displayLexicon = index.loadLexicon().union(
            PersonalLexicon.build(corpus: corpusRows.map(\.text),
                                  thresholds: displayLexiconThresholds))
        let stats = userVocabularyStats(lexicon: displayLexicon,
                                        corpus: corpusRows.map { (text: $0.text, cwd: $0.cwd) })
        let n = max(overview.conversationCount, 1)
        let vocabulary = stats
            .filter { Double($0.df) / Double(n) < stopwordDFRatio && $0.word.count >= 2 }
            .sorted { $0.tf != $1.tf ? $0.tf > $1.tf : $0.word < $1.word }
            .prefix(10).map { (word: $0.word, df: $0.tf) }

        var lines = ["# Minds", ""]
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

    // MARK: - 惊喜区数据（build 查好注入，渲染纯函数）

    /// 惊喜区的全部数据。测试直接构造这个结构驱动渲染，不用碰索引。
    struct SurpriseData {
        /// 你点头放行过的成果(已按判据筛过),以及总条数
        var milestones: [MindsMilestones.Milestone] = []
        var milestonesTotal = 0
        /// 你在选择面前拍的板
        var decisions: [MindsMilestones.Decision] = []
        var decisionsTotal = 0
        var unfinished: [ConversationIndex.UnfinishedThread] = []
        var recurring: [ConversationIndex.RecurringEntity] = []
        var dormant: [ProjectRhythm] = []
        var monthCurrent: [ConversationIndex.FacetCount] = []
        var monthPrevious: [ConversationIndex.FacetCount] = []
        var newEntities: [ConversationIndex.EntityStat] = []
        // 2026-08-12 二批（继续按意外度挖掘）：作息指纹 / 杠杆率 / 马拉松 / 不再说的词
        var hourQuarters: [Int] = []                                  // 6 桶 × 4 小时
        var busiestDay: (day: String, count: Int, messages: Int)?
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
        var phrases: [(phrase: String, times: Int, projects: Int)] = []
        /// 锚点展开成的原话:短语 → 你在不同项目里说过的完整句子
        var quotesByPhrase: [String: [(text: String, cwd: String)]] = [:]
        /// 它先说、你后来接过来的词
        var contagion: [Contagion] = []
        /// 短语展开成的原话：锚点 → 你在不同项目里说过的完整句子
        var phraseQuotes: [String: [(text: String, cwd: String)]] = [:]
        var researchDestinations: [(dest: String, count: Int)] = []
        /// 你引用过的人(2026-08-18)
        var citedPeople: [CitedPerson] = []
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
    /// 「反复交代」的最短跨度。低于它的重复基本是同一个任务周期内的上下文重复
    /// （会话被切分时用户重新粘贴前情），不是隔了一段时间还要再讲一遍的规矩。
    static let briefingMinSpanDays = 14

    public struct RepeatedBriefing: Equatable {
        public let sample: String        // 组内最长样本
        public let times: Int            // 讲过几遍(含同会话重复)
        public let conversations: Int    // 跨几个会话
        /// 首末两次相隔多少天(2026-08-16 用户三特征之三:「隔一段时间会说」)——
        /// 一天里连讲三遍是当时较劲,隔三个月还在讲才是真·反复交代。
        public let spanDays: Int
        public init(sample: String, times: Int, conversations: Int, spanDays: Int = 0) {
            self.sample = sample; self.times = times
            self.conversations = conversations; self.spanDays = spanDays
        }
    }

    /// 噪声行:编号列表/引号/JSON 键值/markdown 标记——粘贴的结构化内容拆行后的残留,
    /// 不是「你讲的话」(2026-08-12 原型两轮过滤实证)。
    /// 三轮真机迭代:+`<`(image 占位符 120× 霸榜)、+`^[A-Za-z]\d+[:：]`(粘贴的
    /// 数据表行「L21:ACCA…」63×)、+`\w+=\S+.*\w+=\S+`(两个以上键值对=结构化数据)。
    private static let briefingNoise = try? NSRegularExpression(
        pattern: #"^\d+[.、)]|^["'{}\[<]|"\w+"\s*:|^[-*] |^#{1,6} |^[A-Za-z]\d+[:：]|\w+=\S+.*\w+=\S+"#)

    static func repeatedBriefings(corpus: [(text: String, convID: String, startAt: Date)],
                                  limit: Int) -> [RepeatedBriefing] {
        // ① 候选:14-200 字、含 CJK、非噪声。上限 200(2026-08-16 放宽):
        // v16 起行=整条消息,完整的角色设定/工作约定常超 80 字,老上限会把
        // 「反复交代的长话」整条拒之门外;粘贴防线已由消息压平+噪声正则+
        // 超长排除承担,不再需要 80 这道矮墙。
        var msgs: [(String, String)] = []
        var dateOf: [String: Date] = [:]        // convID → 会话时间(算首末间隔)
        for (text, cid, startAt) in corpus {
            dateOf[cid] = startAt
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard (14...200).contains(t.count),
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
            // 见下方 briefingMinSpanDays:跨度门槛在算出 span 之后判
            let sample = ids.map { msgs[$0].0 }.max(by: { $0.count < $1.count }) ?? ""
            let dates = convs.compactMap { dateOf[$0] }.sorted()
            let span = (dates.first != nil && dates.count > 1)
                ? Int(dates.last!.timeIntervalSince(dates.first!) / 86_400) : 0
            // 跨度门槛:一天里连讲三遍是当时较劲,隔一段时间还在讲才是真·反复交代。
            // 真机验证(2026-08-18):不加门槛时 12 条里 11 条跨度 0-4 天,全部来自
            // 同一批讨论——会话被切分后用户重新粘贴上下文造成的重复,不是交代规矩。
            guard span >= briefingMinSpanDays else { return nil }
            return RepeatedBriefing(sample: sample, times: ids.count,
                                    conversations: convs.count, spanDays: span)
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
                // 单字不是「短句」:真机上「A ×9」「好 ×11」这类混进来,读者第一反应是
                // 「我没说过这个词」——选项字母 A/B、被拆行的单字都会以整行出现。
                guard t.count >= 2 else { continue }
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

    /// 展示词表阈值:比检索宽——邻字熵 1.2→0.35(固定搭配里的专名/术语也要能出来)。
    /// 展示的容错成本只是「多一个不太有意思的词」,检索的成本是碎片污染整个倒排。
    public static let displayLexiconThresholds = PersonalLexicon.Thresholds(
        minFrequency: 8, cohesionPerExtraChar: 60, minBoundaryEntropy: 0.35)

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

    // MARK: - 反复说的短语(2026-08-16 从真实模式反推的算法)

    /// 短语首尾禁用字:结构助词/量词/连词。汉语最封闭的一类,不是语义黑名单。
    /// 依据:真实短语不会以它们开头或结尾——「的 skill」「个 skill」「skill 的」
    /// 是切碎的残片,「第一性原理」「是什么意思」才是完整单元。
    static let phraseEdgeStops: Set<Character> = ["的", "了", "着", "过", "地", "得",
                                                  "个", "些", "把", "被", "和", "与",
                                                  "或", "就", "都", "也", "还", "很", "更", "再"]

    /// 短语里含代词就不是概念——判据是**词类**不是词义。
    ///
    /// 代词表由 `pronounsByPOS` 从语料里学，不写死：写死一张中文表的话，
    /// 同一套代码换个说英文的人就整体失效。真机现场（2026-08-18）挡住的是：
    /// 我不知道 · 让我看看 · 我希望能 · 我觉得你 · 我的理解 · 我们自己 ·
    /// 类似这样 · 这些信息；而概念短语（产品经理 · 第一性原理 · 热点事件 ·
    /// 最佳实践 · 库存管理 · 调度能力 · AI 产品 · 用户旅程）一个都不含代词。
    ///
    /// 与 `phraseEdgeStops`（结构助词）是同一条思路的延伸——那条管首尾，
    /// 这条管任意位置。
    static func containsPronoun(_ phrase: String, pronouns: Set<String>) -> Bool {
        pronouns.contains { matchesAsWord($0, in: phrase) }
    }

    /// 代词是否在短语里**作为一个词**出现。
    ///
    /// 中日韩没有词间空格，子串匹配就是正确的匹配；
    /// 拉丁字母必须看词边界——否则「I」会命中 AI / API / UI / CI，
    /// 「we」会命中 webhook。这不是假想:代词表改成从语料学之后，
    /// 英文的「I」被学了进来，真机上「AI 味」「AI 产品」当场被误杀
    /// （2026-08-18 现场）。硬编码中文表时遇不到这个坑，一通用化就暴露。
    static func matchesAsWord(_ needle: String, in phrase: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let latin = needle.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard latin else { return phrase.contains(needle) }
        func isWordChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        var from = phrase.startIndex
        while let r = phrase.range(of: needle, options: .caseInsensitive,
                                   range: from..<phrase.endIndex) {
            let beforeOK = r.lowerBound == phrase.startIndex
                || !isWordChar(phrase[phrase.index(before: r.lowerBound)])
            let afterOK = r.upperBound == phrase.endIndex || !isWordChar(phrase[r.upperBound])
            if beforeOK && afterOK { return true }
            guard r.upperBound < phrase.endIndex else { break }
            from = phrase.index(after: r.lowerBound)
        }
        return false
    }

    /// 给语料里每个词元打词性、取众数,得到「词 → 主导词类」。
    /// 代词表和功能词表都从这一份派生:语料一大,这遍 NLTagger 遍历是
    /// 这一层最贵的一步,不能为每张表各跑一遍。
    static func posProfile(corpus: [String]) -> [String: String] {
        var byWord: [String: [String: Int]] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        for text in corpus where !text.isEmpty {
            tagger.string = text
            if let lang = NLLanguageRecognizer.dominantLanguage(for: text) {
                tagger.setLanguage(lang, range: text.startIndex..<text.endIndex)
            }
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                                 scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation]) { tag, r in
                guard let tag else { return true }
                byWord[String(text[r]), default: [:]][tag.rawValue, default: 0] += 1
                return true
            }
        }
        return byWord.compactMapValues { $0.max(by: { $0.value < $1.value })?.key }
    }

    /// 从语料里学出代词表（`NLTagger` 判为 Pronoun 的词元）。
    /// 说中文的人学到 我/我们/这个/什么，说英文的人学到 I/we/this/what。
    static func pronounsByPOS(corpus: [String]) -> Set<String> {
        Set(posProfile(corpus: corpus).compactMap { $0.value == "Pronoun" ? $0.key : nil })
    }

    /// 学出虚词表(冠词/介词/连词/助词/代词…)。与代词表同源,只是放宽到整类。
    /// 用途是短语的**首尾**过滤——中文那条规矩写在 `phraseEdgeStops`
    /// (的/了/着/地/得),是手写的;英文这张表靠 POS 学,一个词都不用写死。
    static func functionWordsByPOS(corpus: [String]) -> Set<String> {
        Set(posProfile(corpus: corpus).compactMap {
            functionWordClasses.contains($0.value) ? $0.key.lowercased() : nil
        })
    }

    /// 短语首尾的拉丁词元是不是虚词。
    ///
    /// 「the user」「in the」「is a」这类组合在英文语料里频次极高但没有内容,
    /// 中文靠 `phraseEdgeStops` 挡同类的「的 skill」,英文此前无人管——
    /// 真机 2026-08-18 放开非中文后,in the / to the / is a / as a / on the
    /// 一次涌进榜单前列。CJK 词元不在这里判,它归成分覆盖率那条管。
    static func edgeIsFunctionWord(_ phrase: String, functionWords: Set<String>) -> Bool {
        let toks = phraseTokenRanges(phrase)
        guard let first = toks.first, let last = toks.last else { return false }
        for r in [first, last] {
            let w = String(phrase[r])
            guard w.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            if functionWords.contains(w.lowercased()) { return true }
        }
        return false
    }

    /// 自然语言的一句话里不会出现的字符:路径分隔符、标记语言的尖括号与等号、
    /// 引号与各种括号。带上它们的那一段不是人说的话,是文件路径、XML 片段
    /// 或工具输出——真机 2026-08-18 短语层一放开非中文,家目录路径 306 次
    /// 冲到榜首(还带着用户名),「image> </image」「path="/var/folders」紧随其后。
    /// 撇号和点不在其中:don't、user's、github.com 都是人写得出来的。
    static func isMachineTextCharacter(_ c: Character) -> Bool {
        "/<>=\"{}[]|\\".contains(c)
    }

    static func isCJKChar(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }

    /// 短语成分的口水词阈值：短语里任一 CJK 双字成分的会话覆盖率超过它，
    /// 这条短语就是句式框架而不是概念。
    ///
    /// 真机定阈（2026-08-18，150 场）：概念型短语的成分覆盖率
    /// 热点事件 20% · 第一性原理 23% · 用户旅程 25% · 产品经理 27% · AI 味 0%；
    /// 框架型 怎么设计 30% · 这个地方/这个 skill 39% · 一个完整 43% ·
    /// 是什么意思 44% · 需要 X 一族 45%。分界落在 27%→30% 之间。
    ///
    /// 这与词表层的 `stopwordDFRatio` 是同一个思想，只是作用在**成分**上：
    /// 一个词你到处都在说，那么含它的短语就不是一个概念。好处是「需要 X」
    /// 这一整族被一次清掉，不需要枚举。
    static let phraseComponentDFRatio = 0.30

    /// 成分过滤的最低样本量。会话太少时「覆盖率」没有意义——
    /// 9 场语料里每个成分的覆盖率都接近 100%，比例失去分辨力，
    /// 会把所有短语一起毙掉（同 `weekPercentile` 的「历史周 <4 个返回 nil」）。
    static let phraseComponentMinConversations = 30

    /// 短语首尾不允许出现的标点。含全角/半角括号、引号、书名号与常见标点——
    /// 判据不是「这个符号不好」，而是「一句话不会以标点开头或结尾」。
    static func isPhraseEdgePunctuation(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return false }
        if c == " " { return false }   // 已在 trim 阶段处理，保留判断的单一职责
        return c.isPunctuation || c.isSymbol
    }

    /// 一个候选短语右边最多可以有多集中的「唯一后续」。超过它就是残片。
    ///
    /// 真机定阈(2026-08-18,150 场):残片 AI 产 84%(后面是「品」)·
    /// AI 工 88%(「具」);完整的词 产品经理 16% · 第一性原理 25% ·
    /// 用户旅程 37% · AI 味 45%。分界落在 45%→84% 之间,0.7 取中。
    static let phraseRightBranchingMax = 0.7

    /// 这个短语是不是从一个更长的词里切出来的一半。
    ///
    /// 判据来自无监督分词的**邻接变化度**(branching entropy):
    /// 一个真正的词,右边接什么都行——「产品经理」后面可以是「团队」「说」
    /// 「，」;而一个残片右边几乎只有一种可能,因为它本来就是被切开的
    /// ——「AI 产」后面 84% 是「品」。纯统计,不查词典,也不挑语言。
    ///
    /// 标点、空白和段尾**不算**收敛证据,恰恰相反:残片后面不会出现句号,
    /// 能收句号说明这里本来就是词尾(真机:「AI 味」45% 的右邻是逗号、
    /// 「在 github」69% 是空格,两个都是完整的说法)。
    static func isTruncatedFragment(rightNeighbors: [String: Int]) -> Bool {
        var content: [String: Int] = [:]
        var total = 0
        for (n, c) in rightNeighbors {
            total += c
            guard let f = n.first, !isPhraseEdgePunctuation(f) else { continue }
            content[n, default: 0] += c
        }
        guard total > 0, let top = content.values.max() else { return false }
        return Double(top) / Double(total) >= phraseRightBranchingMax
    }

    /// 把一段话切成词元的位置。
    ///
    /// 拉丁字母数字连成的一串算**一个**词元(「github」不能从中间切开),
    /// 其余每个字符各算一个词元——中文没有词间空格,字就是最小单位。
    ///
    /// 短语窗口按词元数而不是字符数取,这是能同时服务两种书写系统的关键:
    /// 4-12 个字符对中文是 4-12 个字(正好),对英文连两个词都装不下
    /// (「user journey」就有 12 个字符),纯英文语料因此一条短语都出不来。
    /// 返回原文区间、按首尾区间取子串,空格和连字符就原样留在短语里。
    static func phraseTokenRanges(_ seg: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var i = seg.startIndex
        while i < seg.endIndex {
            let c = seg[i]
            if c.isASCII && (c.isLetter || c.isNumber) {
                var j = i
                while j < seg.endIndex, seg[j].isASCII, seg[j].isLetter || seg[j].isNumber {
                    j = seg.index(after: j)
                }
                out.append(i..<j)
                i = j
            } else if c.isWhitespace {
                i = seg.index(after: i)
            } else {
                let j = seg.index(after: i)
                out.append(i..<j)
                i = j
            }
        }
        return out
    }

    /// 「它先说、你后来接过来」至少要隔多久。同一天不算——那多半只是你在
    /// 同一场对话里顺着它的话复述了一遍，不是把这个词带走了。
    static let contagionMinGapDays = 1

    /// 接过来的词至少要用在几个项目里。只在一个项目里跟着说过一次，
    /// 说明你没真的带走它。
    static let contagionMinProjects = 2

    /// 词汇的传染方向：哪些词是**它先说、你后来接过来**的。
    ///
    /// 这是只有跨工具对话库才做得到的观察——单个 AI 工具只看得见自己那一摊，
    /// 看不到你在别的项目、别的工具里的用词演变。
    ///
    /// 真机实例：「用户旅程」是它先说的，17 天后你开始用，如今带着它走了
    /// 4 个项目；「视觉语言」33 天；「黑名单」108 天。你以为是自己的词，
    /// 其实是它教你的。
    ///
    /// 判据全是时间和精确匹配，没有语义推断：首次出现的先后（谁先说）、
    /// 间隔（≥1 天，排掉同场复述）、你的项目覆盖（≥2，排掉当场跟读）。
    /// 词的会话覆盖率上限。超过它就是到处都有的常用字眼——「浏览器」「互联网」
    /// 「右上角」不是它教你的概念，只是碰巧它先说了
    /// （2026-08-18 真机现场：不设这道闸，前六名全是这种）。
    ///
    /// df **在这一层自己数**，不读 vocab_lex：那张表是词表统计的产物，
    /// Minds 重建的时候它还是空的（时序在后），读出来 df 全是 0，
    /// 这道闸会静默失效——第一版就是这样，装机后结果一字未变才发现。
    /// 自己数还顺带更准：vocab_lex 的 doc 是**段**级的，这里要的是会话级。
    static let contagionMaxDF = 0.10

    /// 覆盖率这道闸的最低样本量。库太小时「出现在几成对话里」没有分辨力
    /// ——三场对话里任何词都是 33% 起步，闸门会把真词一起毙掉
    /// （同 `phraseComponentMinConversations` 的道理）。新装的库因此先不设这道闸。
    static let contagionMinConversations = 30

    /// 一次传染:它先说的词、你接过来的经过。两句原话是这次传染的「案发现场」
    /// ——词是压缩的,句子才看得出发生了什么。
    public struct Contagion: Equatable, Sendable {
        public let word: String
        public let gapDays: Int
        public let projects: Int
        /// 它第一次说这个词的那句
        public let itSaid: String
        /// 你第一次用这个词的那句
        public let youSaid: String
    }

    /// 从一段文本里取出含某词的那句话。要求句子比词本身长——「视觉语言」
    /// 单独成句没有信息,那不是语境是回声。
    ///
    /// 超长的句子**截窗口**而不是丢弃:真机的首现句常埋在长段落里,
    /// 直接丢的话四个词的案发现场全空(2026-08-19 装机实测一行都没出来)。
    static func sentence(containing word: String, in text: String) -> String? {
        let needle = word.lowercased()
        for line in text.split(separator: "\n") {
            for piece in line.split(whereSeparator: { "。！？!?;；".contains($0) }) {
                let s = piece.trimmingCharacters(in: .whitespaces)
                guard s.lowercased().contains(needle), s.count > word.count + 2 else { continue }
                if s.count <= 80 { return s }
                // 围绕词截 80 字的窗口,断口加省略号
                guard let r = s.range(of: word, options: .caseInsensitive) else { continue }
                let lead = 26
                var start = r.lowerBound
                for _ in 0..<lead { if start > s.startIndex { start = s.index(before: start) } }
                var end = start
                for _ in 0..<80 { if end < s.endIndex { end = s.index(after: end) } }
                let head = start > s.startIndex ? "…" : ""
                let tail = end < s.endIndex ? "…" : ""
                return head + String(s[start..<end]).trimmingCharacters(in: .whitespaces) + tail
            }
        }
        return nil
    }

    static func vocabularyContagion(conversations: [(messages: [Message], cwd: String)],
                                    lexicon: Set<String>,
                                    limit: Int,
                                    functionWords: Set<String> = [])
        -> [Contagion] {
        let words = lexicon.filter { $0.count >= 3 }
        var canonical: [String: String] = [:]
        for w in words { canonical[w.lowercased()] = w }
        let summaries = conversations.map {
            (summary: contagionSummary(messages: $0.messages, canonical: canonical), cwd: $0.cwd)
        }
        return mergeContagion(summaries, limit: limit, functionWords: functionWords)
    }

    /// 单场会话对「词汇传染」的贡献：每个词表词的 AI 首现 / 你首现（时间戳 + 那句话）。
    struct ContagionSummary {
        var aiFirst: [String: (at: Date, sentence: String)] = [:]
        var userFirst: [String: (at: Date, sentence: String)] = [:]
        /// 你说过的词（合并时按会话 cwd 计项目数）
        var userWords: Set<String> = []
        /// 会话里出现过的词（合并时计 DF）
        var seen: Set<String> = []
    }

    static func contagionSummary(messages: [Message], canonical: [String: String]) -> ContagionSummary {
        // 从文本里取窗口查词表,而不是拿每个词去 contains 整段文本:
        // 后者是 O(词表 × 语料),真机 2324 词 × 数千条消息直接把测试从 12 秒
        // 拖到 563 秒（2026-08-18 实测）。
        // 窗口按**词元**取,不按字符:字符窗口 3..8 对中文正好(词表词 ≤6 字),
        // 但「visual language」有 15 个字符,英文词表词整个被排除——
        // 英文用户的这一层恒空(2026-08-19 发现)。词元窗口 1..6 两边通吃:
        // 中文一字一词元,英文一词一词元。
        func hits(in text: String) -> Set<String> {
            var out = Set<String>()
            let toks = phraseTokenRanges(text)
            for n in 1...6 where toks.count >= n {
                for i in 0...(toks.count - n) {
                    let gram = String(text[toks[i].lowerBound..<toks[i + n - 1].upperBound])
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    if let orig = canonical[gram] { out.insert(orig) }
                }
            }
            return out
        }
        var s = ContagionSummary()
        for m in messages {
            // 「你说的」走 user_corpus 同一套剥离口径(注入头/图片标记/压平),
            // 不能用 textBlocksOnly——那只剥图片标记,Codex 文件引用头会原样
            // 留下,真机上取到过带家目录路径的注入行,还会写进 minds.md。AI 侧没有注入问题,照旧。
            let text: String
            switch m.role {
            case .user:
                guard let t = Segmenter.userTextOfSingle(m) else { continue }
                text = t
            default:
                text = Segmenter.textBlocksOnly(of: m)
            }
            guard text.count >= 4 else { continue }
            for w in hits(in: text) {
                s.seen.insert(w)
                switch m.role {
                case .assistant:
                    if s.aiFirst[w].map({ m.timestamp < $0.at }) ?? true {
                        s.aiFirst[w] = (m.timestamp, sentence(containing: w, in: text) ?? s.aiFirst[w]?.sentence ?? "")
                    }
                case .user:
                    if s.userFirst[w].map({ m.timestamp < $0.at }) ?? true {
                        s.userFirst[w] = (m.timestamp, sentence(containing: w, in: text) ?? s.userFirst[w]?.sentence ?? "")
                    }
                    s.userWords.insert(w)
                default: break
                }
            }
        }
        return s
    }

    static func mergeContagion(_ summaries: [(summary: ContagionSummary, cwd: String)],
                               limit: Int, functionWords: Set<String>) -> [Contagion] {
        var aiFirst: [String: Date] = [:]
        var userFirst: [String: Date] = [:]
        var userProjects: [String: Set<String>] = [:]
        var conversationsWith: [String: Int] = [:]
        var aiSentence: [String: String] = [:]
        var userSentence: [String: String] = [:]
        for (s, cwd) in summaries {
            for (w, v) in s.aiFirst where aiFirst[w].map({ v.at < $0 }) ?? true {
                aiFirst[w] = v.at
                if !v.sentence.isEmpty || aiSentence[w] == nil { aiSentence[w] = v.sentence }
            }
            for (w, v) in s.userFirst where userFirst[w].map({ v.at < $0 }) ?? true {
                userFirst[w] = v.at
                if !v.sentence.isEmpty || userSentence[w] == nil { userSentence[w] = v.sentence }
            }
            for w in s.userWords { userProjects[w, default: []].insert(cwd) }
            for w in s.seen { conversationsWith[w, default: 0] += 1 }
        }
        let conversations = summaries
        let docTotal = max(conversations.count, 1)
        var out: [Contagion] = []
        for (w, uf) in userFirst {
            guard let af = aiFirst[w], af < uf else { continue }
            let gap = Int(uf.timeIntervalSince(af) / 86400)
            let projects = userProjects[w]?.count ?? 0
            guard gap >= contagionMinGapDays, projects >= contagionMinProjects,
                  docTotal < contagionMinConversations
                    || Double(conversationsWith[w] ?? 0) / Double(docTotal) <= contagionMaxDF,
                  !edgeIsFunctionWord(w, functionWords: functionWords)
            else { continue }
            // 纯拉丁多词组合大多是虚词串(do not / is not)——但词表里的英文词
            // 本身就是拉丁的,只拦「不在词表原形里」的组合没有意义了:
            // 词表准入已经筛过一轮(凝固度+边界熵),这里不再重复拦。
            out.append(Contagion(word: w, gapDays: gap, projects: projects,
                                 itSaid: aiSentence[w] ?? "", youSaid: userSentence[w] ?? ""))
        }
        // 先按你带它走了几个项目（接得有多深），再按隔了多久（隔越久越说明是真学到）
        return Array(out.sorted {
            $0.projects != $1.projects ? $0.projects > $1.projects : $0.gapDays > $1.gapDays
        }.prefix(limit))
    }

    /// 进程级缓存：file_path → (mtime, 词表指纹, 单场摘要)。每轮扫描收尾整体替换，
    /// 顺带淘汰已删除的会话。
    private static var contagionCache: [String: (mtime: Double, lexKey: Int, summary: ContagionSummary)] = [:]
    private static let contagionCacheLock = NSLock()

    static func contagionAcrossLibrary(metadata: [ConversationLite], lexicon: Set<String>,
                                       limit: Int, functionWords: Set<String>) -> [Contagion] {
        let words = lexicon.filter { $0.count >= 3 }
        var canonical: [String: String] = [:]
        for w in words { canonical[w.lowercased()] = w }
        var hasher = Hasher()
        for w in words.sorted() { hasher.combine(w) }
        let lexKey = hasher.finalize()

        contagionCacheLock.lock()
        let cache = contagionCache
        contagionCacheLock.unlock()
        var fresh: [String: (mtime: Double, lexKey: Int, summary: ContagionSummary)] = [:]
        var summaries: [(summary: ContagionSummary, cwd: String)] = []
        summaries.reserveCapacity(metadata.count)
        for lite in metadata {
            let path = lite.fileURL.path
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
                .timeIntervalSince1970 ?? -1
            if let c = cache[path], c.mtime == mtime, c.lexKey == lexKey {
                summaries.append((c.summary, lite.cwd))
                fresh[path] = c
                continue
            }
            // 单场解析完立即统计并释放整份消息，不与其他会话同时驻留
            let summary: ContagionSummary? = autoreleasepool {
                guard let conv = LoaderRuntime.fullParse(url: lite.fileURL, source: lite.source) else { return nil }
                return contagionSummary(messages: conv.messages, canonical: canonical)
            }
            guard let summary else { continue }
            summaries.append((summary, lite.cwd))
            fresh[path] = (mtime, lexKey, summary)
        }
        contagionCacheLock.lock()
        contagionCache = fresh
        contagionCacheLock.unlock()
        return mergeContagion(summaries, limit: limit, functionWords: functionWords)
    }

    /// 传染词显示几个
    static let contagionShown = 10

    /// 前几个词带上「案发现场」的两句原话。全带的话这一节撑成三十行。
    static let contagionQuoted = 4

    /// 「它教你的词」：它先说、你后来接过来、并且带着走了几个项目。
    static func renderContagion(_ items: [Contagion]) -> String {
        var lines = ["## WORDS IT TAUGHT YOU",
                     "Words it used first — you picked them up later and carried them across projects. "
                        + "(mechanical, \(items.count))"]
        if items.isEmpty {
            lines.append("(none yet)")
        } else {
            for i in items {
                lines.append("- \(i.word) — \(i.gapDays)d later, \(i.projects) projects")
            }
            // 词是压缩的,句子才看得出发生了什么:它当时怎么说的、你后来怎么接的。
            // 挑**两句都在**的前几个——列表排序把常用词排前面,而案发现场
            // 值得留给真概念(第一版 prefix(4) 取到的全是空句子的常用词)。
            var quoted = 0
            for i in items where quoted < contagionQuoted {
                guard !i.itSaid.isEmpty, !i.youSaid.isEmpty else { continue }
                lines.append("- \(i.word) — it: \(i.itSaid)")
                lines.append("- \(i.word) — you: \(i.youSaid)")
                quoted += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 短语要跨几个项目才算「跟着你走」。也是能力阶梯上这一层的解锁条件。
    public static let phraseMinProjects = 3

    /// 「你可能忘了的」的时间下限（与 ConversationIndex.forgottenRelated 的
    /// 默认参数同一个值）——库龄不足它,一切都还「记得」,这一层无从谈起。
    public static let recallUnlockDays = 30

    /// 多长的对话才值得有目录。OutlineButton 的真实门槛是节点 ≥3,
    /// 但节点数无法从库的统计里预测;200 条消息是「滚不动了」的经验口径
    /// （真机 30 场长对话的分析基线就是它）。
    public static let outlineWorthMessages = 200

    /// 一条待解锁的能力:kind 标识哪一层,now/needed 是卡住它的那个维度。
    public struct PendingCapability: Equatable, Sendable {
        public let kind: String
        public let now: Int
        public let needed: Int
        public init(kind: String, now: Int, needed: Int) {
            self.kind = kind; self.now = now; self.needed = needed
        }
        public static let allKinds = ["phrases", "contagion", "recall", "outline"]
    }

    /// 能力阶梯：对「保证对所有人有价值」的工程兑现。
    ///
    /// 十一条被否掉的信号 + 各层覆盖率共同证明:**单一信号不可能通用**——
    /// 每个信号都依赖某种前提(跨项目/库龄/语言/交互习惯)。保证只能这样给:
    ///
    ///     保证 = 底座(无条件成立) + 阶梯(每层声明前提,满足即点亮)
    ///
    /// 底座是保管与找回,第 1 场对话起就成立,所以**不在**这张清单里——
    /// 清单只列还没点亮的层和「还差多少」。全部点亮时返回空,界面随之收起。
    ///
    /// 阈值一律引用各层真实的门槛常量,不许另抄数字:抄的那份必然漂移。
    public static func pendingCapabilities(conversations: Int, projects: Int,
                                           daySpanDays: Int, longestConversation: Int)
        -> [PendingCapability] {
        var out: [PendingCapability] = []
        if projects < phraseMinProjects {
            out.append(.init(kind: "phrases", now: projects, needed: phraseMinProjects))
        }
        if conversations < contagionMinConversations {
            out.append(.init(kind: "contagion", now: conversations,
                             needed: contagionMinConversations))
        } else if projects < contagionMinProjects {
            out.append(.init(kind: "contagion", now: projects, needed: contagionMinProjects))
        }
        if daySpanDays < recallUnlockDays {
            out.append(.init(kind: "recall", now: daySpanDays, needed: recallUnlockDays))
        }
        if longestConversation < outlineWorthMessages {
            out.append(.init(kind: "outline", now: longestConversation,
                             needed: outlineWorthMessages))
        }
        return out
    }

    /// 一条代表句的长度区间。短于下界没有信息（「AI 味」本身），
    /// 长于上界就不是一句话而是一段话，摘出来也读不动。
    static let quoteLength = 10...70

    /// 把一个短语**展开成你说过的原话**。
    ///
    /// 短语层给的是压缩后的价值——「AI 味」只有三个字；而
    /// 「太丑，太 AI 味，布局也不高端，缺乏质感」才说清了你到底要什么。
    /// 这一层不产生新判断：锚点（跨项目复现的短语）已经由短语层验证过，
    /// 这里只负责把它还原成完整表达。
    ///
    /// 同一个项目最多出一句：要展示的是**跨项目的一致性**——同一句主张
    /// 你在几个不相干的项目里都说过，它才是跟着你走的偏好，而不是
    /// 某个项目的具体要求。
    static func phraseQuotes(corpus: [(text: String, cwd: String)],
                             phrase: String,
                             limit: Int) -> [(text: String, cwd: String)] {
        var out: [(text: String, cwd: String)] = []
        var seenText = Set<String>()
        var usedProject = Set<String>()
        for (text, cwd) in corpus {
            guard !usedProject.contains(cwd) else { continue }
            for line in text.split(separator: "\n") {
                for piece in line.split(whereSeparator: { "。！？!?;；".contains($0) }) {
                    let sentence = piece.trimmingCharacters(in: .whitespaces)
                    guard sentence.contains(phrase),
                          quoteLength.contains(sentence.count),
                          !seenText.contains(sentence) else { continue }
                    seenText.insert(sentence)
                    usedProject.insert(cwd)
                    out.append((text: sentence, cwd: cwd))
                    break
                }
                if usedProject.contains(cwd) { break }
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// 跨项目高频短语:比词长、比句短的中间层——你的思维口令(「从第一性原理思考」)、
    /// 固定问法(「是什么意思」「是不是需要」)、审美红线(「AI 味」)全在这一层。
    ///
    /// 算法是从真实数据反推出来的(用户 2026-08-16 定的方法:先人工找出该被发现的
    /// 模式,再倒推什么规则能自动发现它们)。四条规则:
    /// ① 4-12 字 n-gram,按标点切片段内提取(不跨句)
    /// ② 边界完整:不切断英文单词(「kill 的」这类残片出局)
    /// ③ 首尾不是结构助词/量词(「的 skill」出局)
    /// ④ 频次 ≥6 且跨 ≥3 个项目——跨项目才是「跟着你走」而非项目内容
    /// 最后去子串(同频时保留最长的),按跨项目数 × 频次排序。
    static func repeatedPhrases(corpus: [(text: String, cwd: String)],
                                limit: Int,
                                pronouns: Set<String> = [],
                                functionWords: Set<String> = [])
        -> [(phrase: String, times: Int, projects: Int)] {
        var count: [String: Int] = [:]
        var projects: [String: Set<String>] = [:]
        var rightOf: [String: [String: Int]] = [:]
        let seps = CharacterSet(charactersIn: "。！？\n;；，,、：:!?")
        for (text, cwd) in corpus {
            for piece in text.components(separatedBy: seps) {
                let seg = piece.trimmingCharacters(in: .whitespaces)
                let toks = phraseTokenRanges(seg)
                // 下限按字数、上限按词元数:「有 AI 味」只有 3 个词元却有 6 个字,
                // 下限也按词元卡的话这种短句会被整段丢掉(真机上「AI 味」
                // 因此从 61 次掉到 31 次);而上限按字数的话,60 个字符对英文
                // 才十来个词,长句子全被挡在外面。
                guard seg.count >= 4, (2...60).contains(toks.count) else { continue }
                for L in 2...12 where toks.count >= L {
                    for i in 0...(toks.count - L) {
                        // 词元化本身就保证了不会从英文单词中间切开
                        let g = String(seg[toks[i].lowerBound..<toks[i + L - 1].upperBound])
                            .trimmingCharacters(in: .whitespaces)
                        guard g.count >= 4, let f = g.first, let l = g.last,
                              !phraseEdgeStops.contains(f), !phraseEdgeStops.contains(l),
                              // 首尾不能是标点/括号:真机上「】改成【」跨 9 个项目 45 次,
                              // 统计完全成立,但那是「把【A】改成【B】」这个书写习惯的
                              // 括号残片,显示出来是一串符号,不是一句话
                              !isPhraseEdgePunctuation(f), !isPhraseEdgePunctuation(l),
                              // 只排阿拉伯数字:Swift 的 isNumber 对中文数字「一」也为真,
                              // 用它会把「第一性原理」整条毙掉(2026-08-16 实测踩中)
                              !g.contains(where: { $0.isASCII && $0.isNumber }),
                              !g.contains(where: isMachineTextCharacter) else { continue }
                        count[g, default: 0] += 1
                        projects[g, default: []].insert(cwd)
                        // 右邻的词元;段尾记空串——那是「这里是词尾」的证据
                        let right = i + L < toks.count ? String(seg[toks[i + L]]) : ""
                        rightOf[g, default: [:]][right, default: 0] += 1
                    }
                }
            }
        }
        // 成分口水词过滤:短语里任一 CJK 双字成分覆盖太多会话 → 那是句式框架。
        // 只看 CJK 子串——ASCII 的字母 bigram(「skill」的 il/ll)天然高频,
        // 拿它算会把所有含英文的短语误杀。
        let convCount = max(corpus.count, 1)
        var bigramDF: [String: Int] = [:]
        for (text, _) in corpus {
            var seen = Set<String>()
            let a = Array(text)
            for i in 0..<max(a.count - 1, 0) where isCJKChar(a[i]) && isCJKChar(a[i + 1]) {
                seen.insert(String(a[i...i + 1]))
            }
            for g in seen { bigramDF[g, default: 0] += 1 }
        }
        func componentsAreTopical(_ phrase: String) -> Bool {
            guard convCount >= phraseComponentMinConversations else { return true }
            let a = Array(phrase)
            var worst = 0
            for i in 0..<max(a.count - 1, 0) where isCJKChar(a[i]) && isCJKChar(a[i + 1]) {
                worst = max(worst, bigramDF[String(a[i...i + 1])] ?? 0)
            }
            return Double(worst) / Double(convCount) < phraseComponentDFRatio
        }

        // 频次 + 跨项目双门槛,再去子串(长的优先;同频的短子串是碎片)
        // 残片必须在去子串**之前**剔除:否则「AI 产」(18次)会在同族合并里
        // 以更高的频次吃掉「AI 产品」,榜上只剩那一半。
        let cands = count.compactMap { (g, c) -> (String, Int, Int)? in
            let p = projects[g]?.count ?? 0
            guard c >= 6, p >= phraseMinProjects else { return nil }
            guard !isTruncatedFragment(rightNeighbors: rightOf[g] ?? [:]) else { return nil }
            return (g, c, p)
        }.sorted { $0.0.count > $1.0.count }
        // 第一步:长度降序去碎片。长串先入选,同频的短子串是它切碎的残片。
        // 这一步不能按频次排——那样长串不先入选,「从第一性」「原理思考」
        // 这类部分重叠的碎片就没人吃掉了(2026-08-18 改错过一次的现场)。
        var kept: [(phrase: String, times: Int, projects: Int)] = []
        for (g, c, p) in cands {
            if kept.contains(where: { $0.phrase.contains(g) && c <= $0.times + 1 }) { continue }
            kept.append((phrase: g, times: c, projects: p))
        }
        // 第二步:同族合并。互为子串的是同一个概念的不同说法,留频次最高的那个。
        // 真机现场——「第一性原理」一族独占 5 个位置(第一性原理 53× / 从第一性原理
        // 26× / 第一性原理思考 16× / 从第一性原理思考 12× / 按照第一性原理 10×),
        // 把别的概念全挤出榜。子串频次必然 ≥ 超串,所以留下的是最核心的说法。
        var merged: [(phrase: String, times: Int, projects: Int)] = []
        for item in kept.sorted(by: { $0.times > $1.times }) {
            // 按小写比:「Claude Code」和「claude code」是同一个说法,
            // 不该各占一个榜位(真机 47 次 / 12 次曾并列在榜)。
            let lower = item.phrase.lowercased()
            if merged.contains(where: {
                let m = $0.phrase.lowercased()
                return m.contains(lower) || lower.contains(m)
            }) { continue }
            merged.append(item)
        }
        let kept2 = merged
        // 成分过滤放在去子串**之后**:反过来做的话,长短语被成分毙掉后,
        // 它的子串会从碎片堆里冒出来顶替它(真机现场:「我觉得需要」因含「需要」
        // 出局,「我觉得需」这个碎片反而进了榜)。
        return kept2.filter { componentsAreTopical($0.phrase)
            && !containsPronoun($0.phrase, pronouns: pronouns)
            && !edgeIsFunctionWord($0.phrase, functionWords: functionWords) }.sorted {
            $0.projects != $1.projects ? $0.projects > $1.projects : $0.times > $1.times
        }.prefix(limit).map { $0 }
    }

    // MARK: - 汉语语法位置过滤(2026-08-16 创造)

    /// 词在句子里的语法位置画像。
    public struct GrammarProfile {
        public var count = 0        // 词元出现次数
        public var degree = 0       // 前面是程度副词(很/非常/比较…)
        public var deictic = 0      // 前面是指示词(这个/那种…)
        public var preDe = 0        // 前面是「的」(领属:你的架构)
        public var postDe = 0       // 后面是「的」(修饰:类似的)
        public init() {}
    }

    /// 程度副词:能修饰形容词,不能修饰名词——「很复杂」通,「很架构」不通。
    static let degreeAdverbs: Set<String> = ["很", "非常", "比较", "更", "太", "最",
                                             "特别", "挺", "相当", "越来越", "有点", "有些"]
    /// 指示词:需要它才能确定所指的是泛指名词——「这个情况」「那种意思」。
    static let deicticWords: Set<String> = ["这个", "那个", "某个", "某种", "这种", "那种",
                                            "每个", "几个", "哪个", "这些", "那些", "什么"]

    /// 一次分词遍历收齐所有词的语法位置统计(与词频统计同量级,无额外扫描成本)。
    static func grammarProfiles(lexicon: Set<String>, corpus: [String]) -> [String: GrammarProfile] {
        guard !lexicon.isEmpty else { return [:] }
        var out: [String: GrammarProfile] = [:]
        for text in corpus {
            let tokens = PersonalLexicon.segment(text, lexicon: lexicon)
                .split(separator: " ").map(String.init)
            for (i, tok) in tokens.enumerated() where lexicon.contains(tok) {
                var p = out[tok] ?? GrammarProfile()
                p.count += 1
                let prev1 = i > 0 ? tokens[i - 1] : ""
                // 「这个」这类双字指示词可能被切成两个词元,拼回来再判
                let prev2 = i > 1 ? tokens[i - 2] + tokens[i - 1] : ""
                let next1 = i + 1 < tokens.count ? tokens[i + 1] : ""
                if degreeAdverbs.contains(prev1) || degreeAdverbs.contains(prev2) { p.degree += 1 }
                if deicticWords.contains(prev1) || deicticWords.contains(prev2) { p.deictic += 1 }
                if prev1 == "的" { p.preDe += 1 }
                if next1 == "的" { p.postDe += 1 }
                out[tok] = p
            }
        }
        return out
    }

    /// 「这是你的词,还是汉语的词」——三条判定性语法规则,零外部词表、零 LLM。
    ///
    /// 为什么不用统计:12 种统计算法全部失效(TF-IDF / 残差 IDF(Church&Gale) /
    /// 项目分布熵 / 基尼系数 / 卡方 / 离散指数 / 共现广度 / 跨项目·跨月排序…),
    /// 最好的 AUC 0.85 但 top30 命中 0——因为「有个性的词」在词频光谱的**中间带**,
    /// 任何单调排序只捞两个极端。根因:「有个性」不是统计属性,是**语法属性**。
    ///
    /// 三条规则(真机验证:正例保留 7/8,负例排除 9/14,97 个通用词被剔除):
    /// ① 能被程度副词修饰 = 形容词(复杂 .36 · 清晰 .22 · 简单 .13;你的词全 0.00)
    /// ② 常需指示词才确定所指 = 泛指名词(意思 .41 · 情况 .09)
    /// ③ 总以「X 的」出现却少被「的 X」领属 = 修饰语(类似 .45 · 更好 .47 · 相关 .25)
    static func isContentWord(_ p: GrammarProfile) -> Bool {
        guard p.count >= 5 else { return true }   // 样本太少不下判断:宁放过不误杀
        let n = Double(p.count)
        if Double(p.degree) / n >= 0.05 { return false }
        if Double(p.deictic) / n >= 0.09 { return false }
        if Double(p.postDe) / n >= 0.22 && Double(p.preDe) / n < 0.10 { return false }
        return true
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

    /// 汉语虚词的词类。用系统词性标注剔除——**词类是语法事实，不是我对词义的判断**，
    /// 这跟「不要黑名单」不冲突：介词/连词/代词/助词在汉语里是封闭类。
    ///
    /// 为什么需要它：现行榜按出现次数排，虚词天然排不上，所以看着没问题；
    /// 可一旦排序换成「跨项目数」（跟着你走的词才算你的词），虚词立刻冒头——
    /// 它们天然跨所有项目。真机验证（2026-08-18）：按跨项目排的 top16 里
    /// 混进了 非常(Adverb) · 完全(OtherWord) · 以及(Conjunction)。
    ///
    /// 查不到词性的一律**保留**：系统分词器不认识的词（真机上「大模型」就被它
    /// 切开了）不该因为工具的局限而出局。
    static let functionWordClasses: Set<String> = [
        "Adverb", "Conjunction", "Pronoun", "Preposition",
        "Particle", "Determiner", "Interjection", "OtherWord",
    ]

    /// 给语料里的词元打词性，取众数。返回「词 → 是否实词」。
    static func contentWordByPOS(corpus: [String]) -> [String: Bool] {
        var byWord: [String: [String: Int]] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        for text in corpus where !text.isEmpty {
            tagger.string = text
            // 不写死语言:让 NLTagger 自己认。写死简体中文的话,同一套代码
            // 换个说英文的人就整体失效——而 NER / 词性标注本身是多语言的。
            if let lang = NLLanguageRecognizer.dominantLanguage(for: text) {
                tagger.setLanguage(lang, range: text.startIndex..<text.endIndex)
            }
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                                 scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation]) { tag, r in
                guard let tag else { return true }
                byWord[String(text[r]), default: [:]][tag.rawValue, default: 0] += 1
                return true
            }
        }
        return byWord.compactMapValues { dist in
            guard let top = dist.max(by: { $0.value < $1.value })?.key else { return nil }
            return !functionWordClasses.contains(top)
        }
    }

    /// 你引用过的人。
    ///
    /// 为什么值得单开一节：人名的价值不在频次而在「你搬出了谁」。马斯克说 3 次、
    /// 贝索斯说 3 次，按任何频次口径都排不进任何榜，但它们是你思想来源的证据。
    ///
    /// 三条判据全是机械的，2026-08-18 在真机语料上逐条验证过：
    /// ① **系统 NER 认它是人名**（`NLTagger.nameType`，离线、零依赖）
    /// ② **跨 ≥2 个项目**——这一条把「你引用的人」和「项目内容里的人」切得干干净净：
    ///    曹操 29 次、袁绍 8 次、吕布/刘备/关羽/赵云 全部只在 1 个项目（那是三国
    ///    游戏项目里的角色数据）；而宫本茂/乔布斯/马斯克/贝索斯 全部跨 ≥2 个项目。
    /// ③ **NER 一致性**——同一个串每次出现有多大比例被判成人名。「小红」出现 27 次
    ///    只有 6 次被判人名（其余是「小红书」）、「高亮」25%、「陈留」21%，
    ///    都是误识别；真人名一致性 94-100%。
    ///
    /// 不用频次门槛：那正是这一节存在的理由。
    public struct CitedPerson: Equatable, Sendable {
        public let name: String
        /// 你提到他的总次数
        public let mentions: Int
        /// 跨几个项目
        public let projects: Int
    }

    /// NER 的原始产出。单独一层是为了让**策略**可测：`NLTagger` 是系统 ML 模型，
    /// 同一句话在不同 OS 版本上判断可能不同，把它的输出写进断言等于测苹果。
    /// 判据（跨项目、一致性）是我们的策略，必须钉住；识别本身只做冒烟。
    public struct NameDetection: Equatable, Sendable {
        public let name: String
        /// 被判成人名的次数。**只有这一个数来自 NER**——
        /// 跨项目数与总次数一律由策略层按语料实测：NER 只在部分出现处识别成功
        /// （真机上贝索斯出现 3 次只被识别 1 次），拿识别命中处去算扩散度会
        /// 系统性低估，把真人名挡在门外。
        public let taggedHits: Int
        public init(name: String, taggedHits: Int) {
            self.name = name; self.taggedHits = taggedHits
        }
    }

    static func detectPersonNames(corpus: [(text: String, cwd: String)]) -> [NameDetection] {
        var hits: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        for (text, _) in corpus where !text.isEmpty {
            tagger.string = text
            // 不写死语言:让 NLTagger 自己认。写死简体中文的话,同一套代码
            // 换个说英文的人就整体失效——而 NER / 词性标注本身是多语言的。
            if let lang = NLLanguageRecognizer.dominantLanguage(for: text) {
                tagger.setLanguage(lang, range: text.startIndex..<text.endIndex)
            }
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                                 scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
                guard tag == .personalName else { return true }
                let n = String(text[r])
                guard n.count >= 2 else { return true }
                hits[n, default: 0] += 1
                return true
            }
        }
        return hits.map { NameDetection(name: $0.key, taggedHits: $0.value) }
    }

    /// 策略层：从 NER 产出里挑出「你引用的人」。纯函数，判据全部可测。
    static func citedPeople(detections: [NameDetection],
                            corpus: [(text: String, cwd: String)],
                            minProjects: Int = 2,
                            minConsistency: Double = 0.3,
                            limit: Int = 8) -> [CitedPerson] {
        var out: [CitedPerson] = []
        for d in detections where !d.name.isEmpty {
            // 总次数与跨项目数都按语料实测(含没被 NER 判成人名的那些出现处)
            var total = 0
            var projs = Set<String>()
            for (text, cwd) in corpus {
                let n = text.components(separatedBy: d.name).count - 1
                guard n > 0 else { continue }
                total += n
                if !cwd.isEmpty { projs.insert(cwd) }
            }
            guard total > 0, projs.count >= minProjects,
                  Double(d.taggedHits) / Double(total) >= minConsistency else { continue }
            out.append(CitedPerson(name: d.name, mentions: total, projects: projs.count))
        }
        return out.sorted {
            $0.projects != $1.projects ? $0.projects > $1.projects : $0.mentions > $1.mentions
        }.prefix(limit).map { $0 }
    }

    static func citedPeople(corpus: [(text: String, cwd: String)]) -> [CitedPerson] {
        citedPeople(detections: detectPersonNames(corpus: corpus), corpus: corpus)
    }

    /// 技术名词也算「你的常用词」。
    ///
    /// 为什么要单开一条路：`userVocabularyStats` 只数个人词表里的词，而那份词表
    /// 只挖中文（`PersonalLexicon` 碰到非 CJK 字符就断 run，真机上含拉丁字母的词
    /// 恒为 0 个）。所以 GitHub 这类词在「常用词」里永远不会出现——真机上它
    /// 被说了 160 次、覆盖 33 场、跨 28 个项目，却一次都没进过榜。
    ///
    /// 两道门槛都是 Minds 已经在用的判据，不是新发明的语义黑名单：
    /// - **跨项目数**：跟着你走的词才算你的词。NodeNext 说了 48 次但只跨 2 个项目
    ///   （某个项目内部的配置值），出局。
    /// - **出现次数**：node_modules / apply_patch 跨 4-6 个项目但各只说过 5 次
    ///   （粘报错时捎带进来的），出局。
    ///
    /// 大小写不敏感地计数；显示用实体系统给出的规范写法——用户既写 GitHub 也写
    /// github，而实体抽取已经归一过一次，没必要在这里再判一遍「哪个写法算数」。
    static func technicalTerms(candidates: [(text: String, projects: Int)],
                               corpus: [(text: String, cwd: String)],
                               excluding projectTails: Set<String>,
                               minTF: Int, minProjects: Int) -> [VocabWord] {
        let wanted = candidates.filter {
            $0.projects >= minProjects && !projectTails.contains($0.text.lowercased())
        }
        guard !wanted.isEmpty else { return [] }

        var tf: [String: Int] = [:]                 // 小写键
        var df: [String: Int] = [:]
        var projs: [String: Set<String>] = [:]
        var canonical: [String: String] = [:]       // 小写键 → 实体的规范写法
        for w in wanted { canonical[w.text.lowercased()] = w.text }
        let keys = wanted.map { $0.text.lowercased() }

        for (text, cwd) in corpus {
            let lower = text.lowercased()
            for key in keys {
                var n = 0
                var from = lower.startIndex
                while let r = lower.range(of: key, range: from..<lower.endIndex) {
                    n += 1
                    from = r.upperBound
                }
                guard n > 0 else { continue }
                tf[key, default: 0] += n
                df[key, default: 0] += 1
                if !cwd.isEmpty { projs[key, default: []].insert(cwd) }
            }
        }

        return tf.compactMap { key, count in
            guard count >= minTF else { return nil }
            return VocabWord(word: canonical[key] ?? key, tf: count,
                             projects: projs[key]?.count ?? 0, df: df[key] ?? 0)
        }
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

    /// 惊喜区（五节）+ 统计区（五节）——即整份 minds.md（增补节已拆除）。
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
            renderPhrases(surprise.phrases, quotes: surprise.quotesByPhrase),
            renderContagion(surprise.contagion),
            renderPeople(surprise.citedPeople),
            renderRepeatedBriefings(surprise.repeatedBriefings),
            renderOpenLoops(surprise.unfinished),
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
                                         busiest: (day: String, count: Int, messages: Int)?,
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
            lines.append("- busiest day: \(b.day) — \(b.count) conversations, \(b.messages) messages "
                        + "(\(share)% of your conversations, in one day)")
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

    /// 你引用过的人。空态说清楚门槛,不装数据多。
    private static func renderPeople(_ people: [CitedPerson]) -> String {
        var lines = ["## PEOPLE YOU CITE",
                     "People you bring up across projects — where your ideas come from. "
                        + "(mechanical, \(people.count) people)"]
        if people.isEmpty {
            lines.append("(none yet — someone has to come up in at least two projects)")
        } else {
            lines.append("- " + people.map { "\($0.name) (\($0.mentions)×/\($0.projects)p)" }
                .joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    /// 每个锚点展开几条原话。三条足够看出一致性,再多就成了语料倾倒。
    static let quotesPerPhrase = 3

    /// 展开成原话的锚点取前几个。全部展开会把这一节撑成几十行,
    /// 而这一节要的是「一眼看出你反复主张什么」。
    static let phrasesWithQuotes = 5

    private static func renderPhrases(_ ps: [(phrase: String, times: Int, projects: Int)],
                                      quotes: [String: [(text: String, cwd: String)]] = [:]) -> String {
        var lines = ["## PHRASES YOU REPEAT",
                     "Turns of phrase you carry across projects — your thinking commands and stock questions. "
                        + "(mechanical, \(ps.count) phrases)"]
        if ps.isEmpty {
            lines.append("(none yet)")
        } else {
            lines.append("- " + ps.map { "\($0.phrase) (\($0.times)×/\($0.projects)p)" }
                .joined(separator: " · "))
            // 词是压缩的价值,句子才是完整的表达:「AI 味」只有三个字,
            // 「太丑,太 AI 味,布局也不高端」才说清了你到底要什么。
            for p in ps.prefix(phrasesWithQuotes) {
                guard let qs = quotes[p.phrase], !qs.isEmpty else { continue }
                for q in qs {
                    lines.append("- \(p.phrase) — [\(friendlyProjectTail((q.cwd as NSString).lastPathComponent))] "
                                 + String(flattened(q.text).prefix(200)))
                }
            }
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
                        + "(mechanical, \(briefings.count) groups)"]
        if briefings.isEmpty {
            lines.append("(none — you rarely repeat yourself)")
        } else {
            for b in briefings {
                let span = b.spanDays >= 1 ? ", spanning \(b.spanDays) days" : ""
                lines.append("- \(flattened(b.sample).prefix(60)) — said \(b.times)× across \(b.conversations) conversations\(span)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 一条里程碑要显示多少条。多了就成流水账——这一栏要的是「回头一看，
    /// 原来这几件事是我点头放行的」，不是全量日志。
    /// 「悬着的事」：它最后问了你一个问题、你再没回过；或者你问了没人答。
    ///
    /// 这一栏对应「价值 = 遗忘度 × 相关性 × **未闭合度**」的第三项：
    /// 做完的事提醒你没用，悬着的才有价值。真机 5 件，条条可执行
    /// （「要我把它归档提交、还是继续调形态？」）。
    static func renderOpenLoops(_ items: [ConversationIndex.UnfinishedThread]) -> String {
        var lines = ["## OPEN LOOPS",
                     "Threads left hanging — it asked, you never answered. (mechanical, \(items.count))"]
        if items.isEmpty {
            lines.append("(none yet)")
        } else {
            for t in items {
                // 上下文用标题,没标题退回项目名——只有一句「要我开始吗？」
                // 说不清悬的是什么事
                let rawCtx = (t.title?.isEmpty == false
                              ? t.title! : friendlyProjectTail((t.cwd as NSString).lastPathComponent))
                // 自由文本一律压平 + 截断：open_question 是 assistant 尾句，注入者可控；
                // 这份文件每个新会话开头都经 minds_read 进模型上下文，不设上限不行。
                let ctx = String(flattened(rawCtx).prefix(80))
                lines.append("- \(day(t.endAt)) [\(ctx)] \(String(flattened(t.preview).prefix(200)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static let milestonesShown = 12

    /// 「你点头的时刻」：你说「继续」之前，AI 那条汇报的首句。
    ///
    /// 为什么这一栏比「你爱说哪些词」值钱：它是**有内容的事件**——具体、
    /// 可回溯、被你本人认可过。而且信号完全是机械的：认可词表从你自己的
    /// 语料学出来，汇报首句是原文照抄，全程没有模型参与。
    static func renderMilestones(_ stones: [MindsMilestones.Milestone],
                                 total: Int) -> String {
        var lines = ["## MILESTONES",
                     "Work you signed off on — what the AI had just reported when you said OK. "
                     + "(mechanical, \(total) of them)"]
        if stones.isEmpty {
            lines.append("(none yet)")
        } else {
            for m in stones.sorted(by: { $0.at > $1.at }).prefix(milestonesShown) {
                lines.append("- \(day(m.at)) [\(m.approval)] \(m.headline)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static let decisionsShown = 8

    /// 「你拍板的时刻」：它把选择摆到你面前之后，你说的那句话。
    ///
    /// 与里程碑互补——里程碑是「你认可了什么成果」，这一栏是「你怎么做的选择」。
    /// 判据同样机械：AI 那条以问号收尾且够长（=在征询），你的回应不是反问。
    static func renderDecisions(_ items: [MindsMilestones.Decision], total: Int) -> String {
        var lines = ["## DECISIONS",
                     "Calls you made when it put the options in front of you. (mechanical, \(total) of them)"]
        if items.isEmpty {
            lines.append("(none yet)")
        } else {
            for d in items.sorted(by: { $0.at > $1.at }).prefix(decisionsShown) {
                lines.append("- \(day(d.at)) \(d.statement)")
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

    /// 测试入口：渲染是 private，但「0 不写这一段」这条规矩要能被验证。
    static func renderProjectRhythmForTest(_ projects: [ProjectRhythm]) -> String {
        renderProjectRhythm(projects)
    }

    private static func renderProjectRhythm(_ projects: [ProjectRhythm]) -> String {
        var lines = ["## PROJECT RHYTHM",
                     "Top \(projects.count) projects by conversation count. (mechanical, \(projects.count) projects)"]
        if projects.isEmpty {
            lines.append("(none yet)")
        } else {
            for p in projects {
                let produced = p.signedOff > 0 ? "\(p.signedOff) signed off, " : ""
                lines.append("- \(p.cwd) — \(p.count) conversations, \(p.messages) messages, "
                            + produced
                            + "active \(day(p.activeStart)) → \(day(p.activeEnd)), "
                            + "last touched \(day(p.lastTouched))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// (2 字真概念词不再误伤,3 字口头语也拦得住)。
    /// 口水词判据:出现在超过这个比例的会话里 = 你的口头语,不是你的标签。
    /// 0.25→0.15(2026-08-16 实测定阈):真机数据在 15-20% 之间有天然断层——
    /// 泛词全部卡在 20-25%(我们 23.3% · 设计 24.7% · 能力 20.7% · 用户 24.0% ·
    /// 建议 24.0% · 必须 24.7%),有个性的词全部 ≤12%(选择 12.0% · 第一性原理
    /// 10.7% · 架构 10.0% · 调度 8.7% · 复用 6.0% · 宫本茂 1.3%)。
    /// 试过的两条弯路:项目分布熵(复用 0.87 比「我们」0.86 还均匀,无法区分)、
    /// TF-IDF(过度奖励罕见词,「第一性原理」掉到 622 名,榜单全是整合稿/较优价)。
    public static let stopwordDFRatio = 0.15

    static func renderVocabulary(stats: [VocabWord], totalConversations: Int) -> String {
        guard !stats.isEmpty else {
            return ["## VOCABULARY",
                    "Your lexicon, counted in your own messages. (mechanical, 0 terms)",
                    "(none yet)"].joined(separator: "\n")
        }
        let n = max(totalConversations, 1)
        // 唯一的两道筛子(2026-08-16 重做):说得够多 + 不是口水词。
        // 不再判断词的「类型」——代码识别不了类型,按类型设门槛(要跨 5 个项目
        // 才算思维词)会把「宫本茂」「复用」「乔布斯」这类真信号挡在门外。
        // 口水词由 df 比例挡:需要 47% / 什么 40% 出局,复用 6% / 架构 10% 留下。
        // df 阈值只管纯中文词。它的经验依据全部来自中文双字词(定阈时的现场:
        // 我们 23.3% · 设计 24.7% · 能力 20.7% · 用户 24.0% 全在 20-25%,
        // 有个性的词全 ≤12%)。拿它去卡拉丁专名是张冠李戴——GitHub 覆盖 22% 会被
        // 判成「口头语」,可专名不可能是虚词。技术名词自有更严的两道门槛
        // (出现 ≥15 次且跨 ≥3 个项目,见 technicalTerms)。
        let topical = stats.filter { w in
            guard w.word.count >= 2 else { return false }
            let hasLatin = w.word.contains { $0.isASCII && $0.isLetter }
            return hasLatin || Double(w.df) / Double(n) < stopwordDFRatio
        }
        let top = topical
            .sorted { $0.tf != $1.tf ? $0.tf > $1.tf : $0.word < $1.word }
            .prefix(32)
        var lines = ["## VOCABULARY",
                     "Words you keep saying, counted in your own messages (not the AI's replies). "
                        + "Filler words excluded; everything else earns its place by repetition. "
                        + "(mechanical, \(stats.count) terms)"]
        if !top.isEmpty {
            // meta 分隔用「/」——「·」会与词间分隔符冲突,GUI 按「·」拆 chips 时被拆断
            lines.append("- " + top.map { "\($0.word) (\($0.tf)×/\($0.projects)p)" }.joined(separator: " · "))
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
        /// 项目下所有会话的消息总数。
        ///
        /// 场数不能单独代表投入：真机上项目 A 54 场共 6027 条消息（一下午的
        /// 一问一答），项目 B 4 场却有 7914 条。只按场数画条形，条长与
        /// 实际投入成反比（2026-08-18 用户定案：条形按消息数，场数留作副信息）。
        let messages: Int
        /// 这个项目里你**放行过**几件事（里程碑数）。
        ///
        /// 场数和消息数量的是「你花了多少时间」，这一项量的是「产出了什么」。
        /// 覆盖率有限（真机 16% 的会话带这个信号）——它只在「长任务 + 你说继续」
        /// 这种协作模式下产生，问答型对话不产生。所以 0 不代表没产出，
        /// 只代表这个项目的推进方式不产生这个信号，渲染时因此整段略去而不是写 0。
        let signedOff: Int
        let activeStart: Date
        let activeEnd: Date
        let lastTouched: Date

        /// signedOff 给默认值：这一项是后加的，既有调用方（测试夹具）不必都改，
        /// 缺了就是 0 —— 与「渲染时 0 整段略去」的规矩一致。
        init(cwd: String, count: Int, messages: Int, signedOff: Int = 0,
             activeStart: Date, activeEnd: Date, lastTouched: Date) {
            self.cwd = cwd; self.count = count; self.messages = messages
            self.signedOff = signedOff
            self.activeStart = activeStart; self.activeEnd = activeEnd
            self.lastTouched = lastTouched
        }
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
    /// 设计上选了这条路径：项目数至多 10 个、每个项目的会话数在个人库量级下
    /// 是几十到几百条，走 Swift 端 `min`/`max` 比新写一条 `GROUP BY cwd` 聚合 SQL
    /// 更省一次 schema 决策，性能差异在这个量级下可忽略。
    /// 家目录本身、以及工具自己的缓存目录，都不是「项目」。
    ///
    /// 真机上家目录本身（6 场）排进了项目榜第 5、
    /// `~/.claude/plugins/cache/.../skill-creator`（4 场共 12 条消息）也在候选池里——
    /// 前者是在家目录随手起的会话，后者是插件缓存，两者都不是用户心里的「项目」。
    static func isRealProject(_ cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // 家目录本身（末尾斜杠算同一个）
        let normalized = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if normalized == home { return false }
        // 工具自己的目录：点开头的段（.claude/.codex/.cache…）出现在任何一层就排除
        let tail = normalized.hasPrefix(home) ? String(normalized.dropFirst(home.count)) : normalized
        return !tail.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    static func projectRhythms(index: ConversationIndex,
                               projects: [ConversationIndex.FacetCount],
                               signedOff: [String: Int] = [:]) -> [ProjectRhythm] {
        projects.compactMap { fc in
            let ids = index.conversationIDs(for: .project(fc.key), limit: Int.max)
            let metas = index.metadata(forIDs: ids)
            guard !metas.isEmpty else { return nil }
            return ProjectRhythm(cwd: fc.key, count: metas.count,
                                 messages: metas.reduce(0) { $0 + $1.messageCount },
                                 signedOff: signedOff[fc.key] ?? 0,
                                 activeStart: metas.map(\.startAt).min()!,
                                 activeEnd: metas.map(\.startAt).max()!,
                                 lastTouched: metas.map(\.endAt).max()!)
        }
    }

    /// VOCABULARY 排序规则：**≥3 字词优先**（组内按 df 降序），不足 `limit`
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
