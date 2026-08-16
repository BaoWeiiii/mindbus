import XCTest
@testable import MindBusCore

/// 思脉底座 · GUI 数据接口：`MindsStore` 合并 `minds.md` 机械层与 `enriched.jsonl`
/// 增补层，供 Minds 侧栏消费。
///
/// 架构红线：直接向 `init(mindsURL:logURL:)` 注入临时 URL（同 `MindsEnrichedLogTests`
/// 的既有隔离手法——`MindsEnrichedLog` 的每个公开函数都接受显式 `url`/`to` 参数），
/// 不依赖 `MINDBUS_MINDS_ROOT` 环境变量，绝不碰真实 `~/.mindbus`。
@MainActor
final class MindsStoreTests: XCTestCase {
    private var mindsURL: URL!
    private var logURL: URL!

    override func setUpWithError() throws {
        let root = NSTemporaryDirectory() + "minds-store-\(UUID().uuidString)"
        mindsURL = URL(fileURLWithPath: root + "/minds.md")
        logURL = URL(fileURLWithPath: root + "/enriched.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: mindsURL.deletingLastPathComponent())
    }

    private func makeStore() -> MindsStore {
        MindsStore(mindsURL: mindsURL, logURL: logURL)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    // MARK: - 缺文件不崩空态

    func testReloadWithMissingFilesYieldsEmptyState() {
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.mechanicalMarkdown, "")
        XCTAssertTrue(store.entriesBySpot.isEmpty)
    }

    /// enriched.jsonl 有内容但 minds.md 还没被扫描建出来（用户装完 App 还没扫过一轮，
    /// 但已经用 MCP 补了条目）：mechanicalMarkdown 空串，entriesBySpot 仍应正常读出——
    /// 两个状态相互独立，不该因为一份文件缺失就把另一份也清空。
    func testReloadWithOnlyLogFilePresentPopulatesEntriesButNotMarkdown() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "goal-a", sources: ["c1"], agent: "a", to: logURL))
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.mechanicalMarkdown, "")
        XCTAssertEqual(store.entriesBySpot[.goals]?.map(\.id), [id])
    }

    // MARK: - mechanicalMarkdown 按标记切分

    func testReloadSplitsAtWeakSpotsMarkerAndDropsWeakSpotsSection() throws {
        let content = "MECHANICAL-FIVE-SECTIONS\n\n\(MindsBuilder.weakSpotsMarker)\nSTALE-WEAK-SPOTS-TEXT"
        try write(content, to: mindsURL)
        let store = makeStore()
        store.reload()
        XCTAssertTrue(store.mechanicalMarkdown.contains("MECHANICAL-FIVE-SECTIONS"))
        XCTAssertFalse(store.mechanicalMarkdown.contains("STALE-WEAK-SPOTS-TEXT"),
                       "标记之后的内容属于 WEAK SPOTS，不该出现在 mechanicalMarkdown 里")
    }

    /// 旧版本遗留文件 / 被用户手改删掉了标记行：找不到标记就整文件当机械层交出去，
    /// 同 `MindsReadTool.merge` 的降级手法——不报错、不崩在 range(of:) 上。
    func testReloadWithoutMarkerKeepsWholeFileAsMechanicalMarkdown() throws {
        let content = "no marker in this hand-edited file"
        try write(content, to: mindsURL)
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.mechanicalMarkdown, content)
    }

    // MARK: - entriesBySpot 三态分组：unreviewed/confirmed 保留，revoked 被滤

    func testReloadGroupsByspotAndExcludesRevokedEntries() throws {
        let unreviewedID = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "goal-a", sources: ["c1"], agent: "a", to: logURL))
        let confirmedID = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .goals, text: "goal-b", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendConfirm(target: confirmedID, to: logURL)
        let revokedID = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .style, text: "style-a", sources: ["c1"], agent: "a", to: logURL))
        MindsEnrichedLog.appendRevoke(target: revokedID, to: logURL)

        let store = makeStore()
        store.reload()

        let goals = store.entriesBySpot[.goals] ?? []
        XCTAssertEqual(Set(goals.map(\.id)), Set([unreviewedID, confirmedID]))
        XCTAssertEqual(goals.first { $0.id == unreviewedID }?.status, .unreviewed)
        XCTAssertEqual(goals.first { $0.id == confirmedID }?.status, .confirmed)

        XCTAssertTrue((store.entriesBySpot[.style] ?? []).isEmpty,
                      "唯一的 spot:style 条目已被 revoke，分组里不该再出现")
    }

    // MARK: - confirm/revoke 动作后状态流转

    func testConfirmMovesEntryToConfirmedAndPersists() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .preferences, text: "p", sources: ["c1"], agent: "a", to: logURL))
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.entriesBySpot[.preferences]?.first?.status, .unreviewed)

        store.confirm(entryID: id)
        XCTAssertEqual(store.entriesBySpot[.preferences]?.first?.status, .confirmed,
                       "confirm 内部已调用 reload，状态流转应立即对 GUI 可见")

        // 底层文件确实落了一条 confirm 记录——不是只改了内存状态。
        let raw = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(raw.first { $0.id == id }?.status, .confirmed)
    }

    func testRevokeRemovesEntryFromEntriesBySpotButKeepsUnderlyingRecord() throws {
        let id = try XCTUnwrap(MindsEnrichedLog.appendEnrich(
            spot: .stack, text: "s", sources: ["c1"], agent: "a", to: logURL))
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.entriesBySpot[.stack]?.count, 1)

        store.revoke(entryID: id)
        XCTAssertTrue((store.entriesBySpot[.stack] ?? []).isEmpty,
                      "GUI 撤销后条目应立即从 entriesBySpot 消失")

        // 底层记录仍在——revoke 是 append 一条新记录，不是物理删改。
        let raw = MindsEnrichedLog.entries(from: logURL)
        XCTAssertEqual(raw.first { $0.id == id }?.status, .revoked)
    }

    /// revoke 一个从未出现过的 id：`MindsEnrichedLog` 的既有合并规则是静默忽略未知
    /// target，`MindsStore` 不该在这层加额外校验或崩溃——append 一条没人认领的 revoke
    /// 记录，reload 之后状态照常（空态不炸）。
    func testRevokeUnknownEntryIDDoesNotCrash() {
        let store = makeStore()
        store.reload()
        store.revoke(entryID: "never-existed")
        XCTAssertTrue(store.entriesBySpot.isEmpty)
    }
}
