import Foundation
import GRDB
import RuleEngine
@testable import TaskStore
import XCTest

final class TaskStoreTests: XCTestCase {
    private var store: TaskStore!
    /// 固定时间，避免测试依赖运行时刻。
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 整秒，规避存储精度问题

    override func setUpWithError() throws {
        store = try TaskStore.inMemory()
    }

    private func payloadDict(_ entry: ActivityLog) -> [String: String]? {
        guard let payload = entry.payload,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return object
    }

    // MARK: - Migration

    func testMigrationCreatesAllFiveTables() throws {
        let names = try store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in ["tasks", "projects", "activity_log", "focus_items", "corrections"] {
            XCTAssertTrue(names.contains(table), "missing table: \(table)")
        }
    }

    // MARK: - CRUD

    func testCreateAndFetch() throws {
        let due = Date(timeIntervalSince1970: 1_800_086_400)
        let task = try store.createTask(title: "跟进 PRG", status: .today, dueDate: due, at: now)
        XCTAssertNotNil(task.id)
        XCTAssertEqual(task.source, .manual)
        XCTAssertEqual(task.createdAt, now)
        XCTAssertEqual(task.updatedAt, now)
        XCTAssertNil(task.waitingSince)

        let fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.title, "跟进 PRG")
        XCTAssertEqual(fetched?.status, .today)
        XCTAssertEqual(fetched?.dueDate?.timeIntervalSince1970 ?? -1, due.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try store.allTasks().count, 1)
    }

    func testCreateDirectlyAsWaitingSetsWaitingSince() throws {
        let task = try store.createTask(title: "等回复", status: .waiting, waitingOn: "Peter", at: now)
        XCTAssertEqual(task.waitingSince, now)
        XCTAssertEqual(task.waitingOn, "Peter")
    }

    func testUpdateTaskEditsFieldsAndLogs() throws {
        let task = try store.createTask(title: "旧标题", at: now)
        let later = now.addingTimeInterval(3600)
        try store.updateTask(id: task.id!, title: "新标题", note: "备注", at: later)

        let fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.title, "新标题")
        XCTAssertEqual(fetched?.note, "备注")
        XCTAssertEqual(fetched?.updatedAt, later)

        let edited = try store.activity(forTaskId: task.id!).filter { $0.type == .edited }
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(payloadDict(edited[0])?["fields"], "title,note")
    }

    func testUpdateTaskWithoutChangesWritesNoLog() throws {
        let task = try store.createTask(title: "标题", at: now)
        try store.updateTask(id: task.id!, title: "标题", at: now.addingTimeInterval(60))
        XCTAssertTrue(try store.activity(forTaskId: task.id!).filter { $0.type == .edited }.isEmpty)
    }

    func testClearDueDate() throws {
        let task = try store.createTask(title: "t", dueDate: now, at: now)
        try store.updateTask(id: task.id!, clearDueDate: true, at: now)
        XCTAssertNil(try store.task(id: task.id!)?.dueDate)
    }

    // MARK: - 手动焦点（focus_pinned）

    func testFocusPinnedDefaultsToFalse() throws {
        let task = try store.createTask(title: "t", at: now)
        XCTAssertFalse(task.focusPinned)
        XCTAssertEqual(try store.task(id: task.id!)?.focusPinned, false)
    }

    func testSetFocusPinnedTogglesAndLogs() throws {
        let task = try store.createTask(title: "t", at: now)
        let later = now.addingTimeInterval(3600)
        try store.setFocusPinned(task.id!, true, at: later)

        var fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.focusPinned, true)
        XCTAssertEqual(fetched?.updatedAt, later)

        let edited = try store.activity(forTaskId: task.id!).filter { $0.type == .edited }
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(payloadDict(edited[0])?["fields"], "focus_pinned")

        // 同值再设是 no-op；设回 false 再记一条
        try store.setFocusPinned(task.id!, true, at: later.addingTimeInterval(60))
        try store.setFocusPinned(task.id!, false, at: later.addingTimeInterval(120))
        fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.focusPinned, false)
        XCTAssertEqual(try store.activity(forTaskId: task.id!).filter { $0.type == .edited }.count, 2)
    }

    // MARK: - 领域（工作/个人）

    func testTaskAreaDefaultsToWork() throws {
        let task = try store.createTask(title: "默认", at: now)
        XCTAssertEqual(task.area, .work)
        XCTAssertEqual(try store.task(id: task.id!)?.area, .work)
    }

    func testCreateTaskWithPersonalArea() throws {
        let task = try store.createTask(title: "买菜", area: .personal, at: now)
        XCTAssertEqual(try store.task(id: task.id!)?.area, .personal)
    }

    func testUpdateTaskAreaEditsAndLogs() throws {
        let task = try store.createTask(title: "t", at: now)
        let later = now.addingTimeInterval(3600)
        try store.updateTask(id: task.id!, area: .personal, at: later)

        let fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.area, .personal)
        XCTAssertEqual(fetched?.updatedAt, later)

        let edited = try store.activity(forTaskId: task.id!).filter { $0.type == .edited }
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(payloadDict(edited[0])?["fields"], "area")

        // 同值再设是 no-op，不重复记日志
        try store.updateTask(id: task.id!, area: .personal, at: later.addingTimeInterval(60))
        XCTAssertEqual(try store.activity(forTaskId: task.id!).filter { $0.type == .edited }.count, 1)
    }

    func testExistingDatabaseMigratesAreaWithDefaultWork() throws {
        // 模拟 v3 时代的旧库：先建库到 v3，塞一条任务，再迁移到最新
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bbboard-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_schema") { db in
            try db.create(table: "tasks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                t.column("source", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            // v2_indexes 依赖的表也要在（真实 v1 一次建齐五张表）
            try db.create(table: "activity_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("task_id", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("payload", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "focus_items") { t in
                t.column("date", .date).notNull()
                t.column("task_id", .integer).notNull()
                t.column("reason", .text).notNull()
                t.column("rank", .integer).notNull()
            }
        }
        let legacyQueue = try DatabaseQueue(path: url.path(percentEncoded: false))
        try migrator.migrate(legacyQueue, upTo: "v1_schema")
        try legacyQueue.write { db in
            try db.execute(
                sql: "INSERT INTO tasks (title, status, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: ["旧任务", "today", "manual", now, now]
            )
        }

        let migrated = try TaskStore.open(at: url)
        let task = try XCTUnwrap(migrated.allTasks().first)
        XCTAssertEqual(task.title, "旧任务")
        XCTAssertEqual(task.area, .work)
    }

    func testDeleteTask() throws {
        let task = try store.createTask(title: "删掉我", at: now)
        try store.deleteTask(id: task.id!)
        XCTAssertNil(try store.task(id: task.id!))
        XCTAssertThrowsError(try store.deleteTask(id: task.id!)) { error in
            XCTAssertEqual(error as? TaskStoreError, .taskNotFound(task.id!))
        }
    }

    // MARK: - 状态流转

    func testEnteringAndLeavingWaiting() throws {
        let task = try store.createTask(title: "t", status: .doing, at: now)
        let waitingAt = now.addingTimeInterval(86_400)
        try store.setStatus(task.id!, to: .waiting, waitingOn: "Peter 的回复", at: waitingAt)

        var fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.status, .waiting)
        XCTAssertEqual(fetched?.waitingSince, waitingAt)
        XCTAssertEqual(fetched?.waitingOn, "Peter 的回复")

        try store.setStatus(task.id!, to: .doing, at: waitingAt.addingTimeInterval(3600))
        fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.status, .doing)
        XCTAssertNil(fetched?.waitingSince)
        XCTAssertNil(fetched?.waitingOn)
    }

    func testDoneSetsAndClearsCompletedAt() throws {
        let task = try store.createTask(title: "t", at: now)
        let doneAt = now.addingTimeInterval(100)
        try store.setStatus(task.id!, to: .done, at: doneAt)
        XCTAssertEqual(try store.task(id: task.id!)?.completedAt, doneAt)

        try store.setStatus(task.id!, to: .today, at: doneAt.addingTimeInterval(100))
        XCTAssertNil(try store.task(id: task.id!)?.completedAt)
    }

    func testSameStatusIsNoop() throws {
        let task = try store.createTask(title: "t", at: now)
        try store.setStatus(task.id!, to: .today, at: now.addingTimeInterval(10))
        XCTAssertEqual(try store.activity(forTaskId: task.id!).count, 1) // 只有 created
    }

    func testSetStatusOnMissingTaskThrows() throws {
        XCTAssertThrowsError(try store.setStatus(42, to: .done)) { error in
            XCTAssertEqual(error as? TaskStoreError, .taskNotFound(42))
        }
    }

    // MARK: - activity_log

    func testActivityLogLifecycle() throws {
        let task = try store.createTask(title: "t", status: .today, at: now)
        try store.setStatus(task.id!, to: .waiting, waitingOn: "API key", at: now)
        try store.setStatus(task.id!, to: .doing, at: now)
        try store.setStatus(task.id!, to: .done, at: now)
        try store.logViewed(taskId: task.id!, at: now)

        let entries = try store.activity(forTaskId: task.id!)
        XCTAssertEqual(
            entries.map(\.type),
            [.created, .statusChanged, .statusChanged, .statusChanged, .completed, .viewed]
        )
        XCTAssertEqual(payloadDict(entries[1]), ["from": "today", "to": "waiting"])
        XCTAssertEqual(payloadDict(entries[3]), ["from": "doing", "to": "done"])
        XCTAssertTrue(entries.allSatisfy { $0.taskId == task.id! })
    }

    // MARK: - Snapshot 桥接

    func testSnapshotMatchesRecord() throws {
        let task = try store.createTask(title: "快照", status: .waiting, waitingOn: "X", at: now)
        let snapshot = task.snapshot
        XCTAssertEqual(snapshot.id, task.id!)
        XCTAssertEqual(snapshot.status, .waiting)
        XCTAssertEqual(snapshot.waitingSince, now)
        XCTAssertEqual(snapshot.updatedAt, now)
    }

    // MARK: - Daily Focus

    func testRecentActivityCounts() throws {
        let task = try store.createTask(title: "t", at: now)
        try store.setStatus(task.id!, to: .doing, at: now)
        try store.updateTask(id: task.id!, title: "t2", at: now)
        let other = try store.createTask(title: "u", at: now)

        let counts = try store.recentActivityCounts(days: 7, now: now)
        XCTAssertEqual(counts[task.id!], 3) // created + status_changed + edited
        XCTAssertEqual(counts[other.id!], 1)
    }

    func testRecentActivityCountsRespectsWindow() throws {
        let task = try store.createTask(title: "t", at: now)
        let old = now.addingTimeInterval(-10 * 86_400)
        try store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO activity_log (task_id, type, created_at) VALUES (?, 'viewed', ?)",
                arguments: [task.id!, old]
            )
        }
        let counts = try store.recentActivityCounts(days: 7, now: now)
        XCTAssertEqual(counts[task.id!], 1) // 10 天前的不计入
    }

    func testFocusSnapshotRoundTripAndReplace() throws {
        let day = Calendar.current.startOfDay(for: now)
        let rows = [
            FocusItemRow(date: day, taskId: 3, reason: "已逾期 2 天", rank: 1),
            FocusItemRow(date: day, taskId: 7, reason: "今天截止", rank: 2),
        ]
        try store.saveFocusSnapshot(day: day, items: rows)
        XCTAssertEqual(try store.focusSnapshot(forDay: day), rows)

        // 同日重写：替换而非追加（幂等）
        let updated = [FocusItemRow(date: day, taskId: 9, reason: "等待 4 天未跟进", rank: 1)]
        try store.saveFocusSnapshot(day: day, items: updated)
        XCTAssertEqual(try store.focusSnapshot(forDay: day), updated)

        // 其它日期不受影响
        XCTAssertTrue(try store.focusSnapshot(forDay: day.addingTimeInterval(86_400)).isEmpty)
    }

    // MARK: - Observation

    @MainActor
    func testTasksObservationEmitsInitialValue() throws {
        _ = try store.createTask(title: "t", at: now)
        let expectation = expectation(description: "observation emits")
        let cancellable = store.tasksObservation().start(
            in: store.dbQueue,
            onError: { XCTFail("observation error: \($0)") },
            onChange: { tasks in
                if tasks.count == 1 { expectation.fulfill() }
            }
        )
        wait(for: [expectation], timeout: 5)
        cancellable.cancel()
    }

    // MARK: - 审计修复回归

    func testDeleteTaskLogsDeletedWithSnapshot() throws {
        let task = try store.createTask(title: "删掉我", status: .waiting, waitingOn: "X", at: now)
        let deletedAt = now.addingTimeInterval(60)
        try store.deleteTask(id: task.id!, at: deletedAt)

        let entries = try store.activity(forTaskId: task.id!)
        XCTAssertEqual(entries.map(\.type), [.created, .deleted])
        XCTAssertEqual(payloadDict(entries[1]), ["title": "删掉我", "status": "waiting"])
        XCTAssertEqual(entries[1].createdAt, deletedAt)
    }

    func testIndexMigrationIsIdempotentOnReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "board.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do { _ = try TaskStore.open(at: url) } // 首次建库 + migrate，出作用域后连接关闭
        let reopened = try TaskStore.open(at: url) // 重开后再次 migrate，不得报错

        let indexes = try reopened.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        for index in ["activity_log_task_id", "activity_log_created_at", "focus_items_date", "tasks_parent_id"] {
            XCTAssertTrue(indexes.contains(index), "missing index: \(index)")
        }
    }

    // MARK: - 快照归一化与字段清除

    func testSaveFocusSnapshotNormalizesItemDatesToDay() throws {
        let day = Calendar.current.startOfDay(for: now)
        let wrongDate = day.addingTimeInterval(86_400 * 3)
        let rows = [FocusItemRow(date: wrongDate, taskId: 3, reason: "date 与 day 不一致", rank: 1)]
        try store.saveFocusSnapshot(day: day.addingTimeInterval(3600), items: rows)

        let fetched = try store.focusSnapshot(forDay: day)
        XCTAssertEqual(fetched.map(\.taskId), [3])
        XCTAssertEqual(fetched[0].date, day)
        XCTAssertTrue(try store.focusSnapshot(forDay: wrongDate).isEmpty)

        // 再次 save 正确替换，脏数据不残留
        let updated = [FocusItemRow(date: wrongDate, taskId: 9, reason: "替换", rank: 1)]
        try store.saveFocusSnapshot(day: day, items: updated)
        XCTAssertEqual(try store.focusSnapshot(forDay: day).map(\.taskId), [9])
    }

    func testClearNoteAndWaitingOn() throws {
        let task = try store.createTask(title: "t", status: .waiting, waitingOn: "Peter", note: "备注", at: now)
        try store.updateTask(id: task.id!, clearNote: true, clearWaitingOn: true, at: now)

        let fetched = try store.task(id: task.id!)
        XCTAssertNil(fetched?.note)
        XCTAssertNil(fetched?.waitingOn)

        let edited = try store.activity(forTaskId: task.id!).filter { $0.type == .edited }
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(payloadDict(edited[0])?["fields"], "note,waiting_on")
    }

    func testDueDateWinsOverClearDueDateWithoutDuplicateFields() throws {
        let task = try store.createTask(title: "t", dueDate: now, at: now)
        let newDue = now.addingTimeInterval(86_400)
        try store.updateTask(id: task.id!, dueDate: newDue, clearDueDate: true, at: now)

        XCTAssertEqual(try store.task(id: task.id!)?.dueDate, newDue)
        let edited = try store.activity(forTaskId: task.id!).filter { $0.type == .edited }
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(payloadDict(edited[0])?["fields"], "due_date")
    }

    func testCreateAsDoneLogsCreatedAndCompleted() throws {
        let task = try store.createTask(title: "t", status: .done, at: now)
        XCTAssertEqual(task.completedAt, now)
        XCTAssertEqual(try store.activity(forTaskId: task.id!).map(\.type), [.created, .completed])
    }

    // MARK: - 子任务

    func testCreateSubtaskAndQuery() throws {
        let parent = try store.createTask(title: "父任务", at: now)
        let sub = try store.createTask(title: "子任务", parentId: parent.id!, at: now)

        XCTAssertEqual(sub.parentId, parent.id)
        XCTAssertEqual(try store.subtasks(of: parent.id!).map(\.title), ["子任务"])
        XCTAssertTrue(try store.subtasks(of: sub.id!).isEmpty)
    }

    func testDeleteParentCascadesSubtasksWithLogs() throws {
        let parent = try store.createTask(title: "父任务", at: now)
        let sub1 = try store.createTask(title: "子1", parentId: parent.id!, at: now)
        let sub2 = try store.createTask(title: "子2", parentId: parent.id!, at: now)

        try store.deleteTask(id: parent.id!, at: now)

        XCTAssertEqual(try store.allTasks().count, 0)
        for id in [parent.id!, sub1.id!, sub2.id!] {
            let deleted = try store.activity(forTaskId: id).filter { $0.type == .deleted }
            XCTAssertEqual(deleted.count, 1, "task \(id) 应各有一条 deleted 日志")
        }
    }

    func testDeleteSubtaskLeavesParentIntact() throws {
        let parent = try store.createTask(title: "父任务", at: now)
        let sub = try store.createTask(title: "子任务", parentId: parent.id!, at: now)

        try store.deleteTask(id: sub.id!, at: now)

        XCTAssertEqual(try store.allTasks().map(\.title), ["父任务"])
    }
}
