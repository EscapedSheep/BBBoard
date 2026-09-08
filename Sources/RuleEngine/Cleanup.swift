import Foundation

/// 停滞任务的类别
public enum StagnantKind: String, Sendable, Equatable, CaseIterable {
    case backlogStale   // 长期躺在 backlog
    case doingStale     // 长期 doing 无更新
    case waitingStale   // 长期 waiting 未跟进
}

public struct StagnantTask: Sendable, Equatable, Identifiable {
    public var taskId: Int64
    public var taskTitle: String
    public var kind: StagnantKind
    /// 停滞天数
    public var days: Int
    /// 面向用户的中文原因，如「在 Backlog 躺了 45 天」
    public var reason: String

    public var id: String { "\(taskId)-\(kind.rawValue)" }

    public init(taskId: Int64, taskTitle: String, kind: StagnantKind, days: Int, reason: String) {
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.kind = kind
        self.days = days
        self.reason = reason
    }
}

/// 停滞检测阈值（自然日）
public struct CleanupConfig: Sendable, Equatable {
    public var backlogStaleDays: Int
    public var doingStaleDays: Int
    public var waitingStaleDays: Int

    public init(backlogStaleDays: Int = 30, doingStaleDays: Int = 7, waitingStaleDays: Int = 7) {
        self.backlogStaleDays = backlogStaleDays
        self.doingStaleDays = doingStaleDays
        self.waitingStaleDays = waitingStaleDays
    }

    public static let `default` = CleanupConfig()
}

extension RuleEngine {
    /// 停滞检测：非 done 任务中找出三类停滞，按停滞天数降序（同天按 taskId 升序，稳定）。
    /// 天数一律用模块内 dayDiff（自然日）。
    public static func stagnantTasks(
        for tasks: [TaskSnapshot],
        now: Date = Date(),
        config: CleanupConfig = .default
    ) -> [StagnantTask] {
        var result: [StagnantTask] = []
        for task in tasks {
            if let stagnant = stagnantTask(for: task, now: now, config: config) {
                result.append(stagnant)
            }
        }
        return result.sorted {
            ($0.days, -$0.taskId) > ($1.days, -$1.taskId)
        }
    }

    /// 单个任务的停滞判定。三类状态互斥，一个任务至多命中一类。
    private static func stagnantTask(for task: TaskSnapshot, now: Date, config: CleanupConfig) -> StagnantTask? {
        switch task.status {
        case .backlog:
            let days = dayDiff(from: task.updatedAt, to: now)
            guard days >= config.backlogStaleDays else { return nil }
            return StagnantTask(
                taskId: task.id, taskTitle: task.title, kind: .backlogStale, days: days,
                reason: "在 Backlog 躺了 \(days) 天，还值得做吗？")
        case .doing:
            let days = dayDiff(from: task.updatedAt, to: now)
            guard days >= config.doingStaleDays else { return nil }
            return StagnantTask(
                taskId: task.id, taskTitle: task.title, kind: .doingStale, days: days,
                reason: "进行中 \(days) 天没有更新")
        case .waiting:
            guard let waitingSince = task.waitingSince else { return nil }
            let days = dayDiff(from: waitingSince, to: now)
            guard days >= config.waitingStaleDays else { return nil }
            let reason: String
            if let waitingOn = task.waitingOn, !waitingOn.isEmpty {
                reason = "等待「\(waitingOn)」\(days) 天未跟进"
            } else {
                reason = "等待 \(days) 天未跟进"
            }
            return StagnantTask(
                taskId: task.id, taskTitle: task.title, kind: .waitingStale, days: days,
                reason: reason)
        case .today, .done:
            return nil
        }
    }
}
