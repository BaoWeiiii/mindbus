import SwiftUI
import MindBusCore

/// Minds 模块真内容页：机械自描述五节 + WEAK SPOTS 增补区。
///
/// 数据全部来自 `MindsStore`（minds.md 机械层 + enriched.jsonl 合并视图）。
/// 布局照 2026-08-11 界面稿：单页滚动、max 760 居中；亮色主题 DSLight
///（浏览窗口整体是亮色，稿子的暗色层级逻辑等价映射：sf=卡片、sf2=chip、
/// sf3=AI 待确认条目的更醒目底）。
///
/// write-back 纪律（红线）：AI 补充且未确认的条目必须一眼可辨——
/// sf3 底 + 金调「AI 补充 · 待确认」徽标；确认后回落 sf2 底 + 灰徽标。
struct MindsView: View {
    @ObservedObject var store: ConversationStore
    @StateObject private var minds = MindsStore()
    @ObservedObject private var l10n = L10n.shared

    /// 图表数据快照:onAppear/刷新时取一次,body 只读——此前 vizFadedSeries 等
    /// 直接写在 body 里,hover/滚动引发的每次 body 重算都全量拉 1.3M 字符语料
    /// 重新分配,malloc 高水位只升不降(2026-08-13 内存取证,「有时候 100MB」从犯)。
    struct VizSnapshot {
        var hourly24: [Int] = []
        var weekday7: [Int] = []
        var monthlyFlow: [(month: String, count: Int)] = []
        var shape: ConversationIndex.CollaborationShape?
        var volume: (userChars: Int, totalChars: Int) = (0, 0)
        var dailyHeat: [(day: String, count: Int)] = []
        var fadedSeries: [String: [Int]] = [:]
        var earliest: Date?
        // 单语化:整行陈述节直查数据(不再显 md 英文行)
        var sanctuary: ConversationIndex.SanctuaryStats?
        var vault: (files: Int, bytes: Int64) = (0, 0)
        var rescuedCount: Int = 0
        var busiest: (day: String, count: Int)?
        var switching: (avgPerDay: Double, peak: (day: String, count: Int)?) = (0, nil)
        var activeDays: MindsBuilder.ActiveDays?
        var weekPercentile: (thisWeek: Int, percentile: Int, median: Int)?
        var weekendSplit: (weekday: [ConversationIndex.FacetCount], weekend: [ConversationIndex.FacetCount]) = ([], [])
        var month: (cur: [ConversationIndex.FacetCount], prev: [ConversationIndex.FacetCount],
                    newEntities: [String], lastYear: Int) = ([], [], [], 0)
        var latestNight: (thread: ConversationIndex.UnfinishedThread, clock: String)?
    }
    @State private var viz = VizSnapshot()

    private func refreshViz() {
        var v = VizSnapshot()
        v.hourly24 = store.vizHourly24()
        v.weekday7 = store.vizWeekday7()
        v.monthlyFlow = store.vizMonthlyFlow()
        v.shape = store.vizShape()
        v.volume = store.vizVolume()
        v.dailyHeat = store.dailyHeat()
        v.earliest = store.vizEarliest()
        // faded 词从刚 reload 的 md 解析——语料只拉这一次
        let words = sectionLines("FADED WORDS").filter { $0.hasPrefix("- ") }
            .compactMap(parseRecurring).map(\.word)
        v.fadedSeries = store.vizFadedSeries(words: words)
        // 整行陈述节数据
        v.sanctuary = store.vizSanctuary()
        v.vault = store.vizVault()
        v.rescuedCount = store.rescuedIDs.count
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
        viz = v
    }

    var body: some View {
        ScrollView {
            renderableContent
        }
        .background(DSLight.bg)
        .onAppear {
            minds.reload()
            refreshViz()
        }
    }

    /// 内容层与 ScrollView 分离：ImageRenderer 渲不出 ScrollView 内部
    ///（离屏预览三盲区之一），设计校验时直接渲这个。
    var renderableContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if minds.mechanicalMarkdown.isEmpty && minds.entriesBySpot.isEmpty {
                fileMissing
            } else {
                // 布局(2026-08-16 重排):hero 数字开屏 → 四个语义组,短节双列
                // 配对压缩纵向长度,大节独占整行。空节整节隐藏。
                heroSection

                groupLabel(l10n.s.mindsGroupRhythm)
                heatmapSection
                workRhythmSection
                pair(thisMonthSection, weekendSection)

                groupLabel(l10n.s.mindsGroupHowYouUseAI)
                delegationSection
                questionShapeSection
                pair(shapeSection, leverageSection)
                projectLeverageSection

                groupLabel(l10n.s.mindsGroupLanguage)
                repeatedBriefingsSection
                pair(catchphrasesSection, invokedNamesSection)
                fadedSection

                groupLabel(l10n.s.mindsGroupProjects)
                pair(dormantSection, marathonsSection)

                groupLabel(l10n.s.mindsGroupForAI)
                overviewSection
                projectsSection
                vocabularySection
                weakSpotsSection
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 48)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 头部

