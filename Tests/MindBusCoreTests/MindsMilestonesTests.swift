import XCTest
@testable import MindBusCore

/// 「你点头的时刻」：用户的短反馈是标注，AI 的汇报是内容。
///
/// 夹具用真机实测到的形态（2026-08-18，150 场 / 3240 条 user 消息 /
/// 271 处认可信号），不是我编的句子。
final class MindsMilestonesTests: XCTestCase {

    private func msg(_ role: MessageRole, _ text: String, minute: Int = 0) -> Message {
        Message(id: UUID().uuidString, role: role,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60),
                blocks: [.text(text)])
    }

    private func plain(_ m: Message) -> String { m.firstTextBlock ?? "" }

    private var report: String {
        "风声扩展 P1 落地完毕(0a1b2c3)：表 + 闸门 + 真实种子全链路跑通，准入判据实弹检验通过。"
            + String(repeating: "后面还有很多细节交代，逐条列出改动与验证方式。", count: 8)
    }

    // MARK: - 认可词

    func testApprovalMustBeTheWholeMessage() {
        XCTAssertTrue(MindsMilestones.isApproval("继续"))
        XCTAssertTrue(MindsMilestones.isApproval("继续。"))
        XCTAssertTrue(MindsMilestones.isApproval(" 确认 "))
        XCTAssertTrue(MindsMilestones.isApproval("OK"), "大小写不敏感")
    }

    /// 「继续，另外把 X 改一下」是新指令不是认可。
    /// 放进来的话里程碑会被普通对话稀释。
    func testApprovalRejectsMessagesCarryingNewInstructions() {
        XCTAssertFalse(MindsMilestones.isApproval("继续，另外把标题改一下"))
        XCTAssertFalse(MindsMilestones.isApproval("好的，那我们先做第二步"))
        XCTAssertFalse(MindsMilestones.isApproval("可以，但是要注意性能"))
    }

    func testApprovalRejectsOrdinaryMessages() {
        XCTAssertFalse(MindsMilestones.isApproval("这个方案不行"))
        XCTAssertFalse(MindsMilestones.isApproval(""))
    }

    // MARK: - 首句

    func testHeadlineStripsMarkdownAndCutsAtSentenceEnd() {
        let h = MindsMilestones.headline(of: "## **思脉底座开发完成、合并、已推送两仓**\n\n细节如下：\n- 一\n- 二")
        XCTAssertEqual(h, "思脉底座开发完成、合并、已推送两仓")
    }

    func testHeadlineSkipsTooShortLeadingLines() {
        let h = MindsMilestones.headline(of: "好\n\n砍完推送(1b2c3d4)，净删 573 行，801 测试全绿，已装机")
        XCTAssertEqual(h, "砍完推送(1b2c3d4)，净删 573 行，801 测试全绿，已装机")
    }

    func testHeadlineIsNilWhenNothingSubstantial() {
        XCTAssertNil(MindsMilestones.headline(of: "好\n嗯\n#"))
    }

    // MARK: - 抽取

    func testExtractsHeadlineOfTheApprovedReport() {
        let ms = [msg(.user, "接着做", minute: 0),
                  msg(.assistant, report, minute: 1),
                  msg(.user, "继续", minute: 2)]
        let out = MindsMilestones.extract(messages: ms, text: plain)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].headline.hasPrefix("风声扩展 P1 落地完毕"), out[0].headline)
        XCTAssertEqual(out[0].approval, "继续")
    }

    /// 认可的是**最近一条够长的**汇报，中间夹着的短应答不该顶替它
    func testExtractSkipsShortChatterAndFindsTheRealReport() {
        let ms = [msg(.assistant, report, minute: 0),
                  msg(.assistant, "好的。", minute: 1),
                  msg(.user, "继续", minute: 2)]
        let out = MindsMilestones.extract(messages: ms, text: plain)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].headline.hasPrefix("风声扩展 P1"), out[0].headline)
    }

    /// 没有够长的汇报就不产出——闲聊里的「继续」不是里程碑
    func testNoMilestoneWithoutASubstantialReport() {
        let ms = [msg(.assistant, "好的，我看看。", minute: 0),
                  msg(.user, "继续", minute: 1)]
        XCTAssertTrue(MindsMilestones.extract(messages: ms, text: plain).isEmpty)
    }

    func testMultipleMilestonesKeepChronology() {
        let second = "第二阶段完成：全部切上新链路，96/96 测绿。"
            + String(repeating: "详细改动逐条说明，含验证方式与回滚预案。", count: 8)
        let ms = [msg(.assistant, report, minute: 0),
                  msg(.user, "继续", minute: 1),
                  msg(.assistant, second, minute: 2),
                  msg(.user, "确认", minute: 3)]
        let out = MindsMilestones.extract(messages: ms, text: plain)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].at < out[1].at)
        XCTAssertEqual(out[1].approval, "确认")
    }

    /// AI 自己说「完成了」不算——必须有用户点头
    func testUnapprovedReportIsNotAMilestone() {
        let ms = [msg(.assistant, report, minute: 0),
                  msg(.user, "这里还有个问题，你再看看", minute: 1)]
        XCTAssertTrue(MindsMilestones.extract(messages: ms, text: plain).isEmpty)
    }
}
