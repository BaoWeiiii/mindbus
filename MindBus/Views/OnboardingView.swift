import MindBusCore
import SwiftUI
import ServiceManagement

// MARK: - Logo Helper

/// 从 SPM bundle 加载真实 Logo（进程级缓存 BrandLogoImage，不再每 render 读盘）
private struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let nsImage = BrandLogoImage.logo {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "diamond.fill")
                    .font(.system(size: size * 0.7, weight: .light))
                    .foregroundColor(DSLight.gold)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Wizard Page

/// 三步。原本有独立的「欢迎」页（大 Logo + 品牌名 + 三条特性），但：
/// - 侧栏顶部已有 Logo 和品牌名，大 Logo 是重复
/// - "欢迎使用 MindBus" 是正确的废话，只是推迟了用户看到价值的时刻
/// - 三条特性在「完成」页已经覆盖
/// 低频工具的第一屏应当直接给确定性（我会读什么、会不会联网），而不是先寒暄。
enum WizardPage: Int, CaseIterable {
    case sources = 0
    case scan = 1
    case complete = 2

    func title(in s: Strings) -> String {
        switch self {
        case .sources: return s.wizardStepSources
        case .scan: return s.wizardStepScan
        case .complete: return s.wizardStepComplete
        }
    }
}

// MARK: - Setup Phase

enum SetupPhase: Equatable {
    case idle, scanning, done
    /// 扫描超时未完成放行：后台继续扫，向导不再卡住（大库首建可能远超 10s）。
    case doneInBackground
}

// MARK: - Setup Wizard

struct SetupWizardView: View {
    let onComplete: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @State private var currentPage: WizardPage = .sources
    @State private var completedPages: Set<WizardPage> = []
    @State private var setupPhase: SetupPhase = .idle

    var body: some View {
        HStack(spacing: 0) {
            WizardSidebar(currentPage: currentPage, completedPages: completedPages)
                .frame(width: 160)

            Rectangle().fill(DSLight.rule).frame(width: 1)

            VStack(spacing: 0) {
                Group {
                    switch currentPage {
                    case .sources:
                        SourcesPage()
                    case .scan:
                        ScanConfigPage(phase: setupPhase)
                    case .complete:
                        WizardCompletePage(phase: setupPhase)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(.easeInOut(duration: 0.25), value: currentPage)

                Rectangle().fill(DSLight.rule).frame(height: 1)

                WizardNavBar(
                    canGoBack: canGoBack,
                    canGoNext: canAdvance,
                    nextLabel: nextLabel,
                    nextShowsChevron: currentPage != .complete,   // 「下一步」才带箭头（完成/扫描中不带）
                    onBack: goBack,
                    onNext: goNext
                )
            }
        }
        .frame(width: 700, height: 500)
        .background(DSLight.bg)
        .grain()   // 与主窗 / TrayPanel / 设置窗同一材质
    }

    // MARK: - Navigation Logic

    private var canGoBack: Bool {
        if currentPage.rawValue == 0 || currentPage == .complete { return false }
        if currentPage == .scan && setupPhase == .scanning { return false }
        return true
    }

    private var canAdvance: Bool {
        switch currentPage {
        case .scan: return setupPhase == .done || setupPhase == .doneInBackground
        default: return true
        }
    }

    private var nextLabel: String {
        switch currentPage {
        case .complete: return l10n.s.done
        case .scan:
            return setupPhase == .scanning ? l10n.s.scanningEllipsis : l10n.s.next
        default: return l10n.s.next
        }
    }

    private func goBack() {
        guard let prev = WizardPage(rawValue: currentPage.rawValue - 1) else { return }
        currentPage = prev
    }

    private func goNext() {
        completedPages.insert(currentPage)

        if currentPage == .complete {
            onComplete()
            return
        }

        if currentPage == .sources && setupPhase == .idle {
            // 登录项注册（来源页已有告知文案，用户知情）。失败仅记日志：
            // 告知说「会随登录启动」，注册失败时至少留下可排查的痕迹。
            if #available(macOS 13.0, *) {
                do { try SMAppService.mainApp.register() }
                catch { NSLog("[onboarding] login item register failed: \(error)") }
            }
            setupPhase = .scanning
            // 真实进度：等启动 warm-up（AppDelegate 首建索引）完成才宣布「扫描完成」——
            // 曾经固定 sleep 1.2s 假进度，大库用户「完成」后打开主窗仍是空列表。
            // 超 10s 未完成放行（后台继续扫），文案改「已开始扫描，稍后自动完成」。
            Task {
                let minShow = Task { try? await Task.sleep(nanoseconds: 600_000_000) }   // 最短过渡，避免瞬间闪跳
                let deadline = Date().addingTimeInterval(10)
                while !WarmUpTracker.shared.isDone && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await minShow.value
                setupPhase = WarmUpTracker.shared.isDone ? .done : .doneInBackground
                completedPages.insert(.scan)
            }
        }

        guard let next = WizardPage(rawValue: currentPage.rawValue + 1) else { return }
        currentPage = next
    }

}

// MARK: - Sidebar

struct WizardSidebar: View {
    let currentPage: WizardPage
    let completedPages: Set<WizardPage>
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppLogo(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MindBus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DSLight.t1)
                    Text(l10n.s.wizardSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(DSLight.t3)
                }
            }
            .padding(.horizontal, DSLight.spaceLg)
            .padding(.top, DSLight.spaceXl)
            .padding(.bottom, DSLight.spaceLg)

