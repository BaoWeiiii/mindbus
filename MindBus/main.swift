import Foundation

#if DEBUG
// 设计校验用离屏渲染（只编进 DEBUG 构建）：`MindBus --render-preview <输出目录>`
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"),
   i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { PreviewRenderer.run(outputDir: CommandLine.arguments[i + 1]) }
}
#endif

// 发布自检：`MindBus --check-resources` 不起 NSApplication，只验证资源包能从 .app 内部
// 找到（build-release.sh / install.sh 组装完 bundle 后各跑一次）。issue #3 的教训：
// 资源解析失败发生在 applicationDidFinishLaunching 里，测试全绿也拦不住启动即崩。
if CommandLine.arguments.contains("--check-resources") {
    exit(AppResources.selfCheck() ? 0 : 1)
}

MindBusApp.main()
