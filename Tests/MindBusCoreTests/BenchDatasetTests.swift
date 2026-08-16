import XCTest
import Foundation
@testable import MindBusCore

/// 评测集生成（spec `MEMORY-LAYER-SPEC.md` §7.59「评测集」）：四路查询来源各自的
/// 生成/丢弃规则、低频词重叠分带边界、JSONL 往返。
///
/// 全部用临时 SQLite 索引 + 临时目录（UUID 命名，`addTeardownBlock` 清理），commit
/// 路额外用 `FileManager` 造临时 git 仓 + 真 `git` 子进程（`XCTSkipUnless` 兜底 git
/// 不可用的环境）——绝不碰真实数据。
final class BenchDatasetTests: XCTestCase {

    // MARK: - 索引 / 临时目录

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "benchds-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("benchds-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 供分带边界测试直接构造 `ConversationLite`（不需要落盘源文件——那条测试不经过
    /// `generate()`，直接调 `BenchDataset.bandForOverlap`）。
    private func lite(_ id: String) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(), endAt: Date(),
                         cwd: "/tmp", gitBranch: nil, preview: "p", messageCount: 1,
                         fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    // MARK: - Claude Code jsonl fixture（`generate()` 走 `loadFull`，必须有真实可读源文件）

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func iso(_ date: Date) -> String { Self.isoFormatter.string(from: date) }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 写一个 Claude Code 格式的 jsonl 到临时目录、用真实 `ClaudeCodeLoader` 解析回来、
    /// 按生产代码同样的路径（parse → segment → upsert）灌进索引——这样 `BenchDataset.
    /// generate()` 内部的 `ConversationStore.loadFull` 才能读到与索引一致的内容
    /// （索引只存 df/entities 这类派生统计，原文回源必须靠磁盘上这份真文件）。
    @discardableResult
    private func writeFixture(_ index: ConversationIndex, dir: URL, name: String, cwd: String,
                               messages: [(role: MessageRole, text: String, at: Date)]) throws -> ConversationLite {
        let lines = messages.enumerated().map { i, m -> String in
            let roleStr = m.role == .user ? "user" : "assistant"
            let content = m.role == .user
                ? "\"\(escape(m.text))\""
                : #"[{"type":"text","text":"\#(escape(m.text))"}]"#
            return #"{"type":"\#(roleStr)","message":{"role":"\#(roleStr)","content":\#(content)},"uuid":"\#(name)-m\#(i)","timestamp":"\#(iso(m.at))","cwd":"\#(escape(cwd))","sessionId":"s-\#(name)"}"#
        }
        let url = dir.appendingPathComponent("\(name).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let conv = try XCTUnwrap(ClaudeCodeLoader.loadConversation(fileURL: url))
        let liteConv = ConversationLite.from(conv, fileURL: url)
        let segs = Segmenter.segments(of: conv.messages)
        try index.upsert([(liteConv, segs, 1, Segmenter.entityText(of: conv.messages))])
        return liteConv
    }

    // MARK: - git 子进程工具（commitMessage 一路专用）

    private func gitAvailable() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "--version"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: URL, epoch: Double? = nil) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        proc.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        if let epoch {
            // git 接受 `@<unix 秒> <tz>` 形式精确指定作者/提交者时间——
            // 窗口边界测试需要秒级精确控制 `%ct`，不能依赖「跑测试那一刻」的真实时间。
            let d = "@\(Int64(epoch)) +0000"
            env["GIT_AUTHOR_DATE"] = d
            env["GIT_COMMITTER_DATE"] = d
        }
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func initGitRepo(at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(try runGit(["init", "-q"], cwd: dir), 0, "git init 失败")
        XCTAssertEqual(try runGit(["config", "user.email", "bench-test@example.com"], cwd: dir), 0)
        XCTAssertEqual(try runGit(["config", "user.name", "Bench Test"], cwd: dir), 0)
    }

    private func commit(_ subject: String, at epoch: Double, in dir: URL) throws {
        XCTAssertEqual(try runGit(["commit", "--allow-empty", "-m", subject], cwd: dir, epoch: epoch), 0,
                       "git commit 失败：\(subject)")
    }

