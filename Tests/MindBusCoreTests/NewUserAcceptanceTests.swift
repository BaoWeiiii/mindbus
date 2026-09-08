import XCTest
@testable import MindBusCore

/// 新用户验收:从第一性原理,把「装上 MindBus 的第一周」拆成一条条承诺,
/// 每条承诺一个测试,全部走**真实管线**(JSONL 文件 → loader → 索引 → Minds md
/// → viz 查询),不用手喂结构体冒充。
///
/// 承诺清单:
///   A. 空库不编造          —— 没有数据时说没有,不谎报
///   B. 第 1 场对话就有价值  —— 接着上次 + 搜索,构造上保证
///   C. 英文用户同等待遇     —— 全链路不是中文特供
///   D. 阈值一到层就点亮     —— 阶梯的数字是真的
///   E. 注入不冒充你的话     —— 客户端塞的东西进不了你的画像
///   F. 计数诚实            —— md 里标称的 N 就是实际的 N
@MainActor
final class NewUserAcceptanceTests: XCTestCase {

    private var dir: URL!
    private var index: ConversationIndex!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = try XCTUnwrap(ConversationIndex(
            path: dir.appendingPathComponent("index.sqlite").path))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 夹具:写真实的 Claude Code JSONL

    /// 时间戳必须是**近期**的:写死一个古老日期的话,OPEN LOOPS 的 90 天窗口
    /// 会把悬着的事滤掉——验收用例第一轮就栽在这上面,和真实数据不符的
    /// 夹具连验收都骗。
    private func claudeLine(uuid: String, role: String, content: String, session: String,
                            cwd: String, minute: Int) -> String {
        let body = role == "user" ? "\"\(content)\"" : "[{\"type\":\"text\",\"text\":\"\(content)\"}]"
        let f = ISO8601DateFormatter()
        let ts = f.string(from: Date().addingTimeInterval(Double(minute) * 60 - 86_400))
        return "{\"type\":\"\(role)\",\"uuid\":\"\(uuid)\",\"cwd\":\"\(cwd)\",\"sessionId\":\"\(session)\",\"message\":{\"role\":\"\(role)\",\"content\":\(body)},\"timestamp\":\"\(ts)\"}"
    }

