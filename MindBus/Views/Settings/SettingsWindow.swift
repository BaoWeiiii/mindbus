import AppKit
import SwiftUI

/// 设置窗口（自管 NSWindow）。
/// 不用 SwiftUI `Settings` scene：popover / 右键菜单等入口需要随时开窗，
/// 走和 `ConversationBrowserWindow` 一样的自管模式，保证点「设置」一定开窗。
///
/// 窗口高度的教训（白边连环案，2026-08）：titled 窗口 frame 天生 =
/// titlebar(32) + contentSize——AppKit 的约束系统会持续把窗口保持在
/// 「hostingView 需求 + titlebar」的高度，任何强设更矮 frame 的尝试
/// （setContentSize / min-maxSize 锁 / didResize 自稳环）要么被覆盖、
/// 要么和布局系统对拉直至 Update Constraints pass 爆炸崩溃。
/// 正解是不抢方向盘：窗口尺寸交还 AppKit，视图侧用
/// `.frame(maxHeight: .infinity, alignment: .top)` 弹性填满——
/// 多出的高度是同色留白而不是露出 NSWindow 白底。
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var windowController: NSWindowController?

    private init() {}

    func show() {
        if let wc = windowController, let w = wc.window {
            w.title = L10n.shared.s.settingsTitle   // 窗口缓存复用，标题跟当前语言
            positionCentered(w)                      // 每次打开都重新居中（相对主窗）
            summonToActiveSpace(w)
            activateApp()
            return
        }

        let hosting = NSHostingController(rootView: CopyPreferencesView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.shared.s.settingsTitle
        // 系统原生 titlebar（白边连环案后的定型）：标题由系统渲染、与红绿灯
        // 原生对齐；titlebar 透明化让暖白窗底延续到顶。此前的
        // fullSizeContentView + 自绘假标题栏让 AppKit 与 SwiftUI 对内容高度
        // 各持一词（safe area 注入 32pt），底部永远悬着一段空白。
        // fullSizeContentView 仅为让标题 overlay 能叠进 titlebar 区居中
        // （macOS 26 系统标题左对齐、且无对齐 API）。白边案的教训在于
        // ignoresSafeArea 强行顶排内容——这次内容照常排在安全区之下，
        // 只有标题文字 overlay 进 titlebar，布局需求与 AppKit 完全一致。
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(srgbRed: 0xFA/255, green: 0xF9/255, blue: 0xF6/255, alpha: 1)   // DSLight.bg
        window.isMovableByWindowBackground = false
        let fit = hosting.view.fittingSize
        window.setContentSize(NSSize(width: 460, height: max(fit.height, 300)))
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua) // 内容为 DSLight 亮色 token，暗色系统下必须锁亮色
        positionCentered(window)

        let wc = NSWindowController(window: window)
        self.windowController = wc

        summonToActiveSpace(window)   // 唤到当前 Space 并置前（含 makeKeyAndOrderFront）
        activateApp()
    }

    /// 设置窗的归属感：从主窗打开就压在主窗正中央；主窗不在（托盘/右键直开）
    /// 退回屏幕居中。每次 show 都重摆——settings 是小浮窗，无位置记忆的必要。
    private func positionCentered(_ window: NSWindow) {
        if let main = ConversationBrowserWindow.shared.visibleWindow {
            let mf = main.frame
            let size = window.frame.size
            let origin = NSPoint(x: mf.midX - size.width / 2,
                                 y: mf.midY - size.height / 2)
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
    }
}
