import XCTest
@testable import MindBusCore

/// 文件夹别名:改名过的项目,历史会话标签合流到新名。
final class FolderAliasStoreTests: XCTestCase {

    private func makeStore() -> (FolderAliasStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "alias-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (FolderAliasStore(fileURL: url), url)
    }

    func testResolvePassthroughWithoutAlias() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.resolve("OldName"), "OldName")
    }

    func testSetAliasResolvesAndPersists() {
        let (store, url) = makeStore()
        store.set(alias: "NewName", for: "OldName")
        XCTAssertEqual(store.resolve("OldName"), "NewName")
        // 重新加载(模拟重启)仍在——跨启动稳定是这功能存在的意义
        let reloaded = FolderAliasStore(fileURL: url)
        XCTAssertEqual(reloaded.resolve("OldName"), "NewName")
    }

    /// 同别名合流:两个旧名都指向新名 → 同键 → 同色。
    func testTwoOldKeysCanMergeIntoOneName() {
        let (store, _) = makeStore()
        store.set(alias: "Project", for: "project-v1")
        store.set(alias: "Project", for: "project_old")
        XCTAssertEqual(store.resolve("project-v1"), store.resolve("project_old"))
    }

    func testEmptyOrSameNameRemovesAlias() {
        let (store, url) = makeStore()
        store.set(alias: "New", for: "Old")
        store.set(alias: "  ", for: "Old")
        XCTAssertEqual(store.resolve("Old"), "Old", "空白应撤销别名")
        store.set(alias: "New", for: "Old")
        store.set(alias: "Old", for: "Old")
        XCTAssertEqual(FolderAliasStore(fileURL: url).resolve("Old"), "Old",
                       "改回原名应撤销别名且落盘")
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "alias-bad-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF, 0x00, 0x7B]).write(to: url)
        let store = FolderAliasStore(fileURL: url)
        XCTAssertEqual(store.resolve("X"), "X", "坏文件不该炸,退回空表")
    }
}
