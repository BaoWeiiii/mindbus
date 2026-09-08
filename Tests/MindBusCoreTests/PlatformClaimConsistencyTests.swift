import XCTest

/// 对外宣称的最低系统版本必须只有一个来源。issue #3 之后的复盘：README 写着 macOS 13，
/// 而索引 schema 要求的 SQLite 3.43 直到 macOS 14 才自带——「宣称」与「实际」各说各的，
/// 没有任何东西把它们钉在一起。这里把 Info.plist、Package.swift、两份 README、
/// CONTRIBUTING 钉成一个数。
final class PlatformClaimConsistencyTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MindBusCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    private func text(_ rel: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func testMinimumSystemVersionIsDeclaredConsistently() throws {
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: root.appendingPathComponent("Info.plist")) as? [String: Any])
        let minimum = try XCTUnwrap(plist["LSMinimumSystemVersion"] as? String)   // 例如 "14.0"
        let major = try XCTUnwrap(minimum.split(separator: ".").first)

        XCTAssertTrue(try text("Package.swift").contains(".macOS(.v\(major))"),
                      "Package.swift 的 platforms 与 Info.plist 不一致")
        for readme in ["README.md", "README.en.md"] {
            let src = try text(readme)
            XCTAssertTrue(src.contains("macOS-\(minimum)+"), "\(readme) 徽章未更新到 \(minimum)")
            XCTAssertTrue(src.contains("macOS \(minimum)"), "\(readme) 安装说明未更新到 \(minimum)")
            XCTAssertFalse(src.contains("macOS 13.0"), "\(readme) 仍在承诺 macOS 13.0")
        }
        XCTAssertFalse(try text("CONTRIBUTING.md").contains("macOS 13.0"), "CONTRIBUTING 仍写着 macOS 13.0")
    }
}
