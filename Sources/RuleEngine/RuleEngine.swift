import Foundation

/// 任务五态，对应看板五列。
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case backlog
    case today
    case doing
    case waiting
    case done

    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .today: "Todo"
        case .doing: "Doing"
        case .waiting: "Waiting"
        case .done: "Done"
        }
    }
}

/// 规则引擎的输入：任务的只读快照，与存储层解耦。
public struct TaskSnapshot: Sendable, Equatable {
    public var id: Int64
    public var title: String
    public var status: TaskStatus
    public var dueDate: Date?
    public var waitingOn: String?
    public var waitingSince: Date?
    public var updatedAt: Date

    public init(
        id: Int64,
        title: String,
        status: TaskStatus,
        dueDate: Date? = nil,
        waitingOn: String? = nil,
        waitingSince: Date? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.dueDate = dueDate
        self.waitingOn = waitingOn
        self.waitingSince = waitingSince
        self.updatedAt = updatedAt
    }
}

public struct Suggestion: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case overdue
        case dueApproaching
        case waitingTooLong
        case doingTooLong
    }

    public var taskId: Int64
    public var taskTitle: String
    public var kind: Kind
    /// 面向用户的中文原因，如「已等待 3 天，要跟进吗？」
    public var reason: String

    public var id: String { "\(taskId)-\(kind.rawValue)" }

    public init(taskId: Int64, taskTitle: String, kind: Kind, reason: String) {
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.kind = kind
        self.reason = reason
    }
}

extension Suggestion.Kind {
    /// 建议列表的排序优先级（越小越靠前）
    var sortOrder: Int {
        switch self {
        case .overdue: 0
        case .dueApproaching: 1
        case .waitingTooLong: 2
        case .doingTooLong: 3
        }
    }
}

/// 规则阈值，全部以自然日计。
public struct RuleThresholds: Sendable, Equatable {
    /// 距截止多少天内视为「临近」
    public var dueApproachingDays: Int
    /// waiting 状态持续多少天视为「等太久」
    public var waitingTooLongDays: Int
    /// doing 状态多少天没更新视为「做太久」
    public var doingTooLongDays: Int

    public init(dueApproachingDays: Int = 1, waitingTooLongDays: Int = 3, doingTooLongDays: Int = 5) {
        self.dueApproachingDays = dueApproachingDays
        self.waitingTooLongDays = waitingTooLongDays
        self.doingTooLongDays = doingTooLongDays
    }

    public static let `default` = RuleThresholds()
}

/// 纯函数规则引擎：不碰数据库、不碰 AI。
public enum RuleEngine {
    /// 输入任务快照与当前时间，输出建议列表。
    /// 每个任务至多产生一条建议（按规则优先级取第一条命中）；
    /// 输出排序稳定：overdue → dueApproaching → waitingTooLong → doingTooLong，同级按 taskId。
    public static func suggestions(
        for tasks: [TaskSnapshot],
        now: Date = Date(),
        thresholds: RuleThresholds = .default
    ) -> [Suggestion] {
        var result: [Suggestion] = []
        for task in tasks where task.status != .done {
            if let suggestion = dueSuggestion(for: task, now: now, thresholds: thresholds)
                ?? waitingSuggestion(for: task, now: now, thresholds: thresholds)
                ?? doingSuggestion(for: task, now: now, thresholds: thresholds)
            {
                result.append(suggestion)
            }
        }
        return result.sorted {
            ($0.kind.sortOrder, $0.taskId) < ($1.kind.sortOrder, $1.taskId)
        }
    }

    // MARK: - Rules

    private static func dueSuggestion(for task: TaskSnapshot, now: Date, thresholds: RuleThresholds) -> Suggestion? {
        guard let dueDate = task.dueDate else { return nil }
        let days = dayDiff(from: now, to: dueDate)
        if days < 0 {
            return Suggestion(
                taskId: task.id, taskTitle: task.title, kind: .overdue,
                reason: "截止日期已过 \(-days) 天")
        }
        if days <= thresholds.dueApproachingDays {
            let reason: String = switch days {
            case 0: "今天截止"
            case 1: "明天截止"
            default: "\(days) 天后截止"
            }
            return Suggestion(taskId: task.id, taskTitle: task.title, kind: .dueApproaching, reason: reason)
        }
        return nil
    }

    private static func waitingSuggestion(for task: TaskSnapshot, now: Date, thresholds: RuleThresholds) -> Suggestion? {
        guard task.status == .waiting, let waitingSince = task.waitingSince else { return nil }
        let days = dayDiff(from: waitingSince, to: now)
        guard days >= thresholds.waitingTooLongDays else { return nil }
        let reason: String
        if let waitingOn = task.waitingOn, !waitingOn.isEmpty {
            reason = "等待「\(waitingOn)」已 \(days) 天，要跟进吗？"
        } else {
            reason = "已等待 \(days) 天，要跟进吗？"
        }
        return Suggestion(taskId: task.id, taskTitle: task.title, kind: .waitingTooLong, reason: reason)
    }

    private static func doingSuggestion(for task: TaskSnapshot, now: Date, thresholds: RuleThresholds) -> Suggestion? {
        guard task.status == .doing else { return nil }
        let days = dayDiff(from: task.updatedAt, to: now)
        guard days >= thresholds.doingTooLongDays else { return nil }
        return Suggestion(
            taskId: task.id, taskTitle: task.title, kind: .doingTooLong,
            reason: "进行中已 \(days) 天没有更新，还在推进吗？")
    }

    /// 按自然日（本地时区 0 点）计算 a → b 的天数差。模块内共享（FocusScoring 也用）。
    static func dayDiff(from a: Date, to b: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: a),
            to: calendar.startOfDay(for: b)
        ).day ?? 0
    }
}
