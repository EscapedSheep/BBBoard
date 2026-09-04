import Foundation

/// Daily Focus 打分配置。权重是直觉起点（M5 设置页可调）：
/// - 逾期最强信号（基础 40 + 每天 4，封顶 +20）；今天截止 30 > 明天 16 > 7 天内 8
/// - waiting 每等一天 4 分，封顶 28（“谁挡着我”是核心差异化，权重大于 doing 停滞）
/// - doing 每停滞一天 2.5 分，封顶 20
/// - 最近活跃（7 天内 activity 数）每次 3 分，封顶 15——只作加权让有实质原因的任务靠前，
///   不单独构成入选理由（"最近 N 次更新"不构成关注理由，2026-09 用户实测砍掉）
public struct FocusConfig: Sendable, Equatable {
    public var maxItems: Int
    public var activityWindowDays: Int
    public var overdueBase: Double
    public var overduePerDay: Double
    public var overduePerDayCap: Double
    public var dueToday: Double
    public var dueTomorrow: Double
    public var dueThisWeek: Double
    public var waitingPerDay: Double
    public var waitingCap: Double
    public var doingPerDay: Double
    public var doingCap: Double
    public var activityPerEvent: Double
    public var activityCap: Double

    public init(
        maxItems: Int = 3,
        activityWindowDays: Int = 7,
        overdueBase: Double = 40,
        overduePerDay: Double = 4,
        overduePerDayCap: Double = 20,
        dueToday: Double = 30,
        dueTomorrow: Double = 16,
        dueThisWeek: Double = 8,
        waitingPerDay: Double = 4,
        waitingCap: Double = 28,
        doingPerDay: Double = 2.5,
        doingCap: Double = 20,
        activityPerEvent: Double = 3,
        activityCap: Double = 15
    ) {
        self.maxItems = maxItems
        self.activityWindowDays = activityWindowDays
        self.overdueBase = overdueBase
        self.overduePerDay = overduePerDay
        self.overduePerDayCap = overduePerDayCap
        self.dueToday = dueToday
        self.dueTomorrow = dueTomorrow
        self.dueThisWeek = dueThisWeek
        self.waitingPerDay = waitingPerDay
        self.waitingCap = waitingCap
        self.doingPerDay = doingPerDay
        self.doingCap = doingCap
        self.activityPerEvent = activityPerEvent
        self.activityCap = activityCap
    }

    public static let `default` = FocusConfig()
}

public struct FocusItem: Sendable, Equatable, Identifiable {
    public var taskId: Int64
    public var taskTitle: String
    /// 主因（贡献最大的单项），如「已逾期 2 天」
    public var reason: String
    public var score: Double
    public var rank: Int

    public var id: Int64 { taskId }

    public init(taskId: Int64, taskTitle: String, reason: String, score: Double, rank: Int) {
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.reason = reason
        self.score = score
        self.rank = rank
    }
}

/// M3 计划中的可选 LLM 重排挂点（当前未启用，Apple Intelligence 不可用时无意义）。
/// 实现者在 TaskStore/视图层算出规则版 Top N 后调用 rerank 即可。
public protocol FocusReranker: Sendable {
    func rerank(_ items: [FocusItem]) async -> [FocusItem]
}

extension RuleEngine {
    /// 计算 Daily Focus：非 done 任务按多因子加权打分，取 Top N（默认 3）。
    /// 零分任务（无截止/非 waiting/非 doing/无近期活跃）不入选——宁缺毋滥。
    public static func focus(
        tasks: [TaskSnapshot],
        activityCounts: [Int64: Int],
        now: Date,
        config: FocusConfig = .default
    ) -> [FocusItem] {
        let scored = tasks.compactMap { focusScore(task: $0, activityCount: activityCounts[$0.id] ?? 0, now: now, config: config) }
        let sorted = scored.sorted { ($0.score, -$0.task.id) > ($1.score, -$1.task.id) }
        return sorted.prefix(config.maxItems).enumerated().map { index, entry in
            FocusItem(
                taskId: entry.task.id,
                taskTitle: entry.task.title,
                reason: entry.reason,
                score: entry.score,
                rank: index + 1
            )
        }
    }

    private static func focusScore(
        task: TaskSnapshot,
        activityCount: Int,
        now: Date,
        config: FocusConfig
    ) -> (task: TaskSnapshot, score: Double, reason: String)? {
        guard task.status != .done else { return nil }
        var components: [(score: Double, reason: String)] = []

        if let dueDate = task.dueDate {
            let days = dayDiff(from: now, to: dueDate)
            if days < 0 {
                let over = -days
                components.append((config.overdueBase + min(Double(over) * config.overduePerDay, config.overduePerDayCap), "已逾期 \(over) 天"))
            } else if days == 0 {
                components.append((config.dueToday, "今天截止"))
            } else if days == 1 {
                components.append((config.dueTomorrow, "明天截止"))
            } else if days <= 7 {
                components.append((config.dueThisWeek, "\(days) 天后截止"))
            }
        }

        if task.status == .waiting, let waitingSince = task.waitingSince {
            let age = dayDiff(from: waitingSince, to: now)
            if age > 0 {
                components.append((min(Double(age) * config.waitingPerDay, config.waitingCap), "等待 \(age) 天未跟进"))
            }
        }

        if task.status == .doing {
            let age = dayDiff(from: task.updatedAt, to: now)
            if age > 0 {
                components.append((min(Double(age) * config.doingPerDay, config.doingCap), "进行中 \(age) 天"))
            }
        }

        // 活跃度只加权、不单独成由："最近 N 次更新"不构成关注理由，
        // 只让已有实质原因（截止/等待/推进中）的任务排得更靠前
        let activityBoost = min(Double(activityCount) * config.activityPerEvent, config.activityCap)

        guard !components.isEmpty, let primary = components.max(by: { $0.score < $1.score }) else { return nil }
        let total = components.reduce(0) { $0 + $1.score } + activityBoost
        return (task, total, primary.reason)
    }
}
