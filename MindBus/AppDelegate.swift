import Cocoa
import SwiftUI
import MindBusCore

/// 启动 warm-up（首建/增量索引）完成状态：Onboarding 扫描页据此显示真实进度，
/// 而不是固定 sleep 假进度（大库用户假进度一过、打开主窗仍是空列表的双重失望）。
@MainActor
final class WarmUpTracker: ObservableObject {
    static let shared = WarmUpTracker()
    @Published private(set) var isDone = false
    func markDone() { isDone = true }
}

/// App 生命周期管理
/// 负责 menubar 图标、popover、全局快捷键注册
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Native Messaging 已在 main.swift 拦截，这里不会进入

        // 初始化 menubar
        statusBar = StatusBarController()

        // 启动 Sparkle 计划检查。shared 是懒加载单例——不在这里 touch 的话，
        // 只有打开过设置窗口的用户才会启动 updater，后台更新检查等于不存在。
        _ = UpdaterManager.shared

        // 每次启动刷新 Native Messaging manifest（本地 IPC，不联网）
        let _ = NativeMessagingConfigurator.configureAll()

        // 后台预热对话索引：首次建库（一次性 + 进度由 popover summary 反映），之后增量。
        // 全程本地操作；峰值内存受控（流式 parse + autoreleasepool，全文进 SQLite 不驻留）。
        Task.detached(priority: .utility) {
            // 共享实例：此前这里与 ConversationStore.loadAsync 各建一个连接，
            // 首次启动时用户点开窗口就会并发跑两遍全量扫描、两个写者互撞回滚。
            guard let index = ConversationIndex.shared else {
                await MainActor.run { WarmUpTracker.shared.markDone() }   // 打不开索引也别让向导干等
                return
            }
            await LoaderRuntime.indexAllSources(into: index)
            NSLog("[vault] index warm-up done")
            await MainActor.run { WarmUpTracker.shared.markDone() }
        }

        // 首次启动检查
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            statusBar?.showOnboarding()
        }
    }

    /// 点 Dock 图标（.regular 期间）或再次双击 .app：没有可见主窗就开对话库。
    /// 「双击 = 想用」——比只弹菜单栏图标更符合预期。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in ConversationBrowserWindow.shared.show() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 常驻型 App（menubar 图标 + 后台采集/同步）永不因关窗退出——
        // 关掉聊天记录窗/设置窗只是收起界面，App 留在 Dock 和菜单栏。
        false
    }
}
