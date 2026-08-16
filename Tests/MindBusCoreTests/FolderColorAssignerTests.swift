import XCTest
@testable import MindBusCore

/// 文件夹颜色分配:活跃集内绝不撞色、哈希原色尽量保住、跨启动确定。
final class FolderColorAssignerTests: XCTestCase {

    /// 核心规则:活跃集(≤8 个)内每个项目一色,绝不重复。
    func testActiveSetNeverCollides() {
        let keys = ["mindbus", "PricingLab", "ResearchKit", "Hotel",
                    "StrategyGame", "TrendRadar", "skill-ux", "Codex"]
        let assigned = FolderColorAssigner.resolve(activeKeysInOrder: keys)
        XCTAssertEqual(assigned.count, 8)
        XCTAssertEqual(Set(assigned.values).count, 8, "活跃集内出现撞色")
    }

    /// 三个活跃项目(用户点名的场景)必不重复——即使它们的裸哈希撞在同一格。
    func testThreeActiveProjectsDistinctEvenWhenHashesCollide() {
        // 构造三个裸哈希同格的键(暴力找:同 poolSize 模的三个字符串)
        var byIndex: [Int: [String]] = [:]
        var i = 0
        while (byIndex.values.map(\.count).max() ?? 0) < 3 {
            let key = "proj-\(i)"
            byIndex[FolderColorAssigner.hashedIndex(key), default: []].append(key)
            i += 1
        }
        let colliding = byIndex.values.first { $0.count >= 3 }!.prefix(3).map { $0 }
        let assigned = FolderColorAssigner.resolve(activeKeysInOrder: colliding)
        XCTAssertEqual(Set(assigned.values).count, 3,
                       "裸哈希全撞的三个活跃项目仍必须三色: \(assigned)")
    }

    /// 尽量保住原色:没撞的项目拿到的就是自己的裸哈希色。
    func testUncontestedKeysKeepTheirHashedColor() {
        // 找 4 个裸哈希互不相同的键
        var picked: [String] = []
        var used = Set<Int>()
        var i = 0
        while picked.count < 4 {
            let key = "stable-\(i)"; i += 1
            let idx = FolderColorAssigner.hashedIndex(key)
            if used.insert(idx).inserted { picked.append(key) }
        }
        let assigned = FolderColorAssigner.resolve(activeKeysInOrder: picked)
        for key in picked {
            XCTAssertEqual(assigned[key], FolderColorAssigner.hashedIndex(key),
                           "无冲突的键被无故挪色——跨日恒色被破坏")
        }
    }

    /// 撞色时:活跃排序靠前者拿原色,靠后者被挪——最活跃的最稳定。
    func testEarlierKeyWinsItsHashedSlot() {
        var byIndex: [Int: [String]] = [:]
        var i = 0
        while (byIndex.values.map(\.count).max() ?? 0) < 2 {
            let key = "pair-\(i)"
            byIndex[FolderColorAssigner.hashedIndex(key), default: []].append(key)
            i += 1
        }
        let pair = byIndex.values.first { $0.count >= 2 }!.prefix(2).map { $0 }
        let assigned = FolderColorAssigner.resolve(activeKeysInOrder: pair)
        XCTAssertEqual(assigned[pair[0]], FolderColorAssigner.hashedIndex(pair[0]),
                       "排序靠前(更活跃)的没拿到自己的原色")
        XCTAssertNotEqual(assigned[pair[1]], assigned[pair[0]])
    }

    /// 确定性:同输入两次分配逐键一致(跨启动稳定的前提)。
    func testResolveIsDeterministic() {
        let keys = (0..<8).map { "det-\($0)" }
        XCTAssertEqual(FolderColorAssigner.resolve(activeKeysInOrder: keys),
                       FolderColorAssigner.resolve(activeKeysInOrder: keys))
    }

    /// 色键语言无关:browser 会话用 source rawValue,不用双语显示名。
    func testColorKeyIsLanguageIndependent() {
        XCTAssertEqual(FolderColorAssigner.colorKey(cwd: "", sourceRawValue: "browser"),
                       "source:browser")
        XCTAssertEqual(FolderColorAssigner.colorKey(cwd: "/Users/dev/mindbus", sourceRawValue: "codex"),
                       "mindbus")
    }

    /// 超过池容量的活跃键:只分配前 8 个,第 9 个起不进 map(走裸哈希回落)。
    func testOverflowKeysAreNotAssigned() {
        let keys = (0..<12).map { "many-\($0)" }
        let assigned = FolderColorAssigner.resolve(activeKeysInOrder: keys)
        XCTAssertEqual(assigned.count, 8)
        XCTAssertNil(assigned["many-8"])
    }
}