    // MARK: - commitMessage：时间窗口边界 [startAt-1h, endAt+1h]

    private static let T: Double = 1_700_000_000   // 固定基准 epoch，窗口边界可精确推算

    func testCommitAtWindowStartBoundaryIsPaired() throws {
        try XCTSkipUnless(gitAvailable(), "本环境没有可用的 git，跳过 commitMessage 一路测试")
        let index = try makeIndex()
        let dir = tempDir()
        let repo = dir.appendingPathComponent("repo")
        try initGitRepo(at: repo)

        let start = Date(timeIntervalSince1970: Self.T)
        let end = start.addingTimeInterval(300)
        try commit("边界正好在窗口起点应该配对", at: Self.T - 3600, in: repo)   // == startAt - 1h（闭区间起点）

        let session = try writeFixture(index, dir: dir, name: "s1", cwd: repo.path, messages: [
            (.user, "开始一次用于窗口边界测试的会话", start),
            (.assistant, "这是助手侧的占位回复内容", end),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .commitMessage }
        XCTAssertEqual(items.count, 1, "窗口起点（闭区间）应该配对")
        XCTAssertEqual(items.first?.query, "边界正好在窗口起点应该配对")
        XCTAssertEqual(items.first?.answerID, session.id)
    }

    func testCommitJustBeforeWindowIsExcluded() throws {
        try XCTSkipUnless(gitAvailable(), "本环境没有可用的 git，跳过 commitMessage 一路测试")
        let index = try makeIndex()
        let dir = tempDir()
        let repo = dir.appendingPathComponent("repo")
        try initGitRepo(at: repo)

        let start = Date(timeIntervalSince1970: Self.T)
        let end = start.addingTimeInterval(300)
        try commit("刚好卡在窗口外一秒不该配对", at: Self.T - 3600 - 1, in: repo)   // 窗口起点前 1 秒

        try writeFixture(index, dir: dir, name: "s1", cwd: repo.path, messages: [
            (.user, "开始一次用于窗口边界测试的会话", start),
            (.assistant, "这是助手侧的占位回复内容", end),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .commitMessage }
        XCTAssertTrue(items.isEmpty, "窗口外 1 秒的 commit 不该被配对")
    }

    func testCommitAtWindowEndBoundaryIsPaired() throws {
        try XCTSkipUnless(gitAvailable(), "本环境没有可用的 git，跳过 commitMessage 一路测试")
        let index = try makeIndex()
        let dir = tempDir()
        let repo = dir.appendingPathComponent("repo")
        try initGitRepo(at: repo)

        let start = Date(timeIntervalSince1970: Self.T)
        let end = start.addingTimeInterval(300)
        try commit("边界正好在窗口终点应该配对", at: Self.T + 300 + 3600, in: repo)   // == endAt + 1h（闭区间终点）

        let session = try writeFixture(index, dir: dir, name: "s1", cwd: repo.path, messages: [
            (.user, "开始一次用于窗口边界测试的会话", start),
            (.assistant, "这是助手侧的占位回复内容", end),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .commitMessage }
        XCTAssertEqual(items.count, 1, "窗口终点（闭区间）应该配对")
        XCTAssertEqual(items.first?.answerID, session.id)
    }

    func testCommitJustAfterWindowIsExcluded() throws {
        try XCTSkipUnless(gitAvailable(), "本环境没有可用的 git，跳过 commitMessage 一路测试")
        let index = try makeIndex()
        let dir = tempDir()
        let repo = dir.appendingPathComponent("repo")
        try initGitRepo(at: repo)

        let start = Date(timeIntervalSince1970: Self.T)
        let end = start.addingTimeInterval(300)
        try commit("刚好卡在终点外一秒不该配对", at: Self.T + 300 + 3600 + 1, in: repo)

        try writeFixture(index, dir: dir, name: "s1", cwd: repo.path, messages: [
            (.user, "开始一次用于窗口边界测试的会话", start),
            (.assistant, "这是助手侧的占位回复内容", end),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .commitMessage }
        XCTAssertTrue(items.isEmpty, "窗口终点外 1 秒的 commit 不该被配对")
    }

    /// subject 短于 8 字符丢；恰好 8 字符保留——边界两侧各构造一条。
    func testCommitSubjectLengthBoundary() throws {
        try XCTSkipUnless(gitAvailable(), "本环境没有可用的 git，跳过 commitMessage 一路测试")
        let index = try makeIndex()
        let dir = tempDir()
        let repo = dir.appendingPathComponent("repo")
        try initGitRepo(at: repo)

        let start = Date(timeIntervalSince1970: Self.T)
        let end = start.addingTimeInterval(300)
        try commit("abcdefg", at: Self.T, in: repo)     // 7 字符：丢
        try commit("abcdefgh", at: Self.T + 10, in: repo)  // 8 字符：留

        try writeFixture(index, dir: dir, name: "s1", cwd: repo.path, messages: [
            (.user, "开始一次用于长度边界测试的会话", start),
            (.assistant, "这是助手侧的占位回复内容", end),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .commitMessage }
        XCTAssertEqual(items.map(\.query), ["abcdefgh"], "7 字符 subject 该丢，8 字符该留")
    }

    /// 同仓库两个会话都命中同一个 commit 的窗口时，取「离会话实际跨度更近」的那个。
    func testCommitPairsWithClosestSessionWhenMultipleMatch() throws {
        try XCTSkipUnless(gitAvailable(), "本环境没有可用的 git，跳过 commitMessage 一路测试")
        let index = try makeIndex()
        let dir = tempDir()
        let repo = dir.appendingPathComponent("repo")
        try initGitRepo(at: repo)

        // A: [T, T+300]，窗口 [T-3600, T+3900]
        // B: [T+2000, T+2300]，窗口 [T-1600, T+5900]
        // commit 在 T+1900：离 A 的距离 = (T+1900)-(T+300) = 1600；离 B 的距离 = (T+2000)-(T+1900) = 100
        // → B 更近。
        let aStart = Date(timeIntervalSince1970: Self.T)
        let aEnd = aStart.addingTimeInterval(300)
        let bStart = Date(timeIntervalSince1970: Self.T + 2000)
        let bEnd = bStart.addingTimeInterval(300)
        try commit("离最近会话应该配对而非最早会话", at: Self.T + 1900, in: repo)

        try writeFixture(index, dir: dir, name: "sessionA", cwd: repo.path, messages: [
            (.user, "这是会话 A 的开场白内容", aStart),
            (.assistant, "这是会话 A 的助手回复内容", aEnd),
        ])
        let sessionB = try writeFixture(index, dir: dir, name: "sessionB", cwd: repo.path, messages: [
            (.user, "这是会话 B 的开场白内容", bStart),
            (.assistant, "这是会话 B 的助手回复内容", bEnd),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .commitMessage }
        XCTAssertEqual(items.count, 1, "一个 commit 只该配对出一条 commitMessage 记录")
        XCTAssertEqual(items.first?.answerID, sessionB.id, "应该配对时间上更近的会话 B，而非更早的 A")
    }

    /// cwd 不落在任何 git 仓库内的会话——不该产出 commitMessage 条目（也不该触发任何
    /// git 子进程调用，这个测试本身不需要 `XCTSkipUnless`）。
    func testSessionOutsideGitRepoProducesNoCommitMessageItems() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let plainDir = dir.appendingPathComponent("no-git-here")
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)

        try writeFixture(index, dir: dir, name: "s1", cwd: plainDir.path, messages: [
            (.user, "这个会话不在任何 git 仓库里", Date(timeIntervalSince1970: Self.T)),
            (.assistant, "所以不该产生 commitMessage 条目", Date(timeIntervalSince1970: Self.T + 10)),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .commitMessage }
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - rareEntity：DF ≤3，每会话最多 2 条

    func testRareEntityWithinThresholdIsIncluded() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let target = try writeFixture(index, dir: dir, name: "target", cwd: "/tmp/re-1", messages: [
            (.user, "提到 rare_signal_alpha 这个标识符", Date(timeIntervalSince1970: Self.T)),
            (.assistant, "好的记下了", Date(timeIntervalSince1970: Self.T + 10)),
        ])
        // 垫几个不相关会话，让总会话数不至于太小（避免 entities() 内部的样板压制阈值
        // 在小样本下产生意外的边界效应）。
        for i in 0..<5 {
            try writeFixture(index, dir: dir, name: "filler\(i)", cwd: "/tmp/re-filler-\(i)", messages: [
                (.user, "第 \(i) 条无关的填充会话内容", Date(timeIntervalSince1970: Self.T + Double(i) * 100)),
                (.assistant, "收到", Date(timeIntervalSince1970: Self.T + Double(i) * 100 + 10)),
            ])
        }

        let items = BenchDataset.generate(index: index, maxPerSource: 10)
            .filter { $0.source == .rareEntity && $0.answerID == target.id }
        XCTAssertTrue(items.contains { $0.query == "rare_signal_alpha" }, "DF=1（≤3）的实体应该被收进 rareEntity")
    }

    /// DF=4（>3）的实体不该产出条目——即便它在 `entities(forConversationID:)` 内部的
    /// 样板压制阈值下依然可见（那条阈值是 ≤50% 会话数，不是 BenchDataset 自己的 ≤3 规则）。
    func testEntityAboveThresholdIsExcluded() throws {
        let index = try makeIndex()
        let dir = tempDir()
        for i in 0..<4 {
            try writeFixture(index, dir: dir, name: "shared\(i)", cwd: "/tmp/re-shared-\(i)", messages: [
                (.user, "都提到 shared_common_entity 这个词", Date(timeIntervalSince1970: Self.T + Double(i) * 100)),
                (.assistant, "确认收到", Date(timeIntervalSince1970: Self.T + Double(i) * 100 + 10)),
            ])
        }
        // 垫够总会话数（10），让 entities() 内部 `总会话数×0.5+1` 的样板压制阈值远高于 4，
        // 这样「DF=4 不出现在结果里」明确是 BenchDataset 自己 ≤3 规则的效果，不是被
        // 上游那道更粗的阈值提前挡掉的巧合。
        for i in 0..<6 {
            try writeFixture(index, dir: dir, name: "filler\(i)", cwd: "/tmp/re-filler2-\(i)", messages: [
                (.user, "第 \(i) 条无关的填充会话内容", Date(timeIntervalSince1970: Self.T + 1000 + Double(i) * 100)),
                (.assistant, "收到", Date(timeIntervalSince1970: Self.T + 1000 + Double(i) * 100 + 10)),
            ])
        }

        let items = BenchDataset.generate(index: index, maxPerSource: 10).filter { $0.source == .rareEntity }
        XCTAssertFalse(items.contains { $0.query == "shared_common_entity" }, "DF=4（>3）的实体不该出现在 rareEntity 里")
    }

    /// 一个会话里有 3 个同样 DF=1 的稀有实体时，只留 2 条——`entities(forConversationID:)`
    /// 按 df 升序、并列时按 text 升序，所以按字典序取前两个。
    func testRareEntityCappedAtTwoPerSession() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let target = try writeFixture(index, dir: dir, name: "target", cwd: "/tmp/re-cap", messages: [
            (.user, "这里有 solo_ident_one solo_ident_two solo_ident_three 三个独有标识",
             Date(timeIntervalSince1970: Self.T)),
            (.assistant, "记下了", Date(timeIntervalSince1970: Self.T + 10)),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10)
            .filter { $0.source == .rareEntity && $0.answerID == target.id }
        XCTAssertEqual(items.count, 2, "每会话最多 2 条")
        XCTAssertEqual(Set(items.map(\.query)), ["solo_ident_one", "solo_ident_three"],
                       "并列 DF 时按字典序取前两个（one < three < two）")
    }

    // MARK: - firstMessage：首条 user 消息截前 12 词，<10 字符丢

    func testFirstMessageTruncatedToTwelveWords() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let longFirst = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november"
        let expected = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima"
        let session = try writeFixture(index, dir: dir, name: "s1", cwd: "/tmp/fm-1", messages: [
            (.user, longFirst, Date(timeIntervalSince1970: Self.T)),
            (.assistant, "收到，这是回复", Date(timeIntervalSince1970: Self.T + 10)),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10)
            .filter { $0.source == .firstMessage && $0.answerID == session.id }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.query, expected, "应截取前 12 个空白切分的词")
    }

    func testFirstMessageTooShortAfterTruncationIsDropped() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let session = try writeFixture(index, dir: dir, name: "s1", cwd: "/tmp/fm-2", messages: [
            (.user, "hi", Date(timeIntervalSince1970: Self.T)),
            (.assistant, "这是回复内容用于占位测试", Date(timeIntervalSince1970: Self.T + 10)),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10)
            .filter { $0.source == .firstMessage && $0.answerID == session.id }
        XCTAssertTrue(items.isEmpty, "截断后长度 <10 字符应该丢")
    }

    // MARK: - structuralEvent：段末用户短消息 6...60 字闭区间

    func testStructuralEventShortFinalUserMessageIsIncluded() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let longReply = String(repeating: "详细方案说明文字", count: 60)   // ≥400 字
        let session = try writeFixture(index, dir: dir, name: "s1", cwd: "/tmp/se-1", messages: [
            (.user, "帮我看看这个复杂的方案设计得对不对", Date(timeIntervalSince1970: Self.T)),
            (.assistant, longReply, Date(timeIntervalSince1970: Self.T + 10)),
            (.user, "这个方案不太对", Date(timeIntervalSince1970: Self.T + 20)),   // 7 字，段末
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10)
            .filter { $0.source == .structuralEvent && $0.answerID == session.id }
        XCTAssertTrue(items.contains { $0.query == "这个方案不太对" }, "段末 6...60 字用户消息应该被收进 structuralEvent")
    }

    func testStructuralEventFinalMessageTooShortIsDropped() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let session = try writeFixture(index, dir: dir, name: "s1", cwd: "/tmp/se-2", messages: [
            (.user, "开场问题内容占位用于测试", Date(timeIntervalSince1970: Self.T)),
            (.assistant, "占位回复内容用于测试目的这里凑一些字数占位", Date(timeIntervalSince1970: Self.T + 10)),
            (.user, "嗯", Date(timeIntervalSince1970: Self.T + 20)),   // 1 字 <6，段末
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10)
            .filter { $0.source == .structuralEvent && $0.answerID == session.id }
        XCTAssertFalse(items.contains { $0.query == "嗯" }, "段末用户消息短于 6 字符该丢")
    }

    func testStructuralEventFinalMessageTooLongIsDropped() throws {
        let index = try makeIndex()
        let dir = tempDir()
        let tooLong = String(repeating: "字", count: 70)   // 70 字 >60
        let session = try writeFixture(index, dir: dir, name: "s1", cwd: "/tmp/se-3", messages: [
            (.user, "开场问题内容占位用于测试", Date(timeIntervalSince1970: Self.T)),
            (.assistant, "占位回复内容用于测试目的这里凑一些字数占位", Date(timeIntervalSince1970: Self.T + 10)),
            (.user, tooLong, Date(timeIntervalSince1970: Self.T + 20)),
        ])

        let items = BenchDataset.generate(index: index, maxPerSource: 10)
            .filter { $0.source == .structuralEvent && $0.answerID == session.id }
        XCTAssertFalse(items.contains { $0.query == tooLong }, "段末用户消息长于 60 字符该丢（不算「短消息」）")
    }

    // MARK: - 分带边界（§7.59：0-1 low / 2-3 mid / ≥4 high）

    /// 构造可控 df 的临时语料：5 个「独占词」各自只出现在 1 个专属段落里（df=1），
    /// 1 个「共享词」出现在 60 个段落里（df=60）；再垫 35 个无关段落，让总段数恰为
    /// 100，使 ceiling = max(2, 5%×100) = 5——独占词（df=1）落在低频区，共享词
    /// （df=60）远超上限、不计入重叠。以此精确控制「低频词重叠数」取 0/1/2/3/4。
    func testBandBoundariesAcrossOverlapCounts() throws {
        let index = try makeIndex()
        let rareWords = ["ralpha", "rbravo", "rcharlie", "rdelta", "recho"]
        for w in rareWords {
            try index.upsert([(lite("rare-\(w)"),
                               [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0,
                                                   text: "filler segment containing \(w) alone")],
                               1, "")])
        }
        for i in 0..<60 {
            try index.upsert([(lite("common-\(i)"),
                               [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0,
                                                   text: "everyword commonoverlap appears \(i)")],
                               1, "")])
        }
        for i in 0..<35 {
            try index.upsert([(lite("filler-\(i)"),
                               [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0,
                                                   text: "unrelated padding number \(i)")],
                               1, "")])
        }
        XCTAssertEqual(index.segmentCount(), 100, "前提：总段数恰为 100，ceiling 公式才如上面注释推算的那样")

        let lexicon = index.loadLexicon()
        let totalSegments = index.segmentCount()

        func band(overlapCount: Int) -> BenchItem.Band {
            let words = Array(rareWords.prefix(overlapCount)) + ["commonoverlap"]
            let text = words.joined(separator: " ")
            return BenchDataset.bandForOverlap(query: text, answerFullText: text, index: index,
                                                lexicon: lexicon, totalSegments: totalSegments)
        }

        XCTAssertEqual(band(overlapCount: 0), .low, "0 个低频重叠词（外加 1 个高频共享词不计入）→ low")
        XCTAssertEqual(band(overlapCount: 1), .low, "1 个低频重叠 → low")
        XCTAssertEqual(band(overlapCount: 2), .mid, "2 个低频重叠 → mid")
        XCTAssertEqual(band(overlapCount: 3), .mid, "3 个低频重叠 → mid")
        XCTAssertEqual(band(overlapCount: 4), .high, "4 个低频重叠 → high")
    }

    // MARK: - JSONL 往返

    func testJSONLRoundTrip() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("dataset.jsonl")
        let items = [
            BenchItem(query: "重构评测管线的分带逻辑", answerID: "conv-1", source: .commitMessage, band: .high),
            BenchItem(query: "rare_entity_x", answerID: "conv-2", source: .rareEntity, band: .low),
            BenchItem(query: "first message truncated to twelve words for testing", answerID: "conv-3",
                      source: .firstMessage, band: .mid),
            BenchItem(query: "这个方案不太对", answerID: "conv-4", source: .structuralEvent, band: .mid),
        ]

        BenchDataset.write(items, to: url)
        let readBack = BenchDataset.read(from: url)
        XCTAssertEqual(readBack, items, "JSONL 往返必须逐位还原（顺序与内容）")
    }

