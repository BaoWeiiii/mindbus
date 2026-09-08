#if DEBUG
import SwiftUI
import AppKit
import Charts
import MindBusCore

/// 设计校验用的离屏渲染工具：把各界面的 SwiftUI 视图渲染成 PNG，用于在没有屏幕录制
/// 权限的环境里核对视觉效果，也用来出 README 截图。用 `MindBus --render-preview <输出目录>` 触发。
///
/// 只编进 DEBUG 构建（由 `#if DEBUG` 控制）。下面所有样本数据必须是纯虚构的——
/// 项目名、对话原话、统计数字、会话 id、git 哈希一律现编，禁止用真机语料改名充数。
@MainActor
enum PreviewRenderer {

    static func run(outputDir: String) -> Never {
        let dir = URL(fileURLWithPath: outputDir)

        // i18n 对照：同一套界面按 zh / en 各渲一轮（临时切 L10n，样张假数据文案保持中文）
        for lang in [AppLanguage.zhHans, AppLanguage.en] {
            L10n.shared.language = lang
            let sub = dir.appendingPathComponent(lang == .zhHans ? "zh" : "en", isDirectory: true)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

            renderHeroComposite(name: "browser-hero", to: sub)
            // 首启欢迎页：右侧空态（DetailView 未选中 + firstRunWelcomeDone 未置位）
            render(DetailView().environmentObject(ConversationStore(indexPath: NSTemporaryDirectory() + "mb-preview-welcome.sqlite"))
                       .frame(width: 760, height: 560).background(DSLight.bg),
                   name: "detail-welcome", size: CGSize(width: 760, height: 560), to: sub)
            render(listRowsSample, name: "list-rows", size: CGSize(width: 340, height: 260), to: sub)
            render(sidebarSample, name: "sidebar", size: CGSize(width: 220, height: 420), to: sub)
            render(sidebarMindsSample, name: "sidebar-minds", size: CGSize(width: 220, height: 420), to: sub)
            render(MindsPlaceholderView(), name: "minds-placeholder", size: CGSize(width: 700, height: 300), to: sub)
            render(mindsContentSample, name: "minds-content", size: CGSize(width: 900, height: 2400), to: sub)
            render(projectsSample, name: "minds-projects", size: CGSize(width: 900, height: 400), to: sub)
            render(outlineSample, name: "outline", size: CGSize(width: 420, height: 420), to: sub)
            render(forgottenSample, name: "forgotten", size: CGSize(width: 400, height: 240), to: sub)
            render(openLoopsSample, name: "minds-open-loops", size: CGSize(width: 900, height: 330), to: sub)
            render(phraseQuotesSample, name: "minds-phrase-quotes", size: CGSize(width: 900, height: 420), to: sub)
            render(taughtSample, name: "minds-taught", size: CGSize(width: 900, height: 340), to: sub)
            render(unlocksSample, name: "minds-unlocks", size: CGSize(width: 900, height: 300), to: sub)
            render(emptyRescueSample, name: "empty-rescue", size: CGSize(width: 340, height: 300), to: sub)
            render(entityHeaderSample, name: "entity-header", size: CGSize(width: 340, height: 260), to: sub)
            render(FavoritesHomeView(store: ConversationStore(), onOpen: { _, _ in })
                       .frame(width: 1100, height: 640).background(DSLight.bg),
                   name: "favorites-home", size: CGSize(width: 1100, height: 640), to: sub)
            render(CopyPreferencesView(), name: "settings", size: CGSize(width: 460, height: 440), to: sub)
            render(listChromeSample, name: "list-chrome", size: CGSize(width: 340, height: 360), to: sub)
            render(bubblesSample, name: "bubbles", size: CGSize(width: 720, height: 320), to: sub)
            render(selectionSample, name: "copy-scope-selection", size: CGSize(width: 720, height: 420), to: sub)
            render(timelineSample, name: "timeline", size: CGSize(width: 720, height: 560), to: sub)
            render(timelineExpandedSample, name: "timeline-expanded", size: CGSize(width: 720, height: 460), to: sub)
            render(searchHighlightSample, name: "search-highlight", size: CGSize(width: 720, height: 560), to: sub)
            render(grainCompare, name: "grain-compare", size: CGSize(width: 600, height: 200), to: sub)
            render(emptyStates, name: "empty-states", size: CGSize(width: 700, height: 240), to: sub)
            render(fontProof, name: "font-proof", size: CGSize(width: 560, height: 220), to: sub)
        }
        L10n.shared.language = .system   // 双轮结束复位，不把渲染语言写进 UserDefaults 常驻

        print("rendered to \(dir.path)")
        exit(0)
    }

    // MARK: - 样本视图
    //
    // 虚构的样本库：六个开源味的小项目，路径统一 /Users/dev/Projects/<Name>。
    //   Lighthouse — SwiftUI 天气小组件      Papyrus — Markdown 笔记工具
    //   Orbit      — 个人日程 CLI            Mosaic  — 照片墙静态站
    //   Sundial    — 番茄钟                  mindbus — 本项目
    // 所有对话原话、数字、日期都围绕这六个项目现编，与任何真实语料无关。

