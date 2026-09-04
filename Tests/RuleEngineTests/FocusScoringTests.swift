import XCTest
@testable import RuleEngine

final class FocusScoringTests: XCTestCase {
    private let calendar = Calendar.current
    /// 固定「现在」：2026-09-03 12:00 本地时间。
    private lazy var now: Date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!

    private func days(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: now)!
    }

    private func task(
        id: Int64,
        status: TaskStatus = .today,
        dueDate: Date? = nil,
        waitingSince: Date? = nil,
        updatedAt: Date? = nil
    ) -> TaskSnapshot {
        TaskSnapshot(
            id: id, title: "任务\(id)", status: status,
            dueDate: dueDate, waitingSince: waitingSince, updatedAt: updatedAt ?? now
        )
    }

    private func focus(_ tasks: [TaskSnapshot], activity: [Int64: Int] = [:], config: FocusConfig = .default) -> [FocusItem] {
        RuleEngine.focus(tasks: tasks, activityCounts: activity, now: now, config: config)
    }

    func testAllDoneBoardIsEmpty() {
        let items = focus([task(id: 1, status: .done, dueDate: days(-3))])
        XCTAssertTrue(items.isEmpty)
    }

    func testZeroScoreTasksExcluded() {
        // 无截止、today、无活跃 → 0 分不入选
        let items = focus([task(id: 1)])
        XCTAssertTrue(items.isEmpty)
    }

    func testOverdueOutranksWaitingOutranksPlainDoing() {
        let tasks = [
            task(id: 1, status: .doing, updatedAt: days(-3)),          // 7.5
            task(id: 2, status: .waiting, waitingSince: days(-4)),     // 16
            task(id: 3, dueDate: days(-2)),                            // 48
            task(id: 4, dueDate: days(0)),                             // 30
        ]
        let items = focus(tasks)
        XCTAssertEqual(items.map(\.taskId), [3, 4, 2])
        XCTAssertEqual(items.map(\.rank), [1, 2, 3])
        XCTAssertEqual(items[0].reason, "已逾期 2 天")
        XCTAssertEqual(items[1].reason, "今天截止")
    }

    func testTopNCapAndShortlist() {
        var config = FocusConfig()
        config.maxItems = 2
        let tasks = [task(id: 1, dueDate: days(-1)), task(id: 2, dueDate: days(0)), task(id: 3, dueDate: days(1))]
        XCTAssertEqual(focus(tasks, config: config).count, 2)

        // 合格任务不足 N 个时返回现有数量
        XCTAssertEqual(focus([task(id: 1, dueDate: days(0))]).count, 1)
    }

    func testActivityBoostsRanking() {
        // 同样明天截止，活跃多的排前面
        let tasks = [task(id: 1, dueDate: days(1)), task(id: 2, dueDate: days(1))]
        let items = focus(tasks, activity: [2: 5])
        XCTAssertEqual(items.map(\.taskId), [2, 1])
        XCTAssertEqual(items[0].reason, "明天截止") // 主因仍是截止（16 > 15）
    }

    func testActivityAloneDoesNotQualify() {
        // 活跃度只加权不成由：无截止/等待/推进中等实质原因的任务不进 focus
        XCTAssertTrue(focus([task(id: 1)], activity: [1: 3]).isEmpty)
    }

    func testPrimaryReasonIsHighestContribution() {
        // 逾期 1 天（44）+ 等待 5 天（20）→ 主因逾期
        let t = task(id: 1, status: .waiting, dueDate: days(-1), waitingSince: days(-5))
        XCTAssertEqual(focus([t])[0].reason, "已逾期 1 天")

        // 等待 6 天（24）+ 明天截止（16）→ 主因等待
        let t2 = task(id: 2, status: .waiting, dueDate: days(1), waitingSince: days(-6))
        XCTAssertEqual(focus([t2])[0].reason, "等待 6 天未跟进")
    }

    func testDueThisWeekReason() {
        XCTAssertEqual(focus([task(id: 1, dueDate: days(4))])[0].reason, "4 天后截止")
        XCTAssertTrue(focus([task(id: 1, dueDate: days(8))]).isEmpty) // 超过 7 天不计分
    }

    func testDoingStagnationReason() {
        XCTAssertEqual(focus([task(id: 1, status: .doing, updatedAt: days(-6))])[0].reason, "进行中 6 天")
    }

    func testScoreTieBreaksByTaskId() {
        let tasks = [task(id: 9, dueDate: days(0)), task(id: 5, dueDate: days(0))]
        XCTAssertEqual(focus(tasks).map(\.taskId), [5, 9])
    }
}