            stepIndicator

            Spacer()

            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                .font(BrandFont.mono(11))
                .foregroundColor(DSLight.t3.opacity(0.5))
                .padding(.horizontal, DSLight.spaceLg)
                .padding(.bottom, DSLight.spaceLg)
        }
        .background(DSLight.sf)
    }

    // MARK: - 步骤指示（玻璃药丸：步骤推进时滑到当前步、折射经过的步骤；停下当前步清晰）

    private let stepRowH: CGFloat = 36

    private var stepIndicator: some View {
        ZStack(alignment: .top) {
            // 底层：所有步骤行常态（玻璃滑过时被折射形变）
            VStack(spacing: 0) {
                ForEach(WizardPage.allCases, id: \.rawValue) { page in
                    stepRow(page, asCurrent: false)
                        .padding(.horizontal, DSLight.spaceLg)
                }
            }
            // 玻璃药丸（折射底层）+ 内部当前步清晰内容（跟随滑动，停下清晰）
            ZStack {
                glassStepPill
                stepRow(currentPage, asCurrent: true)
                    .padding(.horizontal, DSLight.spaceLg - DSLight.spaceSm)
            }
            .frame(height: stepRowH)
            .padding(.horizontal, DSLight.spaceSm)
            .offset(y: CGFloat(currentPage.rawValue) * stepRowH)
            .allowsHitTesting(false)
            .animation(.bouncy(duration: 0.4), value: currentPage)
        }
    }

    private func stepRow(_ page: WizardPage, asCurrent: Bool) -> some View {
        let isCompleted = completedPages.contains(page) && !asCurrent && page != currentPage
        return HStack(spacing: 10) {
            ZStack {
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DSLight.green)
                } else {
                    Text("\(page.rawValue + 1)")
                        .font(BrandFont.mono(11, weight: .medium))
                        .foregroundColor(asCurrent ? DSLight.gold : DSLight.t3)
                }
            }
            .frame(width: 20, height: 20)

            Text(page.title(in: l10n.s))
                .font(.system(size: 13, weight: asCurrent ? .medium : .regular))
                .foregroundColor(asCurrent ? DSLight.t1 : (isCompleted ? DSLight.t2 : DSLight.t3))
            Spacer(minLength: 0)
        }
        .frame(height: stepRowH)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 步骤选中玻璃药丸：通透 glassEffect（折射下面步骤）+ 细边缘高光，旧系统 sf2 实色。
    @ViewBuilder
    private var glassStepPill: some View {
        let shape = RoundedRectangle(cornerRadius: DSLight.radiusSm, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
        } else {
            shape.fill(DSLight.sf2)
        }
    }
}

// MARK: - Navigation Bar

struct WizardNavBar: View {
    let canGoBack: Bool
    let canGoNext: Bool
    let nextLabel: String
    /// 语义化开关替代 `nextLabel == "下一步"` 的字符串比较（双语后文案不可作逻辑依据）。
    let nextShowsChevron: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack {
            if canGoBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                        Text(l10n.s.back)
                    }
                }
                .buttonStyle(MBLightGhostButtonStyle())
            }

            Spacer()

            Button(action: onNext) {
                HStack(spacing: 4) {
                    Text(nextLabel)
                    if canGoNext && nextShowsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                }
            }
            .buttonStyle(MBLightPrimaryButtonStyle())
            .frame(width: 120)
            .disabled(!canGoNext)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DSLight.spaceLg)
        .padding(.vertical, DSLight.spaceMd)
    }
}

// MARK: - Page 1: Sources（首屏 = 知情同意）

