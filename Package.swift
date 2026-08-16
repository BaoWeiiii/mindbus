// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MindBus",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "MindBus", targets: ["MindBus"]),
        // 只读 MCP server：宿主（Claude Code / Codex）以子进程方式拉起，走 stdio。
        .executable(name: "mindbus-mcp", targets: ["mindbus-mcp"]),
        // 评测管线 CLI：本地开发者工具，不进 app bundle（`install.sh`/`build-release.sh`
        // 只按名字拷 `mindbus-mcp` 与主 App 两个二进制，不会捎带上这个）。
        .executable(name: "mindbus-bench", targets: ["mindbus-bench"]),
        .library(name: "MindBusCore", targets: ["MindBusCore"]),
    ],
    // 零外部依赖：App 不联网，因此不需要自动更新（Sparkle）与崩溃上报（Sentry）。
    dependencies: [
        // 唯一外部依赖：Sparkle 自动更新（更新检查 opt-in，用户可关——
        // 除此之外仍是零网络代码，grep URLSession MindBus/ 依然为空）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "MindBusCore",
            path: "MindBus/Core",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // MCP 协议层与三个工具的渲染。逻辑全在库里，可执行文件只是 stdio 泵——
        // 否则协议分支只能靠手工管道验证，测不到。
        .target(
            name: "MindBusMCP",
            dependencies: ["MindBusCore"],
            path: "MindBus/MCP"
        ),
        .executableTarget(
            name: "mindbus-mcp",
            dependencies: ["MindBusMCP"],
            path: "MindBus/MCPMain"
        ),
        // `mindbus-bench`：评测管线 CLI（generate/run 两子命令）。依赖 `MindBusMCP`
        // 而不只是 `MindBusCore`——是为了原样复用 `MCPIndexAccess.defaultIndexPath()`/
        // `.message(for:path:)`（索引路径解析 + "打不开怎么办"文案的唯一真相已经在
        // 那个 target 里，见其文件头注释），不为一句路径解析在这里另起一份、迟早漂移。
        // `MindBusMCP` 本身只是协议/工具层，不带 AppKit/SwiftUI，链进纯 CLI 无副作用。
        .executableTarget(
            name: "mindbus-bench",
            dependencies: ["MindBusCore", "MindBusMCP"],
            path: "MindBus/BenchMain"
        ),
        .executableTarget(
            name: "MindBus",
            dependencies: ["MindBusCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "MindBus",
            // Core/MCP/MCPMain 都在 MindBus/ 下但属于别的 target，必须排掉——
            // 漏排 MCPMain 会把第二个 main.swift 编进 app，报重复入口。
            // BenchMain 是 `mindbus-bench` CLI 的 target 目录（评测管线 Task 2 才建、
            // 本轮尚不存在）——提前占位排除，防止那个 target 建好后有人忘记同步改这里，
            // 让第三个 main.swift 也编进 app（bench 是开发者工具，不该进 app bundle）。
            exclude: ["Assets.xcassets", "Core", "MCP", "MCPMain", "BenchMain"],
            resources: [
                .copy("Resources/logo.png"),
                .copy("Resources/menubar-logo.png"),
                .copy("Resources/claude-mark.png"),
                .copy("Resources/openai-mark.png"),
                // DM Mono（SIL OFL 1.1）—— 许可证按 OFL 要求随字体一并分发
                .copy("Resources/DMMono-Regular.ttf"),
                .copy("Resources/DMMono-Medium.ttf"),
                .copy("Resources/DMMono-OFL.txt"),
            ]
        ),
        .testTarget(
            name: "MindBusCoreTests",
            dependencies: ["MindBusCore", "MindBusMCP", .product(name: "Sparkle", package: "Sparkle")],
            path: "Tests/MindBusCoreTests"
        ),
    ]
)
