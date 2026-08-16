import Foundation

/// 跑分器：配置矩阵 × 评测集 → R@k/MRR 三张表的 Markdown 报告（方法学唯一真相同
/// `BenchDataset.swift`：`docs/superpowers/plans/2026-08-11-bench-pipeline.md` Task 2
/// 节；出处 `MEMORY-LAYER-SPEC.md` §7.59「评测集」/ §7.60「查询扩展」/ §7.61「情境
/// 先验」）。
///
/// **为什么放 MindBusCore**：与 `BenchDataset` 同样的理由——测试要能 `@testable
/// import` 直接单测，`mindbus-bench`（`MindBus/BenchMain/`）要能 `import MindBusCore`
/// 调用。不进 app bundle 的边界由 `Package.swift` 的 target exclude 保证，不是这层
/// 的职责。
public struct BenchConfig {
    public let name: String
    public let expansion: ConversationIndex.ExpansionPolicy
    /// nil = 无先验；`BenchConfig.answerCwdContext`（`"answer-cwd"`）= 逐条用**该
    /// item 答案会话自己的 cwd** 当 context——不是配置级别写死一个路径。
    ///
    /// 语义（§7.61 情境先验的"公平 vs oracle"）：情境先验模拟的是"agent 提问时恰好
    /// 在某个项目目录里"，这个先验要公平，查询本身就得天然带着"在哪个项目里问的"
    /// 这个场景信息。四路查询来源里只有 commitMessage 天然满足——它就是从某个仓库
    /// 的 commit message 派生的，agent 在那个仓库里问是自然场景。其余三路
    /// （rareEntity/firstMessage/structuralEvent）的"该 item 答案会话的 cwd"只有在
    /// **已经知道标准答案是谁**的前提下才给得出，是评测脚本能看见、真实 agent 看不
    /// 见的信息——用在这三路上是事后 oracle，构成结果上界，不是可复现的真实使用
    /// 场景。`BenchRunner.run` 渲染的报告里对此有显式标注，不能只看数字不看标注。
    ///
    /// 其余任何非 nil、非 `answerCwdContext` 的字符串原样传给
    /// `searchWithHits(contextPath:)`（当前默认配置矩阵未用到，为自定义配置留口）。
    public let contextPath: String?

    public init(name: String, expansion: ConversationIndex.ExpansionPolicy, contextPath: String? = nil) {
        self.name = name
        self.expansion = expansion
        self.contextPath = contextPath
    }

    /// `contextPath` 的哨兵值。具名常量而非到处写字面量 `"answer-cwd"`——
    /// `BenchRunner`（解析）、`BenchMain`（构造默认配置矩阵）、测试三处都要用同一个
    /// 值，字面量迟早会有一处敲错还测不出来。
    public static let answerCwdContext = "answer-cwd"
}

public enum BenchRunner {

    /// 报告里三张表的分组展示顺序——固定字面量数组而不是 `CaseIterable`：展示顺序是
    /// 报告可读性的产品决策（低命中带最值得关注、放最上面；四路来源按 §7.59 定义
    /// 顺序），不该被 `BenchItem.Band`/`Source` 未来增删 case 的声明顺序悄悄带偏。
    private static let allBands: [BenchItem.Band] = [.low, .mid, .high]
    private static let allSources: [BenchItem.Source] = [.commitMessage, .rareEntity, .firstMessage, .structuralEvent]

    // MARK: - 入口

    /// 对 `items` 里每一条，逐个 `configs` 跑 `index.searchWithHits`，取
    /// `.map(\.id)` 里 `answerID` 的名次（1-based；未出现记 nil），据此渲染整体 +
    /// 分带 + 分查询来源三张表的 Markdown 报告。
    ///
    /// 索引只读、零写入；`configs.count × items.count` 次检索调用，每次都是普通
    /// 索引查询（毫秒级），千级评测集 × 4 配置在开发机上是秒级到分钟级，不做并发
    /// ——`ConversationIndex` 内部本就是单串行队列，并发调用只会排队等，不会更快。
    public static func run(items: [BenchItem], index: ConversationIndex, configs: [BenchConfig]) -> String {
        let metas = index.allMetadata()
        // 逐条解析 `.answerCwdContext` 要按 answerID 查 cwd；一次性建表好过对每个
        // (config, item) 都重新扫一遍 `allMetadata()`。id 理论唯一，`uniquingKeysWith`
        // 兜底万一撞了也不崩（保留先出现的那条，不影响哨兵解析的正确性）。
        let cwdByID = Dictionary(metas.map { ($0.id, $0.cwd) }, uniquingKeysWith: { first, _ in first })

        var ranksByConfig: [String: [Int?]] = [:]
        for config in configs {
            ranksByConfig[config.name] = items.map { item in
                let ctx = resolveContextPath(config.contextPath, answerID: item.answerID, cwdByID: cwdByID)
                let hitIDs = index.searchWithHits(item.query, expansion: config.expansion, contextPath: ctx).map(\.id)
                return hitIDs.firstIndex(of: item.answerID).map { $0 + 1 }
            }
        }

        return render(items: items, configs: configs, ranksByConfig: ranksByConfig, corpusSize: metas.count)
    }

