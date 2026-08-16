import SwiftUI
import Sparkle

/// Sparkle 自动更新的唯一入口。
///
/// 产品身份约定：这是全 App **唯一的网络功能**——更新检查走 Sparkle → GitHub
/// Releases（appcast 在仓库 main 分支），**默认开启、设置一键关闭**，关掉即
/// 回归零网络。`grep URLSession MindBus/` 依然为空（网络代码在 Sparkle 框架内）。
/// 完整性由 EdDSA 签名保证（公钥在 Info.plist，CI 用私钥签每个更新包）。
///
/// 提示形态（用户定案）：**不弹首启询问、不弹计划检查的更新窗**——后台发现
/// 新版本时只把版本号亮到「设置」顶部的金色横幅（Sparkle gentle reminders），
/// 用户点横幅才进入标准更新流程；手动点「检查更新」仍即时弹标准 UI。
/// 弹窗语言：Sparkle 自带 zh_CN 资源，跟随系统语言（Info.plist 已声明
/// CFBundleLocalizations——不声明的话系统认定 App 只有英文）。
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    /// 裸跑（swift build 直接运行，非 .app bundle）时 Sparkle 不可用——
    /// 整体禁用，设置里也不显示更新卡。
    let available: Bool

    /// 后台计划检查发现的新版本号；非 nil 时设置顶部显示更新横幅。
    @Published private(set) var availableUpdateVersion: String? = nil

    private var controller: SPUStandardUpdaterController?

    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    private override init() {
        let isBundledApp = Bundle.main.bundlePath.hasSuffix(".app")
        available = isBundledApp
        automaticallyChecks = false
        super.init()
        guard isBundledApp else { return }
        // startingUpdater: false → 先建好（delegate 需要 self），再手动 start
        let ctl = SPUStandardUpdaterController(startingUpdater: false,
                                               updaterDelegate: nil,
                                               userDriverDelegate: self)
        controller = ctl
        ctl.startUpdater()
        automaticallyChecks = ctl.updater.automaticallyChecksForUpdates
    }

    /// 手动检查（设置页按钮 / 横幅点击）：Sparkle 标准 UI 接管后续。
    func checkForUpdates() {
        availableUpdateVersion = nil
        controller?.checkForUpdates(nil)
    }
}

// MARK: - Gentle reminders：计划检查不弹窗，改亮设置横幅

extension UpdaterManager: SPUStandardUserDriverDelegate {

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 计划（后台）检查发现更新：返回 false 接管提示——不弹标准窗，
    /// 由 standardUserDriverWillHandleShowingUpdate 记录版本号亮横幅。
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }   // 标准 UI 自己弹（手动检查路径）
        let version = update.displayVersionString
        Task { @MainActor in self.availableUpdateVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableUpdateVersion = nil }
    }
}