    /// 样张用的日期
    private static func day(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s) ?? Date(timeIntervalSince1970: 1_754_000_000)
    }

    /// 「即将解锁」样张:新用户第 3 天的库长这样
    private static var unlocksSample: some View {
        var viz = MindsViz()
        viz.pending = MindsBuilder.pendingCapabilities(conversations: 9, projects: 1,
                                                       daySpanDays: 3, longestConversation: 60)
        return MindsNextUnlocks(ctx: MindsContext(store: ConversationStore(), md: "# Minds",
                                                  viz: viz, isLoading: false))
            .padding(28).frame(width: 900, alignment: .leading).background(MindsUI.page)
    }

    /// 「它教你的词」样张（虚构样本）
    private static var taughtSample: some View {
        let md = """
        # Minds

        ## WORDS IT TAUGHT YOU
        Words it used first. (mechanical, 6)
        - 信息层级 — 29d later, 4 projects
        - 缓动曲线 — 36d later, 3 projects
        - 半开区间 — 52d later, 3 projects
        - 占位态 — 41d later, 3 projects
        - 幂等 — 77d later, 2 projects
        - 回退路径 — 95d later, 2 projects
        - 信息层级 — it: 先把信息层级排出来,再决定字号和颜色
        - 信息层级 — you: 这块的信息层级不对,时间不该比标题还显眼
        - 半开区间 — it: 冲突判定用半开区间,结束时刻等于下一段的开始时刻不算重叠
        - 半开区间 — you: 提醒也改成半开区间,和冲突检测保持一致
        """
        return MindsWordsItTaught(ctx: MindsContext(store: ConversationStore(), md: md,
                                                    viz: MindsViz(), isLoading: false))
            .padding(28).frame(width: 900, alignment: .leading).background(MindsUI.page)
    }

    /// 「你反复说的话」+ 展开成原话（虚构样本）
    private static var phraseQuotesSample: some View {
        let md = """
        # Minds

        ## PHRASES YOU REPEAT
        Turns of phrase you carry across projects. (mechanical, 5 phrases)
        - 先跑通 (23×/9p) · 对照图 (18×/8p) · 信息层级 (15×/7p) · 别写死 (12×/6p) · 空态 (10×/5p)
        - 先跑通 — [Lighthouse] 先跑通最小的一版,刷新间隔和缓存后面再调
        - 先跑通 — [Orbit] 冲突检测先跑通再说,提醒功能放下一轮
        - 对照图 — [Papyrus] 三种宽度各截一张对照图,我看完再决定
        - 对照图 — [Mosaic] 压缩前后放一起出张对照图,肉眼看不出差别才算过
        - 别写死 — [Sundial] 时长别写死 25 分钟,做成设置项
        - 空态 — [mindbus] 空态也要好看,那是新用户看到的第一屏
        """
        return MindsRepeatedPhrases(ctx: MindsContext(store: ConversationStore(), md: md,
                                                     viz: MindsViz(), isLoading: false))
            .padding(28).frame(width: 900, alignment: .leading).background(MindsUI.page)
    }

    /// 「悬着的事」样张（虚构样本）
    private static var openLoopsSample: some View {
        let md = """
        # Minds

        ## OPEN LOOPS
        Threads left hanging. (mechanical, 5)
        - 2026-08-20 [把天气组件的刷新间隔改成 15 分钟] 缓存有效期要跟着改成 10 分钟吗?
        - 2026-08-16 [Markdown 表格在窄屏下换行错乱] 要我把三种断点的对照图一起贴出来吗?
        - 2026-08-13 [番茄钟结束音效换成更轻的] 淡出时长用 0.4 秒还是 0.6 秒,你听完定?
        - 2026-08-10 [照片墙缩略图改为构建期生成] 旧的运行时缩略图代码要顺手删掉吗?
        - 2026-08-06 [日程冲突检测误报] 提醒功能也按半开区间改一轮吗?
        """
        return MindsOpenLoopsCard(ctx: MindsContext(store: ConversationStore(), md: md,
                                                    viz: MindsViz(), isLoading: false))
            .padding(28).frame(width: 900, alignment: .leading).background(MindsUI.page)
    }

    /// 「你可能忘了的」样张（虚构样本）
    private static var forgottenSample: some View {
        ForgottenListPreview(items: [
            .init(id: "1", title: "把天气组件的刷新间隔改成 15 分钟", cwd: "/Users/dev/Projects/Lighthouse", daysAgo: 27),
            .init(id: "2", title: "Markdown 表格在窄屏下换行错乱", cwd: "/Users/dev/Projects/Papyrus", daysAgo: 52),
            .init(id: "3", title: "番茄钟结束音效换成更轻的", cwd: "/Users/dev/Projects/Sundial", daysAgo: 79),
        ])
        .padding(16).background(DSLight.sf)
    }

    /// 长对话目录样张（虚构样本：放行 / 拍板 / 时间断点交织）
    private static var outlineSample: some View {
        let base = Date(timeIntervalSince1970: 1_754_000_000)
        let nodes: [ConversationOutline.Node] = [
            .init(kind: .milestone, messageID: "1",
                  text: "刷新间隔改成 15 分钟,后台刷新预算实测未超限,三种尺寸都正常更新", at: base),
            .init(kind: .decision, messageID: "2",
                  text: "先用系统缓存,自建缓存层放到下一轮", at: base),
            .init(kind: .gap, messageID: "3", text: "", at: base, gap: 4 * 3600),
            .init(kind: .milestone, messageID: "4",
                  text: "旧缓存代码删完并推送(0a1b2c3),净删 218 行,146 个测试全绿", at: base),
            .init(kind: .gap, messageID: "5", text: "", at: base, gap: 19 * 3600),
            .init(kind: .decision, messageID: "6",
                  text: "过期数据一律不显示,宁可空着也别给旧时间", at: base),
            .init(kind: .milestone, messageID: "7", text: "小组件三种尺寸全部上架(1b2c3d4)", at: base),
        ]
        return OutlineListPreview(nodes: nodes).content
            .frame(width: 388).padding(16).background(DSLight.sf)
    }

    /// 项目页样张：核对「放行数」徽章没有把行布局挤坏（虚构数字；条形按消息数画，
    /// 所以故意让场数少的 mindbus 消息数最多，末行不带放行数验证缺段回退）
    private static var projectsSample: some View {
        let md = """
        # Minds

        ## PROJECT RHYTHM
        Top 5 projects. (mechanical, 5 projects)
        - /Users/dev/Projects/Lighthouse — 37 conversations, 4380 messages, 71 signed off, active 2026-04-03 → 2026-08-20, last touched 2026-08-20
        - /Users/dev/Projects/Papyrus — 26 conversations, 3562 messages, 46 signed off, active 2026-05-11 → 2026-08-19, last touched 2026-08-19
        - /Users/dev/Projects/mindbus — 19 conversations, 5210 messages, 29 signed off, active 2026-06-02 → 2026-08-22, last touched 2026-08-22
        - /Users/dev/Projects/Orbit — 15 conversations, 1874 messages, 14 signed off, active 2026-04-27 → 2026-07-14, last touched 2026-07-14
        - /Users/dev/Projects/Mosaic — 13 conversations, 963 messages, active 2026-07-06 → 2026-08-15, last touched 2026-08-15
        """
        return MindsProjectsPage(ctx: MindsContext(store: ConversationStore(), md: md,
                                                   viz: MindsViz(), isLoading: false))
            .padding(28).frame(width: 900, alignment: .leading).background(MindsUI.page)
    }

    /// Minds 全页样张：一份完整的虚构 minds.md，节名与行形态和 MindsBuilder 写出的一致
    private static var mindsContentSample: some View {
        let root = NSTemporaryDirectory() + "minds-preview-sample"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let md = """
        # Minds — mechanical self-description
        > Rebuilt automatically. (policy v14, rebuilt 2026-08-22)

        ## MILESTONES
        Work you signed off on — what the AI had just reported when you said OK. (mechanical, 212 of them)
        - 2026-08-21 [继续] 刷新间隔改成 15 分钟,后台刷新预算实测未超限,三种尺寸都正常更新
        - 2026-08-19 [好的] 窄屏表格换行修好了,三种宽度断点各截了一张对照图
        - 2026-08-17 [继续] 结束音效换成更轻的一版,按 0.4 秒淡出,音量曲线已装机试听
        - 2026-08-15 [可以] 缩略图改为构建期生成,首屏体积从 6.2MB 降到 1.1MB
        - 2026-08-12 [继续] 冲突检测改成半开区间判定,误报用例 18/18 通过
        - 2026-08-09 [确认] 旧缓存代码删完并推送(0a1b2c3),净删 218 行,146 个测试全绿

        ## SANCTUARY
        What this library holds for you — kept on your disk, in duplicate. (mechanical)
        - 118 conversations · 121 archived copies (238 MB) · day 161 of your library
        - 4 conversations have outlived Claude Code's 30-day window — here, they stay
        - milestones passed: 100 conversations · 5.0M characters
        - last collected 2026-08-22

        ## DORMANT PROJECTS
        Heavy investments untouched for 30+ days. (mechanical, 2 projects)
        - Orbit — 15 conversations, last touched 2026-07-14
        - Sundial — 8 conversations, last touched 2026-06-27

        ## THIS MONTH
        14 conversations so far (+3 vs last month). (mechanical, 14 conversations)
        - tools: claudeCode 9 · codex 5
        - first seen this month: ForecastCache · TableWrapper · ChimeFade

        ## FADED WORDS
        Words you used to say a lot — silent for 60+ days now. (mechanical, 3 words)
        - 占位图 — said 27 times, silent 71 days
        - 缓存策略 — said 21 times, silent 66 days
        - 冲突检测 — said 15 times, silent 52 days

        ## WORK RHYTHM
        When and how you work. (mechanical, 118 conversations)
        - most conversations start 21-24 — 44% (52 of 118)
        - busiest day: 2026-06-14 — 13 conversations (11% of everything, in one day)
        - you juggle 1.4 projects per active day — peak 4 on 2026-07-21
        - active 71 of the last 365 days — longest run 8, longest break 5

        ## LEVERAGE
        What your typing turns into. (mechanical, 620k chars typed)
        - you typed 620k characters; the conversations hold 8.9M — leverage 1:14

        ## MARATHONS
        Your longest conversations by message count. (mechanical, 3 shown)
        - 把天气组件的刷新间隔改成 15 分钟 — 2318 messages over 41 days, Lighthouse (id: 00000000-0000-4000-8000-000000000001)
        - Markdown 表格在窄屏下换行错乱 — 1745 messages over 11 days, Papyrus (id: 00000000-0000-4000-8000-000000000002)
        - 日程冲突检测误报 — 1206 messages over 4 days, Orbit (id: 00000000-0000-4000-8000-000000000003)

        ## COLLABORATION SHAPE
        How you and AI actually work together. (mechanical)
        - 63% of conversations run 16+ of your turns — you co-work, you don't just ask
        - sessions are two-peaked: 19% under 2 min, 28% over 2 h
        - your average message: 44 chars — short directives, not essays

        ## WEEKEND SELF
        Which projects own your weekends. (mechanical, 2 weekend projects)
        - weekend: Mosaic 5 · Sundial 2
        - weekdays: Lighthouse 37 · Papyrus 26 · mindbus 19 · Orbit 15

        ## QUESTION SHAPE
        What kind of questions you ask — your cognitive spectrum with AI. (mechanical, 407 questions)
        - should-we 163 · how-to 128 · why 67 · what-is 49
        - you ask AI to judge, more than to explain

        ## DELEGATION
        What you ask AI to do — the verbs of your instructions. (mechanical, 8 verbs)
        - 设计 148×/29c · 测试 131×/33c · 修复 117×/31c · 优化 95×/24c · 检查 88×/21c · 验证 74×/19c · 分析 52×/15c · 调研 37×/14c
        - research destination #1: github (8 of your 调研 orders; then 文档 5 · 论坛 2)

        ## REPEATED BRIEFINGS
        Things you keep explaining from scratch. (mechanical, 2 groups)
        - 改动之前先把要动的文件列出来,等我确认再动手 — said 5× across 3 conversations
        - 所有界面文案都要走本地化表,视图里不要写死中文 — said 3× across 2 conversations

        ## CATCHPHRASES
        Short messages you send again and again. (mechanical, 4 phrases)
        - 继续 ×36 · 好的 ×19 · 可以 ×13 · 为什么 ×8
        - politeness & delegation: 帮我 ×61 · 谢谢 ×22 · please ×4

        ## LEVERAGE BY PROJECT
        Which project stretches your words furthest. (mechanical, 5 projects)
        - Sundial — 1:31 (4k typed → 124k, 8 conversations)
        - Mosaic — 1:12 (18k typed → 216k, 13 conversations)
        - Papyrus — 1:11 (88k typed → 968k, 26 conversations)
        - Lighthouse — 1:6 (196k typed → 1.1M, 37 conversations)
        - Orbit — 1:3 (41k typed → 123k, 15 conversations)

        ## STARRED HIGHLIGHTS
        Messages you bookmarked. (mechanical, 2 shown)
        - 结论：天气数据缓存 10 分钟、时间线每 15 分钟重载一次，后台预算够用且不会显示过期时间 — 2026-08-14 (conversation: 00000000-0000-4000-8000-000000000001)
        - 表格换行的根因是列宽按最长单元格算，改成按容器宽度分配就不再溢出 — 2026-08-11 (conversation: 00000000-0000-4000-8000-000000000002)

        ## OVERVIEW
        118 conversations across 3 tools, 2026-03-14 → 2026-08-22. (mechanical, 118 conversations)
        - codex 61 · claudeCode 55 · claudeAgent 2

        ## PROJECT RHYTHM
        Top 10 projects by conversation count. (mechanical, 6 projects)
        - /Users/dev/Projects/Lighthouse — 37 conversations, 4380 messages, 71 signed off, active 2026-04-03 → 2026-08-20, last touched 2026-08-20
        - /Users/dev/Projects/Papyrus — 26 conversations, 3562 messages, 46 signed off, active 2026-05-11 → 2026-08-19, last touched 2026-08-19
        - /Users/dev/Projects/mindbus — 19 conversations, 5210 messages, 29 signed off, active 2026-06-02 → 2026-08-22, last touched 2026-08-22
        - /Users/dev/Projects/Orbit — 15 conversations, 1874 messages, 14 signed off, active 2026-04-27 → 2026-07-14, last touched 2026-07-14
        - /Users/dev/Projects/Mosaic — 13 conversations, 963 messages, active 2026-07-06 → 2026-08-15, last touched 2026-08-15
        - /Users/dev/Projects/Sundial — 8 conversations, 615 messages, 6 signed off, active 2026-03-14 → 2026-06-27, last touched 2026-06-27

        ## VOCABULARY
        Your lexicon, counted in your own messages. (mechanical, 12 terms)
        - mind: 信息层级 (24×/9p) · 上下文 (41×/8p) · 确定性 (7×/5p)
        - work: 断点 (23) · 类型检查 (21) · 刷新间隔 (15) · 工作树 (13) · 解析器 (11) · 子代理 (10)
        """
        try? md.write(toFile: root + "/minds.md", atomically: true, encoding: .utf8)
        setenv("MINDBUS_MINDS_ROOT", root, 1)
        return MindsView(store: ConversationStore(indexPath: NSTemporaryDirectory() + "mb-preview-minds.sqlite"),
                         previewSynchronousViz: true, previewPage: .ai).renderableContent
            .frame(width: 840)
            .background(MindsUI.page)
    }

    /// 空结果救援样张:高频实体建议 chips。
    private static var emptyRescueSample: some View {
        ListEmptyState(kind: .noMatch(hint: "没有匹配「zzz」的对话"),
                       suggestions: ["ForecastCache", "src/table.ts", "WidgetKit", "ChimeFade", "断点"],
                       onSuggest: { _ in })
            .frame(width: 340, height: 300)
            .background(DSLight.bg)
    }

    /// 实体页头样张:实体名+会话数+共现 chips(store 无真数据,静态复刻同构布局)。
    private static var entityHeaderSample: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ForecastCache").font(BrandFont.mono(14, weight: .medium)).foregroundStyle(DSLight.t1)
                Spacer()
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(DSLight.t3)
            }
            Text("27 场相关会话").font(.system(size: 11)).foregroundStyle(DSLight.t3)
            Text("与它共现——顺着找：").font(.system(size: 11)).foregroundStyle(DSLight.t3).padding(.top, 2)
            FlowLayout(spacing: 6) {
                ForEach(["ForecastTimeline.swift 21", "ForecastCacheTests.swift 16", "WidgetKit 12", "reloadPolicy 8"], id: \.self) { t in
                    Text(t).font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(DSLight.sf2, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 340, alignment: .leading)
        .background(DSLight.sf)
    }

    /// README 主图:三栏主界面拼装(侧栏|列表|详情)。列表与气泡全是虚构项目的虚构对话,
    /// 不含任何真实语料;侧栏来自空 store,只有静态框架。
    /// 主界面样张分两段渲：侧栏走 ImageRenderer（静态内容），列表 + 详情走宿主渲染
    ///（气泡上的右键菜单覆盖层是 NSViewRepresentable，ImageRenderer 会画成占位块），
    /// 再拼成一张。
    static let heroSize = CGSize(width: 1160, height: 560)
    static let heroSidebarWidth: CGFloat = 211

    private static var heroSidebar: some View {
        HStack(spacing: 0) {
            BrowserSidebarView()
                .environmentObject(ConversationStore(
                    indexPath: NSTemporaryDirectory() + "mb-preview-hero.sqlite"))
                .frame(width: 210)
                .background(DSLight.sf)
            Rectangle().fill(DSLight.rule).frame(width: 1)
        }
        .grain()
    }

    private static var heroMain: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ConversationListRow(conversation: lite(
                    folder: "Lighthouse", preview: "把天气组件的刷新间隔改成 15 分钟，顺便看看后台刷新预算够不够",
                    msgs: 36, minutesAgo: 3, dur: 4800,
                    title: "天气组件刷新间隔改 15 分钟"), isSelected: true)
                ConversationListRow(conversation: lite(
                    folder: "Lighthouse", preview: "小组件在锁屏上的温度字号太小了",
                    msgs: 11, minutesAgo: 40, dur: 780, title: "锁屏温度字号调整"))
                ConversationListRow(conversation: lite(
                    folder: "Papyrus", preview: "Markdown 表格在窄屏下换行错乱，列宽像是按最长单元格算的",
                    msgs: 19, minutesAgo: 95, dur: 1300, title: "窄屏表格换行错乱"))
                ConversationListRow(conversation: lite(
                    folder: "Sundial", preview: "番茄钟结束音效换成更轻的，现在太吓人了",
                    msgs: 8, minutesAgo: 1500, dur: 320, title: "结束音效换轻"))
                ConversationListRow(conversation: lite(
                    folder: "Mosaic", preview: "照片墙的缩略图改成构建期生成，别在浏览器里现算",
                    msgs: 9, minutesAgo: 2200, dur: 640, title: "缩略图构建期生成"))
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .frame(width: 330)
            .background(DSLight.bg)
            Rectangle().fill(DSLight.rule).frame(width: 1)
            VStack(alignment: .leading, spacing: 10) {
                MessageBubbleView(message: msg(.user, "把天气组件的刷新间隔改成 15 分钟，顺便看看后台刷新预算够不够"),
                                  starKey: "hero#m1")
                MessageBubbleView(message: msg(.assistant, "可以。刷新间隔在 `ForecastTimeline.swift` 的 `reloadPolicy` 里，现在是 30 分钟；系统给小组件的后台刷新有每日预算，改成 15 分钟大约用掉四成，够用。我先列出改动清单再动手。"),
                                  starKey: "hero#m2")
                MessageBubbleView(message: msg(.user, "好，缓存那部分别动"),
                                  starKey: "hero#m3")
                MessageBubbleView(message: msg(.assistant, "明白——`ForecastCache` 的 10 分钟有效期保持不变，只改时间线的重载策略。改完 3 个文件，测试全绿。"),
                                  starKey: "hero#m4")
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(DSLight.bg)
        }
        .grain()
    }

    private static var listRowsSample: some View {
        VStack(spacing: 0) {
            ConversationListRow(conversation: lite(
                folder: "Lighthouse", preview: "把天气组件的刷新间隔改成 15 分钟，顺便看看后台刷新预算够不够",
                msgs: 36, minutesAgo: 3, dur: 4800,
                title: "天气组件刷新间隔改 15 分钟"), isSelected: true)
            // 同项目第二行:验证「同文件夹恒定同色」——两个 Lighthouse 标签必须一色
            ConversationListRow(conversation: lite(
                folder: "Lighthouse", preview: "小组件在锁屏上的温度字号太小了",
                msgs: 11, minutesAgo: 40, dur: 780, title: "锁屏温度字号调整"))
            ConversationListRow(conversation: lite(
                folder: "Papyrus", preview: "Markdown 表格在窄屏下换行错乱，列宽像是按最长单元格算的",
                msgs: 19, minutesAgo: 95, dur: 1300))
            ConversationListRow(conversation: lite(
                folder: "Sundial", preview: "番茄钟结束音效换成更轻的，现在太吓人了",
                msgs: 8, minutesAgo: 1500, dur: 320))
        }
        .padding(8)
        .background(DSLight.bg)
        .grain()
    }

    /// 列表侧新框架件：header 大/小标题两态 + 搜索框 ⌘K 徽章显隐两态。
    /// FocusState 离屏恒为未聚焦，正好对应「未聚焦无词 → 徽章显示」；
    /// 有词态用第二个 store 注入 searchQuery，验证清除钮替位、徽章让位。
    private static var listChromeSample: some View {
        let idle = ConversationStore(indexPath: NSTemporaryDirectory() + "mb-preview-idle.sqlite")
        let typing = ConversationStore(indexPath: NSTemporaryDirectory() + "mb-preview-typing.sqlite")
        typing.searchQuery = "重构"
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("header · 未滚动（大标题）").font(.system(size: 10)).foregroundStyle(DSLight.t4)
                ListHeaderTitle(count: 118, collapsed: false)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("header · 滚过阈值（收缩）").font(.system(size: 10)).foregroundStyle(DSLight.t4)
                ListHeaderTitle(count: 118, collapsed: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索框 · 未聚焦无词 → ⌘K 徽章").font(.system(size: 10)).foregroundStyle(DSLight.t4)
                SearchBar().environmentObject(idle)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索框 · 已有词 → 清除钮替位").font(.system(size: 10)).foregroundStyle(DSLight.t4)
                SearchBar().environmentObject(typing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSLight.bg)
        .grain()
    }

    /// 消息气泡：user 白卡金色左缘 vs assistant 白卡；行内 code 金色等宽（路径/标识符）
    private static var bubblesSample: some View {
        // starKey 传入保证收藏按钮链路参与编译与 hover 布局;已收藏的金色填充态
        // 依赖 shared store(渲染进程不写真实 ~/.mindbus,不在样张里造),真机一点即见。
        VStack(alignment: .leading, spacing: 10) {
            MessageBubbleView(message: msg(.user, "番茄钟切到后台再回来，计时为什么会多走几秒？"),
                              starKey: "preview#m1")
            MessageBubbleView(message: msg(.assistant, "因为 `TimerEngine.swift` 靠累加的 tick 计数算剩余时间，挂起期间 tick 不触发，恢复时系统会补发一串。改成记录开始时刻、每次用 `Date()` 的差值算就准了。"),
                              starKey: "preview#m2")
        }
        .padding(16)
        .background(DSLight.bg)
        .grain()
    }

    /// 复制范围选择态：选中（金点/浅金底/描边）vs 未选中 0.72 退后；
    /// 圆点应精确对齐气泡垂直中心（时间行 8px 补正后）。短线已按用户定案删除。
    private static var selectionSample: some View {
        VStack(alignment: .leading, spacing: 10) {
            MessageBubbleView(message: msg(.user, "把照片墙的加载改成分页，一次别把整个相册全拉下来"),
                              selectionActive: true, selected: true, onToggleSelect: { _ in })
            MessageBubbleView(message: msg(.assistant, "可以。分页的关键是把 offset 换成基于游标的 cursor——相册增删照片时列表不会漂移，翻页也不会重复。"),
                              selectionActive: true, selected: true, onToggleSelect: { _ in })
            MessageBubbleView(message: msg(.assistant, "这一条未被选中：所选模式下整体退到 0.72 透明度，但保持可读，圆点淡描边常显。"),
                              selectionActive: true, selected: false, onToggleSelect: { _ in })
        }
        .padding(16)
        .background(DSLight.bg)
        .grain()
    }

    /// 侧栏：顶部品牌行（logo 28 + 词标）+ 工具单选 + 底部设置。
    /// 玻璃药丸是离屏渲染已知盲区（渲不出不算缺陷），重点自检品牌行与行布局。
    private static var sidebarSample: some View {
        BrowserSidebarView()
            .environmentObject(ConversationStore(
                indexPath: NSTemporaryDirectory() + "mb-preview-sidebar.sqlite"))
            .frame(width: 220, height: 420)
            .background(DSLight.sf)
            .grain()
    }

    /// 侧栏 · Minds 选中态：工作空间组无选中（药丸退场）、Minds 行转 t1 semibold。
    /// 玻璃药丸是离屏盲区，重点自检分组标题/分隔线/行布局与两组选中互斥。
    private static var sidebarMindsSample: some View {
        let store = ConversationStore(
            indexPath: NSTemporaryDirectory() + "mb-preview-sidebar-minds.sqlite")
        store.mindsSelected = true
        return BrowserSidebarView()
            .environmentObject(store)
            .frame(width: 220, height: 420)
            .background(DSLight.sf)
            .grain()
    }

    /// 执行流时间线：节点卡片行（chevron + thinking/Bash/Read/Edit 分类图标 + 摘要 +
    /// 相对时间 + 淡化勾圈）、正文白卡同宽。静态子视图渲染（ScrollView/glass 是已知盲区）。
    private static var timelineSample: some View {
        let t0 = Date().addingTimeInterval(-3600)
        // rev 序（最新在前），与 DetailView.messageScroll 一致
        let rev: [Message] = [
            Message(id: "tl-5", role: .assistant, timestamp: t0.addingTimeInterval(200),
                    blocks: [.text("已把刷新间隔改成 15 分钟：`reloadPolicy` 改为 15 分钟后重载，缓存有效期保持不变，所有测试通过。")]),
            Message(id: "tl-4", role: .assistant, timestamp: t0.addingTimeInterval(190),
                    blocks: [.toolUse(name: "Edit",
                                      input: #"{"file_path":"/Users/dev/Projects/Lighthouse/Widget/ForecastTimeline.swift","old_string":"a","new_string":"b"}"#)]),
            Message(id: "tl-3", role: .assistant, timestamp: t0.addingTimeInterval(75),
                    blocks: [.toolUse(name: "Read",
                                      input: #"{"file_path":"/Users/dev/Projects/Lighthouse/Widget/ForecastCache.swift"}"#)]),
            Message(id: "tl-2", role: .assistant, timestamp: t0.addingTimeInterval(70),
                    blocks: [.toolUse(name: "Bash",
                                      input: #"{"command":"swift build && swift test"}"#)]),
            Message(id: "tl-1", role: .assistant, timestamp: t0,
                    blocks: [.thinking("用户要改小组件的刷新间隔，先看时间线的 reloadPolicy 现在怎么写，再确认系统给小组件的后台刷新预算够不够。")]),
            Message(id: "tl-0", role: .user, timestamp: t0.addingTimeInterval(-30),
                    blocks: [.text("把天气小组件的刷新间隔改成 15 分钟")]),
        ]
        let infos = TimelineLayout.rowInfos(rev: rev)
        // 静态样张不翻转：视觉顺序 = 旧→新，倒序遍历 rev
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rev.indices.reversed()), id: \.self) { i in
                MessageBubbleView(message: rev[i], timeline: infos[i])
            }
        }
        .padding(16)
        .background(DSLight.bg)
        .grain()
    }

    /// 展开态：thinking 全文排版在卡片内部下方 + chevron 旋转 90°（CodeBlockView 内含
    /// ScrollView，离屏渲染是已知盲区，这里用 thinking 与命令两种展开各验一半）。
    private static var timelineExpandedSample: some View {
        let t0 = Date().addingTimeInterval(-7200)
        let thinkMsg = Message(id: "tle-1", role: .assistant, timestamp: t0,
                               blocks: [.thinking("用户要改小组件的刷新间隔。\n先看时间线的 reloadPolicy 现在怎么写，再确认系统给小组件的后台刷新预算——15 分钟一次会不会超。\n缓存有效期不能跟着动，那是另一层的事，用户明确说过别碰。")])
        let bashMsg = Message(id: "tle-2", role: .assistant, timestamp: t0.addingTimeInterval(80),
                              blocks: [.toolUse(name: "Bash",
                                                input: #"{"command":"cd /Users/dev/Projects/Lighthouse && swift build && swift test"}"#)])
        let rev = [bashMsg, thinkMsg]
        let infos = TimelineLayout.rowInfos(rev: rev)
        return VStack(alignment: .leading, spacing: 8) {
            TimelineMessageView(message: thinkMsg, info: infos[1]!, previewExpanded: [0])
            TimelineMessageView(message: bashMsg, info: infos[0]!, previewExpanded: [0])
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSLight.bg)
        .grain()
    }

    /// 命中词高亮 + 消息级定位强调，四态并排自检：
    /// 列表行（标题+preview 命中 / 无命中对照）、气泡正文（markdown 粗体内命中）、
    /// 定位金描边（located）、时间线节点摘要命中。
    private static var searchHighlightSample: some View {
        let q = "刷新间隔"
        let tlMsg = Message(id: "sh-tl", role: .assistant, timestamp: Date(),
                            blocks: [.thinking("先确认刷新间隔的改动有没有进时间线，再看系统是不是把重载请求合并了。")])
        let tlInfos = TimelineLayout.rowInfos(rev: [tlMsg])
        return VStack(alignment: .leading, spacing: 12) {
            Text("列表行 · 标题/preview 命中金标注（下行为无命中对照）")
                .font(.system(size: 10)).foregroundStyle(DSLight.t4)
            VStack(spacing: 0) {
                ConversationListRow(conversation: lite(
                    folder: "Lighthouse", preview: "把天气组件的刷新间隔改成 15 分钟，顺便看看后台刷新预算够不够",
                    msgs: 36, minutesAgo: 3, dur: 4800, title: "天气组件刷新间隔改 15 分钟"), highlightQuery: q)
                ConversationListRow(conversation: lite(
                    folder: "Sundial", preview: "番茄钟结束音效换成更轻的，现在太吓人了",
                    msgs: 8, minutesAgo: 1500, dur: 320), highlightQuery: q)
            }
            .frame(width: 340)

            Text("气泡正文 · markdown 渲染后按可见文本标注；user 泡带定位强调环")
                .font(.system(size: 10)).foregroundStyle(DSLight.t4)
            MessageBubbleView(message: msg(.user, "为什么**刷新间隔**改了，小组件还是半小时才更新一次？"),
                              highlightQuery: q, located: true)
            MessageBubbleView(message: msg(.assistant, "时间线里的刷新间隔只是建议值，系统会按后台刷新预算合并重载请求；预算余量够的时候才会按 15 分钟走。"),
                              highlightQuery: q)

            Text("时间线节点摘要 · 命中")
                .font(.system(size: 10)).foregroundStyle(DSLight.t4)
            MessageBubbleView(message: tlMsg, timeline: tlInfos[0], highlightQuery: q)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSLight.bg)
        .grain()
    }

    /// 字体注册验证：注册失败会静默 fallback 到系统等宽，肉眼分不出，必须并排对照。
    /// 同时验证 ≈ 和 ~ 这些 UI 里实际会出现的字符有没有字形。
    private static var fontProof: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("系统等宽（对照组）").font(.system(size: 10)).foregroundStyle(DSLight.t4)
                Text("~/.claude/projects/  v1.0.0  ≈1234 token")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DSLight.t1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("DM Mono（若与上行字形一致 = 注册失败）")
                    .font(.system(size: 10)).foregroundStyle(DSLight.t4)
                Text("~/.claude/projects/  v1.0.0  ≈1234 token")
                    .font(BrandFont.mono(12))
                    .foregroundStyle(DSLight.t1)
            }
            Text("0123456789 aeghiklrst {} () [] -> => != ≈ ~ · @#$%")
                .font(BrandFont.mono(12))
                .foregroundStyle(DSLight.t3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSLight.bg)
        .grain()
    }

    /// 三种占位态并排：低频工具里这就是「第一印象」本身
    private static var emptyStates: some View {
        HStack(spacing: 0) {
            Rectangle().fill(DSLight.rule).frame(width: 1)
            placeholderCell("读不到索引（新）",
                            .failed(title: "读不到对话索引",
                                    detail: "索引文件可能损坏，或磁盘空间不足。\n可尝试退出 App 后重新打开。"))
            Rectangle().fill(DSLight.rule).frame(width: 1)
            placeholderCell("筛选无结果", .noMatch(hint: "搜索「重构方案」· 本周 · ChatGPT 客户端"))
        }
        .grain()
    }

    private static func placeholderCell(_ label: String, _ kind: ListPlaceholderKind) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10)).foregroundStyle(DSLight.t4).padding(.top, 10)
            ListEmptyState(kind: kind)
        }
        .background(DSLight.bg)
    }

    /// 质感层强度阶梯：一次渲染多档，肉眼挑最合适的
    private static let grainTile = GrainTexture.makeTile(darkest: 0.96)

    private static var grainCompare: some View {
        HStack(spacing: 0) {
            grainCell(label: "0（无）", intensity: 0)
            grainCell(label: "0.15", intensity: 0.15)
            grainCell(label: "0.25", intensity: 0.25)
            grainCell(label: "0.40", intensity: 0.40)
            grainCell(label: "0.60", intensity: 0.60)
        }
    }

    private static func grainCell(label: String, intensity: Double) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(DSLight.t4)
            Text("Aa 对话").font(.system(size: 17, weight: .semibold)).foregroundStyle(DSLight.t1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSLight.bg)
        .grainTile(grainTile, intensity: intensity)
    }

    // MARK: - 渲染

    /// AppKit 宿主渲染：把视图挂进一个放在屏幕外的离屏窗口，跑一段 runloop 让 onAppear /
    /// Task 的异步加载落地，再 cacheDisplay 截图。ImageRenderer 渲不出 NSViewRepresentable
    /// （右键菜单覆盖层、TextField 会变成黄色占位块），也不触发 onAppear——依赖异步加载的
    /// 页面只能抓到骨架。README 用的几张走这里。
    private static func hostedBitmap<V: View>(_ view: V, size: CGSize, settle: TimeInterval) -> NSBitmapImageRep? {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func renderHosted<V: View>(_ view: V, name: String, size: CGSize,
                                              settle: TimeInterval, to dir: URL) {
        guard let rep = hostedBitmap(view, size: size, settle: settle),
              let data = rep.representation(using: .png, properties: [:])
        else { print("render failed: \(name)"); return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// 侧栏（ImageRenderer）+ 主区（宿主渲染）左右拼接成主界面样张。
    private static func renderHeroComposite(name: String, to dir: URL) {
        let size = heroSize, leftW = heroSidebarWidth, scale: CGFloat = 2
        let left = ImageRenderer(content: heroSidebar.frame(width: leftW, height: size.height))
        left.scale = scale
        guard let leftCG = left.cgImage,
              let rightRep = hostedBitmap(heroMain, size: CGSize(width: size.width - leftW, height: size.height), settle: 2.5),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { print("render failed: \(name)"); return }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSImage(cgImage: leftCG, size: CGSize(width: leftW, height: size.height))
            .draw(in: CGRect(x: 0, y: 0, width: leftW, height: size.height))
        let rightImage = NSImage(size: rightRep.size)
        rightImage.addRepresentation(rightRep)
        rightImage.draw(in: CGRect(x: leftW, y: 0, width: size.width - leftW, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func render<V: View>(_ view: V, name: String, size: CGSize, to dir: URL) {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 2   // Retina
        guard let cg = renderer.cgImage else { print("render failed: \(name)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: - 假数据（不触碰真实对话，避免隐私内容进渲染图）

    private static func lite(folder: String, preview: String, msgs: Int,
                             minutesAgo: Int, dur: Int, title: String? = nil) -> ConversationLite {
        let end = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        return ConversationLite(
            id: UUID().uuidString, source: .claudeCode,
            startAt: end.addingTimeInterval(-Double(dur)), endAt: end,
            cwd: "/Users/dev/Projects/\(folder)", gitBranch: nil, title: title,
            preview: preview, messageCount: msgs,
            fileURL: URL(fileURLWithPath: "/tmp/preview.jsonl")
        )
    }

    private static func msg(_ role: MessageRole, _ text: String) -> Message {
        Message(id: UUID().uuidString, role: role, timestamp: Date(), blocks: [.text(text)])
    }
}
#endif