    /// `.answerCwdContext` 只有在索引里还能查到这条 item 的 answerID 时才解析出
    /// 真实 cwd；查不到（评测集比索引旧、答案会话已被清理/改名）退化成无先验，不崩、
    /// 不报错——同索引层"失败不假装"的一贯风格（`applyContextPrior` 对查不到 cwd 的
    /// 命中同样是静默跳过不加权，不是特例）。
    static func resolveContextPath(_ raw: String?, answerID: String, cwdByID: [String: String]) -> String? {
        guard let raw else { return nil }
        guard raw == BenchConfig.answerCwdContext else { return raw }
        return cwdByID[answerID]
    }

    // MARK: - 指标

    struct GroupMetrics {
        let n: Int
        let r1: Double
        let r5: Double
        let r10: Double
        let r20: Double
        let mrr: Double
    }

    /// R@k = 命中名次 ≤k 的条目占比；MRR = 名次倒数之和 / N，**名次 >20（含未命中的
    /// nil）记 0**——方法学定死（plan Task 2："MRR(名次倒数,>20 名记 0)"），不是无穷
    /// 尾巴的传统 MRR。理由：这是与 R@20 同一个观察窗口内的 MRR，避免"R@20 读数是 0
    /// 但 MRR 因为排名 200 还偷偷贡献了一点点"这种两个指标互相打架、报告读者却看不
    /// 出为什么的怪象——检索系统本就不会把候选看到第 200 名，排名 20 开外在实际使用
    /// 里与"没找到"没有区别。
    ///
    /// `ranks` 为空（该分组 0 条 item）返回 nil，调用方渲染成 N/A 而不是做除以零
    /// 运算（0.0/0.0 在 Swift 里是 NaN，会静默污染 Markdown 表格，比显式 N/A 更难
    /// 发现）。
    ///
    /// internal（非 private）：同 `BenchDataset.bandForOverlap` 的先例，供测试直接
    /// 单测数值边界，不进公开 API。
    static func computeMetrics(ranks: [Int?]) -> GroupMetrics? {
        guard !ranks.isEmpty else { return nil }
        let n = ranks.count
        func recall(_ k: Int) -> Double {
            Double(ranks.filter { ($0 ?? .max) <= k }.count) / Double(n)
        }
        let mrrSum = ranks.reduce(0.0) { acc, rank in
            guard let rank, rank <= 20 else { return acc }
            return acc + 1.0 / Double(rank)
        }
        return GroupMetrics(n: n, r1: recall(1), r5: recall(5), r10: recall(10), r20: recall(20),
                             mrr: mrrSum / Double(n))
    }

    // MARK: - 渲染

    private static func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
    private static func mrrText(_ x: Double) -> String { String(format: "%.3f", x) }

    /// `labels` 打头（整体表 1 列=配置名；分带/分来源表 2 列=分组名+配置名），后接
    /// N/R@1/R@5/R@10/R@20/MRR 六列。`metrics` 为 nil（该分组 0 条）时 N 给 0、其余
    /// 五列一律 `N/A`，不参与任何数值运算。
    private static func row(_ labels: [String], _ metrics: GroupMetrics?) -> String {
        let cells: [String]
        if let m = metrics {
            cells = ["\(m.n)", pct(m.r1), pct(m.r5), pct(m.r10), pct(m.r20), mrrText(m.mrr)]
        } else {
            cells = ["0", "N/A", "N/A", "N/A", "N/A", "N/A"]
        }
        return "| " + (labels + cells).joined(separator: " | ") + " |"
    }