    func testReadMissingFileReturnsEmptyArray() {
        let missing = tempDir().appendingPathComponent("does-not-exist.jsonl")
        XCTAssertTrue(BenchDataset.read(from: missing).isEmpty)
    }

    // MARK: - maxPerSource 独立限制每一路

    func testMaxPerSourceCapsEachRouteIndependently() throws {
        let index = try makeIndex()
        let dir = tempDir()
        // 3 个会话各自贡献一个独占（df=1）稀有实体——rareEntity 天然能产出 3 条，
        // 用 maxPerSource=1 验证只留 1 条（且不影响其它路——这里只断言 rareEntity 计数）。
        for i in 0..<3 {
            try writeFixture(index, dir: dir, name: "cap\(i)", cwd: "/tmp/cap-\(i)", messages: [
                (.user, "提到 unique_cap_marker_\(i) 这个标识", Date(timeIntervalSince1970: Self.T + Double(i) * 100)),
                (.assistant, "收到了", Date(timeIntervalSince1970: Self.T + Double(i) * 100 + 10)),
            ])
        }

        let items = BenchDataset.generate(index: index, maxPerSource: 1)
        XCTAssertEqual(items.filter { $0.source == .rareEntity }.count, 1,
                       "maxPerSource 应独立限制每一路的数量，即便候选远多于此")
    }
}
