import XCTest
@testable import MindBusCore

/// 「你可能忘了的」——用当前对话的特征词去检索历史，只留够久远的。
///
/// 判据来自第一性原理：你会来翻这个库，只有一个根本原因——**你想不起来了**。
/// 记得的东西不需要查。所以
///     价值 = 「你想不起来」× 「你现在需要它」
/// 前者用时间逼近（久远且之后没再提），后者用相关性逼近（与你此刻在看的这场相关）。
final class ForgottenRelatedTests: XCTestCase {

    private func lite(_ id: String, _ title: String, daysAgo: Int, cwd: String = "/w/p") -> ConversationLite {
        let t = Date().addingTimeInterval(-Double(daysAgo) * 86400)
        return ConversationLite(id: id, source: .claudeCode, startAt: t, endAt: t,
                                cwd: cwd, gitBranch: nil, preview: title, messageCount: 10,
                                fileURL: URL(fileURLWithPath: "/f/\(id)"))
    }
    private func seg(_ t: String) -> [Segmenter.Segment] {
        [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: t)]
    }

    /// 相关但久远的会被召回；相关但很近的不算「忘了」，要排除
    func testRecallsOldRelatedAndSkipsRecent() throws {
        let index = try ConversationIndex(path: ":memory:")
        try index.upsert([
            (lite: lite("now", "调度循环怎么做", daysAgo: 0), segments: seg("库存管理 调度策略 出租率怎么算"),
             mtime: 1, entityText: "", userText: "库存管理 调度策略 出租率怎么算", lastRole: "user"),
            (lite: lite("old", "以前的调度工作", daysAgo: 120), segments: seg("库存管理 调度策略 历史结论"),
             mtime: 1, entityText: "", userText: "库存管理 调度策略 历史结论", lastRole: "user"),
            (lite: lite("fresh", "昨天也聊了调度", daysAgo: 2), segments: seg("库存管理 调度策略 昨天"),
             mtime: 1, entityText: "", userText: "库存管理 调度策略 昨天", lastRole: "user"),
            (lite: lite("other", "毫无关系的一场", daysAgo: 200), segments: seg("宠物托运 黑猫投诉"),
             mtime: 1, entityText: "", userText: "宠物托运 黑猫投诉", lastRole: "user"),
        ])
        let out = index.forgottenRelated(to: "now", olderThanDays: 30, limit: 5)
        XCTAssertEqual(out.map(\.id), ["old"],
                       "只要「相关 + 久远」：自己不算、两天前的不算「忘了」、无关的不召回")
    }

    /// 全新话题不该硬凑——召回为空好过召回噪声
    func testBrandNewTopicRecallsNothing() throws {
        let index = try ConversationIndex(path: ":memory:")
        try index.upsert([
            (lite: lite("now", "全新话题", daysAgo: 0), segments: seg("宠物托运 航空箱 检疫证明"),
             mtime: 1, entityText: "", userText: "宠物托运 航空箱 检疫证明", lastRole: "user"),
            (lite: lite("old", "旧的无关话题", daysAgo: 120), segments: seg("库存管理 调度策略"),
             mtime: 1, entityText: "", userText: "库存管理 调度策略", lastRole: "user"),
        ])
        XCTAssertTrue(index.forgottenRelated(to: "now", olderThanDays: 30, limit: 5).isEmpty)
    }

    /// 越久远排越前：同样相关的两场，你更可能忘了老的那场
    func testOlderRanksFirst() throws {
        let index = try ConversationIndex(path: ":memory:")
        try index.upsert([
            (lite: lite("now", "现在", daysAgo: 0), segments: seg("库存管理 调度策略 出租率"),
             mtime: 1, entityText: "", userText: "库存管理 调度策略 出租率", lastRole: "user"),
            (lite: lite("a", "60 天前", daysAgo: 60), segments: seg("库存管理 调度策略 出租率"),
             mtime: 1, entityText: "", userText: "库存管理 调度策略 出租率", lastRole: "user"),
            (lite: lite("b", "300 天前", daysAgo: 300), segments: seg("库存管理 调度策略 出租率"),
             mtime: 1, entityText: "", userText: "库存管理 调度策略 出租率", lastRole: "user"),
        ])
        XCTAssertEqual(index.forgottenRelated(to: "now", olderThanDays: 30, limit: 5).map(\.id), ["b", "a"])
    }
}
