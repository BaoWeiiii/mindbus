import XCTest
@testable import MindBusCore

/// 思脉底座 · GUI 数据接口：`MindsStore` 读 `minds.md` 机械层供 Minds 侧栏消费。
/// 增补层（enriched.jsonl / entriesBySpot / confirm / revoke）已整体拆除
/// （用户 2026-09-01 定案：不要例外），仅剩的加工是截掉旧版本文件遗留的
/// WEAK SPOTS 节。
///
/// 架构红线：直接向 `init(mindsURL:)` 注入临时 URL，不依赖 `MINDBUS_MINDS_ROOT`
/// 环境变量，绝不碰真实 `~/.mindbus`。
@MainActor
final class MindsStoreTests: XCTestCase {
    private var mindsURL: URL!

    override func setUpWithError() throws {
        let root = NSTemporaryDirectory() + "minds-store-\(UUID().uuidString)"
        mindsURL = URL(fileURLWithPath: root + "/minds.md")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: mindsURL.deletingLastPathComponent())
    }

    private func makeStore() -> MindsStore {
        MindsStore(mindsURL: mindsURL)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    // MARK: - 缺文件不崩空态

    func testReloadWithMissingFileYieldsEmptyState() {
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.mechanicalMarkdown, "")
    }

    // MARK: - 常规文件原样交出

    func testReloadKeepsWholeFileAsMechanicalMarkdown() throws {
        let content = "# Minds — mechanical self-description\n## OVERVIEW\nplain mechanical text"
        try write(content, to: mindsURL)
        let store = makeStore()
        store.reload()
        XCTAssertEqual(store.mechanicalMarkdown, content)
    }

    // MARK: - 旧文件遗留 WEAK SPOTS 的截断

    /// 装上新版后、下一轮扫描重写 minds.md 之前的窗口期：旧文件里拆除前模型写入的
    /// WEAK SPOTS 条目必须被截掉，不以"机械层"的名义混进界面。
    func testReloadStripsLegacyWeakSpotsSection() throws {
        let content = "MECHANICAL-FIVE-SECTIONS\n\n\(MindsBuilder.legacyWeakSpotsMarker)\n## WEAK SPOTS\n- [unreviewed] MODEL-WRITTEN"
        try write(content, to: mindsURL)
        let store = makeStore()
        store.reload()
        XCTAssertTrue(store.mechanicalMarkdown.contains("MECHANICAL-FIVE-SECTIONS"))
        XCTAssertFalse(store.mechanicalMarkdown.contains("MODEL-WRITTEN"),
                       "拆除前模型写入的条目不该出现在 mechanicalMarkdown 里")
    }
}
