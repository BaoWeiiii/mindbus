import XCTest
@testable import MindBusCore

/// 情境先验（spec §7.61）：P(会话|查询,情境) ∝ P(查询|会话)·P(会话|情境)。
/// cwd 是免费、100% 覆盖的先验——软加权 ×3，绝不过滤（跨项目答案不能丢）。
final class ContextPriorTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "ctxprior-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    private func lite(_ id: String, cwd: String) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(timeIntervalSince1970: 1_000),
                         endAt: Date(timeIntervalSince1970: 2_000), cwd: cwd, gitBranch: nil,
                         preview: "p", messageCount: 1,
                         fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    /// 重复 `repeating` 次「Sparkle」——重复次数是 BM25 强弱的唯一变量（同
    /// `QueryExpansionTests.testOriginalRankingDominatesAfterFusion` 的构造手法）。
    private func put(_ index: ConversationIndex, _ id: String, repeating: Int, cwd: String) throws {
        let text = Array(repeating: "Sparkle", count: repeating).joined(separator: " ")
        try index.upsert([(lite(id, cwd: cwd),
                           [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)],
                           1, text)])
    }

    /// 同 repo 的弱文本命中要能靠先验翻到异 repo 的强文本命中之前。
    /// 两条断言都要有——先证明无先验时 B 赢，再证明先验翻盘。
    func testSameRepoConversationOutranksStrongerForeignHit() throws {
        let index = try makeIndex()
        try put(index, "proj-a", repeating: 1, cwd: "/proj/a")   // 弱命中，同 repo
        try put(index, "proj-b", repeating: 4, cwd: "/proj/b")   // 强命中，异 repo

        let noContext = index.searchWithHits("Sparkle")
        XCTAssertEqual(noContext.map(\.id), ["proj-b", "proj-a"],
                       "前提：无先验时文本命中更强的 proj-b 应排在前面")

        let withContext = index.searchWithHits("Sparkle", contextPath: "/proj/a")
        XCTAssertEqual(withContext.map(\.id), ["proj-a", "proj-b"],
                       "同 repo 的弱命中应靠情境先验翻到异 repo 强命中之前")
    }

    /// 绝不过滤：异 repo 的命中仍然在结果里（位置可以靠后），且结果集合与无先验时
    /// 完全相等——软先验只能重排，不能增删（铁律）。
    func testForeignRepoHitsAreNeverDropped() throws {
        let index = try makeIndex()
        try put(index, "proj-a", repeating: 1, cwd: "/proj/a")
        try put(index, "proj-b", repeating: 4, cwd: "/proj/b")

        let noContext = index.searchWithHits("Sparkle")
        let withContext = index.searchWithHits("Sparkle", contextPath: "/proj/a")

        XCTAssertEqual(Set(withContext.map(\.id)), Set(noContext.map(\.id)),
                       "软先验绝不过滤——有无 context 的结果集合必须相等")
        XCTAssertTrue(withContext.map(\.id).contains("proj-b"), "异 repo 的强命中仍必须在结果里")
    }

    /// 前缀匹配含子目录：会话 cwd=/repo/sub 在 context=/repo 下命中加权。
    func testSubdirectoryCwdGetsPrior() throws {
        let index = try makeIndex()
        try put(index, "sub", repeating: 1, cwd: "/repo/sub")
        try put(index, "foreign", repeating: 4, cwd: "/other")

        let noContext = index.searchWithHits("Sparkle")
        XCTAssertEqual(noContext.first?.id, "foreign", "前提：无先验时 foreign（文本命中更强）应排前面")

        let withContext = index.searchWithHits("Sparkle", contextPath: "/repo")
        XCTAssertEqual(withContext.first?.id, "sub",
                       "会话 cwd=/repo/sub 应在 context=/repo 下靠子目录前缀匹配吃到先验")
    }

    /// 伪前缀不命中：/repo-other 不是 /repo 的子路径（必须按 "/" 边界判）。
    /// 构造上与「同 repo 弱命中翻盘」同款——若 hasPrefix 判定漏了 "/" 边界，
    /// /repo-other 会被误判成 /repo 的子路径而吃到 ×3，把顺序从 foreign-first 翻成
    /// sibling-first，这条测试就会变红（见变异反证）。
    func testSiblingPathWithSharedPrefixIsNotBoosted() throws {
        let index = try makeIndex()
        try put(index, "sibling", repeating: 1, cwd: "/repo-other")
        try put(index, "foreign", repeating: 4, cwd: "/somewhere")

        let noContext = index.searchWithHits("Sparkle")
        let withContext = index.searchWithHits("Sparkle", contextPath: "/repo")
        XCTAssertEqual(withContext.map(\.id), noContext.map(\.id),
                       "/repo-other 只是字符串共享前缀，不是 /repo 的子路径，不该被先验命中")
    }

    /// gitRoot：临时目录造 root/.git/（目录）与 root/sub/deeper/，从 sub 解析回 root；
    /// 另造 worktree 场景（.git 是文件）、无 .git、路径本身不存在三种情况。
    func testGitRootWalksUpToDotGit() throws {
        let fm = FileManager.default

        // .git 是目录，从多层子目录向上找
        let rootName = "gitroot-\(UUID().uuidString)"
        let root = NSTemporaryDirectory() + rootName
        let sub = root + "/sub/deeper"
        try fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(atPath: root) }
        XCTAssertEqual((ConversationIndex.gitRoot(of: sub) as NSString).lastPathComponent, rootName,
                       "应从多层子目录向上找到含 .git 的目录，而不是原样返回子目录")
        XCTAssertEqual(ConversationIndex.gitRoot(of: sub), ConversationIndex.gitRoot(of: root),
                       "从子目录与从根目录本身解析应落到同一个 root")

        // worktree 场景：.git 是文件而非目录
        let wtRootName = "gitroot-wt-\(UUID().uuidString)"
        let wtRoot = NSTemporaryDirectory() + wtRootName
        let wtSub = wtRoot + "/nested"
        try fm.createDirectory(atPath: wtSub, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: wtRoot + "/.git",
                                    contents: Data("gitdir: ../x/.git/worktrees/y\n".utf8)))
        addTeardownBlock { try? fm.removeItem(atPath: wtRoot) }
        XCTAssertEqual((ConversationIndex.gitRoot(of: wtSub) as NSString).lastPathComponent, wtRootName,
                       "worktree 的 .git 是文件而非目录，fileExists 不带 isDirectory 判定也要能识别")

        // 无 .git：标准化后原样返回
        let noGitName = "gitroot-none-\(UUID().uuidString)"
        let noGit = NSTemporaryDirectory() + noGitName
        try fm.createDirectory(atPath: noGit, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(atPath: noGit) }
        XCTAssertEqual((ConversationIndex.gitRoot(of: noGit) as NSString).lastPathComponent, noGitName,
                       "无 .git 时应返回标准化后的原路径")

        // 自查①：路径本身不存在（MCP 模型可能传错）也不能崩，返回标准化后的原值
        let ghost = "/nonexistent-\(UUID().uuidString)/definitely/not/here"
        XCTAssertEqual(ConversationIndex.gitRoot(of: ghost),
                       URL(fileURLWithPath: ghost).standardizedFileURL.path,
                       "不存在的路径不能崩，应返回标准化后的原值")
    }

    /// contextPath 为 nil（或空串/纯空白）时结果与不传完全一致（默认关，无副作用）。
    func testNilContextIsNoOp() throws {
        let index = try makeIndex()
        try put(index, "proj-a", repeating: 1, cwd: "/proj/a")
        try put(index, "proj-b", repeating: 4, cwd: "/proj/b")

        let bare = index.searchWithHits("Sparkle")
        let explicitNil = index.searchWithHits("Sparkle", contextPath: nil)
        let blank = index.searchWithHits("Sparkle", contextPath: "   ")

        for variant in [explicitNil, blank] {
            XCTAssertEqual(variant.map(\.id), bare.map(\.id))
            XCTAssertEqual(variant.map(\.segmentHitCount), bare.map(\.segmentHitCount))
            XCTAssertEqual(variant.map(\.bestSegmentFirstMessageIndex), bare.map(\.bestSegmentFirstMessageIndex))
        }
    }

    /// 短查询（<3 字走 LIKE 兜底路）+ contextPath 的组合：加权照样生效、集合照样不变。
    /// 真机验收实证过这条组合（查「归档」2 字 + mindbus 路径，top 翻转、26=26），
    /// 这里补自动化守卫——LIKE 路的分数是合成的单调占位，乘 ×3 后的重排也要稳定。
    func testShortQueryLikePathWithContext() throws {
        let index = try makeIndex()
        let root = NSTemporaryDirectory() + "ctx-like-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/.git", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        // 两条都含两字词「接力」；foreign 的 id 字典序更小（LIKE 路按 id 排，无 context 时它在前）
        func putText(_ id: String, cwd: String, text: String) throws {
            try index.upsert([(lite(id, cwd: cwd),
                               [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)],
                               1, text)])
        }
        try putText("a-foreign", cwd: "/elsewhere", text: "接力功能的另一处讨论")
        try putText("b-same", cwd: root, text: "接力窗口的设计")

        let plain = index.searchWithHits("接力", expansion: .off).map(\.id)
        let boosted = index.searchWithHits("接力", expansion: .off, contextPath: root).map(\.id)
        XCTAssertEqual(plain.first, "a-foreign", "前提：无 context 时 LIKE 按 id 排，foreign 在前")
        XCTAssertEqual(boosted.first, "b-same", "同仓会话该被 ×3 翻到前面")
        XCTAssertEqual(Set(plain), Set(boosted), "绝不过滤：集合必须相等")
    }
}
