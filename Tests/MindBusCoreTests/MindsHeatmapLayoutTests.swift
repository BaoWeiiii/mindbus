import XCTest
@testable import MindBusCore

/// 活跃地图排布。三条规则以前只能靠看渲染图验证：
/// 窗口按库龄裁剪、首列补前导空位、月份刻度只在换月时出现。
final class MindsHeatmapLayoutTests: XCTestCase {

    private let now = MindsDocument.day(from: "2026-08-17")!   // 周一

    private func layout(_ daily: [(String, Int)], maxDays: Int = 365) -> MindsHeatmapLayout {
        MindsHeatmapLayout(daily: daily.map { (day: $0.0, count: $0.1) },
                           now: now, maxDays: maxDays)
    }

    // MARK: - 窗口裁剪

    /// 库只有几周时不能画满一年——否则前 250 列全是空格子，一半的图在讲「没有数据」
    func testWindowClipsToFirstActiveDay() {
        let l = layout([("2026-08-01", 3), ("2026-08-10", 1)])
        let days = l.weeks.flatMap { $0 }.compactMap(\.day)
        XCTAssertEqual(days.first, "2026-08-01")
        XCTAssertEqual(days.last, "2026-08-17")
        XCTAssertEqual(days.count, 17)
    }

    /// 数据比窗口还老时，起点是窗口而不是首条数据
    func testWindowNeverExceedsMaxDays() {
        let l = layout([("2020-01-01", 5), ("2026-08-16", 1)], maxDays: 30)
        let days = l.weeks.flatMap { $0 }.compactMap(\.day)
        XCTAssertEqual(days.first, "2026-07-19")   // 30 天窗口
        XCTAssertEqual(days.count, 30)
    }

    /// 一天数据都没有时，退回完整窗口而不是空图
    func testNoActiveDaysFallsBackToFullWindow() {
        let l = layout([], maxDays: 14)
        XCTAssertEqual(l.weeks.flatMap { $0 }.compactMap(\.day).count, 14)
    }

    // MARK: - 网格

    /// 起点不是周一时，首列要补前导空位，否则整张图会错行
    func testLeadingBlanksAlignFirstColumnToMonday() {
        // 2026-08-05 是周三 → 周一、周二两个空位
        let l = layout([("2026-08-05", 1)])
        XCTAssertEqual(l.weeks[0][0], .blank)
        XCTAssertEqual(l.weeks[0][1], .blank)
        XCTAssertEqual(l.weeks[0][2].day, "2026-08-05")
    }

    func testStartOnMondayHasNoLeadingBlank() {
        let l = layout([("2026-08-03", 1)])   // 周一
        XCTAssertEqual(l.weeks[0][0].day, "2026-08-03")
    }

    func testEachColumnIsAtMostSevenCells() {
        let l = layout([("2026-06-01", 1)])
        XCTAssertTrue(l.weeks.allSatisfy { $0.count <= 7 })
        XCTAssertTrue(l.weeks.dropLast().allSatisfy { $0.count == 7 })
    }

    func testCountsAreCarriedOntoTheRightDay() {
        let l = layout([("2026-08-05", 9), ("2026-08-06", 0)])
        let cells = l.weeks.flatMap { $0 }
        XCTAssertEqual(cells.first(where: { $0.day == "2026-08-05" })?.count, 9)
        XCTAssertEqual(cells.first(where: { $0.day == "2026-08-06" })?.count, 0)
    }

    func testLabelsAlignOneToOneWithColumns() {
        let l = layout([("2026-05-01", 1)])
        XCTAssertEqual(l.monthLabels.count, l.weeks.count)
    }

    // MARK: - 月份刻度

    /// 只在换月那一列标，否则每列都写月份就成了噪点
    func testMonthLabelOnlyOnMonthChange() {
        let l = layout([("2026-06-01", 1)])
        let labelled = l.monthLabels.compactMap { $0 }
        XCTAssertEqual(labelled, ["06", "07", "08"])
    }

    func testFirstColumnAlwaysLabelled() {
        let l = layout([("2026-08-01", 1)])
        XCTAssertEqual(l.monthLabels.first, "08")
    }

    // MARK: - 色阶档位

    func testBuckets() {
        XCTAssertEqual(MindsHeatmapLayout.bucket(0), 0)
        XCTAssertEqual(MindsHeatmapLayout.bucket(1), 1)
        XCTAssertEqual(MindsHeatmapLayout.bucket(2), 1)
        XCTAssertEqual(MindsHeatmapLayout.bucket(3), 2)
        XCTAssertEqual(MindsHeatmapLayout.bucket(5), 2)
        XCTAssertEqual(MindsHeatmapLayout.bucket(6), 3)
        XCTAssertEqual(MindsHeatmapLayout.bucket(9), 3)
        XCTAssertEqual(MindsHeatmapLayout.bucket(10), 4)
        XCTAssertEqual(MindsHeatmapLayout.bucket(999), 4)
    }

    /// 0 档必须是「没有对话」的灰，不能和「有一点」混——否则空白日看着像有活动
    func testZeroIsItsOwnBucket() {
        XCTAssertNotEqual(MindsHeatmapLayout.bucket(0), MindsHeatmapLayout.bucket(1))
    }
}
