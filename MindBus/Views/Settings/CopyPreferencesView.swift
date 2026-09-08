import SwiftUI
import MindBusCore

/// 复制偏好持久化（UserDefaults，JSON）。单例，供详情页按钮与设置页共享。
final class CopyPrefsStore: ObservableObject {
    static let shared = CopyPrefsStore()
    private static let key = "copyPreferences"

    @Published var prefs: CopyPreferences { didSet { persist() } }

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode(CopyPreferences.self, from: d) {
            prefs = p
        } else {
            prefs = CopyPreferences()
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }
}

/// 设置（Cmd+,）。不透明暖白底 + 不透明内容卡；Liquid Glass 集中体现在 segmented：
/// 选中胶囊 = 半透玻璃底 + 彩虹折射边缘（lensing 色散，仿 iOS Liquid Glass）+ 顶部高光，
/// 切换时 offset 流动滑过去。顶部 glassEffect header 作导航层。
struct CopyPreferencesView: View {
    @ObservedObject private var store = CopyPrefsStore.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var updater = UpdaterManager.shared
    @ObservedObject private var loginItem = LoginItemManager.shared
    @ObservedObject private var sourcePrefs = SourcePrefsModel.shared
    @ObservedObject private var connector = MCPConnector.shared

    private let segW: CGFloat = 108
    private let segSpacing: CGFloat = 4
    private let segH: CGFloat = 36

    var body: some View {
        // 内容固定不滚，高度自撑；标题/拖动带由系统原生 titlebar 接管
        //（自绘假标题栏时代的 safe area 纠缠与底部悬空已随之退场）。
        VStack(alignment: .leading, spacing: 14) {
            section(title: nil) { copyRelayCard }
            section(title: nil) { languageCard }
            section(title: nil) { exportCard }
            section(title: nil) { sourcesCard }
            section(title: nil) { mcpCard }
            if loginItem.available {
                section(title: nil) { loginItemCard }
            }
            if updater.available {
                section(title: nil) { updateCard }
            }
            versionLine
                .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(DSLight.bg)
        .grain()   // 与主窗 / TrayPanel 同一材质
        // 标题叠进 titlebar 区：水平居中 + 与红绿灯同排（用户定案）。
        // overlay 不参与布局需求，内容仍排在安全区之下——与 AppKit 零分歧。
        .overlay(alignment: .top) {
            Text(l10n.s.settingsTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DSLight.t1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
                .windowDragArea()   // titlebar 区被 contentView 覆盖，拖动带补回
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(width: 460)
    }

    // MARK: - 内容层：不透明卡

    @ViewBuilder
    private func section<C: View>(
        title: String?,
        footer: String? = nil,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DSLight.t2)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 设置窗是独立浮窗语境，卡圆角随概念稿放宽到 10（主窗内嵌卡仍守 ≤6）
            .background(DSLight.sf, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(DSLight.t3)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - 语言卡

    /// 界面语言：跟随系统 / 中文 / English（macOS 惯例用下拉，不复用双选 segmented）。
    /// 切换即时生效于所有窗口——包括下次首启的向导。
    @ViewBuilder
    private var languageCard: some View {
        HStack {
            Text(l10n.s.settingsLanguage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSLight.t1)
            Spacer()
            Menu {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        l10n.language = lang
                    } label: {
                        if l10n.language == lang {
                            Label(languageLabel(lang), systemImage: "checkmark")
                        } else {
                            Text(languageLabel(lang))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(languageLabel(l10n.language))
                        .font(.system(size: 13))
                        .foregroundStyle(DSLight.t2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DSLight.t3)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)   // 系统 indicator 与自绘 chevron 叠成双箭头
            .fixedSize()
        }
    }

    // MARK: - 导出与备份卡(用户定案 2026-08-11:从侧栏挪进设置,参考稿形态)

    /// 「能带走,人才敢住进来」:不造导出向导的假仪式——
    /// 数据本就是纯文件,打开文件夹即是最诚实的导出。
    @ViewBuilder
    private var exportCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.s.exportSectionTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSLight.t1)
                Text(l10n.s.exportSectionBody)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.t3)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".mindbus", isDirectory: true)])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                    Text(l10n.s.exportOpenFolder)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(DSLight.gold)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func languageLabel(_ lang: AppLanguage) -> String {
        switch lang {
        case .system: return l10n.s.langSystem
        case .zhHans: return l10n.s.langZh
        case .en: return l10n.s.langEn
        }
    }

