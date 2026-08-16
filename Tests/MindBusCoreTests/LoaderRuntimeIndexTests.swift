import XCTest
@testable import MindBusCore

final class LoaderRuntimeIndexTests: XCTestCase {
    func testIndexesNewAndSkipsUnchanged() throws {
        let path = NSTemporaryDirectory() + "lr-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let index = try ConversationIndex(path: path)

        // 造一个临时文件
        let dir = NSTemporaryDirectory() + "lr-src-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let u1 = URL(fileURLWithPath: dir + "a.jsonl")
        try "x".write(to: u1, atomically: true, encoding: .utf8)

        var parseCount = 0
        let parse: (URL) -> Conversation? = { url in
            parseCount += 1
            return Conversation(id: url.lastPathComponent, source: .claudeCode,
                                startAt: Date(), endAt: Date(), cwd: "/tmp", gitBranch: nil,
                                messages: [])
        }
        LoaderRuntime.index(urls: [u1], into: index, source: .claudeCode, parse: parse)
        XCTAssertEqual(index.summary().count, 1)
        XCTAssertEqual(parseCount, 1)

        // 第二次同 mtime，应跳过 parse
        LoaderRuntime.index(urls: [u1], into: index, source: .claudeCode, parse: parse)
        XCTAssertEqual(parseCount, 1)  // 未增加
        XCTAssertEqual(index.summary().count, 1)
    }

    /// browser 行的 file_path 是相对伪路径（= conv.id），不是磁盘路径——
    /// pruneMissing 只准 stat 绝对路径，否则每轮扫描 browser 行整段被误删。
    func testPruneMissingSparesBrowserPseudoPaths() throws {
        let path = NSTemporaryDirectory() + "lr-prune-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let index = try ConversationIndex(path: path)

        let dir = NSTemporaryDirectory() + "lr-prune-src-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // 1) browser 行（伪路径）
        let bid = "browser-chatgpt/2026-05-07.jsonl#3"
        index.replaceBrowserVault([Conversation(
            id: bid, source: .browser, startAt: Date(), endAt: Date(),
            cwd: "browser-chatgpt", gitBranch: nil,
            messages: [Message(id: "m", role: .user, timestamp: Date(), blocks: [.text("hi")])])])
        // 2) 真实存在的文件行
        let real = URL(fileURLWithPath: dir + "real.jsonl")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        // 3) 已从磁盘消失的文件行
        let gone = URL(fileURLWithPath: dir + "gone.jsonl")
        func lite(_ id: String, _ u: URL) -> ConversationLite {
            ConversationLite(id: id, source: .claudeCode, startAt: Date(), endAt: Date(),
                             cwd: "/tmp", gitBranch: nil, preview: "p", messageCount: 1, fileURL: u)
        }
        let t = [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: "t")]
        try index.upsert([(lite("real", real), t, 1, "t"), (lite("gone", gone), t, 1, "t")])

        LoaderRuntime.pruneMissing(from: index, hasArchive: { _ in false })

        let ids = Set(index.allMetadata().map(\.id))
        XCTAssertTrue(ids.contains(bid), "browser 伪路径行不得被 prune 误删")
        XCTAssertTrue(ids.contains("real"))
        XCTAssertFalse(ids.contains("gone"), "真实消失的文件行仍要被清掉")
    }

    /// 同 id 不同 path 的副本文件（用户 cp 备份过 jsonl）：upsert 跳过后必须 markSkipped，
    /// 否则副本的 mtime 永远不入库，每轮扫描都白解析一遍再被跳过。
    func testDuplicateIdCopyMarkedSkippedNotReparsedEveryScan() throws {
        let path = NSTemporaryDirectory() + "lr-dup-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let index = try ConversationIndex(path: path)

        let dir = NSTemporaryDirectory() + "lr-dup-src-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let orig = URL(fileURLWithPath: dir + "orig.jsonl")
        let copy = URL(fileURLWithPath: dir + "copy.jsonl")
        try "x".write(to: orig, atomically: true, encoding: .utf8)
        try "x".write(to: copy, atomically: true, encoding: .utf8)

        let lock = NSLock()
        var parseCount = 0
        let parse: (URL) -> Conversation? = { _ in
            lock.lock(); parseCount += 1; lock.unlock()
            return Conversation(id: "same-conv", source: .claudeCode,
                                startAt: Date(), endAt: Date(), cwd: "/tmp", gitBranch: nil,
                                messages: [])
        }
        LoaderRuntime.index(urls: [orig, copy], into: index, source: .claudeCode, parse: parse)
        XCTAssertEqual(index.summary().count, 1, "同 id 只入库一条")
        XCTAssertEqual(parseCount, 2, "首轮两个文件各解析一次")
        XCTAssertEqual(Set(index.knownMtimes().keys), [orig.path, copy.path],
                       "副本路径也要进 mtime 台账（经 skipped_files）")

        // 第二轮：两个文件 mtime 未变，一个都不该再解析
        LoaderRuntime.index(urls: [orig, copy], into: index, source: .claudeCode, parse: parse)
        XCTAssertEqual(parseCount, 2, "副本不再被每轮重解析")
    }
}

extension LoaderRuntimeIndexTests {
    /// 幽灵条目回归：文件早期状态入库（如「活跃会话豁免」窗口里的半成品），
    /// 随后补齐成被过滤的残骸（API Error stub 等）——重扫 parse 返回 nil 时
    /// 必须删掉既有记录，而不是只 markSkipped（否则列表可见、详情又被同一
    /// 过滤器拒掉，误报「源文件已无法读取」）。
    func testBarrenFileEvictsStaleRecord() throws {
        let path = NSTemporaryDirectory() + "lr-evict-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let index = try ConversationIndex(path: path)

        let dir = NSTemporaryDirectory() + "lr-evict-src-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let u = URL(fileURLWithPath: dir + "a.jsonl")
        try "v1".write(to: u, atomically: true, encoding: .utf8)

        var round = 1
        let parse: (URL) -> Conversation? = { _ in
            round == 1
                ? Conversation(id: "s1", source: .claudeCode, startAt: Date(), endAt: Date(),
                               cwd: "/tmp", gitBranch: nil,
                               messages: [Message(id: "m", role: .user, timestamp: Date(),
                                                  blocks: [.text("hi")])])
                : nil   // 第二轮：文件已成残骸，被过滤
        }
        LoaderRuntime.index(urls: [u], into: index, source: .claudeCode, parse: parse)
        XCTAssertEqual(index.summary().count, 1)

        round = 2
        try "v2 residue".write(to: u, atomically: true, encoding: .utf8)
        // 同秒重写可能不改 mtime——显式推 5s 保证触发重 parse
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: u.path)
        LoaderRuntime.index(urls: [u], into: index, source: .claudeCode, parse: parse)
        XCTAssertEqual(index.summary().count, 0, "被过滤文件的既有记录应被清除")
    }
}