    @State private var showWrapped = false

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Minds").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DSLight.t1)
                Text(l10n.s.mindsSubtitle).font(.system(size: 12)).foregroundStyle(DSLight.t2)
                // 信任锚：重建时间 + counted, not generated——机械层可信度的一句话来源
                Text("\(rebuildStamp)\(l10n.s.mindsTrustSuffix)")
                    .font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
            }
            Spacer(minLength: 0)
            // Wrapped 报告入口(行业调研落地:窗口化的对话报告,导出本地 PNG)
            Button { showWrapped = true } label: {
                Label(l10n.s.mindsWrappedButton, systemImage: "sparkles.rectangle.stack")
                    .font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(DSLight.goldG, in: Capsule())
                    .foregroundStyle(DSLight.gold)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showWrapped) { WrappedView(store: store) }
        }
    }

    /// 从机械层首段抽 "(policy v13, rebuilt …)" 那行的日期；抽不到就只显示信任语。
    private var rebuildStamp: String {
        guard let range = minds.mechanicalMarkdown.range(
            of: #"rebuilt \d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return "" }
        return String(minds.mechanicalMarkdown[range]) + "  "
    }

    private var fileMissing: some View {
        Text(l10n.s.mindsFileMissing)
            .font(.system(size: 13)).foregroundStyle(DSLight.t3)
            .padding(.top, 60)
    }

    // MARK: - 机械层解析
    //
    // minds.md 是我们自己机械生成的固定格式（MindsBuilder 单一真相），这里按节名
    // 切开取行做原生渲染——不是通用 Markdown 解析器，格式变更时 MindsBuilder 与
    // 这里要同步改（两处都在仓内，格式测试锁着 Builder 侧）。

    private func sectionLines(_ name: String) -> [String] {
        let md = minds.mechanicalMarkdown
        guard let start = md.range(of: "## \(name)\n") else { return [] }
        let rest = md[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 单语标题(2026-08-13 用户定案:按所选语言展示,不中英并排)。
    /// 英文保持 MONO 大写的设计语言;中文用系统字体加字距。
    private func sectionTitle(_ en: String, _ cn: String, hint: String? = nil) -> some View {
        HStack(spacing: 8) {
            if l10n.isZh {
                Text(cn).font(.system(size: 13, weight: .medium)).kerning(2)
                    .foregroundStyle(DSLight.t2)
            } else {
                Text(en.uppercased())
                    .font(BrandFont.mono(11)).kerning(1.4).foregroundStyle(DSLight.t3)
            }
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(DSLight.t3)
            }
        }
        .padding(.top, 44).padding(.bottom, 14)
    }

    // MARK: - 惊喜区（五节,空则整节隐藏）

    /// 分组标签:惊喜区 / 统计区的阅读指引。金点标「给你的」,灰点标「给 AI 的」。
    private func groupLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(text == l10n.s.mindsGroupForYou ? DSLight.gold : DSLight.t3)
                .frame(width: 5, height: 5)
            Text(text).font(BrandFont.mono(10)).kerning(1.2).foregroundStyle(DSLight.t3)
            Rectangle().fill(DSLight.sf3).frame(height: 1)
        }
        .padding(.top, 40)
    }

    /// 点行打开原会话（会话级定位,消息级留给收藏模块）。
    private func openConversation(_ id: String) {
        store.mindsSelected = false
        store.selectedConversationId = id
    }

    /// (2026-08-13 离屏渲染抓出的空节 bug)。quote 当主行——创世句是主角,项目名是注脚。

    private func parseUnfinished(_ line: String) -> (id: String, label: String, meta: String)? {
        let body = String(line.dropFirst(2))
        guard let idRange = body.range(of: #"\(id: [^)]+\)$"#, options: .regularExpression)
        else { return nil }
        let id = String(body[idRange].dropFirst(5).dropLast(1))
        let front = body[..<idRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let dash = front.range(of: " — ", options: .backwards) else { return nil }
        return (id, String(front[..<dash.lowerBound]),
                String(front[dash.upperBound...]))
    }


    private func parseRecurring(_ line: String) -> (word: String, detail: String)? {
        let body = String(line.dropFirst(2))
        guard let dash = body.range(of: " — ") else { return nil }
        return (String(body[..<dash.lowerBound]), String(body[dash.upperBound...]))
    }

    /// 提问的形状:四类问句横条——认知光谱(md 解析数字,L10n 模板)。
    private var questionShapeSection: some View {
        let lines = sectionLines("QUESTION SHAPE").filter { $0.hasPrefix("- ") }
        // "- should-we 286 · how-to 206 · why 94 · what-is 89"
        let counts: [(String, Int)] = lines.first.map { line in
            line.dropFirst(2).split(separator: "·").compactMap { part -> (String, Int)? in
                let t = part.trimmingCharacters(in: .whitespaces)
                guard let sp = t.lastIndex(of: " "), let n = Int(t[t.index(after: sp)...]) else { return nil }
                return (String(t[..<sp]), n)
            }
        } ?? []
        let kindNames = ["should-we": l10n.s.mQKindConfirm, "how-to": l10n.s.mQKindHow,
                         "why": l10n.s.mQKindWhy, "what-is": l10n.s.mQKindWhat]
        let verdicts = ["should-we": l10n.s.mQVerdictConfirm, "how-to": l10n.s.mQVerdictHow,
                        "why": l10n.s.mQVerdictWhy, "what-is": l10n.s.mQVerdictWhat]
        let maxN = counts.map(\.1).max() ?? 1
        return Group {
            if !counts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Question Shape", l10n.s.mindsSecQuestionShape, hint: l10n.s.mindsQuestionShapeHint)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(counts.enumerated()), id: \.offset) { _, kv in
                            HStack(spacing: 12) {
                                Text(kindNames[kv.0] ?? kv.0)
                                    .font(.system(size: 12)).foregroundStyle(DSLight.t1)
                                    .frame(width: 64, alignment: .leading)
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(kv.1 == maxN ? DSLight.gold : DSLight.gold.opacity(0.35))
                                        .frame(width: max(4, geo.size.width * CGFloat(kv.1) / CGFloat(maxN)), height: 8)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                Text("\(kv.1)").font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .frame(height: 18)
                        }
                        if let top = counts.max(by: { $0.1 < $1.1 }), let v = verdicts[top.0] {
                            Text(v).font(.system(size: 11)).foregroundStyle(DSLight.t3)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// 委托光谱:QUESTION SHAPE 的祈使句孪生——你最常让 AI 干什么活。
    /// 动词是你语料里的原词,zh/en 界面都保留原样(那是你的词,不翻译)。
    private var delegationSection: some View {
        let lines = sectionLines("DELEGATION").filter { $0.hasPrefix("- ") }
        // "- 设计 215×/36c · 验证 192×/40c · …"
        let verbs: [(String, Int, Int)] = lines.first { !$0.hasPrefix("- research") }.map { line in
            line.dropFirst(2).split(separator: "·").compactMap { part -> (String, Int, Int)? in
                let t = part.trimmingCharacters(in: .whitespaces)
                guard let sp = t.lastIndex(of: " ") else { return nil }
                let nums = t[t.index(after: sp)...].split(separator: "×")
                guard nums.count == 2, let l = Int(nums[0]),
                      let c = Int(nums[1].dropFirst().dropLast()) else { return nil }
                return (String(t[..<sp]), l, c)
            }
        } ?? []
        // "- research destination #1: github (12 of your 调研 orders; …" → (github, 12)
        let research: (String, String, String?)? = lines.first { $0.hasPrefix("- research destination") }
            .flatMap { firstTwoGroups($0, #"#1: (\S+) \((\d+)"#) }
        let maxN = verbs.map(\.1).max() ?? 1
        return Group {
            if !verbs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Delegation", l10n.s.mindsSecDelegation, hint: l10n.s.mindsDelegationHint)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(verbs.enumerated()), id: \.offset) { _, kv in
                            HStack(spacing: 12) {
                                Text(kv.0)
                                    .font(.system(size: 12)).foregroundStyle(DSLight.t1)
                                    .frame(width: 64, alignment: .leading)
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(kv.1 == maxN ? DSLight.gold : DSLight.gold.opacity(0.35))
                                        .frame(width: max(4, geo.size.width * CGFloat(kv.1) / CGFloat(maxN)), height: 8)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                Text("\(kv.1) 次 \(kv.2) 场").font(BrandFont.mono(10)).foregroundStyle(DSLight.t3)
                                    .frame(width: 64, alignment: .trailing)
                            }
                            .frame(height: 18)
                        }
                        if let (dest, n, _) = research {
                            Text(String(format: l10n.s.mDelegResearch, dest, n))
                                .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// 项目的第一句话:创世句卡,可点回到起点。
    /// 反复交代的话(观察项 A 的 GUI 节——此前只有 md,本次单语化补齐)。
    private var repeatedBriefingsSection: some View {
        let rows = sectionLines("REPEATED BRIEFINGS").filter { $0.hasPrefix("- ") }
            .compactMap(parseRecurring)
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Repeated Briefings", l10n.s.mindsSecBriefings, hint: l10n.s.mindsBriefingsHint)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows, id: \.word) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "repeat")
                                    .font(.system(size: 11)).foregroundStyle(DSLight.gold)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.word).font(.system(size: 12)).foregroundStyle(DSLight.t1)
                                        .lineLimit(2)
                                    Text(briefMeta(row.detail))
                                        .font(BrandFont.mono(10)).foregroundStyle(DSLight.t3)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // md 行 meta → 单语模板(解析数字,L10n 重组;解析不中回落原文——宁显英文不显错)
    private func recurringMeta(_ d: String) -> String {
        guard let m = firstTwoGroups(d, #"(\d+) conversations, (.+)"#) else { return d }
        return l10n.s.mConvSpan(Int(m.0) ?? 0, m.1)
    }
    private func dormantMeta(_ d: String) -> String {
        guard let m = firstTwoGroups(d, #"(\d+) conversations, last touched (.+)"#) else { return d }
        return l10n.s.mDormantMeta(Int(m.0) ?? 0, m.1)
    }
    private func fadedMeta(_ d: String) -> String {
        guard let m = firstTwoGroups(d, #"said (\d+) times, silent (\d+) days"#) else { return d }
        return l10n.s.mFadedMeta(Int(m.0) ?? 0, Int(m.1) ?? 0)
    }
    private func briefMeta(_ d: String) -> String {
        guard let m = firstTwoGroups(d, #"said (\d+)× across (\d+) conversations"#) else { return d }
        return l10n.s.mBriefSaid(Int(m.0) ?? 0, Int(m.1) ?? 0)
    }
    private func flowMeta(_ d: String) -> String {
        guard let m = firstTwoGroups(d, #"(\d+) shared concepts(.*)"#) else { return d }
        var out = l10n.s.mFlowShared(Int(m.0) ?? 0)
        if let b = firstTwoGroups(m.1, #"(\d+) born in (.+) first"#) {
            out += l10n.s.mFlowBorn(Int(b.0) ?? 0, b.1)
        }
        return out
    }
    private func marathonMeta(_ d: String) -> String {
        // "5497 messages over 64 days, StrategyGame" / "… over 155 h, X"
        if let m = firstTwoGroups(d, #"(\d+) messages over (\d+) days, (.+)"#, third: true) {
            return l10n.s.mMarathonMeta(Int(m.0) ?? 0, l10n.s.mSpanDays(Int(m.1) ?? 0), m.2 ?? "")
        }
        if let m = firstTwoGroups(d, #"(\d+) messages over (\d+) h, (.+)"#, third: true) {
            return l10n.s.mMarathonMeta(Int(m.0) ?? 0, l10n.s.mSpanHours(Int(m.1) ?? 0), m.2 ?? "")
        }
        return d
    }
    /// 正则取前两(三)个捕获组。
    private func firstTwoGroups(_ text: String, _ pattern: String,
                                third: Bool = false) -> (String, String, String?)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text) else { return nil }
        let g3: String? = (third && m.numberOfRanges >= 4)
            ? Range(m.range(at: 3), in: text).map { String(text[$0]) } : nil
        return (String(text[r1]), String(text[r2]), g3)
    }

    /// 从行文本抽两个 ISO 日期,换算成全库时间轴(earliest→今天)上的 0-1 区间。
    private func spanFraction(of detail: String) -> (Double, Double)? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let matches = detail.matchesISO()
        guard matches.count >= 2,
              let a = f.date(from: matches[0]), let b = f.date(from: matches[1]),
              let earliest = viz.earliest else { return nil }
        let total = max(Date().timeIntervalSince(earliest), 86_400)
        let s = max(0, a.timeIntervalSince(earliest) / total)
        let e = min(1, b.timeIntervalSince(earliest) / total)
        return s <= e ? (s, e) : nil
    }

    private var dormantSection: some View {
        // "- proj — 12 conversations, last touched 2026-06-01"
        let rows = sectionLines("DORMANT PROJECTS").filter { $0.hasPrefix("- ") }
            .compactMap(parseRecurring)   // 同构:「名 — 详情」
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Dormant", l10n.s.mindsSecDormant, hint: l10n.s.mindsDormantHint)
                    VStack(spacing: 2) {
                        ForEach(rows, id: \.word) { row in
                            HStack(spacing: 12) {
                                Image(systemName: "moon.zzz")
                                    .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                                Text(row.word).font(.system(size: 13)).foregroundStyle(DSLight.t1)
                                Text(dormantMeta(row.detail))
                                    .font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    private var thisMonthSection: some View {
        let mo = viz.month
        let cur = mo.cur.reduce(0) { $0 + $1.count }
        let prev = mo.prev.reduce(0) { $0 + $1.count }
        return Group {
            if cur > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("This Month", l10n.s.mindsSecThisMonth)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.s.mMonthHead(cur, prev > 0 ? l10n.s.mMonthDelta(cur - prev) : ""))
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(DSLight.t1)
                        let flow = viz.monthlyFlow
                        if flow.count >= 2 {
                            MindsCharts.MonthlyFlow(months: flow)
                                .padding(.top, 4)
                        }
                        if !mo.cur.isEmpty {
                            Text(l10n.s.mMonthTools(mo.cur.map { "\(sourceName($0.key)) \($0.count)" }
                                .joined(separator: " · ")))
                                .font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
                        }
                        if !mo.newEntities.isEmpty {
                            Text(l10n.s.mMonthFirstSeen(mo.newEntities.joined(separator: " · ")))
                                .font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
                                .lineLimit(2)
                        }
                        if mo.lastYear > 0 {
                            Text(l10n.s.mMonthLastYear(mo.lastYear))
                                .font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// 工具展示名(与侧栏同源,单语)。
    private func sourceName(_ raw: String) -> String {
        ConversationSource(rawValue: raw)?.displayName(isZh: l10n.isZh) ?? raw
    }


    // MARK: - 惊喜区五批:保管所(价值感——守护状态宣言)

    /// Backblaze「You are backed up as of…」句式:常驻、现在时、金盾图标。
    /// 数据直查+L10n 模板(单语化:GUI 不再显 md 英文行)。
    /// 双列配对:两个矮节并排,压缩纵向长度(宽屏 1000 列下每列 ~490)。
    /// top 对齐——两节高度不等时短的悬顶,不拉伸。
    private func pair(_ a: some View, _ b: some View) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) { a }
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { b }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Hero 数字带:开屏价值感——四个大数字横排(对话/副本/库龄/救回),
    /// 里程碑与最近收录作副行。金色只给「已救回」(价值最强的数字)。
    private var heroSection: some View {
        Group {
            if let st = viz.sanctuary, st.conversationCount > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("SANCTUARY", l10n.s.mindsSecSanctuary, hint: l10n.s.mindsSanctuaryHint)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 0) {
                            heroNumber("\(st.conversationCount)", l10n.s.heroConversations)
                            heroNumber(String(format: "%.0f MB", Double(viz.vault.bytes) / 1_048_576),
                                       l10n.s.heroVaultCopies)
                            heroNumber("\(st.earliest.map { max(1, Int(Date().timeIntervalSince($0) / 86_400) + 1) } ?? 1)",
                                       l10n.s.heroLibraryDays)
                            if viz.rescuedCount > 0 {
                                heroNumber("\(viz.rescuedCount)", l10n.s.heroRescued, gold: true)
                            }
                            Spacer(minLength: 0)
                        }
                        heroFootnote(st)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func heroNumber(_ value: String, _ label: String, gold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(gold ? DSLight.gold : DSLight.t1)
            Text(label)
                .font(.system(size: 11)).foregroundStyle(DSLight.t3)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    private func heroFootnote(_ st: ConversationIndex.SanctuaryStats) -> some View {
        var parts: [String] = []
        if st.outlivedClaudeCode > 0 { parts.append(l10n.s.mSanctuaryOutlived(st.outlivedClaudeCode)) }
        var passed: [String] = []
        if let m = MindsBuilder.highestMilestone(st.conversationCount, in: MindsBuilder.conversationMilestones) {
            passed.append(l10n.s.mSanctuaryMileConv(m))
        }
        if let m = MindsBuilder.highestMilestone(viz.volume.totalChars, in: MindsBuilder.characterMilestones) {
            passed.append(l10n.s.mSanctuaryMileChars(MindsBuilder.compactChars(m)))
        }
        if !passed.isEmpty { parts.append(l10n.s.mSanctuaryMilestones(passed.joined(separator: "、"))) }
        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: "    "))
                    .font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
            }
        }
    }

    private var sanctuarySection: some View {
        var rows: [String] = []
        if let st = viz.sanctuary, st.conversationCount > 0 {
            let mb = String(format: "%.0f MB", Double(viz.vault.bytes) / 1_048_576)
            let days = st.earliest.map { max(1, Int(Date().timeIntervalSince($0) / 86_400) + 1) } ?? 1
            rows.append(l10n.s.mSanctuaryHead(st.conversationCount, viz.vault.files, mb, days))
            if viz.rescuedCount > 0 { rows.append(l10n.s.mSanctuaryRescued(viz.rescuedCount)) }
            if st.outlivedClaudeCode > 0 { rows.append(l10n.s.mSanctuaryOutlived(st.outlivedClaudeCode)) }
            var passed: [String] = []
            if let m = MindsBuilder.highestMilestone(st.conversationCount, in: MindsBuilder.conversationMilestones) {
                passed.append(l10n.s.mSanctuaryMileConv(m))
            }
            if let m = MindsBuilder.highestMilestone(viz.volume.totalChars, in: MindsBuilder.characterMilestones) {
                passed.append(l10n.s.mSanctuaryMileChars(MindsBuilder.compactChars(m)))
            }
            if !passed.isEmpty { rows.append(l10n.s.mSanctuaryMilestones(passed.joined(separator: "、"))) }
            if let latest = st.latestActivity {
                rows.append(l10n.s.mSanctuaryCollected(Self.dayString(latest)))
            }
        }
        return dataCard("SANCTUARY", title: l10n.s.mindsSecSanctuary, hint: l10n.s.mindsSanctuaryHint,
                        icons: ["shield.checkered", "shield.lefthalf.filled", "clock.badge.checkmark", "flag", "tray.and.arrow.down"],
                        rows: rows)
    }

    /// 数据版陈述卡:与 statementCard 同形,但行来自 L10n 模板而非 md 解析。
    private func dataCard(_ en: String, title: String, hint: String,
                          icons: [String], rows: [String],
                          @ViewBuilder chart: () -> some View = { EmptyView() }) -> some View {
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle(en, title, hint: hint)
                    VStack(alignment: .leading, spacing: 10) {
                        chart()
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: icons[min(i, icons.count - 1)])
                                    .font(.system(size: 11)).foregroundStyle(DSLight.gold)
                                    .frame(width: 16)
                                Text(row).font(BrandFont.mono(12)).foregroundStyle(DSLight.t1)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: - 惊喜区四批:协作形状 / 周末的你 / 项目杠杆榜 / 知识流动

    /// 三行数字陈述卡(图标 + mono 行);`chart` 非空时图表置于文字行上方——
    /// 图是文字的补充不是替换(Lupi:数字连回人话)。
    private func statementCard<C: View>(_ name: String, title: String, hint: String,
                                        icons: [String],
                                        @ViewBuilder chart: () -> C = { EmptyView() }) -> some View {
        let rows = sectionLines(name).filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle(name.capitalized, title, hint: hint)
                    VStack(alignment: .leading, spacing: 10) {
                        chart()
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: icons[min(i, icons.count - 1)])
                                    .font(.system(size: 11)).foregroundStyle(DSLight.gold)
                                    .frame(width: 16)
                                if let pct = percentileIn(row) {
                                    Text(row).font(BrandFont.mono(12)).foregroundStyle(DSLight.t1)
                                        .lineLimit(3)
                                    MindsCharts.PercentileSlider(percentile: pct)
                                        .frame(width: 120)
                                } else {
                                    Text(row).font(BrandFont.mono(12)).foregroundStyle(DSLight.t1)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// 行文本里的个人史分位(「— P92 of your own history」)——命中则行尾配滑条。
    private func percentileIn(_ row: String) -> Int? {
        guard let r = row.range(of: #"P(\d{1,3}) of your own history"#, options: .regularExpression),
              let p = Int(row[r].dropFirst(1).prefix(while: { $0.isNumber })) else { return nil }
        return min(100, max(0, p))
    }

    private var shapeSection: some View {
        var rows: [String] = []
        if let sh = viz.shape {
            let tTotal = sh.turnBands.reduce(0, +)
            let dTotal = sh.durationBands.reduce(0, +)
            if tTotal > 0 { rows.append(l10n.s.mShapeTurns(sh.turnBands[3] * 100 / tTotal)) }
            if dTotal > 0 {
                rows.append(l10n.s.mShapeBimodal(sh.durationBands[0] * 100 / dTotal,
                                                 sh.durationBands[3] * 100 / dTotal))
            }
            if sh.avgCharsPerMessage > 0 { rows.append(l10n.s.mShapeAvg(sh.avgCharsPerMessage)) }
        }
        return dataCard("COLLABORATION SHAPE", title: l10n.s.mindsSecShape, hint: l10n.s.mindsShapeHint,
                        icons: ["arrow.triangle.2.circlepath", "hourglass", "text.alignleft"],
                        rows: rows) {
            if let sh = viz.shape {
                MindsCharts.ShapeHistograms(shape: sh,
                                            durationLabels: ["<2m", "2-30m", "0.5-2h", "2h+"],
                                            turnLabels: ["1-2", "3-5", "6-15", "16+"])
            }
        }
    }

    private var weekendSection: some View {
        var rows: [String] = []
        let split = viz.weekendSplit
        if !split.weekend.isEmpty {
            rows.append(l10n.s.mWeekendLine(split.weekend.prefix(3)
                .map { "\($0.key) \($0.count)" }.joined(separator: " · ")))
        }
        if !split.weekday.isEmpty {
            rows.append(l10n.s.mWeekdayLine(split.weekday.prefix(5)
                .map { "\($0.key) \($0.count)" }.joined(separator: " · ")))
        }
        let dayLabels = l10n.isZh ? ["一", "二", "三", "四", "五", "六", "日"]
                                  : ["M", "T", "W", "T", "F", "S", "S"]
        return dataCard("WEEKEND SELF", title: l10n.s.mindsSecWeekend, hint: l10n.s.mindsWeekendHint,
                        icons: ["sun.max", "calendar"], rows: rows) {
            MindsCharts.WeekdayBars(days: viz.weekday7, labels: dayLabels)
        }
    }

    /// 项目杠杆榜:比率大数字 + 条形。
    private var projectLeverageSection: some View {
        // "- name — 1:45 (3k typed → 170k, 5 conversations)"
        let rows = sectionLines("LEVERAGE BY PROJECT").filter { $0.hasPrefix("- ") }
            .compactMap(parseRecurring)
        let ratios = rows.compactMap { row -> Int? in
            guard let r = row.detail.range(of: #"^1:\d+"#, options: .regularExpression) else { return nil }
            return Int(row.detail[r].dropFirst(2))
        }
        let maxRatio = ratios.max() ?? 1
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Leverage by Project", l10n.s.mindsSecProjectLeverage,
                                 hint: l10n.s.mindsProjectLeverageHint)
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            HStack(spacing: 12) {
                                Text(row.word).font(.system(size: 13)).foregroundStyle(DSLight.t1)
                                    .frame(width: 140, alignment: .leading).lineLimit(1)
                                Text(i < ratios.count ? "1:\(ratios[i])" : "")
                                    .font(BrandFont.mono(12, weight: .medium)).foregroundStyle(DSLight.gold)
                                    .frame(width: 54, alignment: .trailing)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(DSLight.gold.opacity(0.55))
                                        .frame(width: max(4, geo.size.width * CGFloat(i < ratios.count ? ratios[i] : 0) / CGFloat(maxRatio)))
                                }
                                .frame(height: 5)
                                .background(DSLight.sf2, in: RoundedRectangle(cornerRadius: 3))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    /// 知识流动:A ↔ B 共享概念数,点任一端进项目搜索。

    // MARK: - 惊喜区三批:那年今日 / 热力图 / 口头禅 / 独一无二

    @State private var mutedThisSession: Set<String> = []

    /// 活跃热力图:数据不走 minds.md(365 行数据不进文本文件),直接查 store。
    private var heatmapSection: some View {
        let daily = viz.dailyHeat
        return Group {
            if !daily.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Activity Map", l10n.s.mindsSecHeatmap, hint: l10n.s.mindsHeatmapHint)
                    HeatmapGrid(daily: daily, store: store, onOpen: openConversation)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// 你搬出过的名字:引用谁=思维参照系。chips 同口头禅形态,金字胶囊。
    private var invokedNamesSection: some View {
        let line = sectionLines("NAMES YOU INVOKE").first { $0.hasPrefix("- ") }
        let chips: [(String, String)] = line.map {
            $0.dropFirst(2).split(separator: "|").compactMap { part in
                let t = part.trimmingCharacters(in: .whitespaces)
                guard let m = firstTwoGroups(t, #"^(.+) (\d+)x/(\d+)c$"#, third: true),
                      let g3 = m.2 else { return nil }
                return (m.0, l10n.s.mInvokedMeta(Int(m.1) ?? 0, Int(g3) ?? 0))
            }
        } ?? []
        return Group {
            if !chips.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Names You Invoke", l10n.s.mindsSecInvokedNames,
                                 hint: l10n.s.mindsInvokedNamesHint)
                    FlowLayout(spacing: 8) {
                        ForEach(chips, id: \.0) { chip in
                            HStack(spacing: 6) {
                                Text(chip.0)
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DSLight.t1)
                                Text(chip.1)
                                    .font(BrandFont.mono(10)).foregroundStyle(DSLight.gold)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(DSLight.sf, in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var catchphrasesSection: some View {
        let lines = sectionLines("CATCHPHRASES").filter { $0.hasPrefix("- ") }
        let phraseLine = lines.first { !$0.hasPrefix("- politeness") }
        let politeLine = lines.first { $0.hasPrefix("- politeness") }
        let chips = phraseLine.map {
            $0.dropFirst(2).split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        } ?? []
        return Group {
            if !chips.isEmpty || politeLine != nil {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Catchphrases", l10n.s.mindsSecCatchphrases, hint: l10n.s.mindsCatchphrasesHint)
                    VStack(alignment: .leading, spacing: 10) {
                        if !chips.isEmpty {
                            FlowLayout(spacing: 8) {
                                ForEach(chips, id: \.self) { chip in
                                    // "继续 ×47" → 短句 + 次数
                                    let parts = chip.split(separator: "×", maxSplits: 1)
                                    HStack(spacing: 5) {
                                        Text(parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? chip)
                                            .font(.system(size: 13, weight: .medium)).foregroundStyle(DSLight.t1)
                                        if parts.count > 1 {
                                            Text(parts[1].trimmingCharacters(in: .whitespaces) + " 次")
                                                .font(BrandFont.mono(11)).foregroundStyle(DSLight.gold)
                                        }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(DSLight.sf, in: Capsule())
                                }
                            }
                        }
                        if let politeLine {
                            let list = String(politeLine.dropFirst(2))
                                .replacingOccurrences(of: "politeness & delegation: ", with: "")
                                .replacingOccurrences(of: " ×", with: " ")
                                .replacingOccurrences(of: " · ", with: "、")
                            Text(l10n.s.mPoliteness(list))
                                .font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                        }
                    }
                }
            }
        }
    }


    // MARK: - 惊喜区二批:工作节律 / 杠杆率 / 马拉松 / 不再说的词

    private var workRhythmSection: some View {
        let quarters = stride(from: 0, to: 24, by: 4).map { h in
            viz.hourly24.dropFirst(h).prefix(4).reduce(0, +)
        }
        let total = quarters.reduce(0, +)
        let names = ["00-04", "04-08", "08-12", "12-16", "16-20", "20-24"]
        var rows: [String] = []
        if total > 0, let maxIdx = quarters.indices.max(by: { quarters[$0] < quarters[$1] }) {
            rows.append(l10n.s.mRhythmPeak(names[maxIdx], quarters[maxIdx] * 100 / total, quarters[maxIdx], total))
        }
        if let b = viz.busiest, total > 0 {
            rows.append(l10n.s.mRhythmBusiest(b.day, b.count, b.count * 100 / max(total, 1)))
        }
        if let peak = viz.switching.peak, viz.switching.avgPerDay > 0 {
            rows.append(l10n.s.mRhythmJuggle(String(format: "%.1f", viz.switching.avgPerDay), peak.count, peak.day))
        }
        if let a = viz.activeDays, a.active > 0 {
            rows.append(l10n.s.mRhythmActive(a.active, a.window, a.longestRun, a.longestGap))
        }
        if let wp = viz.weekPercentile {
            rows.append(l10n.s.mRhythmWeek(wp.thisWeek, wp.percentile, wp.median))
        }
        return dataCard("WORK RHYTHM", title: l10n.s.mindsSecWorkRhythm, hint: l10n.s.mindsWorkRhythmHint,
                        icons: ["clock", "flame", "arrow.triangle.swap", "calendar", "chart.bar"],
                        rows: rows) {
            MindsCharts.HourlyStrip(hours: viz.hourly24)
        }
    }

    private var leverageSection: some View {
        let vol = viz.volume
        let ratio = vol.userChars > 0 ? vol.totalChars / vol.userChars : 0
        return Group {
            if ratio > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Leverage", l10n.s.mindsSecLeverage, hint: l10n.s.mindsLeverageHint)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("1:\(ratio)").font(BrandFont.mono(28, weight: .medium))
                                .foregroundStyle(DSLight.gold)
                            Text(l10n.s.mLeverageLine(MindsBuilder.compactChars(vol.userChars),
                                                      MindsBuilder.compactChars(vol.totalChars)))
                                .font(.system(size: 12)).foregroundStyle(DSLight.t2)
                                .lineLimit(2)
                        }
                        MindsCharts.LeverageBar(userChars: vol.userChars, totalChars: vol.totalChars)
                        let ub = max(MindsBuilder.bookEquivalent(vol.userChars), 1)
                        let tb = MindsBuilder.bookEquivalent(vol.totalChars)
                        if tb >= 1 {
                            Text(l10n.s.mLeverageBooks(ub, tb))
                                .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var marathonsSection: some View {
        // "- 继续 — 5497 messages over 64 days, StrategyGame (id: m1)"——同 unfinished 的解析形态
        let rows = sectionLines("MARATHONS").filter { $0.hasPrefix("- ") }
            .compactMap(parseUnfinished)
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Marathons", l10n.s.mindsSecMarathons, hint: l10n.s.mindsMarathonsHint)
                    let counts = rows.compactMap { firstInt(after: "", in: $0.meta) }
                    let maxCount = counts.max() ?? 1
                    VStack(spacing: 6) {
                        ForEach(rows, id: \.id) { row in
                            Button { openConversation(row.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "figure.run")
                                        .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.label).font(.system(size: 13)).foregroundStyle(DSLight.t1)
                                            .lineLimit(1)
                                        Text(marathonMeta(row.meta))
                                            .font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                                    }
                                    Spacer(minLength: 0)
                                    if let n = firstInt(after: "", in: row.meta) {
                                        MindsCharts.RatioBar(value: n, maxValue: maxCount)
                                    }
                                    Image(systemName: "arrow.forward")
                                        .font(.system(size: 10)).foregroundStyle(DSLight.t3)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var fadedSection: some View {
        // "- 协变量 — said 38 times, silent 92 days"——灰调:词已沉睡,不用金色
        let rows = sectionLines("FADED WORDS").filter { $0.hasPrefix("- ") }
            .compactMap(parseRecurring)
        let series = viz.fadedSeries
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Faded Words", l10n.s.mindsSecFaded, hint: l10n.s.mindsFadedHint)
                    FlowLayout(spacing: 8) {
                        ForEach(rows, id: \.word) { row in
                            Button {
                                store.searchQuery = row.word
                                store.mindsSelected = false
                            } label: {
                                HStack(spacing: 6) {
                                    Text(row.word).font(.system(size: 12)).foregroundStyle(DSLight.t2)
                                    Text(fadedMeta(row.detail))
                                        .font(BrandFont.mono(10)).foregroundStyle(DSLight.t3)
                                    // 消退曲线(方案原案):说得多→归零的形状;序列全零时退回沉默条
                                    if let sr = series[row.word], sr.contains(where: { $0 > 0 }) {
                                        MindsCharts.DecaySparkline(series: sr)
                                    } else if let days = firstInt(after: "silent ", in: row.detail) {
                                        MindsCharts.SilenceBar(silentDays: days)
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(DSLight.sf2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - ① 概览:大数字卡

    private var overviewSection: some View {
        let lines = sectionLines("OVERVIEW")
        // "144 conversations across 3 tools, 2026-04-24 → 2026-08-10. …"
        let head = lines.first ?? ""
        let convCount = head.split(separator: " ").first.map(String.init) ?? "—"
        let toolCount = head.range(of: #"across (\d+)"#, options: .regularExpression)
            .map { head[$0].split(separator: " ").last.map(String.init) ?? "—" } ?? "—"
        let days = daySpan(from: head)
        let detail = lines.dropFirst().first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "- ")) ?? ""

        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Overview", l10n.s.mindsSecOverview)
            HStack(spacing: 12) {
                statCard(convCount, l10n.s.mindsConversationsUnit, detail)
                statCard(toolCount, l10n.s.mindsToolsUnit, l10n.s.mindsAllLocal)
                statCard(days, l10n.s.mindsDaysUnit, spanText(from: head))
            }
        }
    }

    private func statCard(_ num: String, _ label: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(num).font(.system(size: 26, weight: .semibold)).foregroundStyle(DSLight.t1)
            Text(label).font(.system(size: 11)).foregroundStyle(DSLight.t2)
            Text(detail).font(BrandFont.mono(10)).foregroundStyle(DSLight.t3)
                .lineLimit(1).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 12))
    }

    private func daySpan(from head: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let dates = isoDates(in: head).compactMap { f.date(from: $0) }
        guard dates.count >= 2 else { return "—" }
        let days = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: dates[0], to: dates[1]).day ?? 0
        return "\(days)"
    }

    private func spanText(from head: String) -> String {
        let ds = isoDates(in: head).map { String($0.dropFirst(5)) }
        return ds.count >= 2 ? "\(ds[0]) 至 \(ds[1])" : ""
    }

    // MARK: - ② 项目节奏:条形

    @State private var expandedProject: String?

    private var projectsSection: some View {
        // "- /path — 54 conversations, active 2026-05-15 → 2026-05-15, last touched 2026-07-18"
        let rows = sectionLines("PROJECT RHYTHM").filter { $0.hasPrefix("- ") }
            .compactMap(parseProject)
        let maxCount = rows.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Project Rhythm", l10n.s.mindsSecProjects, hint: l10n.s.mindsProjectsHint)
            VStack(spacing: 2) {
                ForEach(rows.prefix(8), id: \.path) { row in
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                expandedProject = expandedProject == row.path ? nil : row.path
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(row.name).font(.system(size: 13)).foregroundStyle(DSLight.t1)
                                    .frame(width: 180, alignment: .leading).lineLimit(1)
                                Text("\(row.count)").font(BrandFont.mono(12)).foregroundStyle(DSLight.t2)
                                    .frame(width: 30, alignment: .trailing)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(DSLight.gold.opacity(0.72))
                                        .frame(width: max(4, geo.size.width * CGFloat(row.count) / CGFloat(maxCount)))
                                }
                                .frame(height: 5)
                                .background(DSLight.sf2, in: RoundedRectangle(cornerRadius: 3))
                                Text(row.span).font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                                    .frame(width: 150, alignment: .trailing).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expandedProject == row.path {
                            projectTimeline(cwd: row.path)
                        }
                    }
                }
            }
        }
    }

    /// 行内展开:该项目历次会话(Matched Runs 思路)——月度节奏条 + 最近 5 场可点。
    private func projectTimeline(cwd: String) -> some View {
        let convs = store.projectConversations(cwd: cwd)
        // 近 12 个月分桶(旧→新)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        var byMonth: [String: Int] = [:]
        for c in convs { byMonth[f.string(from: c.endAt), default: 0] += 1 }
        let months = byMonth.keys.sorted().suffix(12)
        let maxMonth = months.map { byMonth[$0] ?? 0 }.max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            if months.count > 1 {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(months), id: \.self) { m in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(DSLight.gold.opacity(0.6))
                                .frame(width: 14, height: max(3, 26 * CGFloat(byMonth[m] ?? 0) / CGFloat(maxMonth)))
                            Text(String(m.suffix(2))).font(BrandFont.mono(8)).foregroundStyle(DSLight.t3)
                        }
                        .help("\(m) · \(byMonth[m] ?? 0)")
                    }
                }
            }
            ForEach(convs.prefix(5), id: \.id) { conv in
                Button { openConversation(conv.id) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(DSLight.gold.opacity(0.5)).frame(width: 4, height: 4)
                        Text(conv.label).font(.system(size: 12)).foregroundStyle(DSLight.t2)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(conv.endAt.relativeLabel(isZh: l10n.s.sidebarMinds != "Minds"))
                            .font(BrandFont.mono(10)).foregroundStyle(DSLight.t3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    private func parseProject(_ line: String) -> (path: String, name: String, count: Int, span: String)? {
        let body = String(line.dropFirst(2))
        guard let dash = body.range(of: " — ") else { return nil }
        let path = String(body[..<dash.lowerBound])
        let rest = body[dash.upperBound...]
        let count = Int(rest.split(separator: " ").first ?? "") ?? 0
        let dates = isoDates(in: String(rest)).map { String($0.dropFirst(5)) }
        var span = dates.count >= 2 ? "\(dates[0]) 至 \(dates[1])" : ""
        // 最近 14 天有动静的标活跃——比只看结束日期更符合「节奏」直觉
        if let last = dates.last, isRecent(monthDay: last) { span += " · \(l10n.s.mindsActiveNow)" }
        return (path, (path as NSString).lastPathComponent, count, span)
    }

    private func isRecent(monthDay: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        guard let d = f.date(from: "\(year)-\(monthDay)") else { return false }
        return abs(d.timeIntervalSinceNow) < 14 * 86_400
    }

    // MARK: - ③ 高频实体 / ④ 概念词表:chip 流


    private func entityChip(_ raw: String) -> some View {
        // "NodeNext (42)" → 词 + 计数
        let parts = raw.split(separator: "(", maxSplits: 1)
        let word = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
        let count = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ") ")) : ""
        return Button {
            store.focusedEntity = word        // 进实体页(L1):相关会话+共现实体,真正的导航
        } label: {
            HStack(spacing: 5) {
                Text(word).font(BrandFont.mono(12)).foregroundStyle(DSLight.t1)
                if !count.isEmpty {
                    Text(count).font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(DSLight.sf2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var vocabularySection: some View {
        // 双组:"- mind: 第一性原理 (39×·12p) · …" / "- work: 选题库 (87) · …"
        let lines = sectionLines("VOCABULARY").filter { $0.hasPrefix("- ") }
        let mindChips = lines.first { $0.hasPrefix("- mind: ") }
            .map { chipsFrom(String($0.dropFirst("- mind: ".count))) } ?? []
        let workChips = lines.first { $0.hasPrefix("- work: ") }
            .map { chipsFrom(String($0.dropFirst("- work: ".count))) } ?? []
        return Group {
            if !mindChips.isEmpty || !workChips.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Vocabulary", l10n.s.mindsSecVocabulary, hint: l10n.s.mindsVocabularyHint)
                    VStack(alignment: .leading, spacing: 12) {
                        if !mindChips.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(l10n.s.mVocabMindLabel)
                                    .font(BrandFont.mono(10)).kerning(1).foregroundStyle(DSLight.gold)
                                FlowLayout(spacing: 8) {
                                    ForEach(mindChips, id: \.word) { c in
                                        vocabChip(c, mind: true)
                                    }
                                }
                            }
                        }
                        if !workChips.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(l10n.s.mVocabWorkLabel)
                                    .font(BrandFont.mono(10)).kerning(1).foregroundStyle(DSLight.t3)
                                FlowLayout(spacing: 8) {
                                    ForEach(workChips, id: \.word) { c in
                                        vocabChip(c, mind: false)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func chipsFrom(_ flat: String) -> [(word: String, meta: String)] {
        flat.split(separator: "·").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let parts = t.split(separator: "(", maxSplits: 1)
            let word = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? t
            let meta = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ") ")) : ""
            return (word, meta)
        }
    }

    /// mind 词金实底(身份词,一眼可见——用户三次找「第一性原理」的答案);
    /// work 词淡底(项目词)。meta:「39×·12p」→ 中文「39 次 · 12 个项目」。
    private func vocabChip(_ c: (word: String, meta: String), mind: Bool) -> some View {
        Button {
            store.searchQuery = c.word
            store.mindsSelected = false
        } label: {
            HStack(spacing: 5) {
                Text(c.word)
                    .font(.system(size: mind ? 13 : 12, weight: mind ? .semibold : .regular))
                    .foregroundStyle(mind ? Color.white : DSLight.gold)
                if !c.meta.isEmpty {
                    Text(vocabMeta(c.meta))
                        .font(BrandFont.mono(10))
                        .foregroundStyle(mind ? Color.white.opacity(0.75) : DSLight.t3)
                }
            }
            .padding(.horizontal, mind ? 14 : 12).padding(.vertical, mind ? 7 : 5)
            .background(mind ? AnyShapeStyle(DSLight.gold) : AnyShapeStyle(DSLight.sf), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func vocabMeta(_ meta: String) -> String {
        // "39×·12p" → 「39 次 · 12 个项目」/ "39× · 12 projects";"87" → 「87 次」
        if let m = firstTwoGroups(meta, #"(\d+)×/(\d+)p"#) {
            return l10n.s.mVocabMindMeta(Int(m.0) ?? 0, Int(m.1) ?? 0)
        }
        if let n = Int(meta) { return l10n.s.mVocabWorkMeta(n) }
        return meta
    }

    private func vocabularyChip(_ raw: String) -> some View {
        // "第一性原理 (25)" → 词 + 次数;旧格式纯词(无括号)也兼容——count 落空即不显示
        let parts = raw.split(separator: "(", maxSplits: 1)
        let word = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
        let count = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ") ")) : ""
        return Button {
            store.searchQuery = word
            store.mindsSelected = false
        } label: {
            HStack(spacing: 5) {
                Text(word).font(.system(size: 12)).foregroundStyle(DSLight.gold)
                if !count.isEmpty {
                    Text(count).font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(DSLight.sf, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - ⑤ Agent 引用


    private func parseRef(_ line: String) -> (id: String, meta: String)? {
        guard let m = line.range(of: #"conversation_id="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let id = String(line[m]).dropFirst(#"conversation_id=""#.count).dropLast()
        let meta = isoDates(in: line).last.map { String($0.dropFirst(5)) } ?? ""
        return (String(id), meta)
    }

    /// 引用行显示会话标题（列表数据里有），查不到退回 id 前 8 位。
    private func refTitle(_ id: String) -> String {
        if let lite = store.allConversations.first(where: { $0.id == id }) {
            return lite.title ?? lite.preview
        }
        return String(id.prefix(8)) + "…"
    }

    // MARK: - ⑥ WEAK SPOTS

    private var weakSpotsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Weak Spots", l10n.s.mindsSecWeakSpots)
            ForEach(MindsSpot.allCases, id: \.rawValue) { spot in
                spotCard(spot)
            }
            Text(l10n.s.mindsEnrichHint)
                .font(.system(size: 12)).foregroundStyle(DSLight.t2)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 16)

            injectionRow
        }
    }

    // MARK: - CLAUDE.md 注入(闸门出口)

    /// 有 confirmed 条目才出现——spec §5 的闸门:未经确认的东西进不了常驻注入。
    /// 写的是用户全局 ~/.claude/CLAUDE.md,必须 alert 二次确认(人在环)。
    @State private var showInjectConfirm = false
    @State private var injectionDone = false

    private var confirmedCount: Int {
        minds.entriesBySpot.values.flatMap { $0 }.filter { $0.status == .confirmed }.count
    }

    @ViewBuilder
    private var injectionRow: some View {
        if confirmedCount > 0 {
            HStack(spacing: 10) {
                Button {
                    showInjectConfirm = true
                } label: {
                    Text(MindsInjection.hasSection()
                         ? l10n.s.mindsInjectUpdate : l10n.s.mindsInjectAction)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DSLight.gold)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(DSLight.goldG, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                if MindsInjection.hasSection() {
                    Button(l10n.s.mindsInjectRemove) {
                        _ = MindsInjection.remove()
                        injectionDone = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(DSLight.t3)
                }
                if injectionDone {
                    Text(l10n.s.mindsInjectDone)
                        .font(.system(size: 11)).foregroundStyle(DSLight.t3)
                        .transition(.opacity)
                }
                Spacer()
                Text(l10n.s.mindsInjectHint(confirmedCount))
                    .font(.system(size: 11)).foregroundStyle(DSLight.t3)
            }
            .padding(.top, 14)
            .alert(l10n.s.mindsInjectConfirmTitle, isPresented: $showInjectConfirm) {
                Button(l10n.s.mindsInjectAction) {
                    injectionDone = MindsInjection.inject(content: store.mindsInjectionText())
                }
                Button(l10n.s.cancel, role: .cancel) {}
            } message: {
                Text(l10n.s.mindsInjectConfirmBody)
            }
        }
    }

    private func spotName(_ spot: MindsSpot) -> String {
        switch spot {
        case .preferences: return l10n.s.mindsSpotPreferences
        case .style: return l10n.s.mindsSpotStyle
        case .goals: return l10n.s.mindsSpotGoals
        case .stack: return l10n.s.mindsSpotStack
        }
    }

    private func spotCard(_ spot: MindsSpot) -> some View {
        let entries = minds.entriesBySpot[spot] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(spotName(spot)).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DSLight.t1)
                Spacer()
                Text(spot.rawValue).font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
            }
            if entries.isEmpty {
                Text(l10n.s.mindsSpotEmpty)
                    .font(.system(size: 12)).foregroundStyle(DSLight.t3)
                    .padding(.top, 10)
            } else {
                ForEach(entries, id: \.id) { entryCard($0) }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 14)
    }

    private func entryCard(_ entry: MindsEntry) -> some View {
        let unreviewed = entry.status == .unreviewed
        return VStack(alignment: .leading, spacing: 8) {
            // 徽标:待确认 = 金调(醒目),已确认 = 灰(回落)。这是 write-back 纪律的视觉面。
            Text(unreviewed ? l10n.s.mindsBadgeUnreviewed : l10n.s.mindsBadgeConfirmed)
                .font(.system(size: 10)).kerning(0.6)
                .foregroundStyle(unreviewed ? DSLight.gold : DSLight.t2)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background((unreviewed ? DSLight.goldG : DSLight.sf3.opacity(0.6)), in: Capsule())
            Text(entry.text).font(.system(size: 13)).foregroundStyle(DSLight.t1)
            // 溯源:每个 id 可点回原对话——「AI 说的每句都能查证」
            HStack(spacing: 6) {
                Text("\(l10n.s.mindsSources):").font(.system(size: 11)).foregroundStyle(DSLight.t3)
                ForEach(entry.sources, id: \.self) { src in
                    Button {
                        store.mindsSelected = false
                        store.selectedConversationId = src
                    } label: {
                        Text(String(src.prefix(8)) + "…")
                            .font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
                            .underline(true, pattern: .dot)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(entry.agent) · \(Self.dayFormatter.string(from: entry.createdAt))")
                    .font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
            }
            if unreviewed {
                HStack(spacing: 8) {
                    Button(l10n.s.mindsConfirm) { minds.confirm(entryID: entry.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(DSLight.gold)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(DSLight.goldG, in: RoundedRectangle(cornerRadius: 8))
                    Button(l10n.s.mindsRevoke) { minds.revoke(entryID: entry.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(DSLight.t2)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(DSLight.sf2, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // AI 待确认 = sf3(亮色下更深一档,醒目);确认后 = sf2(回落)
        .background(unreviewed ? DSLight.sf3 : DSLight.sf2,
                    in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// 抽取一段文本里所有 yyyy-MM-dd(裸正则字面量需要 upcoming feature,5.9 工具链默认关,
/// 用 NSRegularExpression 兜)。
private func isoDates(in text: String) -> [String] {
    let re = try! NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}")
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
}

// MARK: - 简易流式布局(chip 换行)


/// chips 的换行流式布局。macOS 13 没有 Flow 原生组件,Layout 协议手写一个最小实现。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

/// 那年今日卡:hover 出「不再显示」(Apple「被回忆伤害」教训——被动唤起必须可屏蔽)。
private struct OnThisDayRow: View {
    let row: (id: String, label: String, meta: String)
    var onOpen: () -> Void
    var onMute: () -> Void
    @State private var hovering = false
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11)).foregroundStyle(DSLight.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label).font(.system(size: 13)).foregroundStyle(DSLight.t1)
                        .lineLimit(1)
                    Text(row.meta).font(BrandFont.mono(11)).foregroundStyle(DSLight.t3)
                }
                Spacer(minLength: 0)
                if hovering {
                    Button {
                        onMute()
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10)).foregroundStyle(DSLight.t3)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n.s.mindsMuteResurface)
                }
                Image(systemName: "arrow.forward")
                    .font(.system(size: 10)).foregroundStyle(DSLight.t3)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 行解析小工具(可视化 sparkline 从 md 行文本抽数)

private func firstInt(after prefix: String, in text: String) -> Int? {
    guard let r = text.range(of: prefix.isEmpty ? #"\d+"# : "\(prefix)\\d+",
                             options: .regularExpression) else { return nil }
    let digits = text[r].drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
    return Int(digits)
}

private extension String {
    /// 抽出全部 yyyy-MM-dd(NSRegularExpression——BareSlashRegexLiterals 未开)。
    func matchesISO() -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#) else { return [] }
        return re.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap {
            Range($0.range, in: self).map { String(self[$0]) }
        }
    }
}