    // MARK: - 对话来源卡（每个工具一个开关；此前只能手改 ~/.mindbus/ignore）

    @ViewBuilder
    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.s.sourcesCardTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSLight.t1)
            Text(l10n.s.sourcesCardBody)
                .font(.system(size: 12))
                .foregroundStyle(DSLight.t3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SourceCatalog.entries, id: \.source) { entry in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.source.displayName(isZh: l10n.isZh))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DSLight.t1)
                        Text(entry.path)
                            .font(BrandFont.mono(11))
                            .foregroundStyle(DSLight.t3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(get: { sourcePrefs.isEnabled(entry.source) },
                                             set: { sourcePrefs.setEnabled($0, for: entry.source) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(DSLight.gold)
                }
            }
        }
    }

    // MARK: - AI 接入卡（一键写进宿主的 MCP 配置；其他工具退回复制指令）

    @ViewBuilder
    private var mcpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.s.mcpCardTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSLight.t1)
            Text(l10n.s.mcpCardBody)
                .font(.system(size: 12))
                .foregroundStyle(DSLight.t3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MCPConnector.Host.allCases) { host in
                let st = connector.state(host)
                HStack(spacing: 12) {
                    Text(host.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DSLight.t1)
                    Spacer(minLength: 12)
                    if !st.installed {
                        Text(l10n.s.mcpNotInstalled)
                            .font(.system(size: 12))
                            .foregroundStyle(DSLight.t4)
                    } else if st.connected {
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                                Text(l10n.s.mcpConnectedShort).font(.system(size: 12))
                            }
                            .foregroundStyle(DSLight.green)
                            Button(l10n.s.mcpDisconnect) { connector.disconnect(host) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(DSLight.t3)
                        }
                    } else if connector.transientLocation {
                        Text(l10n.s.moveToApplicationsFirst)
                            .font(.system(size: 12))
                            .foregroundStyle(DSLight.t3)
                    } else {
                        Button {
                            connector.connect(host)
                        } label: {
                            Text(l10n.s.mcpConnect(host.displayName))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DSLight.gold)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let err = connector.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.5)
            Text(l10n.s.mcpOtherTools)
                .font(.system(size: 12))
                .foregroundStyle(DSLight.t3)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.s.mcpPrompt(MCPSetup.serverPath))
                .font(BrandFont.mono(11))
                .foregroundStyle(DSLight.t2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSLight.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            CopyMCPPromptButton()
        }
        .onAppear { connector.refresh() }
    }

    // MARK: - 登录项卡（默认关；此前向导静默注册且 App 内无处关闭）

    @ViewBuilder
    private var loginItemCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.s.launchAtLoginToggle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSLight.t1)
                Text(loginItem.transientLocation ? l10n.s.moveToApplicationsFirst : l10n.s.launchAtLoginHint)
                    .font(.system(size: 12))
                    .foregroundStyle(DSLight.t3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
                .disabled(loginItem.transientLocation)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DSLight.gold)
        }
    }

    // MARK: - 更新卡（Sparkle → GitHub Releases，默认开可关）

    /// 单行（用户定案）：左「自动检查更新」开关，右手动「检查更新」，无卡标题。
    @ViewBuilder
    private var updateCard: some View {
        HStack {
            Toggle(isOn: $updater.automaticallyChecks) {
                Text(l10n.s.updateAutoCheck)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSLight.t1)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DSLight.gold)
            Spacer()
            Button {
                updater.checkForUpdates()
            } label: {
                HStack(spacing: 3) {
                    Text(l10n.s.aboutCheckUpdates).font(.system(size: 13))
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(DSLight.gold)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 复制接力卡（核心：iOS 风彩虹玻璃 segmented）

    @ViewBuilder
    private var copyRelayCard: some View {
        HStack(spacing: 5) {
            Text(l10n.s.copyScope)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSLight.t1)
            // 问号跟在标题旁（macOS 设置惯例位置）:hover 出智能档说明——
            // 悬在胶囊右上角像未读徽章、破坏控件轮廓,已否决
            HelpBadge(text: l10n.s.copyScopeHelp)
            Spacer()
            slidingSegmented
        }
    }

    /// macOS 原生流动玻璃选择器：选中玻璃药丸做**背景**（在文字之下），文字清晰浮在其上，
    /// offset 滑动。（iOS 那种「玻璃折射背后内容的 lensing 畸变」物理上只在玻璃背后有滚动内容时
    /// 才出现——设置卡是平的不透明面、背后无内容可折射，只能磨砂；真 lensing 的主场是主窗滚动列表。）
    /// 概念稿样式：浅灰轨道上，选中项是「白底浮起胶囊 + 金字」（替代旧金玻璃药丸）——
    /// 白胶囊带一点极轻阴影制造浮起感，offset 滑动切换保留。
    private var slidingSegmented: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
                .frame(width: segW, height: segH)
                .offset(x: store.prefs.stripCode ? 0 : segW + segSpacing)
            HStack(spacing: segSpacing) {
                segLabel(smart: true, title: l10n.s.scopeSmart)
                segLabel(smart: false, title: l10n.s.scopeAll)
            }
        }
        .padding(3)
        .background(Capsule().fill(DSLight.sf2))
        .animation(.bouncy(duration: 0.5), value: store.prefs.stripCode)
    }

    @ViewBuilder
    private func segLabel(smart: Bool, title: String) -> some View {
        let selected = (store.prefs.stripCode == smart)
        Text(title)
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? DSLight.gold : DSLight.t2)
            .frame(width: segW, height: segH)
            .contentShape(Rectangle())
            .onTapGesture { smartModeBinding.wrappedValue = smart }
    }

    // MARK: - 页脚

    /// 压轴行（惯例形态）：软件名 + 版本号 + GitHub 入口，一行小字居中。
    private var versionLine: some View {
        HStack(spacing: 7) {
            Text("MindBus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DSLight.t2)
            Text("v\(Self.appVersion)")
                .font(BrandFont.mono(11))
                .foregroundStyle(DSLight.t3)
            GitHubLinkButton()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 绑定

    /// 复制接力两模式：智能 = 省略代码 + 加交接说明（筛选关键上下文）；全部 = 原封不动整段。
    private var smartModeBinding: Binding<Bool> {
        Binding(
            get: { store.prefs.stripCode },
            set: { smart in
                store.prefs.stripCode = smart
                store.prefs.includeHeader = smart
                store.prefs.scope = .all
            }
        )
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

// MARK: - GitHub mark

/// GitHub octocat 图形（官方 16×16 路径离线转贝塞尔），矢量可染色，无位图资产。
private struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: x, y: y) }
        var p = Path()
        p.move(to: P(8.000, 0.000))
        p.addCurve(to: P(0.000, 8.000), control1: P(3.580, 0.000), control2: P(0.000, 3.580))
        p.addCurve(to: P(5.470, 15.590), control1: P(0.000, 11.540), control2: P(2.290, 14.530))
        p.addCurve(to: P(6.020, 15.210), control1: P(5.870, 15.660), control2: P(6.020, 15.420))
        p.addCurve(to: P(6.010, 13.720), control1: P(6.020, 15.020), control2: P(6.010, 14.390))
        p.addCurve(to: P(3.320, 12.780), control1: P(4.000, 14.090), control2: P(3.480, 13.230))
        p.addCurve(to: P(2.500, 11.650), control1: P(3.230, 12.550), control2: P(2.840, 11.840))
        p.addCurve(to: P(2.490, 11.120), control1: P(2.220, 11.500), control2: P(1.820, 11.130))
        p.addCurve(to: P(3.720, 11.940), control1: P(3.120, 11.110), control2: P(3.570, 11.700))
        p.addCurve(to: P(6.050, 12.600), control1: P(4.440, 13.150), control2: P(5.590, 12.810))
        p.addCurve(to: P(6.560, 11.530), control1: P(6.120, 12.080), control2: P(6.330, 11.730))
        p.addCurve(to: P(2.920, 7.580), control1: P(4.780, 11.330), control2: P(2.920, 10.640))
        p.addCurve(to: P(3.740, 5.430), control1: P(2.920, 6.710), control2: P(3.230, 5.990))
        p.addCurve(to: P(3.820, 3.310), control1: P(3.660, 5.230), control2: P(3.380, 4.410))
        p.addCurve(to: P(6.020, 4.130), control1: P(3.820, 3.310), control2: P(4.490, 3.100))
        p.addCurve(to: P(8.020, 3.860), control1: P(6.660, 3.950), control2: P(7.340, 3.860))
        p.addCurve(to: P(10.020, 4.130), control1: P(8.700, 3.860), control2: P(9.380, 3.950))
        p.addCurve(to: P(12.220, 3.310), control1: P(11.550, 3.090), control2: P(12.220, 3.310))
        p.addCurve(to: P(12.300, 5.430), control1: P(12.660, 4.410), control2: P(12.380, 5.230))
        p.addCurve(to: P(13.120, 7.580), control1: P(12.810, 5.990), control2: P(13.120, 6.700))
        p.addCurve(to: P(9.470, 11.530), control1: P(13.120, 10.650), control2: P(11.250, 11.330))
        p.addCurve(to: P(10.010, 13.010), control1: P(9.760, 11.780), control2: P(10.010, 12.260))
        p.addCurve(to: P(10.000, 15.210), control1: P(10.010, 14.080), control2: P(10.000, 14.940))
        p.addCurve(to: P(10.550, 15.590), control1: P(10.000, 15.420), control2: P(10.150, 15.670))
        p.addCurve(to: P(16.000, 8.000), control1: P(13.807, 14.491), control2: P(16.000, 11.437))
        p.addCurve(to: P(8.000, 0.000), control1: P(16.000, 3.580), control2: P(12.420, 0.000))
        let s = rect.width / 16
        return p.applying(CGAffineTransform(scaleX: s, y: s))
    }
}

/// 版本行里的 GitHub 图标按钮：t3 灰常态，hover 转金。
private struct GitHubLinkButton: View {
    @State private var hovering = false
    var body: some View {
        Button {
            if let u = URL(string: "https://github.com/BaoWeiiii/mindbus") { NSWorkspace.shared.open(u) }
        } label: {
            GitHubMark()
                .fill(hovering ? DSLight.gold : DSLight.t3, style: FillStyle(eoFill: true))
                .frame(width: 13, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("GitHub")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 问号说明浮层

/// hover 出说明的小问号（灰常态 / hover 转金）。popover 走系统浮窗，
/// 不受卡片布局裁剪；鼠标移开即收。
private struct HelpBadge: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 13))
            .foregroundStyle(showing ? DSLight.gold : DSLight.t3)
            .onHover { h in
                withAnimation(.easeOut(duration: 0.12)) { showing = h }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12))
                    .lineSpacing(6)   // 中文行高 ≥1.85（设计系统 CJK 规则）
                    .foregroundStyle(DSLight.t1)
                    .padding(14)
                    .frame(width: 250)
            }
            .accessibilityLabel(text)
    }
}
