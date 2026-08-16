import Foundation

// Chrome Native Messaging 模式检测 — 必须在 NSApplication 启动前拦截
// Chrome 传入 chrome-extension://ID 作为参数
let isNativeMessaging = CommandLine.arguments.contains("--native-messaging")
    || CommandLine.arguments.contains(where: { $0.hasPrefix("chrome-extension://") })

if isNativeMessaging {
    // 直接进入 stdin/stdout 通信模式，不启动 GUI
    NativeMessagingHandler.run() // -> Never
} else if let i = CommandLine.arguments.firstIndex(of: "--render-preview"),
          i + 1 < CommandLine.arguments.count {
    // 临时设计校验脚手架，验证完删除
    MainActor.assumeIsolated { PreviewRenderer.run(outputDir: CommandLine.arguments[i + 1]) }
} else {
    // 正常启动 SwiftUI App
    MindBusApp.main()
}
