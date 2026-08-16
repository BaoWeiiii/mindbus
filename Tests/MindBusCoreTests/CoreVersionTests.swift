import XCTest
@testable import MindBusCore

final class CoreVersionTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(CoreVersion.current.isEmpty, "CoreVersion.current 不应为空")
        XCTAssertTrue(CoreVersion.current.contains("."), "版本号应包含点号")
    }
}
