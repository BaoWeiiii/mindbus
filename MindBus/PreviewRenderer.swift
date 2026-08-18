import SwiftUI
import AppKit
import Charts
import MindBusCore

/// 临时开发工具：把 SwiftUI 视图离屏渲染成 PNG，用于在没有屏幕录制权限的环境里
/// 校验视觉效果。用 `MindBus --render-preview <输出目录>` 触发。
///
/// ⚠️ 这是设计校验用的脚手架，验证完应当删除，不要进入正式发布。
@MainActor
enum PreviewRenderer {

    static func run(outputDir: String) -> Never {
        let dir = URL(fileURLWithPath: outputDir)

        // i18n 对照：同一套界面按 zh / en 各渲一轮（临时切 L10n，样张假数据文案保持中文）
        for lang in [AppLanguage.zhHans, AppLanguage.en] {
            L10n.shared.language = lang
            let sub = dir.appendingPathComponent(lang == .zhHans ? "zh" : "en", isDirectory: true)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

            render(browserHeroSample, name: "browser-hero", size: CGSize(width: 1160, height: 560), to: sub)
            render(listRowsSample, name: "list-rows", size: CGSize(width: 340, height: 260), to: sub)
            render(sidebarSample, name: "sidebar", size: CGSize(width: 220, height: 420), to: sub)
            render(sidebarMindsSample, name: "sidebar-minds", size: CGSize(width: 220, height: 420), to: sub)
            render(MindsPlaceholderView(), name: "minds-placeholder", size: CGSize(width: 700, height: 300), to: sub)
            render(mindsContentSample, name: "minds-content", size: CGSize(width: 900, height: 3400), to: sub)
            render(milestonesSample, name: "minds-milestones", size: CGSize(width: 900, height: 420), to: sub)
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
            render(ScanConfigPage(phase: .scanning).frame(width: 540, height: 440).background(DSLight.bg),
                   name: "onboarding-scan", size: CGSize(width: 540, height: 440), to: sub)
            render(WizardCompletePage(phase: .doneInBackground).frame(width: 540, height: 440).background(DSLight.bg),
                   name: "onboarding-complete-bg", size: CGSize(width: 540, height: 440), to: sub)
            render(SetupWizardView(onComplete: {}), name: "onboarding-first", size: CGSize(width: 700, height: 500), to: sub)
            render(fontProof, name: "font-proof", size: CGSize(width: 560, height: 220), to: sub)
        }
        L10n.shared.language = .system   // 双轮结束复位，不把渲染语言写进 UserDefaults 常驻

        print("rendered to \(dir.path)")
        exit(0)
    }

    // MARK: - 样本视图

    /// 列表行：本次改动的主战场（系统语义色 → DSLight 暖灰四级）
    /// Minds 真内容页样张：临时目录造 minds.md + enriched.jsonl（一条待确认 + 一条已确认），
    /// 经 MINDBUS_MINDS_ROOT 注入让 MindsStore 读到假数据。渲 renderableContent 绕开
    /// ScrollView 盲区。
    /// 「你点头的时刻」单卡样张
    private static var milestonesSample: some View {
        let root = NSTemporaryDirectory() + "minds-milestones-sample"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let md = """
        # Minds

        ## MILESTONES
        Work you signed off on. (mechanical, 307 of them)
        - 2026-08-16 [继续] 砍完推送(1b2c3d4),净删 573 行,801 测试全绿,已装机
        - 2026-08-14 [全部优化] 看了零态和校准流两屏,拿"数字先在、零处明着要"这把尺子量,还能挑出不少毛病
        - 2026-08-13 [继续] 线一:上架合规全套上线(2c3d4e5)
        - 2026-08-12 [继续] 收到,dev 不充值——那正好把架构态度定了:prod 当唯一活管线,dev 当免费沙盒
        - 2026-08-11 [继续] 风声扩展 P1 落地完毕:表 + 闸门 + 真实种子全链路跑通,准入判据实弹检验通过
        - 2026-08-11 [确认] 迁移铺开第一波(B1+B2)完成:读族 + 投票读写全部切上 CloudBase,96/96 测绿
        """
        return MindsMilestonesCard(ctx: MindsContext(store: ConversationStore(), md: md, viz: MindsViz(), isLoading: false))
            .padding(28)
            .frame(width: 900, alignment: .leading)
            .background(MindsUI.page)
    }

