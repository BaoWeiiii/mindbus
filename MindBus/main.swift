import Foundation

#if DEBUG
// 设计校验用离屏渲染（只编进 DEBUG 构建）：`MindBus --render-preview <输出目录>`
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"),
   i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { PreviewRenderer.run(outputDir: CommandLine.arguments[i + 1]) }
}
#endif

MindBusApp.main()
