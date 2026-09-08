import XCTest
@testable import MindBusCore

final class VaultArchiveTests: XCTestCase {

    /// 每个测试自带一个临时 vault 根——绝不碰真实 ~/.mindbus。
    private func makeRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("va-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeSourceFile(_ contents: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("va-src-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        try? Data(contents.utf8).write(to: file)
        return file
    }

    /// 归档覆盖三个本地工具源（「跨工具都保住」是产品承诺）；
    /// browser 源本身就是我们自己写的 vault，不重复归档。
    func testArchivesAllLocalToolSourcesButNotBrowser() {
        XCTAssertTrue(VaultArchive.shouldArchive(.claudeCode))
        XCTAssertTrue(VaultArchive.shouldArchive(.claudeAgent))
        XCTAssertTrue(VaultArchive.shouldArchive(.codex))
        XCTAssertFalse(VaultArchive.shouldArchive(.browser))
    }

    /// 路径必须确定（同源路径永远算出同一个归档位置，否则找不回来），
    /// 且要两级散列扇出，避免单目录堆几万文件。
    func testArchiveURLIsDeterministicAndFannedOut() {
        let root = makeRoot()
        let a = VaultArchive.archiveURL(forSourcePath: "/x/y/a.jsonl", root: root)
        let again = VaultArchive.archiveURL(forSourcePath: "/x/y/a.jsonl", root: root)
        let b = VaultArchive.archiveURL(forSourcePath: "/x/y/b.jsonl", root: root)
        XCTAssertEqual(a, again)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.pathExtension, "lzma")
        // 扇出目录名是 2 个 hex 字符
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent.count, 2)
        XCTAssertTrue(a.path.hasPrefix(root.path))
    }

    func testArchiveWritesCopyAndReportsPresence() throws {
        let root = makeRoot()
        let src = makeSourceFile("{\"a\":1}\n{\"a\":2}\n")
        XCTAssertFalse(VaultArchive.hasArchive(sourcePath: src.path, root: root))
        XCTAssertTrue(VaultArchive.archive(sourcePath: src.path, root: root))
        XCTAssertTrue(VaultArchive.hasArchive(sourcePath: src.path, root: root))
    }

    /// vault 的存在意义：源文件删了，内容还能逐字节拿回来。
    func testRestoredCopySurvivesSourceDeletion() throws {
        let root = makeRoot()
        let body = "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n"
        let src = makeSourceFile(body)
        XCTAssertTrue(VaultArchive.archive(sourcePath: src.path, root: root))
        try FileManager.default.removeItem(at: src)   // 模拟 30 天清理

        let restored: String? = VaultArchive.withRestoredCopy(sourcePath: src.path, root: root) { url in
            try? String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(restored, body)
    }

    /// 临时解压出来的文件必须用完即删，不能在 tmp 里堆垃圾。
    func testRestoredCopyIsCleanedUp() throws {
        let root = makeRoot()
        let src = makeSourceFile("{\"x\":1}\n")
        XCTAssertTrue(VaultArchive.archive(sourcePath: src.path, root: root))
        var seen: URL?
        _ = VaultArchive.withRestoredCopy(sourcePath: src.path, root: root) { url -> Bool? in
            seen = url
            return true
        }
        let path = try XCTUnwrap(seen).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testWithRestoredCopyReturnsNilWhenNoArchive() {
        let root = makeRoot()
        let value: Bool? = VaultArchive.withRestoredCopy(sourcePath: "/nope/none.jsonl", root: root) { _ in true }
        XCTAssertNil(value)
    }
}