/// 首次运行的知情同意页，逐条列出会读取的目录。
///
/// 它同时承担「第一印象」：低频工具的用户隔很久才打开一次，单次体验在记忆中占比极高，
/// 所以第一屏要立刻给确定性——我会读什么、改不改、联不联网——而不是先来一句欢迎辞。
struct SourcesPage: View {
    @ObservedObject private var l10n = L10n.shared

    // 展示名不写死在这里：统一取 ConversationSource.displayName(isZh:)，
    // 改名只改一处，引导页与侧栏/列表永远同名。
    private static let all: [(source: ConversationSource, id: String, path: String)] = [
        (.claudeCode,  "claude_code",  "~/.claude/projects/"),
        (.claudeAgent, "claude_agent", "~/Library/Application Support/Claude/local-agent-mode-sessions/"),
        (.codex,       "codex",        "~/.codex/sessions/"),
    ]

    /// 只列探测到「用过」的工具（用户定案：没有的产品不出现在引导里）。
    /// 全空兜底展示全集——这是知情同意页，至少要说明 App 会读哪些路径。
    private let items: [(source: ConversationSource, id: String, path: String)] = {
        let detected = SourceDetection.detectAvailable()
        let hit = all.filter { detected.contains($0.source) }
        return hit.isEmpty ? all : hit
    }()

