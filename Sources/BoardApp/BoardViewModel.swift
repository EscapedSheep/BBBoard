import Foundation
import Observation
import RuleEngine
import TaskStore

/// 面板的视图模型：GRDB 观察驱动刷新，建议由规则引擎实时计算。
@MainActor
@Observable
final class BoardViewModel {
    private let store: TaskStore
    /// 用户可调阈值（M5 设置页）；派生数据（建议/Focus/清理）以此为准
    let settings: AppSettings

    private(set) var tasks: [Task] = []
    private(set) var suggestions: [Suggestion] = []
    /// Daily Focus Top N（每日快照：当天复用，跨天或快照任务全部完成/消失时重新生成）
    private(set) var focusItems: [FocusItem] = []
    /// 项目 id → 项目名（卡片徽标用）
    private(set) var projectNames: [Int64: String] = [:]
    var errorMessage: String?

    /// 本次会话内被「忽略」的建议 id（Suggestion.id = taskId-kind）。
    private var dismissedSuggestionIDs: Set<String> = []

    // Brain Dump 确认流状态
    var proposals: [TaskProposal] = []
    /// 解析无结果时的安静提示
    var brainDumpNotice: String?
    /// 解析所用的原始输入与原始产出（corrections 记录用）
    private var lastBrainDumpRaw = ""
    private var lastParsedJSON = "[]"

    init(store: TaskStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings
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
            .suggestions(for: topLevel.map(\.snapshot), now: Date(), thresholds: settings.ruleThresholds)
            .filter { !dismissedSuggestionIDs.contains($0.id) }
        // 项目徽标用名查找表（表极小，随任务观察顺手刷新）
        self.projectNames = ((try? store.projects()) ?? []).reduce(into: [:]) { dict, project in
            if let id = project.id { dict[id] = project.name }
        }
        recomputeFocus(topLevel)
    }

    /// FOCUS 区实际展示：手动钉住的卡在前（最近钉的优先，完成的自动隐藏），
    /// 后接规则选出的每日 Focus（剔除已钉住的，避免重复）。
    var focusDisplayItems: [FocusItem] {
        let pinned = topLevelTasks
            .filter { $0.focusPinned && $0.status != .done }
            .sorted { $0.updatedAt > $1.updatedAt }
        let pinnedIDs = Set(pinned.compactMap(\.id))
        return pinned.map {
            FocusItem(taskId: $0.id ?? 0, taskTitle: $0.title, reason: "手动置顶", score: 0, rank: 0)
        } + focusItems.filter { !pinnedIDs.contains($0.taskId) }
    }

    // MARK: - Daily Focus

    /// 上次生成/复用快照的日期（startOfDay）；面板重新展示时比对，跨天则重算
    private var focusDay: Date?

