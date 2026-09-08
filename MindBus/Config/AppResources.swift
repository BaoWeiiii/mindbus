import Foundation
import MindBusCore

/// App 自身资源（logo / 菜单栏图标 / 官方 mark / DM Mono 字体）的唯一入口。
///
/// 不直接用 SwiftPM 生成的 `Bundle.module`：它只找两处——`.app` 根目录旁的
/// `MindBus_MindBus.bundle`，以及编译机上的绝对构建路径。发布包里资源包必须放
/// `Contents/Resources`（放根目录 codesign 报 unsealed contents、公证不过），
/// CI runner 的构建路径在用户机器上又不存在——两个候选全落空，`Bundle.module`
/// 直接 `fatalError`，App 打开即崩（issue #3，v0.1.0 DMG 全体用户中招）。
/// 本机 `install.sh` 装的能跑纯属巧合：兜底的绝对路径恰好就是本机 `.build`。
///
/// 这里先按发布包布局找（`Bundle.main.resourceURL`），找不到再退回 `Bundle.module`
/// （`swift build` 裸跑：`Bundle.main` 就是构建目录，资源包在旁边）。
enum AppResources {
    static let bundleName = "MindBus_MindBus"

    static let bundle: Bundle =
        ResourceBundleLocator.bundled(named: bundleName, in: Bundle.main.resourceURL) ?? Bundle.module

    /// 发布包里必须齐的资源（对应 Package.swift 的 resources 列表，OFL 许可证文本除外）。
    static let required: [(name: String, ext: String)] = [
        ("menubar-logo", "png"), ("logo", "png"),
        ("claude-mark", "png"), ("openai-mark", "png"),
        ("DMMono-Regular", "ttf"), ("DMMono-Medium", "ttf"),
    ]

    /// `MindBus --check-resources`：组装脚本装完 bundle 后跑一次，不起 NSApplication。
    /// 明确要求资源包位于 `Bundle.main` 之内——CI 上 `Bundle.module` 的兜底路径恰好存在，
    /// 不加这条限制，自检在 runner 上永远是绿的、到用户机器上照样崩。
    static func selfCheck() -> Bool {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let found = bundle.bundleURL.resolvingSymlinksInPath().path
        guard found.hasPrefix(app + "/") else {
            FileHandle.standardError.write(Data("✗ resource bundle resolved outside the app: \(found)\n".utf8))
            return false
        }
        let missing = required.filter { bundle.url(forResource: $0.name, withExtension: $0.ext) == nil }
        guard missing.isEmpty else {
            let list = missing.map { "\($0.name).\($0.ext)" }.joined(separator: ", ")
            FileHandle.standardError.write(Data("✗ missing resources in \(found): \(list)\n".utf8))
            return false
        }
        print("✓ resources: \(found)")
        return true
    }
}