    var body: some View {
        // 不套 ScrollView：内容约 250pt、容器 440pt，滚不起来，
        // 徒增一层且让离屏预览渲染不出内容。内容变多时再加回。
        VStack(alignment: .leading, spacing: DSLight.spaceLg) {
            Spacer(minLength: 0)

            // fixedSize(vertical)：英文文案比中文长，几个 Text 竞争高度时
            // 谁没声明纵向完整尺寸谁被压成单行截断——标题/副标题/脚注全部声明。
            Text(l10n.s.sourcesTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DSLight.t1)
                .fixedSize(horizontal: false, vertical: true)

            Text(l10n.s.sourcesSubtitle)
                .font(.system(size: 13))
                .foregroundColor(DSLight.t3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.id) { item in
                    HStack(spacing: DSLight.spaceMd) {
                        Image(systemName: "folder")
                            .foregroundColor(DSLight.gold)
                            .font(.system(size: 16))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.source.displayName(isZh: l10n.isZh))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(DSLight.t1)
                            Text(item.path)
                                .font(BrandFont.mono(11))
                                .foregroundColor(DSLight.t3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, DSLight.spaceBase)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.s.sourcesFootnoteLocal)
                    .font(.system(size: 11))
                    .foregroundColor(DSLight.t4)
                    .fixedSize(horizontal: false, vertical: true)
                // 登录项注册在 goNext 里静默发生——必须在此告知，用户才有知情权。
                Text(l10n.s.sourcesFootnoteLogin)
                    .font(.system(size: 11))
                    .foregroundColor(DSLight.t4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DSLight.spaceXl)
        .padding(.vertical, DSLight.spaceXl)
    }
}

// MARK: - Page 3: Scan & Configure

struct ScanConfigPage: View {
    let phase: SetupPhase
    @ObservedObject private var l10n = L10n.shared
    /// 与第一页同源:只列探测到的工具(此前硬编码三个全名,只装两个工具的
    /// 用户看到与知情同意页矛盾的清单)。
    private let detectedNames: String = {
        let detected = SourceDetection.detectAvailable()
        let names = ConversationStore.browsableSources.filter { detected.contains($0) }
            .map { $0.displayName(isZh: L10n.shared.isZh) }
        return names.isEmpty ? "Claude Code · Claude · Codex" : names.joined(separator: " · ")
    }()
    /// 实时计数:扫描等待从「干等 spinner」变「看着资产被找回来」(Readwise 首扫
    /// 模式——把存量翻译成正在到账的价值)。0.4s 轮询索引条数,纯读快查询。
    @State private var liveCount = 0
    @State private var counting = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSLight.spaceMd) {
            Text(phaseTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DSLight.t1)
                .padding(.horizontal, DSLight.spaceLg)
                .padding(.top, DSLight.spaceLg)

            Text(phaseSubtitle)
                .font(.system(size: 13))
                .foregroundColor(DSLight.t2)
                .padding(.horizontal, DSLight.spaceLg)

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 18))
                    .foregroundColor(DSLight.gold)
                Text(detectedNames)
                    .font(.system(size: 14))
                    .foregroundColor(DSLight.t2)
            }
            .frame(maxWidth: .infinity)

            // 实时收录数:大数字滚动——首扫的 10 秒是制造期待的黄金时机
            if liveCount > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(liveCount)")
                        .font(BrandFont.mono(30, weight: .medium))
                        .foregroundColor(DSLight.gold)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.3), value: liveCount)
                    Text(l10n.s.scanLiveCollected)
                        .font(.system(size: 13))
                        .foregroundColor(DSLight.t2)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                switch phase {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(DSLight.green)
                    Text(l10n.s.scanStatusDone)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DSLight.t1)
                case .doneInBackground:
                    Image(systemName: "clock.arrow.circlepath").foregroundColor(DSLight.gold)
                    Text(l10n.s.scanStatusBackground)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DSLight.t1)
                case .idle, .scanning:
                    ProgressView().controlSize(.small)
                    Text(l10n.s.scanningEllipsis)
                        .font(.system(size: 13))
                        .foregroundColor(DSLight.t2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, DSLight.spaceBase)

            Spacer()
        }
        .onAppear { startCountingIfNeeded() }
        .onChange(of: phase) { _ in startCountingIfNeeded() }
    }

    private func startCountingIfNeeded() {
        guard !counting else { return }
        counting = true
        Task { @MainActor in
            // done 后再刷一次终值;窗口存续期间轮询,页面销毁任务随之取消
            while true {
                liveCount = ConversationIndex.shared?.summary().count ?? 0
                if phase == .done { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .idle, .scanning: return l10n.s.scanTitleScanning
        case .done: return l10n.s.scanTitleDone
        case .doneInBackground: return l10n.s.scanTitleBackground
        }
    }

    private var phaseSubtitle: String {
        switch phase {
        case .idle, .scanning: return l10n.s.scanSubtitleScanning
        case .done: return l10n.s.scanSubtitleDone
        case .doneInBackground: return l10n.s.scanSubtitleBackground
        }
    }

}

// MARK: - Page 5: Complete

struct WizardCompletePage: View {
    /// 完成页文案必须跟随真实扫描状态——scan 页对 doneInBackground 已经诚实，
    /// 这里若恒说「都在这了」等于把谎又说回去（大库用户打开主窗只有部分对话）。
    let phase: SetupPhase
    @ObservedObject private var l10n = L10n.shared
    /// 首扫激活时刻(Readwise 手法):把存量翻译成「险些浪费的价值」。
    /// 「N 段对话·其中 M 段已越过源工具清理线」——第一屏就让新用户看到
    /// 这个库在守护什么。扫描未完成(doneInBackground)时不显示,数字不撒谎。
    @State private var firstScan: ConversationIndex.SanctuaryStats?

    private var stillScanning: Bool { phase == .doneInBackground }

    var body: some View {
        VStack(spacing: DSLight.spaceLg) {
            Spacer()

            Image(systemName: stillScanning ? "clock.arrow.circlepath" : "checkmark.circle.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(stillScanning ? DSLight.gold : DSLight.green)

            Text(l10n.s.completeTitle)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(DSLight.t1)

            Spacer().frame(height: DSLight.spaceBase)

            VStack(spacing: 8) {
                Text(stillScanning ? l10n.s.completeBodyScanning : l10n.s.completeBodyDone)
                    .font(.system(size: 14))
                    .foregroundColor(DSLight.t2)
                Text(l10n.s.completeHint)
                    .font(.system(size: 13))
                    .foregroundColor(DSLight.t3)
                // 菜单栏 App 的关键断点：主窗一关、Dock 无图标、⌘Tab 无条目——
                // 必须在此告知回来的路，否则新用户以为 App 退出了
                Text(l10n.s.completeMenubarHint)
                    .font(.system(size: 11))
                    .foregroundColor(DSLight.t4)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.center)

            if let st = firstScan, st.conversationCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 11)).foregroundStyle(DSLight.gold)
                    Text(sanctuaryLine(st))
                        .font(BrandFont.mono(11)).foregroundStyle(DSLight.t2)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(DSLight.goldG, in: Capsule())
                .padding(.top, DSLight.spaceBase)
            }

            Spacer()
        }
        .padding(.horizontal, DSLight.spaceLg)
        .onAppear {
            // 后台扫描中也取当前已收数——库最大的用户(超时放行)最需要这一眼,
            // 此前 done 才显示,他们反而什么都看不到
            firstScan = ConversationIndex.shared?.sanctuaryStats(now: Date())
        }
    }

    private func sanctuaryLine(_ st: ConversationIndex.SanctuaryStats) -> String {
        if stillScanning {
            return l10n.s.completeSanctuaryOngoing(st.conversationCount)
        }
        return st.outlivedClaudeCode > 0
            ? l10n.s.completeSanctuaryOutlived(st.conversationCount, st.outlivedClaudeCode)
            : l10n.s.completeSanctuary(st.conversationCount)
    }
}




