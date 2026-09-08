import XCTest
@testable import MindBusCore

/// 长对话的目录。
///
/// 夹具规模照着真机来：最长的一场 5495 条消息 / 184 个里程碑 / 24 个时间断点。
final class ConversationOutlineTests: XCTestCase {

    private func msg(_ role: MessageRole, _ text: String, min: Int) -> Message {
        Message(id: "m\(min)", role: role,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(min) * 60),
                blocks: [.text(text)])
    }

    /// 三种节点按消息顺序交织，不是三段拼接
    func testNodesAreOrderedByPosition() {
        let msgs = [
            msg(.assistant, "第一块做完了", min: 0),
            msg(.user, "继续", min: 1),
            msg(.assistant, "两条路，你选哪个？", min: 2),
            msg(.user, "走第二条，先接界面", min: 3),
            msg(.assistant, "好的", min: 400),          // 隔了 ~6.6 小时
        ]
        let out = ConversationOutline.build(
            messages: msgs,
            milestones: [(messageID: "m0", text: "第一块做完了")],
            decisions: [(messageID: "m3", text: "走第二条，先接界面")])
        XCTAssertEqual(out.map(\.kind), [.milestone, .decision, .gap])
        XCTAssertEqual(out.map(\.messageID), ["m0", "m3", "m400"])
        XCTAssertEqual(out[2].text, "", "断点没有标题，文案由界面按间隔长短决定")
    }

    /// 断点指向「恢复之后的第一条」——你要看的是回来以后说了什么
    func testGapPointsAtTheMessageAfterTheBreak() {
        let msgs = [msg(.user, "先到这", min: 0), msg(.assistant, "好", min: 600)]
        let out = ConversationOutline.build(messages: msgs, milestones: [], decisions: [])
        XCTAssertEqual(out.map(\.messageID), ["m600"])
        XCTAssertEqual(out.first?.gap ?? 0, 600 * 60, accuracy: 1)
    }

    /// 同一条消息既是里程碑又落在断点后，只出一个节点——有内容的那种优先
    func testContentNodeWinsOverGapOnSameMessage() {
        let msgs = [msg(.user, "先到这", min: 0), msg(.assistant, "这一块做完了", min: 600)]
        let out = ConversationOutline.build(
            messages: msgs,
            milestones: [(messageID: "m600", text: "这一块做完了")], decisions: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .milestone)
    }

    /// 节点太少不成目录：一两个节点还不如没有，界面据此决定显不显示
    func testTooFewNodesIsNotAnOutline() {
        let msgs = [msg(.assistant, "做完了", min: 0), msg(.user, "继续", min: 1)]
        let out = ConversationOutline.build(
            messages: msgs, milestones: [(messageID: "m0", text: "做完了")], decisions: [])
        XCTAssertFalse(ConversationOutline.isWorthShowing(out))
    }

    /// 间隔阈值以下的不算断点——正常一问一答的停顿不是章节
    func testShortPausesAreNotGaps() {
        let msgs = (0..<8).map { msg($0 % 2 == 0 ? .user : .assistant, "聊", min: $0 * 20) }
        XCTAssertTrue(ConversationOutline.build(messages: msgs, milestones: [], decisions: []).isEmpty)
    }
}
