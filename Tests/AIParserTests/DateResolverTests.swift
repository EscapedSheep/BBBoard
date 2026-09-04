import Foundation
import XCTest
@testable import AIParser

final class DateResolverTests: XCTestCase {
    /// 固定参考时间：2026-09-02（周三）12:00，Asia/Shanghai，周一为一周起点。
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!

    private func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func assertDate(_ text: String, _ expected: Date, file: StaticString = #filePath, line: UInt = #line) {
        let resolved = DateResolver.resolve(text, now: now, calendar: calendar)
        XCTAssertEqual(resolved, calendar.startOfDay(for: expected), "\(text)", file: file, line: line)
    }

    // MARK: - 相对日

    func testRelativeDays() {
        assertDate("今天", day(9, 2))
        assertDate("今日", day(9, 2))
        assertDate("明天", day(9, 3))
        assertDate("明日", day(9, 3))
        assertDate("后天", day(9, 4))
        assertDate("大后天", day(9, 5))
    }

    func testDaysAfter() {
        assertDate("3天后", day(9, 5))
        assertDate("10天后", day(9, 12))
        assertDate("三天后", day(9, 5))
    }

    // MARK: - 星期

    func testWeekdaySameWeek() {
        assertDate("周三", day(9, 2)) // 今天就是周三 → 今天
        assertDate("周四", day(9, 3))
        assertDate("星期一", day(9, 7)) // 本周一已过 → 下周一
        assertDate("礼拜天", day(9, 6))
        assertDate("周日", day(9, 6))
    }

    func testNextWeekWeekday() {
        assertDate("下周一", day(9, 7)) // 下周起点（周一）
        assertDate("下周三", day(9, 9))
        assertDate("下周日", day(9, 13))
    }

    // MARK: - 具体日期

    func testMonthDay() {
        assertDate("9月5日", day(9, 5))
        assertDate("9月5号", day(9, 5))
        assertDate("8月1日", day(8, 1, 2027)) // 今年已过 → 明年
    }

    func testFullWidthMonthDay() {
        assertDate("９月５日", day(9, 5))
    }

    func testSlashDates() {
        assertDate("9/5", day(9, 5))
        assertDate("9/5前", day(9, 5))
        assertDate("12/31", day(12, 31))
        assertDate("8/1", day(8, 1, 2027)) // 今年已过 → 明年
    }

    func testInvalidMonthDayReturnsNil() {
        XCTAssertNil(DateResolver.resolve("13月45日", now: now, calendar: calendar))
        XCTAssertNil(DateResolver.resolve("0月5日", now: now, calendar: calendar))
        XCTAssertNil(DateResolver.resolve("9/45", now: now, calendar: calendar))
    }

    // MARK: - 文本位置优先

    func testEarliestExpressionInTextWins() {
        assertDate("周五前交初稿，明天先对齐", day(9, 4))
        assertDate("明天先对齐，周五前交初稿", day(9, 3))
    }

    // MARK: - 中文数字（至 99）

    func testChineseNumeralUpTo99() {
        assertDate("十天后", day(9, 12))
        assertDate("十五天后", day(9, 17))
        assertDate("二十天后", day(9, 22))
        assertDate("二十五天后", day(9, 27))
        assertDate("九十九天后", day(12, 10))
    }

    // MARK: - 区间与剔除

    func testEmbeddedExpressionReportsRange() {
        let text = "明天跟进 PRG 的 API key"
        let resolved = DateResolver.resolveWithRange(text, now: now, calendar: calendar)
        XCTAssertEqual(resolved?.date, day(9, 3))
        XCTAssertEqual(resolved.map { String(text[$0.range]) }, "明天")
    }

    func testUnresolvableReturnsNil() {
        XCTAssertNil(DateResolver.resolve("有空的时候再说", now: now, calendar: calendar))
    }

    // MARK: - 英文（NSDataDetector 以真实当前时间为基准解析）

    func testEnglishRelativeDates() {
        let realNow = Date()
        let cal = Calendar.current
        let tomorrow = DateResolver.resolve("review the TEMU issue tomorrow", now: realNow)
        XCTAssertEqual(tomorrow, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: realNow)))

        let nextFriday = DateResolver.resolve("follow up next Friday", now: realNow)
        XCTAssertNotNil(nextFriday)
        if let nextFriday {
            XCTAssertEqual(cal.component(.weekday, from: nextFriday), 6) // Friday
            XCTAssertGreaterThan(nextFriday, cal.startOfDay(for: realNow))
        }
    }
}
