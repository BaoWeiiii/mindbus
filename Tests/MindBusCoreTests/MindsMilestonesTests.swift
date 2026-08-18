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

    /// 中文用例用的认可词。真实运行时这张表是 `learnApprovals` 学出来的，
    /// 用例里直接给，是为了把「学」和「用」两件事分开测。
    private let zhApprovals: Set<String> = ["继续", "确认", "好"]

    private var report: String {
        "风声扩展 P1 落地完毕(0a1b2c3)：表 + 闸门 + 真实种子全链路跑通，准入判据实弹检验通过。"
            + String(repeating: "后面还有很多细节交代，逐条列出改动与验证方式。", count: 8)
    }

    // MARK: - 认可词

    func testApprovalMustBeTheWholeMessage() {
        let a: Set<String> = ["继续", "确认", "ok"]
        XCTAssertTrue(MindsMilestones.isApproval("继续", approvals: a))
        XCTAssertTrue(MindsMilestones.isApproval("继续。", approvals: a))
        XCTAssertTrue(MindsMilestones.isApproval(" 确认 ", approvals: a))
        XCTAssertTrue(MindsMilestones.isApproval("OK", approvals: a), "大小写不敏感")
    }

    /// 「继续，另外把 X 改一下」是新指令不是认可。
    /// 放进来的话里程碑会被普通对话稀释。
    func testApprovalRejectsMessagesCarryingNewInstructions() {
        for t in ["继续，另外把标题改一下", "好的，那我们先做第二步", "可以，但是要注意性能"] {
            XCTAssertFalse(MindsMilestones.isApproval(t, approvals: zhApprovals), t)
        }
    }

    func testApprovalRejectsOrdinaryMessages() {
        XCTAssertFalse(MindsMilestones.isApproval("这个方案不行", approvals: zhApprovals))
        XCTAssertFalse(MindsMilestones.isApproval("", approvals: zhApprovals))
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
        let out = MindsMilestones.extract(messages: ms, approvals: zhApprovals, text: plain)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].headline.hasPrefix("风声扩展 P1 落地完毕"), out[0].headline)
        XCTAssertEqual(out[0].approval, "继续")
    }

    /// 认可的是**最近一条够长的**汇报，中间夹着的短应答不该顶替它
    func testExtractSkipsShortChatterAndFindsTheRealReport() {
        let ms = [msg(.assistant, report, minute: 0),
                  msg(.assistant, "好的。", minute: 1),
                  msg(.user, "继续", minute: 2)]
        let out = MindsMilestones.extract(messages: ms, approvals: zhApprovals, text: plain)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].headline.hasPrefix("风声扩展 P1"), out[0].headline)
    }

    /// 没有够长的汇报就不产出——闲聊里的「继续」不是里程碑
    func testNoMilestoneWithoutASubstantialReport() {
        let ms = [msg(.assistant, "好的，我看看。", minute: 0),
                  msg(.user, "继续", minute: 1)]
        XCTAssertTrue(MindsMilestones.extract(messages: ms, approvals: zhApprovals, text: plain).isEmpty)
    }

    func testMultipleMilestonesKeepChronology() {
        let second = "第二阶段完成：全部切上新链路，96/96 测绿。"
            + String(repeating: "详细改动逐条说明，含验证方式与回滚预案。", count: 8)
        let ms = [msg(.assistant, report, minute: 0),
                  msg(.user, "继续", minute: 1),
                  msg(.assistant, second, minute: 2),
                  msg(.user, "确认", minute: 3)]
        let out = MindsMilestones.extract(messages: ms, approvals: zhApprovals, text: plain)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].at < out[1].at)
        XCTAssertEqual(out[1].approval, "确认")
    }

    /// AI 自己说「完成了」不算——必须有用户点头
    func testUnapprovedReportIsNotAMilestone() {
        let ms = [msg(.assistant, report, minute: 0),
                  msg(.user, "这里还有个问题，你再看看", minute: 1)]
        XCTAssertTrue(MindsMilestones.extract(messages: ms, approvals: zhApprovals, text: plain).isEmpty)
    }
}

// MARK: - 你拍板的时刻

extension MindsMilestonesTests {

