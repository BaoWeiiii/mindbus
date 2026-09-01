import Foundation
import MindBusCore
import MindBusMCP

// mindbus-bench：评测管线本地开发者工具，两个子命令 `generate`/`run`。不进 app
// bundle（`Package.swift` 里 `MindBus` target 已 `exclude` `BenchMain`；
// `install.sh`/`build-release.sh` 只按名字拷 `mindbus-mcp` 与主 App 两个二进制，
// 不会捎带上这个）。索引一律只读；产物只落 `~/.mindbus/bench/`（或
// `MINDBUS_BENCH_ROOT` 覆盖）——绝不写索引/vault/minds/refs，评测集内容含用户真实
// 语料，绝不进 git 仓。
//
// 逻辑全在 `MindBusCore`（`BenchDataset`/`BenchRunner`）——这里只做参数解析、路径
// 策略（落盘位置由调用方决定，两个库文件的文件头注释都明说了这一点）、索引开关，
// 同 `MindBus/MCPMain/main.swift` 的定位："可执行文件只是泵，不该有测不到的逻辑"。

let usage = """
Usage:
  mindbus-bench generate [--max-per-source N]   默认 N=200；写 <benchRoot>/dataset.jsonl
  mindbus-bench run [--dataset PATH]            默认读 <benchRoot>/dataset.jsonl；报告写 <benchRoot>/report-<日期>.md
"""

/// `~/.mindbus/bench`。`MINDBUS_BENCH_ROOT` 可覆盖——与 `MindsBuilder.mindsRoot()`
/// 同模式：trim 后为空视同未设置（纯空白不该被当成合法目录名，否则后续操作在一个
/// 诡异路径上悄悄失败），`~` 手工展开（这个值多半来自 shell 环境变量但 Swift 的
/// `ProcessInfo.environment` 读到的是 shell 展开**之前**的原始值，`%`/`~` 这类
/// shell 语法不会被自动处理）。
func benchRoot() -> URL {
    if let raw = ProcessInfo.processInfo.environment["MINDBUS_BENCH_ROOT"] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        }
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mindbus", isDirectory: true)
        .appendingPathComponent("bench", isDirectory: true)
}

/// 索引打不开：复用 `MCPIndexAccess` 的路径解析（尊重 `MINDBUS_INDEX_PATH`）与
/// "打不开怎么办"文案——同 `mindbus-mcp` 的既有措辞，用户/开发者不用为同一个故障学
/// 两套说法。打不开直接退出非零码：bench 是一次性命令行工具不是常驻服务，没有
/// "重试连接"这个概念，调用方（人或 CI）该看着提示去开一次 App。
func openIndexOrExit() -> ConversationIndex {
    let path = MCPIndexAccess.defaultIndexPath()
    do {
        return try ConversationIndex.openReadOnly(path: path)
    } catch {
        FileHandle.standardError.write(Data((MCPIndexAccess.message(for: error, path: path) + "\n").utf8))
        exit(1)
    }
}

func intOption(_ name: String, in args: [String], default def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return def }
    return v
}

func stringOption(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// 四路来源固定展示顺序（同 `BenchRunner` 的理由：产品决策，不依赖 `BenchItem.Source`
/// 声明顺序）。
private let sourceDisplayOrder: [BenchItem.Source] = [.commitMessage, .rareEntity, .firstMessage, .structuralEvent]

func runGenerate(args: [String]) {
    let maxPerSource = intOption("--max-per-source", in: args, default: 200)
    let index = openIndexOrExit()
    let items = BenchDataset.generate(index: index, maxPerSource: maxPerSource)

    let datasetURL = benchRoot().appendingPathComponent("dataset.jsonl")
    BenchDataset.write(items, to: datasetURL)

    print("[mindbus-bench] generated \(items.count) items -> \(datasetURL.path)")
    for source in sourceDisplayOrder {
        let bySource = items.filter { $0.source == source }
        let low = bySource.filter { $0.band == .low }.count
        let mid = bySource.filter { $0.band == .mid }.count
        let high = bySource.filter { $0.band == .high }.count
        print("  \(source.rawValue): \(bySource.count)  (low=\(low) mid=\(mid) high=\(high))")
    }
}

func runRun(args: [String]) {
    let datasetURL = stringOption("--dataset", in: args)
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? benchRoot().appendingPathComponent("dataset.jsonl")
    let items = BenchDataset.read(from: datasetURL)
    guard !items.isEmpty else {
        FileHandle.standardError.write(Data("""
        No bench dataset at \(datasetURL.path) (missing or empty). Run `mindbus-bench generate` first.

        """.utf8))
        exit(1)
    }

    let index = openIndexOrExit()
    // 计划定死的四配置矩阵（plan Task 2）：off 基线 / adaptive（GUI 现行策略）/
    // always（MCP 现行策略）/ always+ctx（叠加情境先验，逐条取答案会话 cwd——
    // 对 commitMessage 一路是公平配置，其余三路是 oracle 上界，见报告里的标注）。
    let configs: [BenchConfig] = [
        BenchConfig(name: "off", expansion: .off),
        BenchConfig(name: "adaptive", expansion: .adaptive),
        BenchConfig(name: "always", expansion: .always),
        BenchConfig(name: "always+ctx", expansion: .always, contextPath: BenchConfig.answerCwdContext),
    ]
    let report = BenchRunner.run(items: items, index: index, configs: configs)

    let root = benchRoot()
    let reportURL = root.appendingPathComponent("report-\(BenchRunner.todayString()).md")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        print(report)
        print("\n[mindbus-bench] report written to \(reportURL.path)")
    } catch {
        // 落盘失败不该吞掉已经算出来的报告——stdout 仍然打印完整结果，只在末尾
        // 补一句失败提示，让用户自己去检查 `benchRoot` 的权限/磁盘空间。
        print(report)
        FileHandle.standardError.write(
            Data("[mindbus-bench] failed to write report to \(reportURL.path): \(error)\n".utf8))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    runGenerate(args: Array(args.dropFirst()))
case "run":
    runRun(args: Array(args.dropFirst()))
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(1)
}
