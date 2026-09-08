import Foundation

/// 「只有新系统才有」的 UI 分支总开关。
///
/// `if #available(macOS 26.0, *)` 在开发机（26）上永远走新分支，旧系统分支等于从没执行过——
/// 与 issue #3 同一类问题：发出去的代码没在对应环境里跑过。这里给一个开关让所有
/// `#available` 分支在新系统上也能强制走旧路径：
///
///     MINDBUS_LEGACY_UI=1 /Applications/MindBus.app/Contents/MacOS/MindBus
///     defaults write ai.mindbus.app legacyUI -bool YES
///
/// 启动、PreviewRenderer（`--render-preview`）都吃这个开关，于是两套布局都能在本机渲出来看。
/// 只在进程启动时读一次；它不能替代真机 / VM 上的旧系统验证，只保证旧分支的代码本身跑得通。
enum DesignCapabilities {
    static let forceLegacy: Bool =
        ProcessInfo.processInfo.environment["MINDBUS_LEGACY_UI"] == "1"
        || UserDefaults.standard.bool(forKey: "legacyUI")
}