    private static var mindsContentSample: some View {
        let root = NSTemporaryDirectory() + "minds-preview-sample"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let md = """
        # Minds — mechanical self-description
        > Rebuilt automatically. (policy v14, rebuilt 2026-08-12)

        ## MILESTONES
        Work you signed off on — what the AI had just reported when you said OK. (mechanical, 307 of them)
        - 2026-08-16 [继续] 砍完推送(1b2c3d4),净删 573 行,801 测试全绿,已装机
        - 2026-08-14 [全部优化] 看了零态和校准流两屏,拿"数字先在、零处明着要"这把尺子量,还能挑出不少毛病
        - 2026-08-13 [继续] 线一:上架合规全套上线(2c3d4e5)
        - 2026-08-12 [继续] 收到,dev 不充值——那正好把架构态度定了:prod 当唯一活管线,dev 当免费沙盒
        - 2026-08-11 [继续] 风声扩展 P1 落地完毕:表 + 闸门 + 真实种子全链路跑通,准入判据实弹检验通过
        - 2026-08-11 [确认] 迁移铺开第一波(B1+B2)完成:读族 + 投票读写全部切上 CloudBase,96/96 测绿

        ## SANCTUARY
        What this library holds for you — kept on your disk, in duplicate. (mechanical)
        - 145 conversations · 149 archived copies (317 MB) · day 111 of your library
        - 8 conversations have outlived Claude Code's 30-day window — here, they stay
        - milestones passed: 100 conversations · 10.0M characters
        - last collected 2026-08-12

        ## DORMANT PROJECTS
        Heavy investments untouched for 30+ days. (mechanical, 2 projects)
        - StrategyGame — 54 conversations, last touched 2026-07-18
        - Codex — 12 conversations, last touched 2026-06-09

        ## THIS MONTH
        12 conversations so far (-8 vs last month). (mechanical, 12 conversations)
        - tools: codex 7 · claudeCode 5
        - first seen this month: FolderAliasStore · user_corpus · GoldShimmer

        ## FADED WORDS
        Words you used to say a lot — silent for 60+ days now. (mechanical, 3 words)
        - 协变量 — said 38 times, silent 92 days
        - 转化率 — said 24 times, silent 75 days
        - 选题库 — said 19 times, silent 61 days

        ## WORK RHYTHM
        When and how you work. (mechanical, 144 conversations)
        - most conversations start 20-24 — 51% (74 of 144)
        - busiest day: 2026-05-15 — 58 conversations (40% of everything, in one day)
        - you juggle 1.7 projects per active day — peak 5 on 2026-08-05
        - active 98 of the last 365 days — longest run 12, longest break 9

        ## LEVERAGE
        What your typing turns into. (mechanical, 1.3M chars typed)
        - you typed 1.3M characters; the conversations hold 15.6M — leverage 1:12

        ## MARATHONS
        Your longest conversations by message count. (mechanical, 3 shown)
        - 继续 — 5497 messages over 64 days, StrategyGame (id: 00000000-0000-4000-8000-000000000001)
        - 检查城市基础数据完整性 — 5145 messages over 6 days, TrendRadar (id: 00000000-0000-4000-8000-000000000002)
        - 解决转化率横条吸顶重叠问题 — 3706 messages over 8 days, TrendRadar (id: 11111111-2222-4333-8444-555555555555)

        ## COLLABORATION SHAPE
        How you and AI actually work together. (mechanical)
        - 77% of conversations run 16+ of your turns — you co-work, you don't just ask
        - sessions are two-peaked: 23% under 2 min, 33% over 2 h
        - your average message: 38 chars — short directives, not essays

        ## WEEKEND SELF
        Which projects own your weekends. (mechanical, 1 weekend projects)
        - weekend: mindbus 3
        - weekdays: StrategyGame 54 · mindbus 8 · Codex 7 · ResearchKit 5 · PricingLab 4

        ## QUESTION SHAPE
        What kind of questions you ask — your cognitive spectrum with AI. (mechanical, 675 questions)
        - should-we 286 · how-to 206 · why 94 · what-is 89
        - you ask AI to judge, more than to explain

        ## DELEGATION
        What you ask AI to do — the verbs of your instructions. (mechanical, 8 verbs)
        - 设计 215×/36c · 验证 192×/40c · 测试 182×/42c · 优化 170×/30c · 检查 113×/28c · 分析 110×/17c · 修复 86×/26c · 调研 64×/22c
        - research destination #1: github (12 of your 调研 orders; then 产品 9 · 最新 2)

        ## REPEATED BRIEFINGS
        Things you keep explaining from scratch. (mechanical, 2 groups)
        - 你是 Senior Code Reviewer,正在审查 Task 4 的代码质量,请只看规格符合性 — said 6× across 4 conversations
        - 对 skill.md 里的 description 要按照卖点一样介绍,吸引人 — said 3× across 2 conversations

        ## CATCHPHRASES
        Short messages you send again and again. (mechanical, 4 phrases)
        - 继续 ×47 · 好的 ×23 · 可以 ×15 · 为什么 ×12
        - politeness & delegation: 帮我 ×89 · 谢谢 ×31 · please ×6

        ## LEVERAGE BY PROJECT
        Which project stretches your words furthest. (mechanical, 5 projects)
        - homelab — 1:45 (3k typed → 170k, 5 conversations)
        - ResearchKit — 1:9 (191k typed → 1.8M, 5 conversations)
        - PricingLab — 1:8 (60k typed → 528k, 6 conversations)
        - StrategyGame — 1:7 (162k typed → 1.2M, 54 conversations)
        - Codex — 1:2 (70k typed → 148k, 7 conversations)

        ## STARRED HIGHLIGHTS
        Messages you bookmarked. (mechanical, 2 shown)
        - 结论：段级 + BM25 双分词比会话级检索 R@1 提升 4.2 倍，结构切分不优于固定切分 — 2026-08-10 (conversation: 00000000-0000-4000-8000-000000000001)
        - 玻璃浮在滚动内容上才折射，贴平背景只磨砂 — 2026-08-08 (conversation: 00000000-0000-4000-8000-000000000002)

        ## OVERVIEW
        144 conversations across 3 tools, 2026-04-24 → 2026-08-10. (mechanical, 144 conversations)
        - codex 102 · claudeCode 41 · claudeAgent 1

        ## PROJECT RHYTHM
        Top 10 projects by conversation count. (mechanical, 5 projects)
        - /Users/dev/Projects/StrategyGame — 54 conversations, active 2026-05-15 → 2026-05-15, last touched 2026-07-18
        - /Users/dev/Projects/mindbus — 11 conversations, active 2026-08-01 → 2026-08-10, last touched 2026-08-10
        - /Users/dev/Projects/Codex — 7 conversations, active 2026-05-08 → 2026-06-09, last touched 2026-06-09
        - /Users/dev/Projects/PricingLab — 6 conversations, active 2026-07-09 → 2026-08-05, last touched 2026-08-10
        - /Users/dev/Projects/ResearchKit — 5 conversations, active 2026-07-01 → 2026-08-10, last touched 2026-08-10

        ## VOCABULARY
        Your lexicon, counted in your own messages. (mechanical, 12 terms)
        - mind: 第一性原理 (39×/12p) · 上下文 (67×/11p) · 确定性 (8×/6p)
        - work: 主工作区 (31) · 类型检查 (18) · 继续推进 (16) · 工作树 (14) · 解析器 (12) · 子代理 (11)

        <!-- weak-spots -->
        ## WEAK SPOTS
        """
        try? md.write(toFile: root + "/minds.md", atomically: true, encoding: .utf8)
        // 两条示例：goals 待确认（AI 徽标 + 确认/撤销按钮）、preferences 已确认（灰徽标）
        let log = """
        {"agent":"claude-code","id":"sample-1","kind":"enrich","sources":["00000000-0000-4000-8000-000000000001","00000000-0000-4000-8000-000000000002"],"spot":"spot:goals","text":"正在把 MindBus 从「AI 记忆引擎」重定位为「跨平台 AI 对话库」，近期主线是 MCP 工具与检索质量。","ts":1786400000}
        {"agent":"claude-code","id":"sample-2","kind":"enrich","sources":["6270d5d0-0000-4000-8000-000000000000"],"spot":"spot:preferences","text":"独立开发者，时间最稀缺；偏好直接执行；给定文案照用不发挥；并行任务同时最多 3 个。","ts":1786300000}
        {"kind":"confirm","target":"sample-2","ts":1786310000}
        """
        try? log.write(toFile: root + "/enriched.jsonl", atomically: true, encoding: .utf8)
        setenv("MINDBUS_MINDS_ROOT", root, 1)
        return MindsView(store: ConversationStore(indexPath: NSTemporaryDirectory() + "mb-preview-minds.sqlite")).renderableContent
            .frame(width: 840)
            .background(MindsUI.page)
    }

