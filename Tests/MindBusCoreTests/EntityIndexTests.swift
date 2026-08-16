import XCTest
@testable import MindBusCore

final class EntityIndexTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "entidx-\(UUID().uuidString).sqlite"
        addTeardownBlock {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
        }
        return try ConversationIndex(path: path)
    }

    private func lite(_ id: String) -> ConversationLite {
        ConversationLite(id: id, source: .claudeCode, startAt: Date(), endAt: Date(),
                         cwd: "/tmp", gitBranch: nil, preview: "p", messageCount: 2,
                         fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    private func seg(_ text: String) -> Segmenter.Segment {
        Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 1, text: text)
    }

    /// upsert 现在多要一个 entityText 字段（实体抽取改用排除 `.toolUse` 的专用口径，
    /// 见 `Segmenter.entityText`）。这里的测试文本都不含 toolUse 结构，直接复用段文字
    /// 拼接即可——与旧口径等价，不改变任何既有断言的语义。
    private func row(_ l: ConversationLite, _ segs: [Segmenter.Segment], _ mtime: Double)
        -> (lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String) {
        (l, segs, mtime, segs.map(\.text).joined(separator: "\n"))
    }

    func testEntitiesAreExtractedOnUpsert() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("改 MindBus/Core/Search/Segmenter.swift 里的 VaultArchive")], 1)])
        let top = index.topEntities(limit: 10).map(\.text)
        XCTAssertTrue(top.contains("MindBus/Core/Search/Segmenter.swift"))
        XCTAssertTrue(top.contains("VaultArchive"))
    }

    /// 同一实体在一个会话里出现多次，只算一个会话——计数口径是「出现在几个会话」。
    func testEntityCountIsPerConversationNotPerMention() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("VaultArchive VaultArchive VaultArchive")], 1)])
        let stat = try XCTUnwrap(index.topEntities(limit: 10).first { $0.text == "VaultArchive" })
        XCTAssertEqual(stat.conversationCount, 1)
    }

    func testTopEntitiesRanksByConversationCount() throws {
        let index = try makeIndex()
        try index.upsert([
            row(lite("c1"), [seg("聊 VaultArchive 和 Segmenter 的事")], 1),
            row(lite("c2"), [seg("又聊 VaultArchive")], 1),
        ])
        XCTAssertEqual(index.topEntities(limit: 1).first?.text, "VaultArchive")
        XCTAssertEqual(index.topEntities(limit: 1).first?.conversationCount, 2)
    }

    func testConversationsWithEntity() throws {
        let index = try makeIndex()
        try index.upsert([
            row(lite("c1"), [seg("提到 VaultArchive")], 1),
            row(lite("c2"), [seg("只提到 Segmenter")], 1),
        ])
        XCTAssertEqual(index.conversations(withEntity: "VaultArchive"), ["c1"])
    }

    /// 共现：同一会话里一起出现过的实体，是「想不起关键词时顺着找」的主力线索。
    func testCoOccurringEntities() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("VaultArchive 和 ArchiveCodec 一起改")], 1)])
        let co = index.coOccurring(with: "VaultArchive", limit: 10).map(\.text)
        XCTAssertTrue(co.contains("ArchiveCodec"))
        XCTAssertFalse(co.contains("VaultArchive"), "共现结果不该包含它自己")
    }

    /// 样板实体（出现在超过一半会话里）不该进导航推荐——这是通用区分度兜底，
    /// 跟实体是不是「样板词」无关（见 `documentFrequencyCeiling` 注释）。这里用
    /// file_path 只是构造一个 DF 达到 100% 的例子来验证阈值机制本身；实测 Claude Code
    /// 真实工具参数名的 DF 最高只有 21%，够不到这条阈值——真正挡住它们的是抽取侧
    /// 跳过 .toolUse（v11），不是这条阈值。但用户主动点它时仍要老实给结果。
    func testBoilerplateEntitiesSuppressedFromTopButStillQueryable() throws {
        let index = try makeIndex()
        // file_path 出现在全部 3 个会话（100% > 50% 上限）；VaultArchive 只在 1 个
        try index.upsert([
            row(lite("c1"), [seg("改 file_path 参数，顺便看 VaultArchive")], 1),
            row(lite("c2"), [seg("又是 file_path")], 1),
            row(lite("c3"), [seg("还是 file_path")], 1),
        ])
        let top = index.topEntities(limit: 10).map(\.text)
        XCTAssertFalse(top.contains("file_path"), "样板实体不该进导航推荐")
        XCTAssertTrue(top.contains("VaultArchive"))
        XCTAssertEqual(index.conversations(withEntity: "file_path").count, 3,
                       "用户主动点高频实体时仍要给全部结果")
    }

    /// 会话被删时实体关联必须连带清掉，否则实体页会指向已不存在的会话。
    func testPruneRemovesEntityLinks() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("提到 VaultArchive")], 1)])
        index.prune(missingPaths: ["/tmp/c1.jsonl"])
        XCTAssertTrue(index.conversations(withEntity: "VaultArchive").isEmpty)
        XCTAssertTrue(index.topEntities(limit: 10).isEmpty, "零引用实体不该出现在 Top 里")
    }

    /// 重新入库（源文件变化后重扫）时旧实体关联要被换掉，不是叠加。
    func testUpsertReplacesEntityLinks() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("提到 VaultArchive")], 1)])
        try index.upsert([row(lite("c1"), [seg("改成提到 ArchiveCodec")], 2)])
        XCTAssertTrue(index.conversations(withEntity: "VaultArchive").isEmpty,
                      "旧实体关联没被换掉")
        XCTAssertEqual(index.conversations(withEntity: "ArchiveCodec"), ["c1"])
    }

    /// 回归：重入库时必须按**旧** rowid 删实体关联。
    ///
    /// SQLite 无 AUTOINCREMENT 时新 rowid = 表内最大 rowid+1，多会话库里重入库拿到的
    /// 新号几乎必然不等于旧号；只按新号删会让旧号的关联变成孤儿，直接触发哨兵。
    /// 单会话库测不出这个——删空后 rowid 复用巧合会让新号退化成原号，两种实现都绿。
    func testUpsertDeletesEntityLinksByOldRowidInMultiConversationIndex() throws {
        let index = try makeIndex()
        try index.upsert([
            row(lite("c1"), [seg("提到 VaultArchive")], 1),
            row(lite("c2"), [seg("提到 ArchiveCodec")], 1),
        ])
        // 重入库 c1（此时新 rowid 必然 != 旧 rowid）
        try index.upsert([row(lite("c1"), [seg("改成提到 SegmentIndex")], 2)])
        // topEntities 不 JOIN conversations，孤儿关联会被它数出来——正好当探针
        let top = index.topEntities(limit: 20).map(\.text)
        XCTAssertFalse(top.contains("VaultArchive"), "旧实体关联成了孤儿（没按旧 rowid 删）")
        XCTAssertTrue(top.contains("SegmentIndex"))
        XCTAssertTrue(top.contains("ArchiveCodec"), "不该连累另一个会话")
    }

    /// 回归：实体表必须只反映 entityText 口径，不能退回段文本拼接。
    ///
    /// 本分支的治本改法是「抽实体时跳过 .toolUse」，靠 upsert 的 entityText 字段传下来。
    /// 但此前所有测试里 entityText 都由段文本派生、两者永远同值，于是把生产接线改回
    /// 段口径，312 条测试照样全绿——最核心的那根钉子毫无保护。这里让两者故意不同。
    func testEntityTableReflectsEntityTextNotSegmentText() throws {
        let index = try makeIndex()
        try index.upsert([(
            lite: lite("c1"),
            segments: [Segmenter.Segment(firstMessageIndex: 0, lastMessageIndex: 0,
                                          text: "段文本里有 OnlyInSegments 这个标识符")],
            mtime: 1,
            entityText: "实体文本里只有 OnlyInEntityText 这个标识符"
        )])
        let all = index.topEntities(limit: 20).map(\.text)
        XCTAssertTrue(all.contains("OnlyInEntityText"), "实体没按 entityText 口径抽")
        XCTAssertFalse(all.contains("OnlyInSegments"), "实体退回按段文本抽了——治本接线被绕开")
    }

    /// L0 地图：一眼看清「我这两年在聊什么」——按工具、项目、月份三个正交切面。
    func testMapOverviewAggregatesFacets() throws {
        let index = try makeIndex()
        func liteAt(_ id: String, _ source: ConversationSource, _ cwd: String, _ iso: String) -> ConversationLite {
            let f = ISO8601DateFormatter()
            let d = f.date(from: iso)!
            return ConversationLite(id: id, source: source, startAt: d, endAt: d,
                                    cwd: cwd, gitBranch: nil, preview: "p", messageCount: 1,
                                    fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
        }
        // 时间戳特意选在月中（15/16 号），而不是贴月界——mapOverview 按 'localtime' 切月
        // 是产品要的行为（本地日历月），但测试本身要跟时区解耦：贴月界的时间戳换个时区
        // 就可能被切进相邻月份，OSS 仓贡献者的机器时区不可控（实测 TZ=Pacific/Pago_Pago
        // 下贴月界的写法会变红）。月中 ±14 小时的极端时区偏移也不会跨出当月。
        try index.upsert([
            row(liteAt("a", .claudeCode, "/dev/mindbus", "2026-07-15T10:00:00Z"), [seg("聊 VaultArchive")], 1),
            row(liteAt("b", .claudeCode, "/dev/mindbus", "2026-08-15T10:00:00Z"), [seg("又聊 VaultArchive")], 1),
            row(liteAt("c", .codex, "/dev/other", "2026-08-16T10:00:00Z"), [seg("别的事 Segmenter")], 1),
        ])

        let m = index.mapOverview()
        XCTAssertEqual(m.conversationCount, 3)
        XCTAssertEqual(m.bySource.first?.key, ConversationSource.claudeCode.rawValue)
        XCTAssertEqual(m.bySource.first?.count, 2)
        XCTAssertEqual(m.byProject.first?.key, "/dev/mindbus")
        XCTAssertEqual(m.byProject.first?.count, 2)
        XCTAssertEqual(m.byMonth.map(\.key), ["2026-07", "2026-08"], "月份应按时间升序")
        XCTAssertEqual(m.byMonth.last?.count, 2)
        XCTAssertEqual(m.topEntities.first?.text, "VaultArchive")
    }

    /// 空库不该崩，也不该给出假数据——这是「空结果返回地图节选」那条设计的前提。
    func testMapOverviewOnEmptyIndex() throws {
        let index = try makeIndex()
        let m = index.mapOverview()
        XCTAssertEqual(m.conversationCount, 0)
        XCTAssertNil(m.earliest)
        XCTAssertTrue(m.bySource.isEmpty)
        XCTAssertTrue(m.topEntities.isEmpty)
    }
}
