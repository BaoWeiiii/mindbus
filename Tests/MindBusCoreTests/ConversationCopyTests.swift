import XCTest
@testable import MindBusCore

final class ConversationCopyTests: XCTestCase {
    private func conv(_ messages: [Message], cwd: String = "/Users/me/dev/proj",
                      source: ConversationSource = .claudeCode) -> Conversation {
        Conversation(id: "c", source: source, startAt: Date(), endAt: Date(),
                     cwd: cwd, gitBranch: nil, messages: messages)
    }
    private func msg(_ role: MessageRole, _ text: String) -> Message {
        Message(id: UUID().uuidString, role: role, timestamp: Date(), blocks: [.text(text)])
    }

    func testHandoffStripsCodeBlocks() {
        let c = conv([msg(.user, "改这个"),
                      msg(.assistant, "好的\n```swift\nlet x = 1\n```\n完成")])
        let out = ConversationCopy.render(c, prefs: CopyPreferences())   // 默认接力
        XCTAssertTrue(out.contains("[代码已省略"))
        XCTAssertFalse(out.contains("let x = 1"))
        XCTAssertTrue(out.contains("改这个"))
        XCTAssertTrue(out.contains("完成"))
    }

    func testFullScopeKeepsCode() {
        let c = conv([msg(.assistant, "```\ncode_here\n```")])
        var p = CopyPreferences(); p.stripCode = false; p.includeHeader = false
        XCTAssertTrue(ConversationCopy.render(c, prefs: p).contains("code_here"))
    }

    func testUserOnlyScopeDropsAssistant() {
        let c = conv([msg(.user, "U1"), msg(.assistant, "A1"), msg(.user, "U2")])
        var p = CopyPreferences(); p.scope = .userOnly; p.includeHeader = false
        let out = ConversationCopy.render(c, prefs: p)
        XCTAssertTrue(out.contains("U1") && out.contains("U2"))
        XCTAssertFalse(out.contains("A1"))
    }

    func testOnlyMessageIdsFiltersAndOverridesScopePrefs() {
        let m1 = Message(id: "m1", role: .user, timestamp: Date(), blocks: [.text("U1")])
        let m2 = Message(id: "m2", role: .assistant, timestamp: Date(), blocks: [.text("A1")])
        let m3 = Message(id: "m3", role: .user, timestamp: Date(), blocks: [.text("U2")])
        let c = conv([m1, m2, m3])
        // prefs.scope = userOnly 本会滤掉 assistant——但手选覆盖 scope：点了 m2 就必须有 m2
        var p = CopyPreferences(); p.scope = .userOnly; p.includeHeader = false
        let out = ConversationCopy.render(c, prefs: p, onlyMessageIds: ["m2", "m3"])
        XCTAssertFalse(out.contains("U1"))
        XCTAssertTrue(out.contains("A1"))
        XCTAssertTrue(out.contains("U2"))
    }

    func testRecentScopeKeepsLastN() {
        let c = conv([msg(.user, "old"), msg(.assistant, "mid"), msg(.user, "new")])
        var p = CopyPreferences(); p.scope = .recent; p.recentTurns = 1; p.includeHeader = false
        let out = ConversationCopy.render(c, prefs: p)
        XCTAssertTrue(out.contains("new"))
        XCTAssertFalse(out.contains("old"))
    }

    func testHeaderMentionsProjectAndFiles() {
        let out = ConversationCopy.render(conv([msg(.user, "x")]), prefs: CopyPreferences())
        XCTAssertTrue(out.contains("proj"))   // cwd 末段项目名
        XCTAssertTrue(out.contains("文件"))    // "当前文件你可以直接读取"
    }

    func testHeaderIncludesFullCwdPath() {
        // 能读文件的 agent（CC/Cursor/Codex）需要完整根路径才能深挖，仅末段不够。
        let out = ConversationCopy.render(conv([msg(.user, "x")], cwd: "/Users/me/dev/proj"),
                                          prefs: CopyPreferences())
        XCTAssertTrue(out.contains("/Users/me/dev/proj"))
    }

    func testHeaderWithoutCwdOmitsPathLine() {
        // 无 cwd（如浏览器来源）时不输出裸路径行，正文照常。
        let out = ConversationCopy.render(conv([msg(.user, "x")], cwd: ""),
                                          prefs: CopyPreferences())
        XCTAssertFalse(out.contains("项目根目录"))
        XCTAssertTrue(out.contains("x"))
    }

    func testHeaderPathStripsTrailingSlash() {
        let out = ConversationCopy.render(conv([msg(.user, "x")], cwd: "/Users/me/dev/proj/"),
                                          prefs: CopyPreferences())
        XCTAssertTrue(out.contains("/Users/me/dev/proj"))
        XCTAssertFalse(out.contains("proj/（"))   // 路径行里不应残留尾斜杠
    }

    // MARK: - 接力噪音过滤：只留对话价值，丢工具输出/思考/独立代码

    func testHandoffDropsToolResultKeepsConclusion() {
        let m = Message(id: "1", role: .assistant, timestamp: Date(),
                        blocks: [.text("测试失败了，原因是空指针"),
                                 .toolResult(text: "BUILD_LOG_9000_LINES")])
        var p = CopyPreferences(); p.includeHeader = false
        let out = ConversationCopy.render(conv([m]), prefs: p)
        XCTAssertTrue(out.contains("测试失败了"))            // 对话里的结论留下
        XCTAssertFalse(out.contains("BUILD_LOG_9000_LINES")) // 原始工具输出丢弃
    }

    func testHandoffDropsThinkingAndToolUse() {
        let m = Message(id: "1", role: .assistant, timestamp: Date(),
                        blocks: [.thinking("内部推理SECRET"),
                                 .toolUse(name: "Bash", input: "rm -rf CMD"),
                                 .text("我清理了临时文件")])
        var p = CopyPreferences(); p.includeHeader = false
        let out = ConversationCopy.render(conv([m]), prefs: p)
        XCTAssertTrue(out.contains("我清理了临时文件"))
        XCTAssertFalse(out.contains("内部推理SECRET"))
        XCTAssertFalse(out.contains("rm -rf CMD"))
        XCTAssertFalse(out.contains("[thinking]"))
        XCTAssertFalse(out.contains("[tool:"))
    }

    func testHandoffDropsStandaloneCodeBlockWhenStripCode() {
        let m = Message(id: "1", role: .assistant, timestamp: Date(),
                        blocks: [.text("改好了"),
                                 .code(language: "swift", text: "STANDALONE_CODE_X")])
        let out = ConversationCopy.render(conv([m]), prefs: CopyPreferences())  // stripCode 默认 true
        XCTAssertTrue(out.contains("改好了"))
        XCTAssertFalse(out.contains("STANDALONE_CODE_X"))
    }

    func testHandoffKeepsStandaloneCodeWhenStripCodeOff() {
        let m = Message(id: "1", role: .assistant, timestamp: Date(),
                        blocks: [.code(language: "swift", text: "KEEP_THIS_CODE_Y")])
        var p = CopyPreferences(); p.stripCode = false; p.includeHeader = false
        let out = ConversationCopy.render(conv([m]), prefs: p)
        XCTAssertTrue(out.contains("KEEP_THIS_CODE_Y"))
    }

    func testTokenEstimatePositive() {
        XCTAssertGreaterThan(ConversationCopy.estimateTokens("你好世界 hello world"), 0)
    }
}
