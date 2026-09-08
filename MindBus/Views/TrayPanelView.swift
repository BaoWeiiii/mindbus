import SwiftUI
import MindBusCore

extension Notification.Name {
    static let openConversationBrowser = Notification.Name("MindBus.openConversationBrowser")
}

/// 品牌 logo 进程级缓存：
/// 曾经 TrayPanel header / Onboarding 每次 render 都 NSImage(contentsOf:) 读盘。
enum BrandLogoImage {
    static let logo: NSImage? = {
        guard let url = Bundle.module.url(forResource: "logo", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }()
}

/// Menubar 展开面板（亮色主题，全本地）
struct TrayPanelView: View {
    @StateObject private var viewModel = TrayPanelViewModel()
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.5)

            vaultSummary

            Divider().opacity(0.5)

            openBrowserRow

            Divider().opacity(0.5)

            footer
        }
        .frame(width: 280)
        .grain()   // 与主窗同一材质：同 App 内一个窗有纸纹、另一个没有，比都没有更糟
        .onAppear {
            viewModel.refresh()
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if let nsImage = BrandLogoImage.logo {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "diamond.fill")
                        .foregroundColor(DSLight.gold)
                }
            }
            .frame(width: 20, height: 20)

            Text("MindBus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DSLight.t1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 本地对话库汇总

    private var vaultSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.isScanning && viewModel.localCount == 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(l10n.s.scanningEllipsis)
                        .font(.system(size: 13))
                        .foregroundColor(DSLight.t2)
                }
            } else {
                HStack(spacing: 6) {
                    Text("\(viewModel.localCount)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DSLight.t1)
                    Text(l10n.s.trayConversationsUnit(viewModel.localCount))
                        .font(.system(size: 12))
                        .foregroundColor(DSLight.t2)
                }

                if let date = viewModel.latestConversationAt {
                    Text(l10n.s.trayLatest(date.relativeLabel(isZh: l10n.isZh)))
                        .font(.system(size: 11))
                        .foregroundColor(DSLight.t3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 打开聊天记录

    private var openBrowserRow: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "folder", label: l10n.s.openConversationBrowser, trailing: nil) {
                NotificationCenter.default.post(name: .openConversationBrowser, object: nil)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 底部（设置 + 退出）

    private var footer: some View {
        VStack(spacing: 0) {
            ActionRow(icon: "gearshape", label: l10n.s.settingsTitle, trailing: nil) {
                SettingsWindow.shared.show()
            }

            ActionRow(icon: "power", label: l10n.s.quitMindBus, trailing: nil, tint: DSLight.t3) {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 子组件

/// 通用操作行
private struct ActionRow: View {
    let icon: String
    let label: String
    let trailing: String?
    var tint: Color = DSLight.t1
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 18)
                    .foregroundColor(tint == DSLight.t1 ? DSLight.t2 : tint)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(tint)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DSLight.t3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .rowHoverBackground(isHovering)
            .contentShape(Rectangle())
            .padding(.horizontal, 6)   // hover 块左右留 inset，不贴面板边
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - ViewModel

@MainActor
class TrayPanelViewModel: ObservableObject {
    // Local vault summary
    @Published var localCount: Int = 0
    @Published var sourceCount: Int = 0
    @Published var latestConversationAt: Date? = nil
    @Published var isScanning: Bool = false

    private var refreshTimer: Timer?
    private var lastScanAt: Date?

    func refresh() {
        loadLocalSummary()
    }

    /// 本地对话库汇总：总数 / 来源数 / 最新对话时间。
    /// 主线程只读 UserDefaults 标量（微秒级），扫描全程在后台。
    /// 1) 先读轻量汇总缓存秒显
    /// 2) 节流 30s 后台增量扫描（priorCache 复用未变文件，结果回写 UserDefaults）
    func loadLocalSummary() {
        // 1. 轻量汇总缓存秒显（UserDefaults 标量）
        let d = UserDefaults.standard
        let cachedCount = d.integer(forKey: Self.kCount)
        if cachedCount > 0 {
            localCount = cachedCount
            sourceCount = d.integer(forKey: Self.kSources)
            latestConversationAt = d.object(forKey: Self.kLatest) as? Date
        }

        // 2. 节流：30s 内不重复
        let now = Date()
        if let last = lastScanAt, now.timeIntervalSince(last) < 30 { return }
        lastScanAt = now
        if localCount == 0 { isScanning = true }

        // 3. 后台读 index.summary()（SQL 聚合，毫秒级，不解析全文）。
        //    共享实例，避免每 60 秒新开一个连接。
        Task.detached(priority: .utility) {
            let s = ConversationIndex.shared?.summary() ?? (count: 0, sources: 0, latest: nil)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // index 还没建好（count 0）但有历史缓存 → 维持缓存显示，避免闪 0
                if s.count == 0 && cachedCount > 0 { return }
                self.localCount = s.count
                self.sourceCount = s.sources
                self.latestConversationAt = s.latest
                self.isScanning = false
                let d = UserDefaults.standard
                d.set(s.count, forKey: Self.kCount)
                d.set(s.sources, forKey: Self.kSources)
                if let latest = s.latest { d.set(latest, forKey: Self.kLatest) }
            }
        }
    }

    private static let kCount = "vault.localCount"
    private static let kSources = "vault.sourceCount"
    private static let kLatest = "vault.latestConversationAt"

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
