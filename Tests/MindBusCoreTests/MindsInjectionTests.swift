import XCTest
@testable import MindBusCore

/// CLAUDE.md 受管分节写入。红线:用户自己写的内容一个字不碰——
/// 注入是标记内替换、移除只删标记段、半个标记宁可拒绝也不猜边界。
final class MindsInjectionTests: XCTestCase {

    private func tempFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "claude-md-\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testInjectCreatesFileWhenMissing() throws {
        let url = tempFile()
        XCTAssertTrue(MindsInjection.inject(content: "hello minds", into: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(MindsInjection.beginMarker))
        XCTAssertTrue(text.contains("hello minds"))
        XCTAssertTrue(text.contains(MindsInjection.endMarker))
    }

    /// 用户既有内容必须原样保留,分节追加在末尾。
    func testInjectAppendsWithoutTouchingUserContent() throws {
        let url = tempFile()
        try "# 我自己的规则\n\n永远用中文回复\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(MindsInjection.inject(content: "minds block", into: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# 我自己的规则\n\n永远用中文回复\n"),
                      "用户内容被动了")
        XCTAssertTrue(text.contains("minds block"))
    }

    /// 重复注入 = 幂等替换,不叠加第二段。
    func testReinjectReplacesExistingSection() throws {
        let url = tempFile()
        try "user top\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(MindsInjection.inject(content: "v1", into: url))
        XCTAssertTrue(MindsInjection.inject(content: "v2", into: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("v1"), "旧内容没被替换")
        XCTAssertTrue(text.contains("v2"))
        XCTAssertEqual(text.components(separatedBy: MindsInjection.beginMarker).count, 2,
                       "出现了第二段受管分节")
        XCTAssertTrue(text.hasPrefix("user top\n"))
    }

    /// 分节在用户内容**中间**时,替换不能吞掉分节之后的用户内容。
    func testReinjectPreservesUserContentAfterSection() throws {
        let url = tempFile()
        try "top\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(MindsInjection.inject(content: "v1", into: url))
        // 用户在分节后面又加了自己的内容
        var text = try String(contentsOf: url, encoding: .utf8)
        text += "\n# 分节之后我又写的\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(MindsInjection.inject(content: "v2", into: url))
        let final = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(final.contains("# 分节之后我又写的"), "分节后的用户内容被吞了")
        XCTAssertTrue(final.contains("v2"))
    }

    /// 半个标记(用户手改坏)= 边界不可信,拒绝写入且文件原样。
    func testHalfMarkerRefusesToWrite() throws {
        let url = tempFile()
        let broken = "top\n\(MindsInjection.beginMarker)\nno end marker here\n"
        try broken.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(MindsInjection.inject(content: "x", into: url),
                       "半个标记还敢写——可能吞掉用户内容")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken, "文件被动了")
    }

    func testRemoveDeletesOnlyTheSection() throws {
        let url = tempFile()
        try "top\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(MindsInjection.inject(content: "block", into: url))
        XCTAssertTrue(MindsInjection.remove(from: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(MindsInjection.beginMarker))
        XCTAssertFalse(text.contains("block"))
        XCTAssertTrue(text.contains("top"), "用户内容被连坐删了")
    }

    func testHasSectionReflectsState() throws {
        let url = tempFile()
        XCTAssertFalse(MindsInjection.hasSection(at: url))
        _ = MindsInjection.inject(content: "x", into: url)
        XCTAssertTrue(MindsInjection.hasSection(at: url))
        _ = MindsInjection.remove(from: url)
        XCTAssertFalse(MindsInjection.hasSection(at: url))
    }
}