    /// 报告头部日期，格式 `yyyy-MM-dd`。`Calendar(identifier: .gregorian)` 显式指定
    /// ——不能依赖 `Calendar.current`，用户系统日历设成非公历（日本历/佛历等）时会
    /// 读出完全不同的年月日（铁律，见 plan Global Constraints）。
    ///
    /// `public`（非 private）：`BenchMain` 给报告文件命名 `report-<日期>.md` 时要用
    /// **同一个**日期字符串——报告正文头部的日期与文件名的日期必须是同一次计算，
    /// 两处各调一次 `Date()` 理论上能在跨午夜的极端时刻读出两个不同的日子，
    /// 单一入口从物理上排除这种可能。
    public static func todayString() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func render(items: [BenchItem], configs: [BenchConfig],
                                ranksByConfig: [String: [Int?]], corpusSize: Int) -> String {
        var lines: [String] = []

        // MARK: 头部——日期/语料规模/评测集规模/与 §7.59 的语料差异声明
        lines.append("# MindBus Bench 评测报告")
        lines.append("")
        lines.append("- 日期：\(todayString())")
        lines.append("- 语料规模：\(corpusSize) 会话（§7.59 当年建库时为 738 会话，本次仅 \(corpusSize)——" +
                      "如实标注语料规模差异，本报告只承诺趋势可比，不承诺复现当年绝对数字）")
        let sourceBreakdown = allSources
            .map { source in "\(source.rawValue) \(items.filter { $0.source == source }.count)" }
            .joined(separator: " / ")
        lines.append("- 评测集规模：\(items.count) 条（\(sourceBreakdown)）")
        lines.append("")

        // MARK: 配置矩阵——先说清每个配置名对应的 expansion/contextPath 是什么
        lines.append("## 配置矩阵")
        lines.append("")
        lines.append("| 配置 | expansion | contextPath |")
        lines.append("|---|---|---|")
        for config in configs {
            let ctxDesc: String
            switch config.contextPath {
            case nil: ctxDesc = "无"
            case BenchConfig.answerCwdContext?: ctxDesc = "answer-cwd（逐条取答案会话 cwd，见下方 oracle 标注）"
            case let other?: ctxDesc = other
            }
            lines.append("| \(config.name) | \(String(describing: config.expansion)) | \(ctxDesc) |")
        }
        lines.append("")

        // MARK: 整体
        lines.append("## 整体")
        lines.append("")
        lines.append("| 配置 | N | R@1 | R@5 | R@10 | R@20 | MRR |")
        lines.append("|---|---|---|---|---|---|---|")
        for config in configs {
            lines.append(row([config.name], computeMetrics(ranks: ranksByConfig[config.name] ?? [])))
        }
        lines.append("")

        // MARK: 分带
        lines.append("## 分带")
        lines.append("")
        lines.append("| 带 | 配置 | N | R@1 | R@5 | R@10 | R@20 | MRR |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for band in allBands {
            let idxs = items.indices.filter { items[$0].band == band }
            for config in configs {
                let ranks = idxs.map { (ranksByConfig[config.name] ?? [])[$0] }
                lines.append(row([band.rawValue, config.name], computeMetrics(ranks: ranks)))
            }
        }
        lines.append("")

        // MARK: 分查询来源
        lines.append("## 分查询来源")
        lines.append("")
        lines.append("| 来源 | 配置 | N | R@1 | R@5 | R@10 | R@20 | MRR |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for source in allSources {
            let idxs = items.indices.filter { items[$0].source == source }
            for config in configs {
                let ranks = idxs.map { (ranksByConfig[config.name] ?? [])[$0] }
                lines.append(row([source.rawValue, config.name], computeMetrics(ranks: ranks)))
            }
        }
        lines.append("")

        // MARK: oracle 标注——只在配置矩阵里出现过 answer-cwd 时才有意义,但固定打印
        // 不做条件判断：报告结构稳定好过"有时候多一段有时候没有"，且哪怕这一轮没跑
        // always+ctx，这段说明本身也是无害的方法论备忘。
        lines.append("> **oracle 标注**：`always+ctx` 配置的 context 是该 item 答案会话的 cwd。" +
                      "对 **commitMessage** 来源公平——查询本身就是从该仓库的 commit message 派生，" +
                      "agent 在那个仓库里提问是自然场景，不是作弊。对 **rareEntity / firstMessage / " +
                      "structuralEvent** 三路，这个 context 只有已经知道标准答案是谁才给得出，是事后 " +
                      "oracle、构成结果上界，不是可复现的真实使用场景。")
        lines.append(">")
        lines.append("> commitMessage rows are fair-context; other sources are oracle-context (upper bound).")

        return lines.joined(separator: "\n")
    }
}
