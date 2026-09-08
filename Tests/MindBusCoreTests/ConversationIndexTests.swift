import XCTest
@testable import MindBusCore

final class ConversationIndexTests: XCTestCase {
    private var path: String!
    private var index: ConversationIndex!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "cidx-\(UUID().uuidString).sqlite"
        index = try ConversationIndex(path: path)
    }
    override func tearDown() {
        index = nil
        // WAL 模式会产生 -wal / -shm 旁文件，一并清理
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func lite(_ id: String, source: ConversationSource = .claudeCode,
                      end: Date = Date(), title: String? = nil, path p: String) -> ConversationLite {
        ConversationLite(id: id, source: source, startAt: end.addingTimeInterval(-60),
                         endAt: end, cwd: "/tmp", gitBranch: nil, title: title, preview: "p-\(id)",
                         messageCount: 1, fileURL: URL(fileURLWithPath: p))
    }

    /// upsert 现在接收段数组而非整段全文字符串——测试只关心「这段文字能不能被搜到」，
    /// 用单段包一层即可，不需要真的走 Segmenter 切段。
    private func segs(_ text: String) -> [Segmenter.Segment] {
        [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0, text: text)]
    }

    /// upsert 现在多要一个 entityText 字段（实体抽取改用排除 `.toolUse` 的专用口径，
    /// 见 `Segmenter.entityText`）。这里的测试文本都不含 toolUse 结构，直接复用段文字
    /// 拼接即可——与旧口径等价，不改变任何既有断言的语义。
    private func row(_ l: ConversationLite, _ s: [Segmenter.Segment], _ mtime: Double)
        -> (lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String) {
        (l, s, mtime, s.map(\.text).joined(separator: "\n"))
    }

    func testUpsertAndSummary() throws {
        let now = Date()
        try index.upsert([
            row(lite("a", source: .claudeCode, end: now, path: "/f/a"), segs("hello world"), 100),
            row(lite("b", source: .cursor, end: now.addingTimeInterval(10), path: "/f/b"), segs("重构方案讨论"), 200),
        ])
        let s = index.summary()
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.sources, 2)
        XCTAssertEqual(s.latest?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(10).timeIntervalSince1970, accuracy: 1)
    }

    func testAllMetadataHasNoFullText() throws {
        try index.upsert([row(lite("a", path: "/f/a"), segs("secret fulltext body"), 100)])
        let metas = index.allMetadata()
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0].preview, "p-a")
        // 瘦身 lite 无 searchableText 字段（编译期保证）；这里确认 metadata 完整
        XCTAssertEqual(metas[0].id, "a")
    }

    func testUpsertSameFilePathReplacesNotDuplicates() throws {
        // 同一 file_path 二次 upsert 应覆盖而非新增行（增量幂等）
        try index.upsert([row(lite("a", end: Date(), path: "/f/a"), segs("v1"), 100)])
        try index.upsert([row(lite("a", end: Date(), path: "/f/a"), segs("v2"), 200)])
        XCTAssertEqual(index.summary().count, 1)
    }

    func testSearchTrigramChineseAndEnglish() throws {
        try index.upsert([
            row(lite("a", path: "/f/a"), segs("上周和ChatGPT讨论的重构方案"), 1),
            row(lite("b", path: "/f/b"), segs("refactor the Database layer"), 1),
        ])
        XCTAssertEqual(index.search("重构方"), ["a"])          // 中文子串 ≥3
        XCTAssertEqual(index.search("database"), ["b"])         // 英文 + 大小写不敏感
        XCTAssertEqual(index.search("不存在的词"), [])
    }

    /// search 现在按相关度排序（BM25 双路 RRF），不再是无序集合。
    /// 此前 UI 只能按时间倒序展示召回结果 —— 实测 R@1 仅 5.2%。
    func testSearchRanksByRelevance() throws {
        try index.upsert([
            // 只捎带提了一次，且正文很长 —— BM25 的长度归一化会压低它
            row(lite("weak", path: "/f/w"), segs("今天聊了很多别的事情，顺带提到窗口这个词一次，然后继续聊了很久很久别的话题一直没停"), 1),
            // 通篇都在讲，词频高 → 应排前面
            row(lite("strong", path: "/f/s"), segs("窗口 窗口 窗口 窗口 反复讨论窗口层级与窗口置顶"), 1),
            row(lite("none", path: "/f/n"), segs("完全无关的内容：字体与排版"), 1),
        ])
        let hits = index.search("窗口")
        XCTAssertEqual(hits.count, 2, "只应召回含该词的两条")
        XCTAssertEqual(hits.first, "strong", "词频高的排在前 —— 这正是 BM25 的作用")
        XCTAssertFalse(hits.contains("none"))
    }

    /// 多词查询：此前把整串当一个 phrase，搜「migrate database」只能命中
    /// 原文里恰好连着出现这两个词的对话，召回极低。现在切词 OR + BM25 排序。
    func testSearchMultiWordUsesOrNotPhrase() throws {
        try index.upsert([
            row(lite("both", path: "/f/b"), segs("we should migrate the database schema next week"), 1),
            row(lite("one", path: "/f/o"), segs("the database is fine, nothing to change"), 1),
        ])
        let hits = index.search("migrate database")
        XCTAssertEqual(Set(hits), ["both", "one"], "OR 语义：任一词命中即召回")
        XCTAssertEqual(hits.first, "both", "两词都命中的排第一")
    }

    /// 短词（<3 字）走 segments 表的 LIKE 全文扫描——
    /// 曾只扫 preview：真实库上「接力」这类两字词命中 0 条，形同虚设。
    func testSearchShortQueryScansFullText() throws {
        try index.upsert([
            row(lite("a", path: "/f/a"), segs("开头别的话……中间聊到了接力功能……结尾"), 1),
            row(lite("b", path: "/f/b"), segs("nothing relevant here"), 1),
        ])
        XCTAssertEqual(index.search("接力"), ["a"])   // 命中全文中部（preview 之外）
        XCTAssertEqual(index.search("re"), ["b"])     // 英文 2 字符 + 大小写不敏感
        XCTAssertEqual(index.search("咕"), [])         // 单字无命中不误报
    }

    func testSearchEmptyQueryReturnsNothing() throws {
        try index.upsert([row(lite("a", path: "/f/a"), segs("body"), 1)])
        XCTAssertEqual(index.search(""), [])
        XCTAssertEqual(index.search("   "), [])
    }

    func testKnownMtimesAndPrune() throws {
        try index.upsert([
            row(lite("a", path: "/f/a"), segs("alpha content"), 100),
            row(lite("b", path: "/f/b"), segs("beta content"), 200),
        ])
        XCTAssertEqual(index.knownMtimes(), ["/f/a": 100, "/f/b": 200])
        XCTAssertEqual(index.search("alpha"), ["a"])    // prune 前能搜到
        index.prune(missingPaths: ["/f/a"])
        XCTAssertEqual(index.summary().count, 1)
        XCTAssertEqual(index.knownMtimes(), ["/f/b": 200])
        XCTAssertEqual(index.search("alpha"), [])       // prune 后其 fts 连带消失
        XCTAssertEqual(index.search("beta"), ["b"])     // 兄弟行不受影响
    }

    func testOpenRecoveringCorruptionRebuildsFromGarbageFile() throws {
        // index.sqlite 损坏曾表现为静默空列表且无出路——
        // 现在把损坏文件搬到 .corrupt-<时间戳> 后重建空库（索引可从源 JSONL 完整重扫）。
        let p = NSTemporaryDirectory() + "cidx-corrupt-\(UUID().uuidString).sqlite"
        let dir = (p as NSString).deletingLastPathComponent
        let base = (p as NSString).lastPathComponent
        defer {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                where f.hasPrefix(base) {
                try? FileManager.default.removeItem(atPath: dir + "/" + f)
            }
        }
        try "this is not a sqlite database".write(toFile: p, atomically: true, encoding: .utf8)

        let idx = ConversationIndex.openRecoveringCorruption(path: p)
        XCTAssertNotNil(idx)
        XCTAssertEqual(idx?.summary().count, 0)   // 重建后是可用的空库
        // 损坏文件被搬走留档，而不是原地删除
        let moved = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .contains { $0.hasPrefix(base + ".corrupt-") } ?? false
        XCTAssertTrue(moved)
    }

    func testUpsertDuplicateIdDifferentPathSkipsCopyKeepsBatch() throws {
        // 用户 cp 备份过 jsonl：同一对话 id 出现在两个 file_path。
        // 曾经 UNIQUE(id) 冲突让整批回滚且被上游 try? 吞掉，同批其余对话陪葬；
        // 现在预查重跳过副本文件，其余照常入库。
        try index.upsert([row(lite("a", path: "/f/a"), segs("original body"), 100)])
        try index.upsert([
            row(lite("a", path: "/f/a-copy"), segs("copied body"), 150),
            row(lite("b", path: "/f/b"), segs("sibling survives"), 200),
        ])
        XCTAssertEqual(index.summary().count, 2)             // a(原) + b；副本被跳过
        XCTAssertEqual(index.knownMtimes()["/f/a"], 100)     // 原行未被副本覆盖
        XCTAssertNil(index.knownMtimes()["/f/a-copy"])
        XCTAssertEqual(index.search("sibling"), ["b"])       // 同批兄弟不再陪葬
    }

    /// title 列 round-trip：有则存取一致，无则 NULL → nil。
    func testUpsertPersistsTitle() throws {
        try index.upsert([
            row(lite("t1", title: "重构方案讨论", path: "/f/t1"), segs("body"), 100),
            row(lite("t2", path: "/f/t2"), segs("body"), 100),
        ])
        let metas = index.allMetadata()
        XCTAssertEqual(metas.first { $0.id == "t1" }?.title, "重构方案讨论")
        let t2 = try XCTUnwrap(metas.first { $0.id == "t2" })
        XCTAssertNil(t2.title)
    }

    /// replaceBrowserVault 此前漏写 search_text（现为 segments）：browser 对话的短词
    /// （<3 字，trigram 够不着）搜索命中永远是 0。长词（fts）与短词（segments LIKE）都要通。
    func testReplaceBrowserVaultWritesSearchTextForShortQueries() throws {
        let conv = Conversation(
            id: "browser-chatgpt/2026-05-29.jsonl#0", source: .browser,
            startAt: Date(), endAt: Date(), cwd: "browser-chatgpt", gitBranch: nil,
            messages: [Message(id: "m", role: .user, timestamp: Date(),
                               blocks: [.text("开头别的话……中间聊到了接力功能……结尾 redis migration")])])
        index.replaceBrowserVault([conv])
        XCTAssertEqual(index.search("接力"), [conv.id], "短词走 segments 表 LIKE 兜底")
        XCTAssertEqual(index.search("migration"), [conv.id], "长词走 fts trigram")
    }

    func testReplaceBrowserVaultSurvivesDistinctIdsAndIsolatesSource() throws {
        func browserConv(_ id: String, _ text: String) -> Conversation {
            Conversation(id: id, source: .browser, startAt: Date(), endAt: Date(),
                         cwd: "browser-x", gitBranch: nil,
                         messages: [Message(id: "m", role: .user, timestamp: Date(), blocks: [.text(text)])])
        }
        // 一条非 browser 行，replace 不应碰它
        try index.upsert([row(lite("keep", source: .claudeCode, path: "/f/keep"), segs("keep me"), 1)])
        // 同文件名不同 source（id 已 source 限定）→ 两条都存活，不触发 UNIQUE 回滚
        let c1 = browserConv("browser-chatgpt/2026-05-29.jsonl#0", "redis cluster migration")
        let c2 = browserConv("browser-claude/2026-05-29.jsonl#0", "postgres vector index")
        index.replaceBrowserVault([c1, c2])
        XCTAssertEqual(index.summary().count, 3)        // keep + c1 + c2
        XCTAssertEqual(index.search("redis"), [c1.id])
        XCTAssertEqual(index.search("postgres"), [c2.id])
        // 二次 replace 仅替换 browser 段，不累加、不碰 keep
        index.replaceBrowserVault([c1])
        XCTAssertEqual(index.summary().count, 2)        // keep + c1
        XCTAssertEqual(index.search("postgres"), [])
        XCTAssertNotNil(index.allMetadata().first { $0.id == "keep" })
    }
}
