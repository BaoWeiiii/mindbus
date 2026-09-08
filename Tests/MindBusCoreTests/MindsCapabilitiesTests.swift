import XCTest
@testable import MindBusCore

/// 能力阶梯：对「保证对所有人有价值」的工程兑现。
///
/// 十一条被否掉的信号 + 各层覆盖率共同证明：**单一信号不可能通用**——
/// 每个信号都依赖某种前提（跨项目/库龄/语言/交互习惯）。所以保证只能这样给：
///
///     保证 = 底座（无条件成立）+ 阶梯（每层声明前提，满足即点亮）
///
/// 底座是保管与找回：第 1 场对话起就成立。阶梯必须满足四条性质，
/// 缺一条「保证」就是空话——本文件逐条测它们。
final class MindsCapabilitiesTests: XCTestCase {

    private func pending(convs: Int, projects: Int, days: Int, longest: Int)
        -> [MindsBuilder.PendingCapability] {
        MindsBuilder.pendingCapabilities(conversations: convs, projects: projects,
                                         daySpanDays: days, longestConversation: longest)
    }

    /// ① 底座零前提：空库时四层全都待解锁，但**没有任何一层叫「保管/检索」**
    /// ——那两样不进阶梯，因为它们不需要解锁。
    func testDayZeroHasAllPendingButFloorNeedsNothing() {
        let p = pending(convs: 0, projects: 0, days: 0, longest: 0)
        XCTAssertEqual(p.count, MindsBuilder.PendingCapability.allKinds.count,
                       "空库时每一层都该出现在待解锁清单里")
    }

    /// ② 单调：库只增不减时，已解锁的层永不回到待解锁
    func testUnlocksAreMonotonic() {
        let small = pending(convs: 5, projects: 1, days: 3, longest: 40)
        let mid = pending(convs: 35, projects: 3, days: 45, longest: 250)
        let big = pending(convs: 200, projects: 9, days: 120, longest: 7000)
        func kinds(_ xs: [MindsBuilder.PendingCapability]) -> Set<String> {
            Set(xs.map(\.kind))
        }
        XCTAssertTrue(kinds(mid).isSubset(of: kinds(small)))
        XCTAssertTrue(kinds(big).isSubset(of: kinds(mid)))
        XCTAssertTrue(big.isEmpty, "全条件满足时清单必须为空——卡片随之隐藏")
    }

    /// ③ 数字可行动：每条待解锁都带「现在几 / 需要几」，且需要 > 现在
    func testPendingCarriesActionableNumbers() {
        for c in pending(convs: 10, projects: 1, days: 10, longest: 50) {
            XCTAssertGreaterThan(c.needed, c.now, "\(c)")
        }
    }

    /// ④ 阈值与实现同源：阶梯引用的常量必须就是各层真实的门槛，
    /// 不许在这里另抄一份数字（抄的那份必然漂移）
    func testThresholdsComeFromTheRealConstants() {
        let p = pending(convs: MindsBuilder.contagionMinConversations - 1,
                        projects: 2, days: 100, longest: 500)
        XCTAssertTrue(p.contains { $0.kind == "contagion" },
                      "差 1 场就该还在待解锁里")
        let p2 = pending(convs: MindsBuilder.contagionMinConversations,
                         projects: 2, days: 100, longest: 500)
        XCTAssertFalse(p2.contains { $0.kind == "contagion" })
    }
}
