import XCTest
@testable import MindBusCore

/// 索引 schema 的三张 FTS5 表都用 `contentless_delete=1`，这个选项 SQLite 3.43.0（2023-08-24）
/// 才有。系统自带的 SQLite 低于它时建表直接报 `unrecognized option`——此前的后果是
/// `ConversationIndex.shared` 为 nil、App 静默停在空库欢迎页、每次启动还把刚建的空库当
/// 损坏件挪走。门槛必须显式判、失败必须出声。
final class SQLiteVersionGuardTests: XCTestCase {

    func testRequiredVersionIsContentlessDeleteBaseline() {
        XCTAssertEqual(SQLiteDB.requiredLibVersionNumber, 3_043_000)
    }

    func testVersionsBelowBaselineAreRejected() {
        XCTAssertFalse(SQLiteDB.libVersionIsSupported(3_039_005), "macOS 13 自带 3.39.5")
        XCTAssertFalse(SQLiteDB.libVersionIsSupported(3_042_000))
        XCTAssertTrue(SQLiteDB.libVersionIsSupported(3_043_000))
        XCTAssertTrue(SQLiteDB.libVersionIsSupported(3_043_002), "Sonoma 14.7.4 实测 3.43.2")
        XCTAssertTrue(SQLiteDB.libVersionIsSupported(3_051_000))
    }

    /// 开发机 / CI 自身必须满足门槛，否则整套 FTS 测试都在骗人
    func testThisMachineMeetsBaseline() {
        XCTAssertTrue(SQLiteDB.libVersionIsSupported(), "本机 SQLite \(SQLiteDB.libVersion)")
        XCTAssertFalse(SQLiteDB.libVersion.isEmpty)
    }

    /// 门槛判定的失败形态：不建库、不挪文件、返回 nil。
    /// 用注入的假版本号验证，不依赖本机 SQLite。
    func testOpeningIsRefusedWithoutTouchingDiskWhenLibraryTooOld() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.sqlite").path

        XCTAssertNil(ConversationIndex.openIfLibrarySupported(path: path, libVersionNumber: 3_039_005))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "版本不够时不该留下任何文件（含 .corrupt-*）")

        XCTAssertNotNil(ConversationIndex.openIfLibrarySupported(path: path, libVersionNumber: 3_043_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
