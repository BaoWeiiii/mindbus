import AppKit
import SwiftUI
import MindBusCore

/// 失焦也保持激活态外观：材质 / Liquid Glass 跟随 isKeyWindow 渲染，
/// 恒报 key 让玻璃、列表等不在切走焦点时整体变灰。
private final class AlwaysActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// 单例管理"聊天记录"独立窗口。
@MainActor
final class ConversationBrowserWindow {
    static let shared = ConversationBrowserWindow()

    private var windowController: NSWindowController?
    private let store = ConversationStore()
    private var clickMonitor: Any?
    private static let frameAutosaveName = "MindBusConversationBrowser"

    private init() {}

    /// 供设置窗相对主窗居中定位：仅当主窗可见时返回。
    var visibleWindow: NSWindow? {
        guard let w = windowController?.window, w.isVisible else { return nil }
        return w
    }

    func show() {
        if let wc = windowController, let window = wc.window {
            // 不再强制 positionTopCenter：窗口是单例、永不销毁，每次唤起都摆回
            // 「居中靠上」会把用户拖到副屏或摆去半屏的位置一并抹掉。
            // 只在首次创建时定位（见下方 showWindow 之后那次）。
            summonToActiveSpace(window)
            activateApp()
            store.refresh()   // 单例窗口不会重建，这里补一次增量刷新（内部 30s 节流）
            return
        }

        let rootView = ConversationBrowserView()
            .environmentObject(store)

        let hosting = NSHostingController(rootView: rootView)

        let window = AlwaysActiveWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = ""

        // 折叠钮挂 titlebar accessory：系统把它钉在红绿灯右侧，折叠/展开位置永远不变。
        let toggleHost = NSHostingView(rootView: SidebarToggleButton().environmentObject(store))
        toggleHost.frame = NSRect(x: 0, y: 0, width: 40, height: 34)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = toggleHost
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
        // 无边框窗：内容延伸到标题栏区，三栏直接顶到窗口顶（与设置窗一致）。
        // 红绿灯浮在最左侧栏左上，侧栏顶部留 inset 避让。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact   // 系统 toolbar 控件（侧栏折叠钮）紧凑化，接近自绘 34px 圆钮
        window.isMovableByWindowBackground = false   // 全背景拖动会把 SwiftUI 自绘滚动条的拖动误判成拖窗——可拖区由 windowDragArea() 精确划定
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua) // 内容为 DSLight 亮色 token，暗色系统下必须锁亮色

        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = false        // 禁止系统 cascade 偏移（否则窗口飘到右上）
        self.windowController = wc

        summonToActiveSpace(window)   // 唤到当前 Space 并置前（含 makeKeyAndOrderFront）
        // 记住窗口大小与位置。只有从未保存过时才用默认的「居中靠上」——
        // 否则用户每次重启都得重新把窗口摆回副屏 / 半屏的位置。
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            positionTopCenter(window)
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        activateApp()

        // 点击搜索框以外的区域时收回输入焦点（否则光标一直闪烁）。
        // O(1)：只在「文本正聚焦 + 点击落在其 frame 外」时收——不做整树 hitTest
        //（hitTest 巨型 LazyVStack 会同步卡住点击路径，曾导致光标延迟约 1s）。
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let win = self?.windowController?.window, event.window === win else { return event }
                if let tv = win.firstResponder as? NSTextView {
                    let frameInWindow = tv.convert(tv.bounds, to: nil)
                    if !frameInWindow.contains(event.locationInWindow) {
                        win.makeFirstResponder(nil)
                    }
                }
                return event
            }
        }

        if store.allConversations.isEmpty {
            store.loadAsync()
        }
        store.startWatching()   // 之后靠文件监听自动跟进，不必等 App 激活
    }

    /// 把窗口摆到当前屏幕「水平居中、垂直靠上」（菜单栏下方留边距，不挡 Dock）。
    private func positionTopCenter(_ window: NSWindow) {
        // 选「鼠标所在的屏」——点 menubar 时鼠标在你当前操作的那块屏，多显示器下更符合预期。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { window.center(); return }
        let vf = screen.visibleFrame
        let size = window.frame.size
        let x = vf.minX + (vf.width - size.width) / 2
        let topMargin = max(40, vf.height * 0.06)        // 靠上，但不贴死菜单栏
        let y = vf.maxY - size.height - topMargin
        window.setFrameOrigin(NSPoint(x: x, y: max(vf.minY, y)))
    }
}
