import Foundation

/// 为 Chromium 浏览器注册 Native Messaging Host
/// 写入 com.mindbus.native.json 到各浏览器的 NativeMessagingHosts 目录
/// 浏览器扩展通过 Chrome Native Messaging 把抓到的对话推给本 App。
enum NativeMessagingConfigurator {

    static let hostName = "com.mindbus.native"

    /// 浏览器 → NativeMessagingHosts 目录路径
    private static let browserPaths: [(String, String)] = [
        ("Chrome",  "Google/Chrome/NativeMessagingHosts"),
        ("Arc",     "Arc/User Data/NativeMessagingHosts"),
        ("Edge",    "Microsoft Edge/NativeMessagingHosts"),
        ("Brave",   "BraveSoftware/Brave-Browser/NativeMessagingHosts"),
        ("Opera",   "com.operasoftware.Opera/NativeMessagingHosts"),
        ("Chromium","Chromium/NativeMessagingHosts"),
    ]

    struct Result: Identifiable {
        let id: String
        let browser: String
        let success: Bool
    }

    /// 写入所有检测到的浏览器的 NativeMessagingHosts 目录
    /// - Parameter extensionID: Chrome 扩展 ID（上架后替换）
    /// - Returns: 配置结果列表
    static func configureAll(extensionID: String = "fefgdhhdpcehmogchinofieoakboogme") -> [Result] {
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        let manifest = buildManifest(extensionID: extensionID)

        var results: [Result] = []

        for (browser, relativePath) in browserPaths {
            let hostDir = appSupport.appendingPathComponent(relativePath)

            // 只写入已有浏览器数据目录的路径（不为不存在的浏览器创建目录）
            let parentDir = hostDir.deletingLastPathComponent()
            guard fm.fileExists(atPath: parentDir.path) else { continue }

            do {
                // 创建 NativeMessagingHosts 目录（如果浏览器目录存在但 NMH 子目录不存在）
                if !fm.fileExists(atPath: hostDir.path) {
                    try fm.createDirectory(at: hostDir, withIntermediateDirectories: true)
                }

                let manifestPath = hostDir.appendingPathComponent("\(hostName).json")
                try manifest.write(to: manifestPath, atomically: true, encoding: .utf8)

                results.append(Result(id: browser, browser: browser, success: true))
            } catch {
                results.append(Result(id: browser, browser: browser, success: false))
            }
        }

        return results
    }

    /// 构建 Native Messaging Host manifest JSON
    private static func buildManifest(extensionID: String) -> String {
        let appPath = Bundle.main.executablePath ?? "/Applications/MindBus.app/Contents/MacOS/MindBus"

        let manifest: [String: Any] = [
            "name": hostName,
            "description": "MindBus Native Messaging Host — API Key sync & extension bridge",
            "path": appPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]

        // JSONSerialization for ordered output
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        // Fallback
        return """
        {
          "name": "\(hostName)",
          "description": "MindBus Native Messaging Host",
          "path": "\(appPath)",
          "type": "stdio",
          "allowed_origins": ["chrome-extension://\(extensionID)/"]
        }
        """
    }

    /// 清除所有已写入的 manifest 文件
    static func removeAll() {
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        for (_, relativePath) in browserPaths {
            let manifestPath = appSupport
                .appendingPathComponent(relativePath)
                .appendingPathComponent("\(hostName).json")
            try? fm.removeItem(at: manifestPath)
        }
    }
}
