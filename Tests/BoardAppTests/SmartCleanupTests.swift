import Foundation
import GRDB
import RuleEngine
import TaskStore
@testable import BoardApp
import XCTest

/// M4 Smart Cleanup 编排逻辑测试（全规则，无外部依赖）。
/// 覆盖：重复检测（经 runSmartCleanup）、resolve*/confirm* 纯本地动作、
/// 并查集聚类 projectProposals 与 commonPrefix。
@MainActor
final class SmartCleanupTests: XCTestCase {
    private var store: TaskStore!
    private var viewModel: BoardViewModel!

    override func setUp() async throws {
        store = try TaskStore.inMemory()
        viewModel = BoardViewModel(store: store)
    }

    /// GRDB 观察是异步投递的：轮询直到条件满足或超时失败。
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "等待超时：\(description)")
    }

    private func corrections() async throws -> [Correction] {
        try await store.dbQueue.read { db in try Correction.order(Column("id")).fetchAll(db) }
    }

    /// 直接写库造一个指定更新时间的任务，并等观察流把它投递进视图模型
    ///（runSmartCleanup 读的是视图模型当前状态）。
    @discardableResult
    private func makeTask(
        title: String,
        status: TaskStatus = .today,
        note: String? = nil,
        waitingOn: String? = nil,
        parentId: Int64? = nil,
        daysAgo: Int = 0
    ) async throws -> Task {
        let at = Date().addingTimeInterval(-TimeInterval(daysAgo) * 86_400)
        let task = try store.createTask(
            title: title, status: status, waitingOn: waitingOn, note: note, parentId: parentId, at: at
        )
        await waitUntil("任务「\(title)」进入视图模型") {
            self.viewModel.tasks.contains { $0.id == task.id }
        }
        return task
    }

    private func duplicatePairs() -> [DuplicatePair] {
        viewModel.cleanupProposals.compactMap { proposal in
            guard case .duplicate(let pair) = proposal.kind else { return nil }
            return pair
        }
    }

    private func stagnantItems() -> [StagnantTask] {
        viewModel.cleanupProposals.compactMap { proposal in
            guard case .stagnant(let item) = proposal.kind else { return nil }
            return item
        }
    }

    // MARK: - runSmartCleanup：停滞召回（纯规则，无 AI 依赖）

    /// 三类停滞任务被检出；新鲜任务、done 任务、子任务不在清理视野内。
    func testRunSmartCleanupFlagsStagnantTasks() async throws {
        let backlog = try await makeTask(title: "整理会议纪要", status: .backlog, daysAgo: 45)
        let doing = try await makeTask(title: "修复登录崩溃", status: .doing, daysAgo: 10)
        let waiting = try await makeTask(title: "催供应商报价", status: .waiting, waitingOn: "供应商", daysAgo: 10)
        let parent = try await makeTask(title: "年度体检安排") // 新鲜 today，不命中
        _ = try await makeTask(title: "给猫打疫苗", status: .done, daysAgo: 60) // done 不参与
        _ = try await makeTask(title: "预约体检医院", status: .backlog, parentId: parent.id, daysAgo: 45) // 子任务不参与

        viewModel.runSmartCleanup()

        XCTAssertNil(viewModel.cleanupNotice)
        let stagnant = stagnantItems()
        XCTAssertEqual(stagnant.count, 3)
        XCTAssertEqual(Set(stagnant.map(\.taskId)), [backlog.id!, doing.id!, waiting.id!])
        XCTAssertEqual(Set(stagnant.map(\.kind)), [.backlogStale, .doingStale, .waitingStale])
        XCTAssertEqual(Set(viewModel.cleanupProposals.map(\.id)).count, viewModel.cleanupProposals.count)
    }

    /// 什么都没发现时：提案为空并给出安静提示。
    func testRunSmartCleanupEmptyResultSetsNotice() async throws {
        _ = try await makeTask(title: "新鲜的任务")

        viewModel.runSmartCleanup()

        XCTAssertNotNil(viewModel.cleanupNotice)
        XCTAssertTrue(viewModel.cleanupProposals.isEmpty)
        XCTAssertEqual(viewModel.cleanupNotice, "看板很干净，没发现重复或停滞任务")
    }

    // MARK: - runSmartCleanup：重复判定（Jaccard≥0.8 / 归一化相等）

    /// 归一化相等（仅标点差异）的标题命中保守规则，产出重复提案。
    func testRunSmartCleanupDetectsNormalizedDuplicate() async throws {
        let a = try await makeTask(title: "买牛奶")
        let b = try await makeTask(title: "买牛奶！")

        viewModel.runSmartCleanup()

        let pairs = duplicatePairs()
        XCTAssertEqual(pairs.count, 1)
        let pair = try XCTUnwrap(pairs.first)
        XCTAssertEqual(pair.reason, "标题高度相似")
        XCTAssertEqual(Set([pair.candidate.firstID, pair.candidate.secondID]), [a.id!, b.id!])
    }

    /// 三条归一化相等的标题：三对重复 + 一个连通分量（3 个任务）聚出的项目成组提案。
    func testRunSmartCleanupClustersDuplicateTripleIntoProjectProposal() async throws {
        let a = try await makeTask(title: "周报 2025")
        let b = try await makeTask(title: "周报2025")
        let c = try await makeTask(title: "周报：2025")

        viewModel.runSmartCleanup()

        let pairs = duplicatePairs()
        XCTAssertEqual(pairs.count, 3)

        let projects = viewModel.cleanupProposals.filter {
            if case .project = $0.kind { return true }
            return false
        }
        XCTAssertEqual(projects.count, 1)
        guard case .project(let ids, let titles) = projects[0].kind else {
            XCTFail("应为项目成组提案")
            return
        }
        XCTAssertEqual(ids, [a.id!, b.id!, c.id!].sorted())
        XCTAssertEqual(Set(titles), ["周报 2025", "周报2025", "周报：2025"])
        XCTAssertEqual(projects[0].projectName, "周报", "项目名取标题最长公共前缀")
        XCTAssertEqual(projects[0].id, "proj-\(ids.map(String.init).joined(separator: "-"))")
    }

    // MARK: - resolveDuplicate：纯本地动作

    /// 保留前者：被弃方 note 合并到保留方、被弃方删除、记 dedup correction。
    func testResolveDuplicateKeepFirstMergesNoteDeletesDroppedRecordsCorrection() async throws {
        let keep = try await makeTask(title: "写季度总结", note: "旧备注")
        let drop = try await makeTask(title: "写季度总结！", note: "补充信息")
        let pair = DuplicatePair(
            candidate: DuplicateCandidate(
                firstID: keep.id!, secondID: drop.id!,
                firstTitle: keep.title, secondTitle: drop.title, similarity: 1.0
            ),
            reason: "标题高度相似"
        )

        viewModel.resolveDuplicate(CleanupProposal(id: "dup-\(pair.id)", kind: .duplicate(pair)), keepFirst: true)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(try store.task(id: keep.id!)?.note, "旧备注\n补充信息")
        XCTAssertNil(try store.task(id: drop.id!), "被弃方应删除")
        let corrections = try await corrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].kind, .dedup)
        XCTAssertEqual(corrections[0].rawInput, "写季度总结 ↔ 写季度总结！")
        XCTAssertEqual(corrections[0].aiOutput, "标题高度相似")
        XCTAssertEqual(corrections[0].finalOutput, "保留前者")
    }

    /// 保留后者：删除前者，其 note 并入后者（后者原本无 note）。
    func testResolveDuplicateKeepSecond() async throws {
        let first = try await makeTask(title: "给妈妈打电话", note: "周末前")
        let second = try await makeTask(title: "给妈妈打电话！")
        let pair = DuplicatePair(
            candidate: DuplicateCandidate(
                firstID: first.id!, secondID: second.id!,
                firstTitle: first.title, secondTitle: second.title, similarity: 1.0
            ),
            reason: "标题高度相似"
        )

        viewModel.resolveDuplicate(CleanupProposal(id: "dup-\(pair.id)", kind: .duplicate(pair)), keepFirst: false)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(try store.task(id: first.id!))
        XCTAssertEqual(try store.task(id: second.id!)?.note, "周末前")
        let corrections = try await corrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].finalOutput, "保留后者")
    }

    // MARK: - resolveStagnant / dismissCleanup

    /// 推进（→ today）/ 降级（→ backlog）/ 删除：动作落库且提案随之移除。
    func testResolveStagnantActions() async throws {
        let backlog = try await makeTask(title: "整理会议纪要", status: .backlog, daysAgo: 45)
        let doing = try await makeTask(title: "修复登录崩溃", status: .doing, daysAgo: 10)
        let waiting = try await makeTask(title: "催供应商报价", status: .waiting, waitingOn: "供应商", daysAgo: 10)

        viewModel.runSmartCleanup()

        func proposal(for taskId: Int64) -> CleanupProposal? {
            viewModel.cleanupProposals.first {
                guard case .stagnant(let item) = $0.kind else { return false }
                return item.taskId == taskId
            }
        }

        let promote = try XCTUnwrap(proposal(for: backlog.id!))
        viewModel.resolveStagnant(promote, action: .promote)
        XCTAssertEqual(try store.task(id: backlog.id!)?.status, .today)
        XCTAssertFalse(viewModel.cleanupProposals.contains { $0.id == promote.id })

        let demote = try XCTUnwrap(proposal(for: doing.id!))
        viewModel.resolveStagnant(demote, action: .demote)
        XCTAssertEqual(try store.task(id: doing.id!)?.status, .backlog)
        XCTAssertFalse(viewModel.cleanupProposals.contains { $0.id == demote.id })

        let delete = try XCTUnwrap(proposal(for: waiting.id!))
        viewModel.resolveStagnant(delete, action: .delete)
        XCTAssertNil(try store.task(id: waiting.id!))

        XCTAssertTrue(viewModel.cleanupProposals.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 落库失败时保留提案并写 errorMessage。
    func testResolveStagnantFailureKeepsProposal() async throws {
        let task = try await makeTask(title: "整理会议纪要", status: .backlog, daysAgo: 45)
        viewModel.runSmartCleanup()
        let proposal = try XCTUnwrap(viewModel.cleanupProposals.first)

        try store.deleteTask(id: task.id!) // 先删掉，制造 taskNotFound 失败
        viewModel.resolveStagnant(proposal, action: .delete)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.cleanupProposals.contains { $0.id == proposal.id }, "失败的提案应保留")
    }

    /// 「忽略」只移除提案，不动任务。
    func testDismissCleanupRemovesProposalOnly() async throws {
        let task = try await makeTask(title: "整理会议纪要", status: .backlog, daysAgo: 45)
        viewModel.runSmartCleanup()
        let proposal = try XCTUnwrap(viewModel.cleanupProposals.first)

        viewModel.dismissCleanup(proposal)

        XCTAssertTrue(viewModel.cleanupProposals.isEmpty)
        XCTAssertEqual(try store.task(id: task.id!)?.status, .backlog, "忽略不应改变任务")
    }

    // MARK: - confirmProject

    /// 建项目并关联全部任务；卡片上编辑过的名字（trim 后）为准。
    func testConfirmProjectCreatesProjectAssignsTasksUsesEditedName() async throws {
        let a = try await makeTask(title: "周报 2025")
        let b = try await makeTask(title: "周报2025")
        let c = try await makeTask(title: "周报：2025")
        let ids = [a.id!, b.id!, c.id!].sorted()
        let proposal = CleanupProposal(
            id: "proj-\(ids.map(String.init).joined(separator: "-"))",
            kind: .project(taskIDs: ids, titles: [a.title, b.title, c.title]),
            projectName: "旧名字"
        )
        viewModel.cleanupProposals = [proposal]

        var edited = proposal
        edited.projectName = "  季度规划  "
        viewModel.updateCleanupProposal(edited)

        viewModel.confirmProject(proposal)

        XCTAssertTrue(viewModel.cleanupProposals.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        let project = try XCTUnwrap(store.projects().first)
        XCTAssertEqual(project.name, "季度规划", "以编辑后 trim 的名字为准")
        for id in ids {
            XCTAssertEqual(try store.task(id: id)?.projectId, project.id)
        }
        await waitUntil("项目徽标名查找表刷新") {
            self.viewModel.projectNames[project.id!] == "季度规划"
        }
    }

    /// 名字为空白时直接拒绝：不建项目、不动任务、提案保留。
    func testConfirmProjectBlankNameIsNoop() async throws {
        let a = try await makeTask(title: "周报 2025")
        let proposal = CleanupProposal(
            id: "proj-blank",
            kind: .project(taskIDs: [a.id!], titles: [a.title]),
            projectName: "   "
        )
        viewModel.cleanupProposals = [proposal]

        viewModel.confirmProject(proposal)

        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertNil(try store.task(id: a.id!)?.projectId)
        XCTAssertTrue(viewModel.cleanupProposals.contains { $0.id == proposal.id })
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - 并查集聚类与项目名建议（纯函数）

    /// 链式重复对连通成 ≥3 的分量才成组；孤对不成组；提案至多 3 个。
    func testProjectProposalsUnionFindComponentsAndCap() {
        let snapshots = (1...12).map {
            TaskSnapshot(id: Int64($0), title: "任务\($0)", status: .today, updatedAt: Date())
        }
        func pair(_ a: Int64, _ b: Int64) -> DuplicatePair {
            DuplicatePair(
                candidate: DuplicateCandidate(
                    firstID: a, secondID: b, firstTitle: "任务\(a)", secondTitle: "任务\(b)", similarity: 1.0
                ),
                reason: "r"
            )
        }

        // (1,2),(2,3) 链式连通 → {1,2,3} 成组；孤对 (4,5) 不足 3 个不成组
        var proposals = BoardViewModel.projectProposals(
            from: [pair(1, 2), pair(2, 3), pair(4, 5)], snapshots: snapshots
        )
        XCTAssertEqual(proposals.count, 1)
        guard case .project(let ids, let titles) = proposals[0].kind else {
            XCTFail("应为项目成组提案")
            return
        }
        XCTAssertEqual(ids, [1, 2, 3])
        XCTAssertEqual(titles, ["任务1", "任务2", "任务3"])
        XCTAssertEqual(proposals[0].id, "proj-1-2-3")
        XCTAssertEqual(proposals[0].projectName, "任务")

        // 4 个各含 3 任务的分量 → 至多 3 个提案
        proposals = BoardViewModel.projectProposals(
            from: [
                pair(1, 2), pair(2, 3),
                pair(4, 5), pair(5, 6),
                pair(7, 8), pair(8, 9),
                pair(10, 11), pair(11, 12),
            ],
            snapshots: snapshots
        )
        XCTAssertEqual(proposals.count, 3)
    }

    /// 最长公共前缀 ≥2 字作为项目名建议，否则「相关任务」。
    func testCommonPrefixNaming() {
        XCTAssertEqual(BoardViewModel.commonPrefix(of: ["周报 2025", "周报2025"]), "周报")
        XCTAssertEqual(BoardViewModel.commonPrefix(of: ["abc", "abd"]), "ab")
        XCTAssertEqual(BoardViewModel.commonPrefix(of: ["买牛奶", "买手机"]), "相关任务", "前缀不足 2 字")
        XCTAssertEqual(BoardViewModel.commonPrefix(of: ["完全无关", "另一件事"]), "相关任务")
        XCTAssertEqual(BoardViewModel.commonPrefix(of: ["单个"]), "相关任务")
        XCTAssertEqual(BoardViewModel.commonPrefix(of: []), "相关任务")
    }
}
