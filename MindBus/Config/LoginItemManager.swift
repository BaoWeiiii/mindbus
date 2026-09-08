import Foundation
import ServiceManagement

/// 登录项（开机自启）的唯一入口。
///
/// 默认关闭：向导里勾选或设置里打开才注册，关闭即 unregister。
/// 此前向导点「下一步」即静默注册、App 内无处关闭——对本地隐私工具是负面观感。
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    /// 裸跑（swift build 直接运行，非 .app bundle）时 SMAppService 不可用——设置里不显示该卡。
    let available: Bool

    @Published private(set) var enabled: Bool

    private init() {
        available = Bundle.main.bundlePath.hasSuffix(".app")
        enabled = available && SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) {
        guard available else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[login-item] %@ failed: %@", on ? "register" : "unregister", String(describing: error))
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
