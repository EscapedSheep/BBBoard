import AIParser
import Foundation
import Observation
import RuleEngine
import TaskStore

/// 面板的视图模型：GRDB 观察驱动刷新，建议由规则引擎实时计算。
@MainActor
@Observable
final class BoardViewModel {
    private let store: TaskStore

    private(set) var tasks: [Task] = []
    private(set) var suggestions: [Suggestion] = []
    /// Daily Focus Top N（每日快照：当天复用，跨天或快照任务全部完成/消失时重新生成）
    private(set) var focusItems: [FocusItem] = []
    var errorMessage: String?

    /// 本次会话内被「忽略」的建议 id（Suggestion.id = taskId-kind）。
    private var dismissedSuggestionIDs: Set<String> = []

    // Brain Dump 确认流状态
    var proposals: [TaskProposal] = []
    var isParsingBrainDump = false
    /// 解析无结果时的安静提示
    var brainDumpNotice: String?
    /// 解析所用的原始输入与原始产出（corrections 记录用）
    private var lastBrainDumpRaw = ""
    private var lastAIOutputJSON = "[]"

    init(store: TaskStore) {
        self.store = store
        observeTasks()
    }

    // MARK: - 展示数据

    /// 顶层任务（子任务不参与看板列、Focus 与建议，随父卡展示）。
    private var topLevelTasks: [Task] {
        tasks.filter { $0.parentId == nil }
    }

    func tasks(in status: TaskStatus) -> [Task] {
        topLevelTasks.filter { $0.status == status }
    }

    /// 某任务的子任务（按创建顺序）。
    func subtasks(of task: Task) -> [Task] {
        tasks.filter { $0.parentId == task.id }
    }

    /// 子任务完成度（done, total），无子任务时 total 为 0。
    func subtaskProgress(of task: Task) -> (done: Int, total: Int) {
        let subs = subtasks(of: task)
        return (subs.filter { $0.status == .done }.count, subs.count)
    }

    // MARK: - 观察

