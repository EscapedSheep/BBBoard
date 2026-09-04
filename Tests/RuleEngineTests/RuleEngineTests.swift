import XCTest
@testable import RuleEngine

final class RuleEngineTests: XCTestCase {
    private let calendar = Calendar.current
    /// 固定的「现在」：2026-09-01 12:00 本地时间。
    private lazy var now: Date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!

    private func days(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    private func task(
        id: Int64 = 1,
        title: String = "任务",
        status: TaskStatus = .today,
        dueDate: Date? = nil,
        waitingOn: String? = nil,
        waitingSince: Date? = nil,
        updatedAt: Date? = nil
    ) -> TaskSnapshot {
        TaskSnapshot(
            id: id, title: title, status: status,
            dueDate: dueDate, waitingOn: waitingOn,
            waitingSince: waitingSince, updatedAt: updatedAt ?? now
        )
    }

    // MARK: - due_date 规则

    func testOverdue() {
        let suggestions = RuleEngine.suggestions(for: [task(dueDate: days(-2))], now: now)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].kind, .overdue)
        XCTAssertEqual(suggestions[0].reason, "截止日期已过 2 天")
    }

    func testDueTodayIsApproaching() {
        let suggestions = RuleEngine.suggestions(for: [task(dueDate: days(0))], now: now)
        XCTAssertEqual(suggestions.map(\.kind), [.dueApproaching])
        XCTAssertEqual(suggestions[0].reason, "今天截止")
    }

    func testDueTomorrowIsApproachingWithDefaultThreshold() {
        let suggestions = RuleEngine.suggestions(for: [task(dueDate: days(1))], now: now)
        XCTAssertEqual(suggestions.map(\.kind), [.dueApproaching])
        XCTAssertEqual(suggestions[0].reason, "明天截止")
    }

    func testDueTomorrowIgnoredWhenThresholdIsZero() {
        let thresholds = RuleThresholds(dueApproachingDays: 0)
        let suggestions = RuleEngine.suggestions(for: [task(dueDate: days(1))], now: now, thresholds: thresholds)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testDueBeyondThresholdIsIgnored() {
        let suggestions = RuleEngine.suggestions(for: [task(dueDate: days(2))], now: now)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testDoneTaskNeverSuggests() {
        let t = task(status: .done, dueDate: days(-5))
        XCTAssertTrue(RuleEngine.suggestions(for: [t], now: now).isEmpty)
    }

    // MARK: - waiting 规则

    func testWaitingAtThresholdFires() {
        let t = task(status: .waiting, waitingOn: "Peter 的回复", waitingSince: days(-3))
        let suggestions = RuleEngine.suggestions(for: [t], now: now)
        XCTAssertEqual(suggestions.map(\.kind), [.waitingTooLong])
        XCTAssertEqual(suggestions[0].reason, "等待「Peter 的回复」已 3 天，要跟进吗？")
    }

    func testWaitingBelowThresholdIsSilent() {
        let t = task(status: .waiting, waitingSince: days(-2))
        XCTAssertTrue(RuleEngine.suggestions(for: [t], now: now).isEmpty)
    }

    func testWaitingThresholdOverride() {
        let t = task(status: .waiting, waitingSince: days(-2))
        let thresholds = RuleThresholds(waitingTooLongDays: 2)
        let suggestions = RuleEngine.suggestions(for: [t], now: now, thresholds: thresholds)
        XCTAssertEqual(suggestions.map(\.kind), [.waitingTooLong])
    }

    func testWaitingWithoutWaitingSinceIsSilent() {
        let t = task(status: .waiting)
        XCTAssertTrue(RuleEngine.suggestions(for: [t], now: now).isEmpty)
    }

    func testWaitingReasonWithoutWaitingOn() {
        let t = task(status: .waiting, waitingSince: days(-4))
        let suggestions = RuleEngine.suggestions(for: [t], now: now)
        XCTAssertEqual(suggestions[0].reason, "已等待 4 天，要跟进吗？")
    }

    // MARK: - doing 规则

    func testDoingAtThresholdFires() {
        let t = task(status: .doing, updatedAt: days(-5))
        let suggestions = RuleEngine.suggestions(for: [t], now: now)
        XCTAssertEqual(suggestions.map(\.kind), [.doingTooLong])
        XCTAssertEqual(suggestions[0].reason, "进行中已 5 天没有更新，还在推进吗？")
    }

    func testDoingBelowThresholdIsSilent() {
        let t = task(status: .doing, updatedAt: days(-4))
        XCTAssertTrue(RuleEngine.suggestions(for: [t], now: now).isEmpty)
    }

    func testDoingThresholdOverride() {
        let t = task(status: .doing, updatedAt: days(-8))
        let thresholds = RuleThresholds(doingTooLongDays: 10)
        XCTAssertTrue(RuleEngine.suggestions(for: [t], now: now, thresholds: thresholds).isEmpty)
    }

    // MARK: - 组合行为

    func testOneSuggestionPerTaskDueRuleWins() {
        // waiting 超期 + 已过期：只保留优先级更高的 overdue。
        let t = task(status: .waiting, dueDate: days(-1), waitingSince: days(-10))
        let suggestions = RuleEngine.suggestions(for: [t], now: now)
        XCTAssertEqual(suggestions.map(\.kind), [.overdue])
    }

    func testOrderingIsStable() {
        let tasks = [
            task(id: 1, status: .doing, updatedAt: days(-6)),
            task(id: 2, status: .waiting, waitingSince: days(-4)),
            task(id: 3, dueDate: days(0)),
            task(id: 4, dueDate: days(-1)),
        ]
        let suggestions = RuleEngine.suggestions(for: tasks, now: now)
        XCTAssertEqual(
            suggestions.map { "\($0.taskId):\($0.kind.rawValue)" },
            ["4:overdue", "3:dueApproaching", "2:waitingTooLong", "1:doingTooLong"]
        )
    }

    func testSameKindOrderingByTaskId() {
        let tasks = [
            task(id: 9, status: .waiting, waitingSince: days(-3)),
            task(id: 5, status: .waiting, waitingSince: days(-5)),
        ]
        let suggestions = RuleEngine.suggestions(for: tasks, now: now)
        XCTAssertEqual(suggestions.map(\.taskId), [5, 9])
    }

    func testEmptyInput() {
        XCTAssertTrue(RuleEngine.suggestions(for: [], now: now).isEmpty)
    }
}
