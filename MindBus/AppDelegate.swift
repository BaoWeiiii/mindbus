import Cocoa
import SwiftUI
import MindBusCore

/// App 生命周期管理
/// 负责 menubar 图标、popover、全局快捷键注册
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化 menubar
        statusBar = StatusBarController()

        // 两道启动前提检查（issue #3 复盘：失败必须出声，不能静默空库）。
        // ① 系统 SQLite 低于索引门槛（macOS 14 以下）→ 索引根本建不起来；
        // ② 从安装镜像 / translocation 临时位置启动 → 自启、MCP 接入、自动更新写下的路径都会失效。
        warnIfSQLiteTooOld()
        warnIfRunningFromTransientLocation()

        // 启动 Sparkle 计划检查。shared 是懒加载单例——不在这里 touch 的话，
        // 只有打开过设置窗口的用户才会启动 updater，后台更新检查等于不存在。
        _ = UpdaterManager.shared

        // 1.4.1：清掉 ≤1.4.0 写进各浏览器的 Native Messaging 清单（扩展桥已整体移除），
        // 并把 ~/.mindbus 权限收紧到 700/600——副本不该比源目录更开放。
        Task.detached(priority: .utility) {
            LegacyCleanup.removeNativeMessagingManifests()
            MindBusHome.tightenPermissions()
        }

        // 后台预热对话索引：首次建库（一次性 + 进度由 popover summary 反映），之后增量。
        // 全程本地操作；峰值内存受控（流式 parse + autoreleasepool，全文进 SQLite 不驻留）。
        Task.detached(priority: .utility) {
            // 共享实例：此前这里与 ConversationStore.loadAsync 各建一个连接，
            // 首次启动时用户点开窗口就会并发跑两遍全量扫描、两个写者互撞回滚。
            guard let index = ConversationIndex.shared else { return }
            await LoaderRuntime.indexAllSources(into: index)
            NSLog("[vault] index warm-up done")
        }

        // 首次启动：不弹向导，直接开对话库——列表标题显示「正在收集 · 已找到 N 场」、
        // 侧栏各工具行显示正在读取 / 场数，右侧空态是欢迎页（只读三目录、数据留本机、一键接入）；
        // 来源 / 自启 / 更新开关都在设置页，默认值就是合理值。
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            Task { @MainActor in ConversationBrowserWindow.shared.show() }
        }
    }

    @MainActor private func warnIfSQLiteTooOld() {
        guard !SQLiteDB.libVersionIsSupported() else { return }
        let s = L10n.shared.s
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = s.sqliteTooOldTitle
        alert.informativeText = s.sqliteTooOldBody(SQLiteDB.libVersion)
        alert.runModal()
    }

    @MainActor private func warnIfRunningFromTransientLocation() {
        guard InstallLocation.isTransient(bundlePath: Bundle.main.bundlePath) else { return }
        let s = L10n.shared.s
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = s.transientLocationTitle
        alert.informativeText = s.transientLocationBody
        alert.addButton(withTitle: s.transientLocationOpenApplications)
        alert.addButton(withTitle: s.transientLocationContinue)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
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
        // 常驻型 App（menubar 图标 + 后台采集）永不因关窗退出——
        // 关掉聊天记录窗/设置窗只是收起界面，App 留在 Dock 和菜单栏。
        false
    }
}
