import Foundation
import RuleEngine

/// Brain Dump 产出的一条任务提案（AI 与降级解析器产出同构）。
public struct TaskProposal: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// 简洁标题，保留原文语言
    public var title: String
    public var status: TaskStatus
    /// 原文中的时间表述原始片段（模型只标注、不计算）
    public var dueText: String?
    /// dueText 经规则代码解析后的日期（不可解析则为 nil，绝不猜测）
    public var dueDate: Date?
    public var waitingOn: String?

    public init(
        id: UUID = UUID(),
        title: String,
        status: TaskStatus,
        dueText: String? = nil,
        dueDate: Date? = nil,
        waitingOn: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.dueText = dueText
        self.dueDate = dueDate
        self.waitingOn = waitingOn
    }
}

public struct BrainDumpOutcome: Sendable {
    public var proposals: [TaskProposal]
    /// true = 走的降级解析器（AI 不可用或出错）
    public var usedFallback: Bool

    public init(proposals: [TaskProposal], usedFallback: Bool) {
        self.proposals = proposals
        self.usedFallback = usedFallback
    }
}
