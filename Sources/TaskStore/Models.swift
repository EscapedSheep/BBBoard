import Foundation
import GRDB
import RuleEngine

// GRDB 为 RawRepresentable 枚举提供 DatabaseValueConvertible 默认实现。
extension TaskStatus: DatabaseValueConvertible {}

public enum TaskSource: String, Codable, Sendable, DatabaseValueConvertible {
    case manual
    case braindump
    case cleanup
}

/// 任务所属领域：工作 / 个人。看板列内按此分组展示。
public enum TaskArea: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case work
    case personal

    public var displayName: String {
        switch self {
        case .work: "工作"
        case .personal: "个人"
        }
    }
}

/// activity_log 的事件类型。
public enum ActivityType: String, Codable, Sendable, DatabaseValueConvertible {
    case created
    case viewed
    case statusChanged = "status_changed"
    case edited
    case completed
    case deleted
}

/// tasks 表记录。
public struct Task: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public var id: Int64?
    public var title: String
    public var note: String?
    public var status: TaskStatus
    public var area: TaskArea
    /// 手动钉进 FOCUS 区（跨天保持，直到取消或完成）；规则选出的每日 Focus 不受影响。
    public var focusPinned: Bool
    public var projectId: Int64?
    /// 父任务 id（nil = 顶层任务）。子任务嵌套在父卡下展示，不参与看板列/Focus/建议。
    public var parentId: Int64?
    public var dueDate: Date?
    public var waitingOn: String?
    public var waitingSince: Date?
    public var source: TaskSource
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public static let databaseTableName = "tasks"

    enum CodingKeys: String, CodingKey {
        case id, title, note, status, area, source
        case focusPinned = "focus_pinned"
        case projectId = "project_id"
        case parentId = "parent_id"
        case dueDate = "due_date"
        case waitingOn = "waiting_on"
        case waitingSince = "waiting_since"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// 供规则引擎使用的只读快照。未持久化任务（id 为 nil）以哨兵 id=0 兜底，
    /// 快照仅供纯函数规则消费，不会回写数据库。
    public var snapshot: TaskSnapshot {
        TaskSnapshot(
            id: id ?? 0,
            title: title,
            status: status,
            dueDate: dueDate,
            waitingOn: waitingOn,
            waitingSince: waitingSince,
            updatedAt: updatedAt
        )
    }
}

/// projects 表记录：任务成组（M4）。
public struct Project: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public var id: Int64?
    public var name: String
    public var createdAt: Date

    public static let databaseTableName = "projects"

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// activity_log 表记录。
public struct ActivityLog: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public var id: Int64?
    public var taskId: Int64
    public var type: ActivityType
    /// JSON，如 {"from":"doing","to":"waiting"}
    public var payload: String?
    public var createdAt: Date

    public static let databaseTableName = "activity_log"

    enum CodingKeys: String, CodingKey {
        case id, type, payload
        case taskId = "task_id"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum CorrectionKind: String, Codable, Sendable, DatabaseValueConvertible {
    case braindump
    case dedup
}

/// focus_items 表记录：Daily Focus 每日快照（无自增主键，date+rank 定位）。
public struct FocusItemRow: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    /// 所属自然日（startOfDay）
    public var date: Date
    public var taskId: Int64
    public var reason: String
    public var rank: Int

    public static let databaseTableName = "focus_items"

    enum CodingKeys: String, CodingKey {
        case date, reason, rank
        case taskId = "task_id"
    }

    public init(date: Date, taskId: Int64, reason: String, rank: Int) {
        self.date = date
        self.taskId = taskId
        self.reason = reason
        self.rank = rank
    }
}

/// corrections 表记录：用户对 AI 提案的修改痕迹（M2 braindump 起用）。
public struct Correction: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public var id: Int64?
    public var kind: CorrectionKind
    public var rawInput: String
    /// JSON，AI/降级解析器的原始产出
    public var aiOutput: String
    /// JSON，用户确认后的最终版本
    public var finalOutput: String
    public var createdAt: Date

    public static let databaseTableName = "corrections"

    enum CodingKeys: String, CodingKey {
        case id, kind
        case rawInput = "raw_input"
        case aiOutput = "ai_output"
        case finalOutput = "final_output"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