    /// 幂等规则（计划 §M3）：当天快照存在且引用任务未全部完成 → 直接复用（剔除已完成/已消失的任务）；
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
                    guard let task = tasks.first(where: { $0.id == row.taskId }), task.status != .done else { return nil }
                    return FocusItem(taskId: row.taskId, taskTitle: task.title, reason: row.reason, score: 0, rank: row.rank)
                }
                focusDay = today
                return
            }

            let counts = try store.recentActivityCounts(days: FocusConfig.default.activityWindowDays)
            let items = RuleEngine.focus(tasks: tasks.map(\.snapshot), activityCounts: counts, now: Date(), config: settings.focusConfig)
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

    /// 设置（阈值/Focus 条数）变化后重算派生数据（建议 + Focus）。
    func recomputeDerived() {
        apply(tasks: tasks)
    }

    // MARK: - 操作

    func addTask(title: String, status: TaskStatus, area: TaskArea = .work, dueDate: Date?, waitingOn: String?) {
        perform("创建任务失败") {
            try store.createTask(title: title, status: status, area: area, dueDate: dueDate, waitingOn: waitingOn)
        }
    }

    /// 切换任务领域（工作/个人），列内泳道分组随之变化。
    func setArea(_ task: Task, to area: TaskArea) {
        guard let id = task.id, area != task.area else { return }
        perform("领域更新失败") { try store.updateTask(id: id, area: area) }
    }

    /// 钉进/移出 FOCUS 区（手动焦点，跨天保持直到取消或完成）。
    func toggleFocusPinned(_ task: Task) {
        guard let id = task.id else { return }
        perform("焦点更新失败") { try store.setFocusPinned(id, !task.focusPinned) }
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

    /// 设置/清除截止时间（nil = 清除）。
    func setDueDate(_ task: Task, to dueDate: Date?) {
        guard let id = task.id else { return }
        perform("更新截止时间失败") {
            if let dueDate {
                try store.updateTask(id: id, dueDate: dueDate)
            } else {
                try store.updateTask(id: id, clearDueDate: true)
            }
        }
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

    /// 规则解析（同步、确定性），产出提案卡片待用户确认。
    func runBrainDump(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        brainDumpNotice = nil
        let parsed = BrainDumpParser.parse(trimmed)
        if parsed.isEmpty {
            brainDumpNotice = "没识别出任务，试试换个说法"
            return
        }
        lastBrainDumpRaw = trimmed
        lastParsedJSON = Self.jsonString(parsed) ?? "[]"
        proposals = parsed
    }

    /// 编辑提案卡片（标题/状态/日期/等待对象均就地修改）。
    func updateProposal(_ updated: TaskProposal) {
        guard let index = proposals.firstIndex(where: { $0.id == updated.id }) else { return }
        proposals[index] = updated
    }

    func discardProposal(_ proposal: TaskProposal) {
        proposals.removeAll { $0.id == proposal.id }
    }

    /// 确认入库：source=.braindump，并写 corrections（raw input + 解析产出 JSON + 最终确认 JSON）。
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
                aiOutput: lastParsedJSON,
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

    // MARK: - Smart Cleanup（M4）

    /// 本次清理的提案列表（重复合并 / 停滞处置 / 项目成组），确认或忽略后移除
    var cleanupProposals: [CleanupProposal] = []
    /// 跑完但什么也没发现时的安静提示
    var cleanupNotice: String?

    /// 跑一次智能清理：重复检测 + 停滞检测（均 RuleEngine 纯规则）。
    /// 产物一律是提案卡片，不做任何静默修改。
    func runSmartCleanup() {
        cleanupNotice = nil
        // 子任务不参与（随父卡管理）；done 不在清理视野内
        let snapshots = topLevelTasks.filter { $0.status != .done }.map(\.snapshot)
        let pairs = DuplicateDetector.findDuplicates(tasks: snapshots)
        let stagnant = RuleEngine.stagnantTasks(for: snapshots, config: settings.cleanupConfig)
        var proposals: [CleanupProposal] = pairs.map {
            CleanupProposal(id: "dup-\($0.id)", kind: .duplicate($0))
        }
        proposals += Self.projectProposals(from: pairs, snapshots: snapshots)
        proposals += stagnant.map {
            CleanupProposal(id: "stag-\($0.id)", kind: .stagnant($0))
        }
        cleanupProposals = proposals
        if proposals.isEmpty {
            cleanupNotice = "看板很干净，没发现重复或停滞任务"
        }
    }

    /// 编辑项目提案的名字
    func updateCleanupProposal(_ updated: CleanupProposal) {
        guard let index = cleanupProposals.firstIndex(where: { $0.id == updated.id }) else { return }
        cleanupProposals[index] = updated
    }

    /// 重复提案：保留一方，删除另一方（被删方的 note 合并到保留方），记 dedup correction。
    func resolveDuplicate(_ proposal: CleanupProposal, keepFirst: Bool) {
        guard case .duplicate(let pair) = proposal.kind else { return }
        let keepID = keepFirst ? pair.candidate.firstID : pair.candidate.secondID
        let dropID = keepFirst ? pair.candidate.secondID : pair.candidate.firstID
        let persisted = perform("合并任务失败") {
            if let keep = try store.task(id: keepID), let drop = try store.task(id: dropID),
               let dropNote = drop.note, !dropNote.isEmpty {
                let merged = [keep.note, dropNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                if merged != (keep.note ?? "") {
                    try store.updateTask(id: keepID, note: merged)
                }
            }
            try store.deleteTask(id: dropID)
            try store.insertCorrection(
                kind: .dedup,
                rawInput: "\(pair.candidate.firstTitle) ↔ \(pair.candidate.secondTitle)",
                aiOutput: pair.reason,
                finalOutput: keepFirst ? "保留前者" : "保留后者"
            )
        }
        if persisted { dismissCleanup(proposal) }
    }

    /// 停滞提案操作：推进（→ Todo）/ 降级（→ Backlog）/ 删除。
    func resolveStagnant(_ proposal: CleanupProposal, action: StagnantAction) {
        guard case .stagnant(let item) = proposal.kind else { return }
        let succeeded: Bool = switch action {
        case .promote:
            perform("状态更新失败") { try store.setStatus(item.taskId, to: .today) }
        case .demote:
            perform("状态更新失败") { try store.setStatus(item.taskId, to: .backlog) }
        case .delete:
            perform("删除失败") { try store.deleteTask(id: item.taskId) }
        }
        if succeeded { dismissCleanup(proposal) }
    }

    /// 项目成组提案：建项目并关联全部任务。以最新状态里的名字为准（卡片上可编辑）。
    func confirmProject(_ proposal: CleanupProposal) {
        guard let current = cleanupProposals.first(where: { $0.id == proposal.id }),
              case .project(let taskIDs, _) = current.kind else { return }
        let name = current.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let persisted = perform("创建项目失败") {
            let project = try store.createProject(name: name)
            for taskID in taskIDs {
                try store.assignTaskToProject(taskId: taskID, projectId: project.id)
            }
        }
        if persisted { dismissCleanup(proposal) }
    }

    func dismissCleanup(_ proposal: CleanupProposal) {
        cleanupProposals.removeAll { $0.id == proposal.id }
    }

    /// 已确认重复对的连通分量（≥3 个任务）→ 项目成组提案，至多 3 个。
    /// internal（非 private）供单测直接验证并查集聚类逻辑。
    static func projectProposals(from pairs: [DuplicatePair], snapshots: [TaskSnapshot]) -> [CleanupProposal] {
        var parent: [Int64: Int64] = [:]
        func root(of x: Int64) -> Int64 {
            var node = x
            while let next = parent[node], next != node { node = next }
            return node
        }
        func union(_ a: Int64, _ b: Int64) {
            let (ra, rb) = (root(of: a), root(of: b))
            if ra != rb { parent[rb] = ra }
        }
        for pair in pairs {
            union(pair.candidate.firstID, pair.candidate.secondID)
        }
        var components: [Int64: [Int64]] = [:]
        for pair in pairs {
            for id in [pair.candidate.firstID, pair.candidate.secondID] {
                components[root(of: id), default: []].append(id)
            }
        }
        var seen = Set<Int64>()
        var result: [CleanupProposal] = []
        for (_, members) in components where members.count >= 3 {
            let ids = Array(Set(members)).sorted()
            guard let first = ids.first, !seen.contains(first) else { continue }
            seen.formUnion(ids)
            let titles = ids.compactMap { id in snapshots.first { $0.id == id }?.title }
            let name = commonPrefix(of: titles)
            result.append(CleanupProposal(
                id: "proj-\(ids.map(String.init).joined(separator: "-"))",
                kind: .project(taskIDs: ids, titles: titles),
                projectName: name
            ))
            if result.count >= 3 { break }
        }
        return result
    }

    /// 项目名建议：标题的最长公共前缀（≥2 字），否则「相关任务」。
    /// internal（非 private）供单测直接验证。
    static func commonPrefix(of titles: [String]) -> String {
        guard let first = titles.first, titles.count > 1 else { return "相关任务" }
        var prefix = first
        for title in titles.dropFirst() {
            prefix = String(prefix.prefix(title.count))
            while !title.hasPrefix(prefix), !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 ? trimmed : "相关任务"
    }
}

/// Smart Cleanup 的一条清理提案（重复合并 / 停滞处置 / 项目成组）。
/// 与 Brain Dump 提案同纪律：产出必须经用户确认才落库。
struct CleanupProposal: Identifiable, Equatable {
    enum Kind: Equatable {
        case duplicate(DuplicatePair)
        case stagnant(StagnantTask)
        case project(taskIDs: [Int64], titles: [String])
    }

    let id: String
    let kind: Kind
    /// 项目提案的可编辑名字（仅 .project 用）
    var projectName: String = ""
}

/// 停滞提案的处置动作
enum StagnantAction {
    case promote  // 拉回 Todo 推进
    case demote   // 降级 Backlog
    case delete
}
