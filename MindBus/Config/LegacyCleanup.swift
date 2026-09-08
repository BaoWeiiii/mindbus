import Foundation
import MindBusCore

/// 旧版本残留清理。
///
/// ≤1.4.0 每次启动都往 Chrome / Arc / Edge / Brave / Opera / Chromium 的
/// `NativeMessagingHosts/` 写 `com.mindbus.native.json`（浏览器扩展桥，已整体移除）。
/// 这里只删这一个确定的文件名，以及扩展桥在 `~/.mindbus` 留下的两个标记文件。
enum LegacyCleanup {

    private static let hostFile = "com.mindbus.native.json"

    private static let browserDirs = [
        "Google/Chrome/NativeMessagingHosts",
        "Arc/User Data/NativeMessagingHosts",
        "Microsoft Edge/NativeMessagingHosts",
        "BraveSoftware/Brave-Browser/NativeMessagingHosts",
        "com.operasoftware.Opera/NativeMessagingHosts",
        "Chromium/NativeMessagingHosts",
    ]

    static func removeNativeMessagingManifests() {
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        for dir in browserDirs {
            let f = appSupport.appendingPathComponent(dir).appendingPathComponent(hostFile)
            guard fm.fileExists(atPath: f.path) else { continue }
            do {
                try fm.removeItem(at: f)
                NSLog("[cleanup] removed legacy native messaging manifest under %@", dir)
            } catch {
                NSLog("[cleanup] failed to remove legacy manifest: %@", String(describing: error))
            }
        }
        for name in ["extension-connected", "settings-cache.json", "settings-cache.json.tmp"] {
            let f = MindBusHome.root.appendingPathComponent(name)
            if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
        }
    }
}
