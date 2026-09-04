import Foundation
import GRDB
import RuleEngine

public enum TaskStoreError: Error, Equatable {
    case taskNotFound(Int64)
}

/// GRDB 封装：迁移、CRUD、状态流转、activity_log、数据库观察。
public final class TaskStore: Sendable {
    public let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// 内存数据库，供测试使用。
    public static func inMemory() throws -> TaskStore {
        try TaskStore(dbQueue: DatabaseQueue())
    }

    /// 打开（必要时创建）指定路径的数据库文件。
    public static func open(at url: URL) throws -> TaskStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try TaskStore(dbQueue: DatabaseQueue(path: url.path(percentEncoded: false)))
    }

    /// 默认库路径：~/Library/Application Support/BBBoard/board.sqlite
    public static func defaultDatabaseURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "BBBoard", directoryHint: .isDirectory)
            .appending(path: "board.sqlite")
    }

    // MARK: - Schema（实施计划 §4，五张表一次建齐）

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_schema") { db in
            try db.create(table: "projects") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "tasks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("note", .text)
                t.column("status", .text).notNull()
                t.column("project_id", .integer).references("projects")
                t.column("due_date", .date)
                t.column("waiting_on", .text)
                t.column("waiting_since", .date)
                t.column("source", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("completed_at", .datetime)
            }
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
            try db.create(table: "corrections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("raw_input", .text).notNull()
                t.column("ai_output", .text).notNull()
                t.column("final_output", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2_indexes") { db in
            try db.create(index: "activity_log_task_id", on: "activity_log", columns: ["task_id"], ifNotExists: true)
            try db.create(index: "activity_log_created_at", on: "activity_log", columns: ["created_at"], ifNotExists: true)
            try db.create(index: "focus_items_date", on: "focus_items", columns: ["date"], ifNotExists: true)
        }
        migrator.registerMigration("v3_subtasks") { db in
            try db.alter(table: "tasks") { t in
                t.add(column: "parent_id", .integer).references("tasks")
            }
            try db.create(index: "tasks_parent_id", on: "tasks", columns: ["parent_id"], ifNotExists: true)
        }
        return migrator
    }()

    // MARK: - CRUD

    @discardableResult
    public func createTask(
        title: String,
        status: TaskStatus = .today,
        dueDate: Date? = nil,
        waitingOn: String? = nil,
        note: String? = nil,
        parentId: Int64? = nil,
        source: TaskSource = .manual,
        at now: Date = Date()
    ) throws -> Task {
        var task = Task(
            id: nil,
            title: title,
            note: note,
            status: status,
            projectId: nil,
            parentId: parentId,
            dueDate: dueDate,
            waitingOn: status == .waiting ? waitingOn : nil,
            waitingSince: status == .waiting ? now : nil,
            source: source,
            createdAt: now,
            updatedAt: now,
            completedAt: status == .done ? now : nil
        )
        try dbQueue.write { db in
            try task.insert(db)
            try Self.log(db, taskId: task.id!, type: .created, payload: nil, at: now)
            if status == .done {
                try Self.log(db, taskId: task.id!, type: .completed, payload: nil, at: now)
            }
        }
        return task
    }

    /// 编辑非状态字段；传 nil 的字段保持不变。clearNote / clearWaitingOn / clearDueDate 显式清除对应字段；
    /// clearDueDate 与 dueDate 同传时以 dueDate 为准。
    public func updateTask(
        id: Int64,
        title: String? = nil,
        note: String? = nil,
        clearNote: Bool = false,
        dueDate: Date? = nil,
        clearDueDate: Bool = false,
        waitingOn: String? = nil,
        clearWaitingOn: Bool = false,
        at now: Date = Date()
    ) throws {
        try dbQueue.write { db in
            guard var task = try Task.fetchOne(db, id: id) else { throw TaskStoreError.taskNotFound(id) }
            var fields: [String] = []
            if let title, title != task.title { task.title = title; fields.append("title") }
            if let note, note != task.note { task.note = note; fields.append("note") }
            else if clearNote, task.note != nil { task.note = nil; fields.append("note") }
            if let dueDate, dueDate != task.dueDate { task.dueDate = dueDate; fields.append("due_date") }
            else if clearDueDate, task.dueDate != nil { task.dueDate = nil; fields.append("due_date") }
            if let waitingOn, waitingOn != task.waitingOn { task.waitingOn = waitingOn; fields.append("waiting_on") }
            else if clearWaitingOn, task.waitingOn != nil { task.waitingOn = nil; fields.append("waiting_on") }
            guard !fields.isEmpty else { return }
            task.updatedAt = now
            try task.update(db)
            let payload = Self.jsonPayload(["fields": fields.joined(separator: ",")])
            try Self.log(db, taskId: id, type: .edited, payload: payload, at: now)
        }
    }

    /// 状态流转：自动维护 waiting_since / completed_at，并写 status_changed（+ completed）日志。
    /// 同状态调用是 no-op。进入 waiting 时可用 waitingOn 更新等待对象。
    public func setStatus(_ id: Int64, to status: TaskStatus, waitingOn: String? = nil, at now: Date = Date()) throws {
        try dbQueue.write { db in
            guard var task = try Task.fetchOne(db, id: id) else { throw TaskStoreError.taskNotFound(id) }
            let from = task.status
            guard from != status else { return }
            task.status = status
            task.updatedAt = now
            if status == .waiting {
                task.waitingSince = now
                if let waitingOn { task.waitingOn = waitingOn }
            } else if from == .waiting {
                task.waitingSince = nil
                task.waitingOn = nil
            }
            if status == .done {
                task.completedAt = now
            } else if from == .done {
                task.completedAt = nil
            }
            try task.update(db)
            let payload = Self.jsonPayload(["from": from.rawValue, "to": status.rawValue])
            try Self.log(db, taskId: id, type: .statusChanged, payload: payload, at: now)
            if status == .done {
                try Self.log(db, taskId: id, type: .completed, payload: nil, at: now)
            }
        }
    }

    /// 删除任务；若是父任务，同事务级联删除其全部子任务（各记一条 deleted 日志）。
    public func deleteTask(id: Int64, at now: Date = Date()) throws {
        try dbQueue.write { db in
            guard let task = try Task.fetchOne(db, id: id) else { throw TaskStoreError.taskNotFound(id) }
            let subtasks = try Task.filter(Column("parent_id") == id).fetchAll(db)
            for subtask in subtasks {
                try subtask.delete(db)
                let payload = Self.jsonPayload(["title": subtask.title, "status": subtask.status.rawValue])
                try Self.log(db, taskId: subtask.id!, type: .deleted, payload: payload, at: now)
            }
            try task.delete(db)
            let payload = Self.jsonPayload(["title": task.title, "status": task.status.rawValue])
            try Self.log(db, taskId: id, type: .deleted, payload: payload, at: now)
        }
    }

    /// 某任务的子任务（按创建顺序）。
    public func subtasks(of parentId: Int64) throws -> [Task] {
        try dbQueue.read { db in
            try Task
                .filter(Column("parent_id") == parentId)
                .order(Column("created_at"), Column("id"))
                .fetchAll(db)
        }
    }

    public func allTasks() throws -> [Task] {
        try dbQueue.read { db in
            try Task.order(Column("created_at"), Column("id")).fetchAll(db)
        }
    }

    public func task(id: Int64) throws -> Task? {
        try dbQueue.read { db in try Task.fetchOne(db, id: id) }
    }

    public func activity(forTaskId taskId: Int64) throws -> [ActivityLog] {
        try dbQueue.read { db in
            try ActivityLog
                .filter(Column("task_id") == taskId)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    /// 记录 viewed 事件（如面板展示某任务时）。
    public func logViewed(taskId: Int64, at now: Date = Date()) throws {
        try dbQueue.write { db in
            try Self.log(db, taskId: taskId, type: .viewed, payload: nil, at: now)
        }
    }

    /// 记录一条 AI 提案的确认/修改痕迹（braindump 确认流起用）。
    public func insertCorrection(
        kind: CorrectionKind,
        rawInput: String,
        aiOutput: String,
        finalOutput: String,
        at now: Date = Date()
    ) throws {
        try dbQueue.write { db in
            var correction = Correction(
                id: nil, kind: kind,
                rawInput: rawInput, aiOutput: aiOutput, finalOutput: finalOutput,
                createdAt: now
            )
            try correction.insert(db)
        }
    }

    // MARK: - Daily Focus

    /// 最近 N 天每个任务的 activity 计数（activity_log 聚合）。
    public func recentActivityCounts(days: Int, now: Date = Date()) throws -> [Int64: Int] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now)
            ?? now.addingTimeInterval(TimeInterval(-days) * 86_400)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT task_id, COUNT(*) AS count FROM activity_log WHERE created_at >= ? GROUP BY task_id",
                arguments: [cutoff]
            )
            var counts: [Int64: Int] = [:]
            for row in rows {
                counts[row["task_id"]] = row["count"]
            }
            return counts
        }
    }

    /// 读取某自然日（调用方传 startOfDay）的 focus 快照，按 rank 排序。
    public func focusSnapshot(forDay day: Date) throws -> [FocusItemRow] {
        try dbQueue.read { db in
            try FocusItemRow
                .filter(Column("date") == day)
                .order(Column("rank"))
                .fetchAll(db)
        }
    }

    /// 写入某自然日的 focus 快照（先删后插，幂等）。
    /// day 归一化到 startOfDay，且强制覆盖每行的 date（以入参 day 为准，不信任 item.date）。
    public func saveFocusSnapshot(day: Date, items: [FocusItemRow]) throws {
        let day = Calendar.current.startOfDay(for: day)
        try dbQueue.write { db in
            try FocusItemRow.filter(Column("date") == day).deleteAll(db)
            for var item in items {
                item.date = day
                try item.insert(db)
            }
        }
    }

    // MARK: - Observation

    public typealias TasksObservation = ValueObservation<ValueReducers.Fetch<[Task]>>

    /// 全量任务观察，供 UI 驱动刷新（配合 GRDB 的 `values(in:)` 或 `start(in:)` 使用）。
    public func tasksObservation() -> TasksObservation {
        ValueObservation.tracking { db in
            try Task.order(Column("created_at"), Column("id")).fetchAll(db)
        }
    }

    // MARK: - Helpers

    static func log(_ db: Database, taskId: Int64, type: ActivityType, payload: String?, at now: Date) throws {
        var entry = ActivityLog(id: nil, taskId: taskId, type: type, payload: payload, createdAt: now)
        try entry.insert(db)
    }

    static func jsonPayload(_ dictionary: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