    private func solicitation(_ body: String) -> String {
        "关于这块我给两个方案。方案 A：" + body
            + String(repeating: "各自的代价与收益逐条摊开说明，便于你判断。", count: 8)
            + "\n\n方案 B：另一条路线，改动更小但天花板也更低。你倾向哪一种？"
    }

    func testDecisionCapturesTheAnswerToASolicitation() {
        let ms = [msg(.assistant, solicitation("推倒重来"), minute: 0),
                  msg(.user, "所有事情都要在今年 12 月做完。", minute: 1)]
        let out = MindsMilestones.extractDecisions(messages: ms, text: plain)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].statement, "所有事情都要在今年 12 月做完。")
    }

    /// 追问不是拍板。判据只看问号——不列疑问词表，因为那是语言相关的。
    func testDecisionRejectsQuestions() {
        for q in ["测试和验收呢？按传统流程还漏了什么",
                  "什么是语义地图渲染管线？太抽象了",
                  "Which one should we pick?"] {
            let ms = [msg(.assistant, solicitation("推倒重来"), minute: 0),
                      msg(.user, q, minute: 1)]
            XCTAssertTrue(MindsMilestones.extractDecisions(messages: ms, text: plain).isEmpty, q)
        }
    }

    /// 已知代价，记在这里免得以后被当成 bug 重新「修」成词表：
    /// 不带问号的疑问句会漏网。用疑问词表能补上，但那张表是语言相关的
    /// （中文「什么/为什么」、英文 what/why），会把整套判据绑死在一种语言上。
    /// 宁可漏一条。
    func testUnpunctuatedQuestionsAreAKnownMiss() {
        let ms = [msg(.assistant, solicitation("推倒重来"), minute: 0),
                  msg(.user, "什么是语义地图渲染管线", minute: 1)]
        XCTAssertEqual(MindsMilestones.extractDecisions(messages: ms, text: plain).count, 1,
                       "没有问号就判不出是疑问句——这是通用性换来的代价")
    }

    /// 没有征询就没有决策点——AI 只是在汇报时，用户说什么都不算「拍板」
    func testDecisionNeedsASolicitationFirst() {
        let ms = [msg(.assistant, report, minute: 0),
                  msg(.user, "前后端分离", minute: 1)]
        XCTAssertTrue(MindsMilestones.extractDecisions(messages: ms, text: plain).isEmpty)
    }

    /// 「要么…要么…」是同一个语用形态，只是写不成固定串
    /// 征询 = 够长 + 以问号收尾。判据是书写符号，不是某种语言的模式表。
    func testSolicitationIsQuestionMarkNotAPatternList() {
        let long = String(repeating: "两条路线的代价与收益逐条摊开。", count: 12)
        XCTAssertTrue(MindsMilestones.isSolicitation(long + "你倾向哪一种？"))
        XCTAssertTrue(MindsMilestones.isSolicitation(
            String(repeating: "Both routes have real trade-offs to weigh. ", count: 8)
                + "Which one do you want?"), "英文同样成立")
        XCTAssertFalse(MindsMilestones.isSolicitation(long + "我先按 A 做了。"),
                       "陈述句不是征询")
        XCTAssertFalse(MindsMilestones.isSolicitation("要哪个？"), "太短不算一次征询")
    }

    /// 隔太远的回应不算对这次征询的回答
    func testDecisionIgnoresFarAwayReplies() {
        let ms = [msg(.assistant, solicitation("推倒重来"), minute: 0),
                  msg(.assistant, "补充一点背景。", minute: 1),
                  msg(.assistant, "再补充一点。", minute: 2),
                  msg(.user, "前后端分离", minute: 3)]
        XCTAssertTrue(MindsMilestones.extractDecisions(messages: ms, text: plain).isEmpty)
    }

    /// 太长的回应是在展开新需求，不是一句拍板
    func testDecisionRejectsOverlongReplies() {
        let long = String(repeating: "这里还有一大段新的需求要展开说明。", count: 12)
        let ms = [msg(.assistant, solicitation("推倒重来"), minute: 0),
                  msg(.user, long, minute: 1)]
        XCTAssertTrue(MindsMilestones.extractDecisions(messages: ms, text: plain).isEmpty)
    }
}