    /// 观察抛错（如数据库被重建）不永久退出：短暂等待后重建观察流，取消时正常结束。
    private func observeTasks() {
        let store = self.store
        _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                do {
                    for try await tasks in store.tasksObservation().values(in: store.dbQueue) {
                        self?.apply(tasks: tasks)
                    }
                } catch {
                    if _Concurrency.Task.isCancelled { break }
                    NSLog("BoardApp: 数据观察中断，1 秒后重试: \(error)")
                    self?.errorMessage = "数据观察中断：\(error.localizedDescription)"
                    try? await _Concurrency.Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func apply(tasks: [Task]) {
        self.tasks = tasks
        let topLevel = tasks.filter { $0.parentId == nil }
        self.suggestions = RuleEngine
            .suggestions(for: topLevel.map(\.snapshot), now: Date())
            .filter { !dismissedSuggestionIDs.contains($0.id) }
        recomputeFocus(topLevel)
    }

    // MARK: - Daily Focus

    /// 上次生成/复用快照的日期（startOfDay）；面板重新展示时比对，跨天则重算
    private var focusDay: Date?

    /// 幂等规则（计划 §M3）：当天快照存在且引用任务未全部完成 → 直接复用；
    /// 跨天 / 快照任务全部完成或消失 → 重新生成并覆盖快照。
    private func recomputeFocus(_ tasks: [Task]) {
        let today = Calendar.current.startOfDay(for: Date())
        do {
            let snapshot = try store.focusSnapshot(forDay: today)
            let allResolved = !snapshot.isEmpty && snapshot.allSatisfy { row in
                guard let task = tasks.first(where: { $0.id == row.taskId }) else { return true }
                return task.status == .done
            }
            if !snapshot.isEmpty, !allResolved {
                focusItems = snapshot.compactMap { row in
                    guard let task = tasks.first(where: { $0.id == row.taskId }) else { return nil }
                    return FocusItem(taskId: row.taskId, taskTitle: task.title, reason: row.reason, score: 0, rank: row.rank)
                }
                focusDay = today
                return
            }

            let counts = try store.recentActivityCounts(days: FocusConfig.default.activityWindowDays)
            let items = RuleEngine.focus(tasks: tasks.map(\.snapshot), activityCounts: counts, now: Date())
            // M3 可选 LLM 重排挂点：此处可对 items 应用 FocusReranker（当前未启用）
            try store.saveFocusSnapshot(
                day: today,
                items: items.map { FocusItemRow(date: today, taskId: $0.taskId, reason: $0.reason, rank: $0.rank) }
            )
            focusItems = items
            focusDay = today
        } catch {
            NSLog("BoardApp: focus 计算失败: \(error)")
        }
    }

    /// 面板展示/展开时调用：跨天则重新计算 Daily Focus（快照按天替换）。
    func refreshFocusIfDayChanged() {
        let today = Calendar.current.startOfDay(for: Date())
        guard focusDay != today else { return }
        recomputeFocus(topLevelTasks)
    }

    /// 点击 FOCUS 行：标记为进行中（最小可用交互）。
    func activateFocus(_ item: FocusItem) {
        guard let task = tasks.first(where: { $0.id == item.taskId }) else { return }
        setStatus(task, to: .doing)
    }

    // MARK: - 操作

    func addTask(title: String, status: TaskStatus, dueDate: Date?, waitingOn: String?) {
        perform("创建任务失败") {
            try store.createTask(title: title, status: status, dueDate: dueDate, waitingOn: waitingOn)
        }
    }

    /// 添加子任务（挂在父卡下，状态 today，不进看板列）。
    func addSubtask(to parent: Task, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parentId = parent.id else { return }
        perform("创建子任务失败") {
            try store.createTask(title: trimmed, status: .today, parentId: parentId)
        }
    }

    func rename(_ task: Task, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title, let id = task.id else { return }
        perform("重命名失败") { try store.updateTask(id: id, title: trimmed) }
    }

    /// 更新卡片说明；空文本 = 清除说明。
    func setNote(_ task: Task, _ note: String) {
        guard let id = task.id else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (task.note ?? "") else { return }
        perform("更新说明失败") {
            if trimmed.isEmpty {
                try store.updateTask(id: id, clearNote: true)
            } else {
                try store.updateTask(id: id, note: trimmed)
            }
        }
    }

    func setStatus(_ task: Task, to status: TaskStatus) {
        guard let id = task.id else { return }
        perform("状态更新失败") { try store.setStatus(id, to: status) }
    }

    func toggleDone(_ task: Task) {
        setStatus(task, to: task.status == .done ? .today : .done)
    }

    func delete(_ task: Task) {
        guard let id = task.id else { return }
        perform("删除失败") { try store.deleteTask(id: id) }
    }

    /// 清空所有已完成任务（逐条删除，各记一条 deleted 日志，与单个删除行为一致）。
    func clearDone() {
        perform("清空已完成失败") {
            for task in tasks where task.status == .done {
                if let id = task.id { try store.deleteTask(id: id) }
            }
        }
    }

    func dismiss(_ suggestion: Suggestion) {
        dismissedSuggestionIDs.insert(suggestion.id)
        suggestions.removeAll { $0.id == suggestion.id }
    }

    /// 「去处理」：把任务拉回 Todo 列。
    func handle(_ suggestion: Suggestion) {
        perform("操作失败") { try store.setStatus(suggestion.taskId, to: .today) }
        dismiss(suggestion)
    }

    /// 返回是否成功，供需要按结果继续动作的调用方（如提案确认后才丢弃）。
    @discardableResult
    private func perform(_ failurePrefix: String, _ action: () throws -> Void) -> Bool {
        do {
            try action()
            errorMessage = nil
            return true
        } catch {
            NSLog("BoardApp: \(failurePrefix): \(error)")
            errorMessage = "\(failurePrefix)：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Brain Dump 确认流

    /// AI 不可用时的 UI 提示；可用时为 nil。
    var aiUnavailableHint: String? {
        AIAvailabilityProbe.current.hint
    }

    func runBrainDump(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isParsingBrainDump else { return }
        isParsingBrainDump = true
        brainDumpNotice = nil
        NSLog("BoardApp: brain dump parse start (\(trimmed.count) chars)")
        _Concurrency.Task { [weak self] in
            let outcome = await BrainDumpParser.parse(trimmed)
            guard let self else { return }
            self.isParsingBrainDump = false
            NSLog("BoardApp: brain dump parse done, \(outcome.proposals.count) proposals, fallback=\(outcome.usedFallback)")
            if outcome.proposals.isEmpty {
                self.brainDumpNotice = "没识别出任务，试试换个说法"
                return
            }
            self.lastBrainDumpRaw = trimmed
            self.lastAIOutputJSON = Self.jsonString(outcome.proposals) ?? "[]"
            self.proposals = outcome.proposals
        }
    }

    /// 编辑提案卡片（标题/状态/日期/等待对象均就地修改）。
    func updateProposal(_ updated: TaskProposal) {
        guard let index = proposals.firstIndex(where: { $0.id == updated.id }) else { return }
        proposals[index] = updated
    }

    func discardProposal(_ proposal: TaskProposal) {
        proposals.removeAll { $0.id == proposal.id }
    }

    /// 确认入库：source=.braindump，并写 corrections（raw input + 原始产出 JSON + 最终确认 JSON）。
    /// 入库失败时保留提案，避免用户已确认的内容无声丢失。
    func confirmProposal(_ proposal: TaskProposal) {
        let persisted = perform("提案入库失败") {
            try store.createTask(
                title: proposal.title,
                status: proposal.status,
                dueDate: proposal.dueDate,
                waitingOn: proposal.status == .waiting ? proposal.waitingOn : nil,
                source: .braindump
            )
            try store.insertCorrection(
                kind: .braindump,
                rawInput: lastBrainDumpRaw,
                aiOutput: lastAIOutputJSON,
                finalOutput: Self.jsonString(proposal) ?? "{}"
            )
        }
        if persisted {
            discardProposal(proposal)
        }
    }

    func confirmAllProposals() {
        // confirmProposal 会就地移除已入库的提案，先拍快照再迭代
        let all = proposals
        for proposal in all {
            confirmProposal(proposal)
        }
    }

    private static func jsonString(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
