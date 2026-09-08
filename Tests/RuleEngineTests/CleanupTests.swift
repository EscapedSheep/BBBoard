import XCTest
@testable import RuleEngine

final class CleanupTests: XCTestCase {
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
        waitingOn: String? = nil,
        waitingSince: Date? = nil,
        updatedAt: Date? = nil
    ) -> TaskSnapshot {
        TaskSnapshot(
            id: id, title: title, status: status,
            waitingOn: waitingOn, waitingSince: waitingSince,
            updatedAt: updatedAt ?? now
        )
    }

    // MARK: - backlog 停滞

    func testBacklogStaleAtThresholdFires() {
        let t = task(status: .backlog, updatedAt: days(-30))
        let result = RuleEngine.stagnantTasks(for: [t], now: now)
        XCTAssertEqual(result.map(\.kind), [.backlogStale])
        XCTAssertEqual(result[0].days, 30)
        XCTAssertEqual(result[0].reason, "在 Backlog 躺了 30 天，还值得做吗？")
    }

    func testBacklogBelowThresholdIsSilent() {
        let t = task(status: .backlog, updatedAt: days(-29))
        XCTAssertTrue(RuleEngine.stagnantTasks(for: [t], now: now).isEmpty)
    }

    func testBacklogThresholdOverride() {
        let t = task(status: .backlog, updatedAt: days(-10))
        let config = CleanupConfig(backlogStaleDays: 10)
        let result = RuleEngine.stagnantTasks(for: [t], now: now, config: config)
        XCTAssertEqual(result.map(\.kind), [.backlogStale])
    }

    // MARK: - doing 停滞

    func testDoingStaleAtThresholdFires() {
        let t = task(status: .doing, updatedAt: days(-7))
        let result = RuleEngine.stagnantTasks(for: [t], now: now)
        XCTAssertEqual(result.map(\.kind), [.doingStale])
        XCTAssertEqual(result[0].days, 7)
        XCTAssertEqual(result[0].reason, "进行中 7 天没有更新")
    }

    func testDoingBelowThresholdIsSilent() {
        let t = task(status: .doing, updatedAt: days(-6))
        XCTAssertTrue(RuleEngine.stagnantTasks(for: [t], now: now).isEmpty)
    }

    // MARK: - waiting 停滞

    func testWaitingStaleAtThresholdFires() {
        let t = task(status: .waiting, waitingSince: days(-7), updatedAt: days(-2))
        let result = RuleEngine.stagnantTasks(for: [t], now: now)
        XCTAssertEqual(result.map(\.kind), [.waitingStale])
        XCTAssertEqual(result[0].days, 7)
        XCTAssertEqual(result[0].reason, "等待 7 天未跟进")
    }

    func testWaitingStaleReasonIncludesWaitingOn() {
        let t = task(status: .waiting, waitingOn: "Peter 的回复", waitingSince: days(-9))
        let result = RuleEngine.stagnantTasks(for: [t], now: now)
        XCTAssertEqual(result[0].reason, "等待「Peter 的回复」9 天未跟进")
    }

    func testWaitingBelowThresholdIsSilent() {
        let t = task(status: .waiting, waitingSince: days(-6))
        XCTAssertTrue(RuleEngine.stagnantTasks(for: [t], now: now).isEmpty)
    }

    func testWaitingWithoutWaitingSinceIsSilent() {
        let t = task(status: .waiting, updatedAt: days(-60))
        XCTAssertTrue(RuleEngine.stagnantTasks(for: [t], now: now).isEmpty)
    }

    // MARK: - 排除与组合行为

    func testDoneTaskNeverDetected() {
        let tasks = [
            task(id: 1, status: .done, updatedAt: days(-90)),
            task(id: 2, status: .done, waitingSince: days(-90)),
        ]
        XCTAssertTrue(RuleEngine.stagnantTasks(for: tasks, now: now).isEmpty)
    }

    func testTodayTaskNeverDetected() {
        let t = task(status: .today, updatedAt: days(-90))
        XCTAssertTrue(RuleEngine.stagnantTasks(for: [t], now: now).isEmpty)
    }

    func testSortedByDaysDescending() {
        let tasks = [
            task(id: 1, status: .doing, updatedAt: days(-10)),
            task(id: 2, status: .backlog, updatedAt: days(-45)),
            task(id: 3, status: .waiting, waitingSince: days(-8)),
        ]
        let result = RuleEngine.stagnantTasks(for: tasks, now: now)
        XCTAssertEqual(result.map(\.taskId), [2, 1, 3])
        XCTAssertEqual(result.map(\.days), [45, 10, 8])
    }

    func testSameDaysOrderedByTaskIdAscending() {
        let tasks = [
            task(id: 9, status: .doing, updatedAt: days(-8)),
            task(id: 4, status: .waiting, waitingSince: days(-8)),
            task(id: 7, status: .backlog, updatedAt: days(-8)),
        ]
        // backlogStale 默认阈值 30，需调低使三者同为 8 天命中
        let config = CleanupConfig(backlogStaleDays: 8)
        let result = RuleEngine.stagnantTasks(for: tasks, now: now, config: config)
        XCTAssertEqual(result.map(\.taskId), [4, 7, 9])
    }

    func testReasonContainsDays() {
        let tasks = [
            task(id: 1, status: .backlog, updatedAt: days(-31)),
            task(id: 2, status: .doing, updatedAt: days(-8)),
            task(id: 3, status: .waiting, waitingSince: days(-9)),
        ]
        let result = RuleEngine.stagnantTasks(for: tasks, now: now)
        for stagnant in result {
            XCTAssertTrue(stagnant.reason.contains("\(stagnant.days) 天"), "\(stagnant.reason) 应包含天数")
        }
    }

    func testStagnantTaskIdIsStable() {
        let result = RuleEngine.stagnantTasks(
            for: [task(id: 42, status: .doing, updatedAt: days(-8))], now: now)
        XCTAssertEqual(result[0].id, "42-doingStale")
    }

    func testEmptyInput() {
        XCTAssertTrue(RuleEngine.stagnantTasks(for: [], now: now).isEmpty)
    }
}
