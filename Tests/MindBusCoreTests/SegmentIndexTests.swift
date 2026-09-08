import XCTest
@testable import MindBusCore

final class SegmentIndexTests: XCTestCase {

    private func makeIndex() throws -> ConversationIndex {
        let path = NSTemporaryDirectory() + "segidx-\(UUID().uuidString).sqlite"
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

    private func seg(_ text: String, _ first: Int = 0, _ last: Int = 1) -> Segmenter.Segment {
        Segmenter.Segment(firstMessageIndex: first, lastMessageIndex: last, text: text)
    }

    /// upsert 现在多要一个 entityText 字段（实体抽取改用排除 `.toolUse` 的专用口径，
    /// 见 `Segmenter.entityText`）。这里的测试文本都不含 toolUse 结构，直接复用段文字
    /// 拼接即可——与旧口径等价，不改变任何既有断言的语义。
    private func row(_ l: ConversationLite, _ segs: [Segmenter.Segment], _ mtime: Double)
        -> (lite: ConversationLite, segments: [Segmenter.Segment], mtime: Double, entityText: String) {
        (l, segs, mtime, segs.map(\.text).joined(separator: "\n"))
    }

    /// 段写进去就该搜得到，且能定位回它所属的会话。
    func testSearchFindsConversationBySegmentText() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("Sparkle 自动更新怎么配")], 1)])
        XCTAssertEqual(index.search("Sparkle"), ["c1"])
    }

    /// 短词（<3 字）trigram 索引够不着，要有 LIKE 兜底——段的 text 存着就是为了这个。
    func testShortQueryFallsBackToLike() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("修 UI 的问题")], 1)])
        XCTAssertEqual(index.search("UI"), ["c1"])
    }

    /// 会话被 prune 掉时它的段必须一起消失，否则会搜出已删会话的幽灵结果。
    func testPruneRemovesSegments() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("孤儿段落 Sparkle")], 1)])
        index.prune(missingPaths: ["/tmp/c1.jsonl"])
        XCTAssertTrue(index.search("Sparkle").isEmpty, "会话删了段还在——会搜出幽灵结果")
        XCTAssertEqual(index.segmentCount(), 0)
    }

    /// 同一会话重新入库（源文件变化后重扫）时，旧段必须被换掉而不是叠加。
    func testUpsertReplacesOldSegments() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [seg("旧内容 Sparkle")], 1)])
        try index.upsert([row(lite("c1"), [seg("新内容 Sparkle")], 2)])
        XCTAssertEqual(index.segmentCount(), 1, "旧段没被换掉，段会随每次重扫翻倍")
        XCTAssertTrue(index.searchWithHits("Sparkle")[0].bestSegmentText.contains("新内容"))
    }

    /// 段级排序的意义：命中集中在某一段的会话，应排在「命中被整场对话稀释」的会话前面。
    /// 这正是会话级索引 R@1 只有 5.2% 的原因——命中词被整场对话淹没。
    func testSegmentLevelRankingBeatsDilutedConversation() throws {
        let index = try makeIndex()
        let noise = String(repeating: "无关内容 ", count: 400)
        try index.upsert([
            row(lite("c_focused"), [seg("EdDSA 私钥放在 Actions secret")], 1),
            row(lite("c_diluted"), [seg(noise + " EdDSA " + noise)], 1),
        ])
        let hits = index.search("EdDSA")
        XCTAssertEqual(hits.first, "c_focused", "段级 BM25 应让命中集中的会话排前")
        XCTAssertEqual(hits.count, 2)
    }

    /// 同一会话多段命中要合并成一条结果，并报出命中段数与最佳段的消息位置
    /// （GUI 显示「命中 N 处」、点击跳转到那条消息都靠它）。
    func testAggregatesMultipleSegmentHitsWithCountAndPosition() throws {
        let index = try makeIndex()
        try index.upsert([row(lite("c1"), [
            seg("第一次提到 Sparkle", 0, 1),
            seg("后面又提到 Sparkle", 2, 3),
            seg("这段没有关键词", 4, 5),
        ], 1)])
        let hits = index.searchWithHits("Sparkle")
        XCTAssertEqual(hits.count, 1, "同一会话的多段命中要折叠成一条")
        XCTAssertEqual(hits[0].id, "c1")
        XCTAssertEqual(hits[0].segmentHitCount, 2, "三段里两段命中")
        XCTAssertTrue(hits[0].bestSegmentText.contains("Sparkle"))
        let pos = try XCTUnwrap(hits[0].bestSegmentFirstMessageIndex)
        XCTAssertTrue(pos == 0 || pos == 2, "最佳段的首条消息下标应是两个命中段之一")
    }

    /// 修复：`search()` 为省掉按键级的原文物化，给底层 SQL 加了 `includeText` 开关
    /// （false 时不取 `s.text`）；`searchWithHits()` 仍要真原文。这条开关只该影响
    /// text 列，不能连带影响命中了哪些会话、排序如何——覆盖 FTS 双路与 LIKE 兜底
    /// 两条路径，钉住「两条路径不许分叉」这个不变量。
    func testSearchAndSearchWithHitsAgreeOnIdsAndOrder() throws {
        let index = try makeIndex()
        let noise = String(repeating: "无关内容 ", count: 400)
        try index.upsert([
            row(lite("c_focused"), [seg("EdDSA 私钥放在 Actions secret")], 1),
            row(lite("c_diluted"), [seg(noise + " EdDSA " + noise)], 1),
            row(lite("c_other"), [seg("完全不相关的内容")], 1),
        ])
        // FTS 路径（≥3 字符，走双路 BM25 + RRF）
        let ftsViaSearch = index.search("EdDSA")
        XCTAssertEqual(ftsViaSearch, index.searchWithHits("EdDSA").map(\.id))
        XCTAssertFalse(ftsViaSearch.isEmpty)

        // LIKE 兜底路径（<3 字符，trigram 索引够不着）
        try index.upsert([row(lite("c_short"), [seg("修 UI 的问题")], 1)])
        let likeViaSearch = index.search("UI")
        XCTAssertEqual(likeViaSearch, index.searchWithHits("UI").map(\.id))
        XCTAssertFalse(likeViaSearch.isEmpty)
    }

    /// 修复：命中预览必须在 SQL 侧用 substr 限长，不能把巨长段原文整段吐给调用方——
    /// 段的软上限是 `Segmenter.maxCharsPerSegment`=4000，但单条巨长消息能撑出远超
    /// 这个数字的段（最坏到 `Segmenter.hardTextCap`=200,000）。命中面广的查询一次
    /// 命中成百上千段时，不截断就是按键级的内存/CPU 抖动。
    func testBestSegmentTextTruncatedTo4000Chars() throws {
        let index = try makeIndex()
        let huge = String(repeating: "长文 Sparkle 段落内容 ", count: 1000)
        XCTAssertGreaterThan(huge.count, 4000)
        try index.upsert([row(lite("c1"), [seg(huge)], 1)])
        let hits = index.searchWithHits("Sparkle")
        XCTAssertEqual(hits.count, 1)
        XCTAssertLessThanOrEqual(hits[0].bestSegmentText.count, 4000,
                                  "命中预览必须在 SQL 侧截断，不能把巨长段原文整段吐给调用方")
    }
}
