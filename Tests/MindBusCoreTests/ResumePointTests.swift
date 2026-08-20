import XCTest
@testable import MindBusCore

/// 「接着上次」——挖掘体系的全覆盖底层。
///
/// 十一条否定证明内容信号都有前提;这一层只用**结构不变量**:任何一场对话
/// 构造上必有「停在哪」(最后一句)和「何时」(时间戳)。因此整个体系成为
/// 全函数——这里测的就是那条定理:**对任何 ≥1 场对话的库,挖掘非空**。
final class ResumePointTests: XCTestCase {

    private func put(_ index: ConversationIndex, id: String, cwd: String, text: String,
                     minutesAgo: Int, lastRole: String = "assistant",
                     openQuestion: String? = nil) throws {
        let t = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        let lite = ConversationLite(id: id, source: .claudeCode, startAt: t, endAt: t,
                                    cwd: cwd, gitBranch: nil, preview: text, messageCount: 4,
                                    fileURL: URL(fileURLWithPath: "/f/\(id)"))
        var h = MindsMilestones.Harvest()
        h.openQuestion = openQuestion
        try index.upsert([(lite: lite,
                           segments: [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)],
                           mtime: 1, entityText: "", userText: text, lastRole: lastRole, harvest: h)])
    }

    /// 定理主体:一场对话就够——不挑语言、不挑习惯、不需要问号
    func testSingleConversationAnyLanguageYieldsResume() throws {
        let zh = try ConversationIndex(path: ":memory:")
        try put(zh, id: "c1", cwd: "/w/p", text: "先到这里,明天继续", minutesAgo: 60)
        XCTAssertNotNil(zh.latestThread(), "1 场中文对话必须有接续点")

        let en = try ConversationIndex(path: ":memory:")
        try put(en, id: "c1", cwd: "/w/p", text: "stopped after the schema change", minutesAgo: 60)
        let r = en.latestThread()
        XCTAssertEqual(r?.preview, "stopped after the schema change",
                       "「停在哪」= 最后一句,构造上必然存在")
    }

    /// 空库是唯一的例外——那时没有任何东西可挖,返回 nil 而不是编造
    func testEmptyLibraryIsTheOnlyExemption() throws {
        XCTAssertNil(try ConversationIndex(path: ":memory:").latestThread())
    }

    /// 取的是最近的那场;悬着的问题一并带出——那是「它在等你什么」
    func testPicksLatestAndCarriesOpenQuestion() throws {
        let index = try ConversationIndex(path: ":memory:")
        try put(index, id: "old", cwd: "/w/a", text: "旧的", minutesAgo: 600)
        try put(index, id: "new", cwd: "/w/b", text: "改完了,要我提交吗?",
                minutesAgo: 30, openQuestion: "要我提交吗?")
        let r = index.latestThread()
        XCTAssertEqual(r?.id, "new")
        XCTAssertEqual(r?.openQuestion, "要我提交吗?")
    }
}
