import XCTest
@testable import MindBusCore

/// 复制范围两态模型：0 条手动选择 = 完整会话；≥1 条 = 仅所选；无第三态。
final class CopySelectionTests: XCTestCase {

    // MARK: 单条翻转

    func testToggleFromAllEntersSelectionWithSingleId() {
        let scope = CopyScope.all.toggling("m1")
        XCTAssertEqual(scope, .selected(["m1"]))
        XCTAssertTrue(scope.isSelection)
        XCTAssertEqual(scope.count, 1)
    }

    func testToggleAccumulatesWithoutModifier() {
        let scope = CopyScope.all.toggling("m1").toggling("m3")
        XCTAssertEqual(scope, .selected(["m1", "m3"]))
    }

    func testToggleSelectedIdDeselects() {
        let scope = CopyScope.selected(["m1", "m3"]).toggling("m3")
        XCTAssertEqual(scope, .selected(["m1"]))
    }

    func testDeselectingLastIdReturnsToAll() {
        let scope = CopyScope.selected(["m1"]).toggling("m1")
        XCTAssertEqual(scope, .all)
        XCTAssertFalse(scope.isSelection)
        XCTAssertEqual(scope.count, 0)
    }

    // MARK: Shift 区间

    private let order = ["m1", "m2", "m3", "m4", "m5"]

    func testRangeSelectsInclusiveSpan() {
        let scope = CopyScope.selected(["m2"])
            .selectingRange(anchor: "m2", target: "m4", order: order)
        XCTAssertEqual(scope, .selected(["m2", "m3", "m4"]))
    }

    func testRangeWorksBackwards() {
        let scope = CopyScope.selected(["m4"])
            .selectingRange(anchor: "m4", target: "m2", order: order)
        XCTAssertEqual(scope, .selected(["m2", "m3", "m4"]))
    }

    func testRangeUnionsWithExistingSelection() {
        let scope = CopyScope.selected(["m1"])
            .selectingRange(anchor: "m3", target: "m5", order: order)
        XCTAssertEqual(scope, .selected(["m1", "m3", "m4", "m5"]))
    }

    func testRangeWithoutAnchorFallsBackToSingleToggle() {
        let scope = CopyScope.all.selectingRange(anchor: nil, target: "m3", order: order)
        XCTAssertEqual(scope, .selected(["m3"]))
    }

    func testRangeWithUnknownAnchorFallsBackToSingleToggle() {
        let scope = CopyScope.selected(["m1"])
            .selectingRange(anchor: "ghost", target: "m2", order: order)
        XCTAssertEqual(scope, .selected(["m1", "m2"]))
    }
}