    @discardableResult
    private func writeConversation(name: String, session: String, cwd: String,
                                   turns: [(role: String, text: String)],
                                   startMinute: Int = 0) throws -> URL {
        let url = dir.appendingPathComponent("\(name).jsonl")
        try turns.enumerated().map { i, t in
            claudeLine(uuid: "\(session)-\(i)", role: t.role, content: t.text,
                       session: session, cwd: cwd, minute: startMinute + i)
        }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func scan(_ urls: [URL]) {
        LoaderRuntime.indexRows(urls: urls, into: index, source: .claudeCode,
                                makeRow: ClaudeCodeLoader.indexRow)
    }

    private func buildMinds() throws -> String {
        let mdURL = dir.appendingPathComponent("minds.md")
        MindsBuilder.build(from: index, to: mdURL)
        return try String(contentsOf: mdURL, encoding: .utf8)
    }

    // MARK: - A. 空库不编造

    func testA_EmptyLibraryFabricatesNothing() throws {
        XCTAssertNil(index.latestThread(), "A1 空库没有「接着上次」——不编造")
        let s = index.libraryStats()
        let pending = MindsBuilder.pendingCapabilities(
            conversations: s.conversations, projects: s.projects,
            daySpanDays: s.daySpanDays, longestConversation: s.longestConversation)
        XCTAssertEqual(pending.count, MindsBuilder.PendingCapability.allKinds.count,
                       "A2 阶梯如实列出全部待解锁")
        XCTAssertTrue(pending.allSatisfy { $0.now == 0 }, "A3 现状数字如实为 0")
        let md = try buildMinds()
        XCTAssertFalse(md.isEmpty, "A4 空库的 minds.md 也能生成,不崩")
        XCTAssertTrue(md.contains("(none yet)"), "A5 空节诚实说 (none yet)")
    }

    // MARK: - B. 第 1 场对话就有价值

    func testB_FirstConversationYieldsResumeAndSearch() throws {
        let ask = String(repeating: "我把接入层的三个问题都修完了,细节写在上面。", count: 8) + "要我提交吗？"
        scan([try writeConversation(name: "first", session: "s1", cwd: "/home/u/demo",
                                    turns: [("user", "帮我看看接入层的性能问题"),
                                            ("assistant", ask)])])
        // B1 接着上次:构造上必有
        let r = try XCTUnwrap(index.latestThread(), "B1 第 1 场对话就有接续点")
        // preview 是最后一条消息的**开头**——AI 汇报的首句即结论;
        // 结尾的问题由 openQuestion 单独承载。「结论 + 悬问」两样都有。
        XCTAssertTrue(r.preview.contains("接入层的三个问题"), "B2 「停在哪」= 最后一条消息的结论句")
        XCTAssertEqual(r.openQuestion, "要我提交吗？", "B3 它在等你什么,一并带出")
        // B4 搜索:自己说过的话能找回
        XCTAssertEqual(index.search("接入层"), ["s1"], "B4 第 1 天搜索就能用")
        // B5 阶梯数字如实
        let s = index.libraryStats()
        XCTAssertEqual(s.conversations, 1, "B5 统计如实")
        XCTAssertEqual(s.projects, 1, "B5 统计如实")
        // B6 悬着的事进 md
        let md = try buildMinds()
        XCTAssertTrue(md.contains("要我提交吗"), "B6 悬着的问题进 OPEN LOOPS")
    }

    // MARK: - C. 英文用户同等待遇

    func testC_EnglishOnlyUserGetsTheSameFloor() throws {
        let ask = String(repeating: "refactored the auth middleware and split the token helper. ", count: 4)
            + "want me to push the branch?"
        scan([try writeConversation(name: "en", session: "e1", cwd: "/home/u/api",
                                    turns: [("user", "please refactor the authentication middleware"),
                                            ("assistant", ask)])])
        let r = try XCTUnwrap(index.latestThread(), "C1 英文库同样第 1 场就有接续点")
        XCTAssertTrue(r.preview.lowercased().contains("refactored the auth middleware"),
                      "C2 停在哪(结论句),英文同样成立")
        XCTAssertEqual(r.openQuestion?.lowercased().contains("push"), true, "C3 英文问句同样被识别")
        XCTAssertEqual(index.search("middleware"), ["e1"], "C4 英文搜索")
    }

    // MARK: - D. 阈值一到,层就点亮

    func testD_PhrasesLightUpAtThreeProjects() throws {
        // 同一句主张出现在 3 个项目×2 场 = 6 次——短语层的真实门槛
        var urls: [URL] = []
        for (p, proj) in ["alpha", "beta", "gamma"].enumerated() {
            for k in 0..<2 {
                urls.append(try writeConversation(
                    name: "d-\(proj)-\(k)", session: "d-\(proj)-\(k)", cwd: "/home/u/\(proj)",
                    turns: [("user", "这里的用户旅程要重新梳理一遍"),
                            ("assistant", "好的,我按用户旅程重新排布")],
                    startMinute: (p * 2 + k) * 10))
            }
        }
        scan(urls)
        let s = index.libraryStats()
        let pending = MindsBuilder.pendingCapabilities(
            conversations: s.conversations, projects: s.projects,
            daySpanDays: s.daySpanDays, longestConversation: s.longestConversation)
        XCTAssertFalse(pending.contains { $0.kind == "phrases" }, "D1 三个项目 → 短语层解锁")
        let md = try buildMinds()
        XCTAssertTrue(md.contains("用户旅程"), "D2 短语真的出现在画像里")
        let doc = MindsDocument(markdown: md)
        XCTAssertFalse(doc.phraseQuotes().isEmpty, "D3 而且带着你说过的原话")
    }

    // MARK: - E. 注入不冒充你的话

    func testE_ClientInjectionsNeverEnterYourProfile() throws {
        scan([try writeConversation(
            name: "inj", session: "i1", cwd: "/home/u/demo",
            turns: [("user", "帮我调一下这个页面的布局"),
                    ("assistant", "改好了"),
                    ("user", "[Request interrupted by user]"),
                    ("user", "这版可以")])])
        for corpus in index.userCorpusTexts() {
            XCTAssertFalse(corpus.contains("Request interrupted"), "E1 系统注入不进你的语料")
        }
        let md = try buildMinds()
        XCTAssertFalse(md.contains("Request interrupted"), "E2 也不进画像")
    }

    // MARK: - F. 计数诚实

    func testF_StatedCountsMatchReality() throws {
        let ask = String(repeating: "第一块收尾了,測試全部通过,报告如上。", count: 8) + "要我继续吗？"
        scan([try writeConversation(name: "f1", session: "f1", cwd: "/home/u/x",
                                    turns: [("user", "开始吧"), ("assistant", ask)])])
        let md = try buildMinds()
        let doc = MindsDocument(markdown: md)
        // OPEN LOOPS 标称数 = 实际行数
        if let line = md.split(separator: "\n").first(where: { $0.contains("Threads left hanging") }),
           let n = line.split(separator: ",").last?.trimmingCharacters(in: .whitespaces)
               .split(separator: ")").first.flatMap({ Int($0) }) {
            XCTAssertEqual(doc.openLoops.count, n, "F1 标称 \(n) 条就得有 \(n) 条")
        } else {
            XCTFail("OPEN LOOPS 节必须存在且带计数")
        }
    }
}
