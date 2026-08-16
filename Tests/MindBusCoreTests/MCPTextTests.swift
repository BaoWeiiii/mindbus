import XCTest
@testable import MindBusMCP

/// 三个 MCP 工具共用的文字加工。此前只在 `MemoryBrowseToolTests` 里顺带被走到——
/// `oneLine` 的截断分支（超长文本加省略号）从没被任何测试真正命中过。这里单独把
/// `oneLine`/`day`/`minute` 的边界锁住。
final class MCPTextTests: XCTestCase {

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: oneLine

    func testOneLineLeavesShortTextUntouched() {
        XCTAssertEqual(MCPText.oneLine("短文本", max: 100), "短文本")
    }

    /// 换行/制表/连续空格一律折成单个空格——列表项里出现真换行会把对齐彻底毁掉。
    func testOneLineCollapsesNewlinesTabsAndRunsOfSpaces() {
        XCTAssertEqual(MCPText.oneLine("a\nb\tc   d\n\ne", max: 100), "a b c d e")
    }

    /// 唯一从未被命中过的分支：超过 `max` 就截断并加省略号。
    func testOneLineTruncatesPastMaxAndAppendsEllipsis() {
        let input = String(repeating: "x", count: 10)
        let result = MCPText.oneLine(input, max: 5)
        XCTAssertEqual(result, "xxxxx…")
    }

    func testOneLineExactlyAtMaxDoesNotTruncate() {
        let input = String(repeating: "x", count: 5)
        XCTAssertEqual(MCPText.oneLine(input, max: 5), "xxxxx", "恰好等于 max 不该多切一刀")
    }

    func testOneLineOnEmptyStringIsEmpty() {
        XCTAssertEqual(MCPText.oneLine("", max: 10), "")
    }

    func testOneLineOnAllWhitespaceCollapsesToEmpty() {
        XCTAssertEqual(MCPText.oneLine("   \n\t  ", max: 10), "")
    }

    // MARK: day / minute

    func testDayFormatsAsYearMonthDay() {
        XCTAssertEqual(MCPText.day(date(year: 2026, month: 7, day: 15, hour: 21, minute: 14)),
                       "2026-07-15")
    }

    func testMinuteFormatsWithHourAndMinute() {
        XCTAssertEqual(MCPText.minute(date(year: 2026, month: 7, day: 15, hour: 21, minute: 14)),
                       "2026-07-15 21:14")
    }

    /// 越界日期（超出 Calendar/strftime 能表示的范围）不是 nil、不崩溃，而是空字符串——
    /// `MemoryBrowseTool` 的地图页正是依赖这一行为判断"这个日期能不能印出来"。
    func testDayOnExtremeOutOfRangeDateReturnsEmptyString() {
        XCTAssertEqual(MCPText.day(Date(timeIntervalSince1970: 1e18)), "")
    }
}
