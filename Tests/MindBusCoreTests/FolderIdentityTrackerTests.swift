import XCTest
@testable import MindBusCore

/// inode 改名追踪:真实建目录、真实 rename,验证自动别名。
final class FolderIdentityTrackerTests: XCTestCase {

    private func makeEnv() -> (root: URL, store: URL, alias: FolderAliasStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "fid-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("identity.json")
        let aliasURL = root.appendingPathComponent("aliases.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, store, FolderAliasStore(fileURL: aliasURL))
    }

    /// 核心链路:记录 → 真实改名 → 再追踪 → 自动别名出现。
    func testRenameIsDetectedAndAliased() throws {
        let (root, store, alias) = makeEnv()
        let old = root.appendingPathComponent("OldProject")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)

        // 第一轮:记录身份
        var renames = FolderIdentityTracker.track(cwds: [old.path], storeURL: store, aliasStore: alias)
        XCTAssertTrue(renames.isEmpty, "首轮只记录,不该有改名")

        // 真实 rename(inode 不变)
        let new = root.appendingPathComponent("NewProject")
        try FileManager.default.moveItem(at: old, to: new)

        // 第二轮:新会话的 cwd 已是新路径
        renames = FolderIdentityTracker.track(cwds: [new.path], storeURL: store, aliasStore: alias)
        XCTAssertEqual(renames.count, 1)
        XCTAssertEqual(renames.first?.old, "OldProject")
        XCTAssertEqual(renames.first?.new, "NewProject")
        // 历史会话(旧尾名)从此解析到新名——标签合流
        XCTAssertEqual(alias.resolve("OldProject"), "NewProject")
    }

    /// 人工优先:用户已给旧名设过别名,自动机制不覆盖。
    func testManualAliasIsNeverOverwritten() throws {
        let (root, store, alias) = makeEnv()
        let old = root.appendingPathComponent("Proj")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        _ = FolderIdentityTracker.track(cwds: [old.path], storeURL: store, aliasStore: alias)

        alias.set(alias: "我手动定的名字", for: "Proj")   // 人工先行
        let new = root.appendingPathComponent("ProjRenamed")
        try FileManager.default.moveItem(at: old, to: new)

        let renames = FolderIdentityTracker.track(cwds: [new.path], storeURL: store, aliasStore: alias)
        XCTAssertTrue(renames.isEmpty, "人工设过的键不该被自动改名覆盖")
        XCTAssertEqual(alias.resolve("Proj"), "我手动定的名字")
    }

    /// 未改名的目录:多轮追踪零别名、零噪声。
    func testStableDirectoryProducesNothing() throws {
        let (root, store, alias) = makeEnv()
        let dir = root.appendingPathComponent("Stable")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<3 {
            XCTAssertTrue(FolderIdentityTracker.track(
                cwds: [dir.path], storeURL: store, aliasStore: alias).isEmpty)
        }
        XCTAssertNil(alias.alias(for: "Stable"))
    }

    /// 已消失且无身份记录的 cwd(历史死路径):静默跳过,不炸。
    func testDeadPathWithoutHistoryIsSkipped() {
        let (root, store, alias) = makeEnv()
        let renames = FolderIdentityTracker.track(
            cwds: [root.appendingPathComponent("never-existed").path],
            storeURL: store, aliasStore: alias)
        XCTAssertTrue(renames.isEmpty)
    }

    /// 只挪位置尾名不变(~/a/App → ~/b/App):不产别名(名字没变,无需合流)。
    func testMoveWithSameNameProducesNoAlias() throws {
        let (root, store, alias) = makeEnv()
        let a = root.appendingPathComponent("a/App")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        _ = FolderIdentityTracker.track(cwds: [a.path], storeURL: store, aliasStore: alias)
        let b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let moved = b.appendingPathComponent("App")
        try FileManager.default.moveItem(at: a, to: moved)
        let renames = FolderIdentityTracker.track(cwds: [moved.path], storeURL: store, aliasStore: alias)
        XCTAssertTrue(renames.isEmpty, "尾名未变不需要别名")
    }
}
