import Foundation

/// 按 App 发布包布局定位 SwiftPM 资源包：`<App>.app/Contents/Resources/<name>.bundle`。
///
/// SwiftPM 生成的 `Bundle.module` 不认这个位置——它只找 `.app` 根目录旁的
/// `<name>.bundle` 与编译机上的绝对构建路径，两处都落空就 `fatalError`。
/// 而资源包又只能放这里：`.app` 根目录多任何东西 codesign 都报
/// "unsealed contents present in the bundle root"，公证不过。
/// 找不到返回 nil，由调用方决定兜底（App 侧退回 `Bundle.module` 供裸跑）。issue #3。
public enum ResourceBundleLocator {
    public static func bundled(named name: String, in resourceURL: URL?) -> Bundle? {
        guard let resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("\(name).bundle", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return Bundle(url: url)
    }
}
