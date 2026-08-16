import SwiftUI
import AppKit

/// MindBus macOS App 入口
/// 常规 App（Dock 图标常在）+ menubar 图标做快捷入口
struct MindBusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 不声明 WindowGroup——主窗由 ConversationBrowserWindow 自管。
        // Cmd+, 会开出 SwiftUI Settings 空窗：这里立即转发到自管 SettingsWindow
        // 并关掉宿主空窗——避免出现第二个设置窗。
        Settings {
            SettingsRedirectView()
        }
    }
}

/// Settings scene 占位内容：一旦被系统展示，抓到宿主窗口 → 关掉它 → 打开真正的设置窗。
private struct SettingsRedirectView: View {
    var body: some View {
        SettingsWindowGrabber()
            .frame(width: 1, height: 1)
    }
}

private struct SettingsWindowGrabber: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            let host = v.window
            SettingsWindow.shared.show()
            host?.close()
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
