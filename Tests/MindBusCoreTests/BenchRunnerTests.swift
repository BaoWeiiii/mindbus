import XCTest
import Foundation
@testable import MindBusCore

/// 跑分器（spec `MEMORY-LAYER-SPEC.md` §7.59-§7.61；方法学唯一真相：
/// `docs/superpowers/plans/2026-08-11-bench-pipeline.md` Task 2 节）：R@k/MRR 计算、
/// 分带/分来源表聚合、`"answer-cwd"` 哨兵解析、oracle 标注。
///
/// 全部用临时 SQLite 索引（UUID 命名，`addTeardownBlock` 清理）+ 直接 `upsert` 注入
/// 可控内容（同 `ContextPriorTests` 的既有手法：用重复词频而不是内容重复造分数差，
/// 因为 bm25 分数相同时的第二排序键不是 SQL 层保证的稳定顺序，只有真实分数差才可靠）
/// ——绝不碰真实数据。
final class BenchRunnerTests: XCTestCase {

    // MARK: - 索引 / 临时目录

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "benchrun-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    private func lite(_ id: String, cwd: String) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(timeIntervalSince1970: 1_000),
                         endAt: Date(timeIntervalSince1970: 2_000), cwd: cwd, gitBranch: nil,
                         preview: "p", messageCount: 1, fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    private func put(_ index: ConversationIndex, _ id: String, text: String, cwd: String = "/tmp") throws {
        try index.upsert([(lite(id, cwd: cwd),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)],
                           1, text)])
    }

    // MARK: - 手工可验小例：3 条 item，已知检索结果排名的构造
    //
    // - alpha：唯一命中，rank 1（R@1/5/10/20 全中，MRR 贡献 1/1）
    // - bravo：两个候选，标准答案靠重复词频弱于 decoy，rank 2（R@1 miss，R@5/10/20
    //   中，MRR 贡献 1/2）——同 `ContextPriorTests` 的"repeating 次数是 BM25 强弱
    //   唯一变量"手法，不依赖任何 tie-break 顺序。
    // - charlie：查询词库里哪个会话都不含，rank=nil（全 miss，MRR 贡献 0）——顺带
    //   验证"命中列表里根本没有这个 id"与"命中了但排名靠后"两种 nil 成因都归 0。
    //
    // 三条 item 各自落在不同 band（low/mid/high）与不同 source（rareEntity/
    // commitMessage/firstMessage），structuralEvent 一路留空（0 条）——顺带验证
    // N=0 分组不崩、渲染成 N/A 而不是除零。
    private func makeManualExampleIndex() throws -> ConversationIndex {
        let index = try makeIndex()
        try put(index, "alpha-true", text: "AlphaUniqueTerm appears exactly once")
        try put(index, "bravo-decoy", text: Array(repeating: "BravoSharedTerm", count: 4).joined(separator: " "))
        try put(index, "bravo-true", text: "BravoSharedTerm mentioned once")
        try put(index, "charlie-true", text: "completely unrelated filler content")
        return index
    }

    private func manualExampleItems() -> [BenchItem] {
        [
            BenchItem(query: "AlphaUniqueTerm", answerID: "alpha-true", source: .rareEntity, band: .low),
            BenchItem(query: "BravoSharedTerm", answerID: "bravo-true", source: .commitMessage, band: .mid),
            BenchItem(query: "CharlieAbsentTerm", answerID: "charlie-true", source: .firstMessage, band: .high),
        ]
    }

    private func offConfig() -> BenchConfig { BenchConfig(name: "off", expansion: .off) }

    // MARK: - R@k / MRR：整体表

    func testManualExampleOverallRecallAndMRR() throws {
        let index = try makeManualExampleIndex()
        let report = BenchRunner.run(items: manualExampleItems(), index: index, configs: [offConfig()])

        XCTAssertTrue(report.contains("## 整体"), "报告应含整体表\n\(report)")
        // R@1 = 1/3(仅 alpha 命中）≈33.3%；R@5/10/20 = 2/3(alpha+bravo)≈66.7%；
        // MRR = (1/1 + 1/2 + 0)/3 = 0.500。
        XCTAssertTrue(
            report.contains("| off | 3 | 33.3% | 66.7% | 66.7% | 66.7% | 0.500 |"),
            "整体行应精确匹配手工算出的 R@k/MRR\n\(report)")
    }

    /// 变异反证（不落盘为正式测试，评审时手工核验用）：若把 MRR 的 `1/rank` 改成
    /// `1/(rank+1)`，上面这条精确断言会变成 (1/2+1/3+0)/3≈0.278，与 "0.500" 不符，
    /// 这条测试必红——证明这条断言真的钉住了 MRR 公式，不是巧合过关。
    func testManualExampleBandAndSourceTablesAggregateCorrectly() throws {
        let index = try makeManualExampleIndex()
        let report = BenchRunner.run(items: manualExampleItems(), index: index, configs: [offConfig()])

        XCTAssertTrue(report.contains("## 分带"), "报告应含分带表\n\(report)")
        XCTAssertTrue(report.contains("## 分查询来源"), "报告应含分查询来源表\n\(report)")

        // 分带：每带恰好 1 条，指标退化成该条自己的命中/未命中。
        XCTAssertTrue(report.contains("| low | off | 1 | 100.0% | 100.0% | 100.0% | 100.0% | 1.000 |"),
                      "low 带只有 alpha（rank 1）\n\(report)")
        XCTAssertTrue(report.contains("| mid | off | 1 | 0.0% | 100.0% | 100.0% | 100.0% | 0.500 |"),
                      "mid 带只有 bravo（rank 2）\n\(report)")
        XCTAssertTrue(report.contains("| high | off | 1 | 0.0% | 0.0% | 0.0% | 0.0% | 0.000 |"),
                      "high 带只有 charlie（未命中）\n\(report)")

        // 分来源：同上，按来源而非带分组，数字应与分带表一一对应（本例里两种分组
        // 恰好是同一个 item 的不同视角）。
        XCTAssertTrue(report.contains("| rareEntity | off | 1 | 100.0% | 100.0% | 100.0% | 100.0% | 1.000 |"),
                      "rareEntity 来源只有 alpha\n\(report)")
        XCTAssertTrue(report.contains("| commitMessage | off | 1 | 0.0% | 100.0% | 100.0% | 100.0% | 0.500 |"),
                      "commitMessage 来源只有 bravo\n\(report)")
        XCTAssertTrue(report.contains("| firstMessage | off | 1 | 0.0% | 0.0% | 0.0% | 0.0% | 0.000 |"),
                      "firstMessage 来源只有 charlie\n\(report)")
        // structuralEvent 一路在评测集里 0 条：N=0，指标一律 N/A，不做除零运算。
        XCTAssertTrue(report.contains("| structuralEvent | off | 0 | N/A | N/A | N/A | N/A | N/A |"),
                      "0 条的来源应渲染成 N/A 而不是崩溃或除零\n\(report)")
    }

    // MARK: - oracle 标注

    func testAlwaysCtxOracleAnnotationAppears() throws {
        let index = try makeManualExampleIndex()
        let configs = [offConfig(), BenchConfig(name: "always+ctx", expansion: .always,
                                                 contextPath: BenchConfig.answerCwdContext)]
        let report = BenchRunner.run(items: manualExampleItems(), index: index, configs: configs)

        XCTAssertTrue(
            report.contains("commitMessage rows are fair-context; other sources are oracle-context (upper bound)."),
            "always+ctx 表必须原文标注 commitMessage 公平 / 其余三路 oracle 上界\n\(report)")
    }

    // MARK: - "answer-cwd" 哨兵：逐条解析成该 item 答案会话自己的 cwd

    /// 两个会话内容不同（`bravo` 那条手法：repeat 次数是分数差异唯一变量），decoy
    /// 靠更高词频在无 context 时天然排第一、true（标准答案）排第二；true 的 cwd 落在
    /// 一个"仓库"里（只需要 `.git` 存在这个标记，`gitRoot(of:)` 不发子进程，同
    /// `ContextPriorTests.testGitRootWalksUpToDotGit` 的手法），decoy 的 cwd 在仓库外。
    /// `contextPath: .answerCwdContext` 必须逐条解析出**这一条 item 自己**答案会话的
    /// cwd（而不是配置级别写死一个路径），×3 加权后应翻盘到第一。
    func testAnswerCwdContextResolvesPerItemAndFlipsRanking() throws {
        let index = try makeIndex()
        let repo = NSTemporaryDirectory() + "benchrun-ctx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: repo) }

        try put(index, "flip-decoy", text: Array(repeating: "FlipCandidateTerm", count: 4).joined(separator: " "),
                cwd: "/elsewhere/outside-repo")
        try put(index, "flip-true", text: "FlipCandidateTerm mentioned once", cwd: repo)

        let items = [BenchItem(query: "FlipCandidateTerm", answerID: "flip-true", source: .rareEntity, band: .low)]
        let configs = [offConfig(), BenchConfig(name: "always+ctx", expansion: .off,
                                                 contextPath: BenchConfig.answerCwdContext)]
        let report = BenchRunner.run(items: items, index: index, configs: configs)

        XCTAssertTrue(report.contains("| off | 1 | 0.0% | 100.0% | 100.0% | 100.0% | 0.500 |"),
                      "前提：无 context 时 decoy（词频更高）应排第 1，true 排第 2\n\(report)")
        XCTAssertTrue(report.contains("| always+ctx | 1 | 100.0% | 100.0% | 100.0% | 100.0% | 1.000 |"),
                      "answer-cwd 应解析出该 item 答案会话自己的 cwd，×3 加权翻盘到第 1\n\(report)")
    }
}