    /// 空结果救援样张:高频实体建议 chips。
    private static var emptyRescueSample: some View {
        ListEmptyState(kind: .noMatch(hint: "没有匹配「zzz」的对话"),
                       suggestions: ["NodeNext", "src/index.ts", "Sparkle", "WorldState", "接力"],
                       onSuggest: { _ in })
            .frame(width: 340, height: 300)
            .background(DSLight.bg)
    }

    /// 实体页头样张:实体名+会话数+共现 chips(store 无真数据,静态复刻同构布局)。
    private static var entityHeaderSample: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("NodeNext").font(BrandFont.mono(14, weight: .medium)).foregroundStyle(DSLight.t1)
                Spacer()
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(DSLight.t3)
            }
            Text("42 场相关会话").font(.system(size: 11)).foregroundStyle(DSLight.t3)
            Text("与它共现——顺着找：").font(.system(size: 11)).foregroundStyle(DSLight.t3).padding(.top, 2)
            FlowLayout(spacing: 6) {
                ForEach(["src/index.ts 33", "expedition.test.ts 25", "TypeScript 19", "WorldState 12"], id: \.self) { t in
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

    /// README 主图:三栏主界面拼装(侧栏|列表|详情),全假数据脱敏。
    private static var browserHeroSample: some View {
        HStack(spacing: 0) {
            BrowserSidebarView()
                .environmentObject(ConversationStore(
                    indexPath: NSTemporaryDirectory() + "mb-preview-hero.sqlite"))
                .frame(width: 210)
                .background(DSLight.sf)
            Rectangle().fill(DSLight.rule).frame(width: 1)
            VStack(spacing: 0) {
                ConversationListRow(conversation: lite(
                    folder: "mindbus", preview: "帮我把云同步相关的代码全部移除，保持最干净的状态",
                    msgs: 42, minutesAgo: 3, dur: 5400,
                    title: "移除云同步保持本地纯净"), isSelected: true)
                ConversationListRow(conversation: lite(
                    folder: "mindbus", preview: "检索三增强的收益账再核一遍",
                    msgs: 12, minutesAgo: 40, dur: 900, title: "核对检索收益账"))
                ConversationListRow(conversation: lite(
                    folder: "momo-cat", preview: "这个动画的缓动曲线再收一点，现在太弹了",
                    msgs: 18, minutesAgo: 95, dur: 1200, title: "收紧弹跳动画曲线"))
                ConversationListRow(conversation: lite(
                    folder: "landing-page", preview: "中文标题的字号需要按规范缩小 7%",
                    msgs: 7, minutesAgo: 1500, dur: 300, title: "标题字号规范化"))
                ConversationListRow(conversation: lite(
                    folder: "momo-cat", preview: "喵星人页面的首屏插画换成夜间版本",
                    msgs: 9, minutesAgo: 2200, dur: 640, title: "首屏插画夜间版"))
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .frame(width: 330)
            .background(DSLight.bg)
            Rectangle().fill(DSLight.rule).frame(width: 1)
            VStack(alignment: .leading, spacing: 10) {
                MessageBubbleView(message: msg(.user, "帮我把云同步相关的代码全部移除，保持最干净的状态"),
                                  starKey: "hero#m1")
                MessageBubbleView(message: msg(.assistant, "可以。云同步涉及三处：`SyncManager.swift`、设置页的同步开关、以及 `AccountSession` 里的令牌刷新。全部移除后 App 将是纯本地状态，我先列出改动清单再动手。"),
                                  starKey: "hero#m2")
                MessageBubbleView(message: msg(.user, "好，注意别动本地索引部分"),
                                  starKey: "hero#m3")
                MessageBubbleView(message: msg(.assistant, "明白——`ConversationIndex` 与全文检索保持原样，只摘除网络层。改完 12 个文件，测试全绿。"),
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
                folder: "mindbus", preview: "帮我把云同步相关的代码全部移除，保持最干净的状态",
                msgs: 42, minutesAgo: 3, dur: 5400,
                title: "移除云同步保持本地纯净"), isSelected: true)
            // 同项目第二行:验证「同文件夹恒定同色」——两个 mindbus 标签必须一色
            ConversationListRow(conversation: lite(
                folder: "mindbus", preview: "检索三增强的收益账再核一遍",
                msgs: 12, minutesAgo: 40, dur: 900, title: "核对检索收益账"))
            ConversationListRow(conversation: lite(
                folder: "momo-cat", preview: "这个动画的缓动曲线再收一点，现在太弹了",
                msgs: 18, minutesAgo: 95, dur: 1200))
            ConversationListRow(conversation: lite(
                folder: "landing-page", preview: "中文标题的字号需要按规范缩小 7%",
                msgs: 7, minutesAgo: 1500, dur: 300))
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
                ListHeaderTitle(count: 42, collapsed: false)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("header · 滚过阈值（收缩）").font(.system(size: 10)).foregroundStyle(DSLight.t4)
                ListHeaderTitle(count: 42, collapsed: true)
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
            MessageBubbleView(message: msg(.user, "这段代码为什么会内存泄漏？"),
                              starKey: "preview#m1")
            MessageBubbleView(message: msg(.assistant, "因为 `DetailView.swift` 的闭包里强引用了 self，形成了循环引用。把 self 改成 `weak` 就能断开。"),
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
            MessageBubbleView(message: msg(.user, "帮我把这段接口改成分页加载"),
                              selectionActive: true, selected: true, onToggleSelect: { _ in })
            MessageBubbleView(message: msg(.assistant, "可以。分页的关键是把 offset 换成基于游标的 cursor——列表在增删时不会漂移，翻页也不会重复。"),
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
                    blocks: [.text("已完成时间线重构：节点行默认收起，点击展开原始内容，所有测试通过。")]),
            Message(id: "tl-4", role: .assistant, timestamp: t0.addingTimeInterval(190),
                    blocks: [.toolUse(name: "Edit",
                                      input: #"{"file_path":"/Users/dev/mindbus/MindBus/Views/ConversationBrowser/Detail/DetailView.swift","old_string":"a","new_string":"b"}"#)]),
            Message(id: "tl-3", role: .assistant, timestamp: t0.addingTimeInterval(75),
                    blocks: [.toolUse(name: "Read",
                                      input: #"{"file_path":"/Users/dev/mindbus/MindBus/Views/ConversationBrowser/Detail/MessageBubbleView.swift"}"#)]),
            Message(id: "tl-2", role: .assistant, timestamp: t0.addingTimeInterval(70),
                    blocks: [.toolUse(name: "Bash",
                                      input: #"{"command":"swift build && swift test"}"#)]),
            Message(id: "tl-1", role: .assistant, timestamp: t0,
                    blocks: [.thinking("用户要求把详情从纯气泡流升级为执行流时间线，先读设计系统确认 token，再看翻转列表结构。")]),
            Message(id: "tl-0", role: .user, timestamp: t0.addingTimeInterval(-30),
                    blocks: [.text("把 agent 会话的渲染升级为执行流时间线")]),
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
                               blocks: [.thinking("用户要求把详情从纯气泡流升级为执行流时间线。\n先读设计系统确认 token 与圆角分级，再精读翻转列表结构——任何新视图都要兼容内容 y 翻转 + 行翻回 + 数据倒序。\n摘要计算必须缓存，不能在 body 里做全文扫描。")])
        let bashMsg = Message(id: "tle-2", role: .assistant, timestamp: t0.addingTimeInterval(80),
                              blocks: [.toolUse(name: "Bash",
                                                input: #"{"command":"cd /Users/dev/mindbus-oss && swift build && swift test"}"#)])
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
        let q = "内存泄漏"
        let tlMsg = Message(id: "sh-tl", role: .assistant, timestamp: Date(),
                            blocks: [.thinking("先复现内存泄漏，再定位闭包里的循环引用。")])
        let tlInfos = TimelineLayout.rowInfos(rev: [tlMsg])
        return VStack(alignment: .leading, spacing: 12) {
            Text("列表行 · 标题/preview 命中金标注（下行为无命中对照）")
                .font(.system(size: 10)).foregroundStyle(DSLight.t4)
            VStack(spacing: 0) {
                ConversationListRow(conversation: lite(
                    folder: "内存泄漏排查", preview: "帮我查这段代码的内存泄漏，顺便看看闭包引用",
                    msgs: 42, minutesAgo: 3, dur: 5400), highlightQuery: q)
                ConversationListRow(conversation: lite(
                    folder: "landing-page", preview: "中文标题的字号需要按规范缩小 7%",
                    msgs: 7, minutesAgo: 1500, dur: 300), highlightQuery: q)
            }
            .frame(width: 340)

            Text("气泡正文 · markdown 渲染后按可见文本标注；user 泡带定位强调环")
                .font(.system(size: 10)).foregroundStyle(DSLight.t4)
            MessageBubbleView(message: msg(.user, "这段代码为什么会**内存泄漏**？"),
                              highlightQuery: q, located: true)
            MessageBubbleView(message: msg(.assistant, "闭包强引用了 self，形成循环引用导致内存泄漏。改成 weak 即可断开。"),
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
            cwd: "/Users/dev/\(folder)", gitBranch: nil, title: title,
            preview: preview, messageCount: msgs,
            fileURL: URL(fileURLWithPath: "/tmp/preview.jsonl")
        )
    }

    private static func msg(_ role: MessageRole, _ text: String) -> Message {
        Message(id: UUID().uuidString, role: role, timestamp: Date(), blocks: [.text(text)])
    }
}
