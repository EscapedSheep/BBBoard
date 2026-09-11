import Foundation
import XCTest
@testable import RuleEngine

final class BrainDumpParserTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!

    private func parse(_ text: String) -> [TaskProposal] {
        BrainDumpParser.parse(text, now: now, calendar: calendar)
    }

    func testFragmentsSplitOnPunctuation() {
        let fragments = BrainDumpParser.fragments(of: "处理 PRG。看看 TEMU，修 invoice bug")
        XCTAssertEqual(fragments, ["处理 PRG", "看看 TEMU", "修 invoice bug"])
    }

    func testFragmentsStripLeadingConjunctions() {
        let fragments = BrainDumpParser.fragments(of: "今天处理 PRG，还有 TEMU 的问题，然后找找 Hungary")
        XCTAssertEqual(fragments, ["今天处理 PRG", "TEMU 的问题", "找找 Hungary"])
    }

    func testWaitingFragmentMergesIntoPrevious() {
        let proposals = parse("明天跟进 PRG 的 API key，等 Peter 回复。还有 invoice 接口的 bug 今天得修")
        XCTAssertEqual(proposals.count, 2)

        XCTAssertEqual(proposals[0].title, "跟进 PRG 的 API key")
        XCTAssertEqual(proposals[0].status, .waiting)
        XCTAssertEqual(proposals[0].waitingOn, "Peter 回复")
        XCTAssertEqual(proposals[0].dueDate, calendar.date(from: DateComponents(year: 2026, month: 9, day: 3)))

        XCTAssertEqual(proposals[1].title, "invoice 接口的 bug 得修")
        XCTAssertEqual(proposals[1].status, .today)
        XCTAssertEqual(proposals[1].dueDate, calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)))
    }

    func testStandaloneWaitingFragment() {
        let proposals = parse("等海关回复")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].status, .waiting)
        XCTAssertEqual(proposals[0].waitingOn, "海关回复")
        XCTAssertEqual(proposals[0].title, "等海关回复")
    }

    func testDengWordNotMisjudgedAsWaiting() {
        let graded = parse("明天处理等级评定")
        XCTAssertEqual(graded.count, 1)
        XCTAssertEqual(graded[0].status, .today)
        XCTAssertNil(graded[0].waitingOn)
        XCTAssertEqual(graded[0].title, "处理等级评定")

        let equality = parse("平等条款确认")
        XCTAssertEqual(equality.count, 1)
        XCTAssertEqual(equality[0].status, .today)
        XCTAssertNil(equality[0].waitingOn)
    }

    func testDengdengFragmentDoesNotMergeIntoPrevious() {
        let proposals = parse("修完 bug。等等再说")
        XCTAssertEqual(proposals.count, 2)
        XCTAssertEqual(proposals[0].title, "修完 bug")
        XCTAssertEqual(proposals[1].status, .today)
        XCTAssertNil(proposals[1].waitingOn)
    }

    func testMergingWaitingDoesNotOverwriteExistingWaitingOn() {
        let proposals = parse("等海关回复。等 Peter 回复")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].status, .waiting)
        XCTAssertEqual(proposals[0].waitingOn, "海关回复、Peter 回复")
    }

    func testSlashAndDotAreNotSeparators() {
        let proposals = parse("9/5前交报告")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].title, "交报告")
        XCTAssertEqual(proposals[0].dueDate, calendar.date(from: DateComponents(year: 2026, month: 9, day: 5)))

        let version = parse("发布 v1.2")
        XCTAssertEqual(version.count, 1)
        XCTAssertEqual(version[0].title, "发布 v1.2")
    }

    func testDefaultStatusIsToday() {
        let proposals = parse("修 bug")
        XCTAssertEqual(proposals.map(\.status), [.today])
        XCTAssertNil(proposals[0].dueDate)
    }

    func testWaitingPatternInsideFragment() {
        let proposals = parse("明天跟进 PRG 的 API key 等 Peter 的回复")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].status, .waiting)
        XCTAssertEqual(proposals[0].waitingOn, "Peter 的回复")
        XCTAssertEqual(proposals[0].title, "跟进 PRG 的 API key")
    }

    func testEmptyInputProducesNothing() {
        XCTAssertTrue(parse("").isEmpty)
        XCTAssertTrue(parse("。。。").isEmpty)
    }

    func testDuePrefixSuffixStrippedFromTitle() {
        let proposals = parse("周五前把 customs XML 的测试跑完")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].title, "把 customs XML 的测试跑完")
        XCTAssertEqual(proposals[0].dueDate, calendar.date(from: DateComponents(year: 2026, month: 9, day: 4)))
    }

    func testEnglishConjunctionSplits() {
        let proposals = parse("review A tomorrow and follow up B")
        XCTAssertEqual(proposals.map(\.title), ["review A", "follow up B"])
    }
}
