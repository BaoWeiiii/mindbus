import XCTest
@testable import MindBusCore

/// Codex 归档过滤（B 方案）。
///
/// 为什么 Codex 不像 Claude 那样整拷：实测 `~/.codex/sessions` 主会话 2.99 GiB 里
/// **62.7% 是 agent 截图**（工具输出内嵌 1283.6 + compacted 重复内嵌 399.7 + 注入 176.7 MiB）、
/// **22.2% 是 event_msg 遥测**，真正的对话文本不足 0.4%。整拷要多占 1.2 GiB，
/// 而丢掉的恰是图片政策早已判定「永不展示」的字节。
final class CodexArchiveFilterTests: XCTestCase {

    /// event_msg 是 agent 遥测/状态流，占 22.2% 体积，CodexLoader 压根不读。
    func testDropsEventMsgAndTurnContext() {
        XCTAssertNil(CodexArchiveFilter.filterLine(#"{"type":"event_msg","payload":{"type":"token_count"}}"#))
        XCTAssertNil(CodexArchiveFilter.filterLine(#"{"type":"turn_context","payload":{"cwd":"/x"}}"#))
    }

    /// session_meta 带 id/cwd，是 loader 建元数据的唯一来源，必须原样保留。
    func testKeepsSessionMetaVerbatim() throws {
        let line = #"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#
        XCTAssertEqual(CodexArchiveFilter.filterLine(line), line)
    }

    /// 用户主动附件图（同条消息里带「# Files mentioned by the user:」）按政策保留。
    func testKeepsUserAttachedImage() throws {
        let line = """
        {"type":"response_item","timestamp":"2026-08-01T10:00:00.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# Files mentioned by the user:\\nlook"},{"type":"input_image","image_url":"data:image/png;base64,AAAABBBB"}]}}
        """
        let out = try XCTUnwrap(CodexArchiveFilter.filterLine(line))
        XCTAssertTrue(out.contains("AAAABBBB"), "用户主动贴的图被误丢")
    }

    /// 非用户附件的图（browser-use 注入截图等）按政策丢弃，只留占位文字。
    /// 这一条是 Codex 侧最大的省空间来源。
    func testDropsInjectedImageButKeepsText() throws {
        let line = """
        {"type":"response_item","timestamp":"2026-08-01T10:00:00.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# In app browser:"},{"type":"input_image","image_url":"data:image/png;base64,ZZZZZZZZ"}]}}
        """
        let out = try XCTUnwrap(CodexArchiveFilter.filterLine(line))
        XCTAssertFalse(out.contains("ZZZZZZZZ"), "注入截图没被丢掉")
        XCTAssertTrue(out.contains("# In app browser:"), "文字被连带丢了")
    }

    /// 工具输出里内嵌的截图（data URI）剥掉，但输出文本本身保留——
    /// 文本只占 3.8%，截断它省不了多少却真丢内容。
    func testStripsDataURIFromToolOutputKeepingText() throws {
        let line = """
        {"type":"response_item","payload":{"type":"function_call_output","output":"screenshot: data:image/png;base64,QQQQQQQQ done: 42 rows"}}
        """
        let out = try XCTUnwrap(CodexArchiveFilter.filterLine(line))
        XCTAssertFalse(out.contains("QQQQQQQQ"))
        XCTAssertTrue(out.contains("42 rows"), "工具输出文本被误丢")
    }

    /// 加密推理内容不可渲染（任何人都读不出来），零保留价值。
    func testDropsEncryptedReasoning() {
        XCTAssertNil(CodexArchiveFilter.filterLine(
            #"{"type":"response_item","payload":{"type":"reasoning","encrypted_content":"gAAAAA"}}"#))
    }

    /// compacted 行保留（它是模型对前文的压缩摘要，将来可能要展示），
    /// 但里面重复内嵌的历史截图（占 13% 体积）要剥掉。
    func testKeepsCompactedButStripsItsImages() throws {
        let line = """
        {"type":"compacted","payload":{"message":"summary text data:image/png;base64,WWWWWWWW end"}}
        """
        let out = try XCTUnwrap(CodexArchiveFilter.filterLine(line))
        XCTAssertFalse(out.contains("WWWWWWWW"))
        XCTAssertTrue(out.contains("summary text"))
    }

    /// 工具调用（function_call）原样保留：它是将来渲染执行时间线的原料。
    func testKeepsFunctionCallVerbatim() throws {
        let line = #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"cmd\":\"ls\"}"}}"#
        XCTAssertEqual(CodexArchiveFilter.filterLine(line), line)
    }

    /// 非 JSON 噪声行丢弃。
    func testDropsNonJSONLine() {
        XCTAssertNil(CodexArchiveFilter.filterLine("not json at all"))
        XCTAssertNil(CodexArchiveFilter.filterLine(""))
    }

    /// 回归：过滤不得重新序列化 JSON，因为那会打乱键序。
    ///
    /// `CodexLoader.messageLineFilter` 为省内存做字节级预筛，**只扫每行前 256 字节**
    /// 找 "response_item"。而 `JSONSerialization` 不保证键序——一旦 "payload" 被排到
    /// "type" 前面且 payload 很大，"response_item" 就被挤出预筛窗口，整行被解析器
    /// **静默跳过**。真实数据实测：一个会话从 206 条消息掉到 147 条，而 240 条 message
    /// 行一条不少、JSON 语义也完全正确——这种 bug 只有拿真实大会话才看得见。
    func testNothingToStripMeansByteIdenticalOutput() throws {
        let long = String(repeating: "很长的助手回复内容", count: 60)   // 远超 256 字节
        let line = """
        {"type":"response_item","timestamp":"2026-08-01T10:00:00.000Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\(long)"}]}}
        """
        XCTAssertEqual(CodexArchiveFilter.filterLine(line), line,
                       "无图可剥的行被重新序列化了——键序会被打乱")
    }

    /// 剥图之后，"response_item" 仍必须落在前 256 字节的预筛窗口内。
    func testStrippedLineStillPassesBytePrescreen() throws {
        let bigB64 = String(repeating: "A", count: 5000)
        let line = "{\"type\":\"response_item\",\"timestamp\":\"2026-08-01T10:00:00.000Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"# In app browser:\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,\(bigB64)\"}]}}"
        let out = try XCTUnwrap(CodexArchiveFilter.filterLine(line))
        XCTAssertFalse(out.contains(bigB64), "图没剥掉")
        XCTAssertTrue(String(out.prefix(256)).contains("response_item"),
                      "type 被挤出 256 字节预筛窗口——解析器会静默跳过整行")
        XCTAssertNotNil(CodexLoader.parseLine(out, lineIndex: 1), "剥图后解析不出消息了")
    }

    /// Codex 现在也要归档（此前只保 Claude 系，Codex 完全没保护，与「跨工具」承诺矛盾）。
    func testCodexIsNowArchived() {
        XCTAssertTrue(VaultArchive.shouldArchive(.codex))
        XCTAssertTrue(VaultArchive.isArchivableSourcePath(
            CodexLoader.defaultSessionsDir.appendingPathComponent("2026/08/rollout.jsonl").path))
        // 兄弟目录不该误命中
        XCTAssertFalse(VaultArchive.isArchivableSourcePath(
            CodexLoader.defaultSessionsDir.path + "-old/x.jsonl"))
    }

    /// 归档 Codex 会话时要过滤：归档体积必须显著小于源，且还原后仍能被 CodexLoader 解析出对话。
    ///
    /// 本测试曾经假绿：源文件建在临时目录，不在 `~/.codex/sessions` 下，
    /// `VaultArchive.needsFilter`（判路径前缀）返回 false，`archive()` 实际走的是
    /// 整拷分支，过滤器一次没跑。体积断言之所以仍然通过，纯粹因为旧的假图片是
    /// 400_000 个重复字符 "A"——LZMA 把这种高度重复数据压到几百字节，不管有没有
    /// 过滤，压缩比本身就已经 < 0.05，测试对「过滤到底发生没发生」完全没有鉴别力。
    /// 现在改三处：①显式注入 `needsFilter` 绕开路径前缀判定，真正走到过滤分支；
    /// ②假图片换成不可压缩的随机字节 base64，只有真的把图剥掉才能让归档变小；
    /// ③加一条对照——同源文件在 `needsFilter` 恒为 false（整拷）下归档，体积必须
    /// 显著大于过滤版，证明这条测试在「过滤没发生」时必然失败。
    func testArchivingCodexSessionFiltersAndStaysParseable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cxarch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // 过滤版与整拷对照版分放两个 vault root，避免同一份归档路径互相覆盖。
        let filteredRoot = dir.appendingPathComponent("vault-filtered", isDirectory: true)
        let wholeRoot = dir.appendingPathComponent("vault-whole", isDirectory: true)

        // 造一个含大截图的 Codex 会话：一条真消息 + 一条巨大的注入截图 + 遥测。
        // 不可压缩的假图：随机字节的 base64。用重复字符（如 400_000 个 "A"）会被 LZMA
        // 压到几百字节，于是「过滤没发生」也能让体积断言通过——这条测试原本就是这样假绿的。
        let randomBytes = (0..<300_000).map { _ in UInt8.random(in: 0...255) }
        let bigB64 = Data(randomBytes).base64EncodedString()
        let src = dir.appendingPathComponent("rollout.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#,
            #"{"type":"response_item","timestamp":"2026-08-01T10:00:00.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"过滤后我还在吗"}]}}"#,
            "{\"type\":\"response_item\",\"timestamp\":\"2026-08-01T10:00:01.000Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"# In app browser:\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,\(bigB64)\"}]}}",
            #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: src)
        let srcSize = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: src.path)[.size]) as? Int)

        // 显式注入 needsFilter: { _ in true }，绕开「源路径必须真的在 ~/.codex/sessions
        // 下」这条前缀判定——测试源在临时目录，不这样做就会像本测试曾经那样悄悄走整拷分支。
        XCTAssertTrue(VaultArchive.archive(sourcePath: src.path, root: filteredRoot, needsFilter: { _ in true }))

        // 过滤 + 压缩后必须远小于源（源里 97% 是那张注入截图，且不可压缩）
        let archived = VaultArchive.archiveURL(forSourcePath: src.path, root: filteredRoot)
        let packed = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: archived.path)[.size]) as? Int)
        XCTAssertLessThan(Double(packed) / Double(srcSize), 0.05, "注入截图似乎没被过滤掉")

        // 还原后仍能被现有解析器读出那条真消息
        let conv = VaultArchive.withRestoredCopy(sourcePath: src.path, root: filteredRoot) { url in
            try? CodexLoader.loadConversation(fileURL: url)
        }
        let unwrapped = try XCTUnwrap(conv, "过滤后的归档 CodexLoader 解析不出来")
        XCTAssertTrue(unwrapped.searchableText.contains("过滤后我还在吗"))

        // 对照组：同一份源在 needsFilter 恒为 false（整拷、模拟"过滤没发生"）下归档，
        // 体积必须显著大于过滤版——证明上面的体积断言真的在测「过滤发生了」，
        // 而不是像旧版那样随便压缩一下就能过。
        XCTAssertTrue(VaultArchive.archive(sourcePath: src.path, root: wholeRoot, needsFilter: { _ in false }))
        let wholeArchived = VaultArchive.archiveURL(forSourcePath: src.path, root: wholeRoot)
        let wholePacked = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: wholeArchived.path)[.size]) as? Int)
        XCTAssertGreaterThan(wholePacked, packed * 5,
                            "整拷（未过滤）体积应显著大于过滤版；若相近，说明假图片仍然可压缩，体积断言会失去鉴别力")
    }

    /// 整文件过滤：写出的文件必须仍是合法 jsonl，且丢掉该丢的。
    func testFiltersWholeFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cxfilter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("in.jsonl")
        let dst = dir.appendingPathComponent("out.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
            #"{"type":"response_item","timestamp":"2026-08-01T10:00:00.000Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"你好"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_reasoning"}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: src)

        let written = try CodexArchiveFilter.filter(source: src, to: dst)
        XCTAssertEqual(written, 2, "该留 session_meta + 一条消息")

        let outText = try String(contentsOf: dst, encoding: .utf8)
        XCTAssertFalse(outText.contains("event_msg"))
        XCTAssertTrue(outText.contains("你好"))
        // 每行都得是合法 JSON
        for line in outText.split(separator: "\n") {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                            "过滤后产出了非法 JSON 行：\(line)")
        }
    }
}
