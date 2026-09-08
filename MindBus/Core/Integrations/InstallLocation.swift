import Foundation

/// App 自身所在位置的稳定性判定。
///
/// 直接在 DMG 里双击启动会被 Gatekeeper 做 App Translocation（跑在
/// `/private/var/folders/…/AppTranslocation/<随机>/d/MindBus.app`），或者干脆跑在
/// `/Volumes/<镜像>/…`——这些路径一弹出镜像就失效。凡是「把自己的路径写到别处」的功能
/// （MCP 接入写 `~/.claude.json` / Codex 配置、开机自启注册、Sparkle 更新）都必须先过这一关，
/// 否则写下的就是一条几分钟后失效的路径。
public enum InstallLocation {
    public enum Kind: Equatable {
        /// 普通安装位置（/Applications、~/Applications 或任何非临时目录）
        case installed
        /// Gatekeeper App Translocation 的随机只读路径
        case translocated
        /// 挂载的卷（安装镜像 / 外接盘）
        case volume
        /// 非 .app 裸跑（swift build 直接运行）
        case bare
    }

    public static func classify(bundlePath: String) -> Kind {
        guard bundlePath.hasSuffix(".app") else { return .bare }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .volume }
        return .installed
    }

    /// 路径会随镜像弹出或下次启动失效：不该被写进任何配置。
    public static func isTransient(bundlePath: String) -> Bool {
        switch classify(bundlePath: bundlePath) {
        case .translocated, .volume: return true
        case .installed, .bare: return false
        }
    }
}
