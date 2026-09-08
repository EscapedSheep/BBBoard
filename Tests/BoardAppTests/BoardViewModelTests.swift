import AIParser
import Foundation
import GRDB
import RuleEngine
import TaskStore
@testable import BoardApp
import XCTest

@MainActor
final class BoardViewModelTests: XCTestCase {
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

    // MARK: - 创建与列归属

    func testAddTaskAppearsInBacklogColumn() async {
        viewModel.addTask(title: "写周报", status: .backlog, dueDate: nil, waitingOn: nil)

        await waitUntil("新任务进入 backlog 列") {
            self.viewModel.tasks(in: .backlog).contains { $0.title == "写周报" }
        }
        XCTAssertTrue(viewModel.tasks(in: .today).isEmpty)
        XCTAssertEqual(viewModel.errorMessage, nil)
    }

    func testSetStatusMovesTaskBetweenColumns() async throws {
        viewModel.addTask(title: "迁移任务", status: .backlog, dueDate: nil, waitingOn: nil)
        await waitUntil("任务出现在 backlog") { !self.viewModel.tasks(in: .backlog).isEmpty }
        let task = try XCTUnwrap(viewModel.tasks(in: .backlog).first)

        viewModel.setStatus(task, to: .doing)

        await waitUntil("任务移入 doing 列") {
            self.viewModel.tasks(in: .doing).contains { $0.id == task.id }
        }
        XCTAssertTrue(viewModel.tasks(in: .backlog).isEmpty)
        XCTAssertEqual(try store.task(id: task.id!)?.status, .doing)
    }

    // MARK: - 重命名与说明

    func testRenameTrimsAndPersists() async throws {
        viewModel.addTask(title: "旧标题", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("任务出现在 today") { !self.viewModel.tasks(in: .today).isEmpty }
        let task = try XCTUnwrap(viewModel.tasks(in: .today).first)

        viewModel.rename(task, to: "  新标题  ")

        await waitUntil("标题更新") {
            self.viewModel.tasks(in: .today).first?.title == "新标题"
        }
        XCTAssertEqual(try store.task(id: task.id!)?.title, "新标题")
    }

    func testRenameEmptyOrUnchangedIsNoop() async throws {
        viewModel.addTask(title: "标题", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("任务出现在 today") { !self.viewModel.tasks(in: .today).isEmpty }
        let task = try XCTUnwrap(viewModel.tasks(in: .today).first)

        viewModel.rename(task, to: "   ")
        viewModel.rename(task, to: "标题")

        XCTAssertEqual(try store.task(id: task.id!)?.title, "标题")
        XCTAssertTrue(try store.activity(forTaskId: task.id!).filter { $0.type == .edited }.isEmpty)
    }

    func testSetNoteWritesAndClears() async throws {
        viewModel.addTask(title: "带说明", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("任务出现在 today") { !self.viewModel.tasks(in: .today).isEmpty }
        var task = try XCTUnwrap(viewModel.tasks(in: .today).first)

        viewModel.setNote(task, "  备注内容  ")
        await waitUntil("说明写入") {
            self.viewModel.tasks(in: .today).first?.note == "备注内容"
        }
        XCTAssertEqual(try store.task(id: task.id!)?.note, "备注内容")

        task = try XCTUnwrap(viewModel.tasks(in: .today).first)
        viewModel.setNote(task, "")
        await waitUntil("说明清除") {
            self.viewModel.tasks(in: .today).first?.note == nil
        }
        XCTAssertNil(try store.task(id: task.id!)?.note)
    }

    /// 内容未变（含首尾空白归一后相同）时不写库、不记 edited 日志。
    func testSetNoteUnchangedSkipsWrite() async throws {
        viewModel.addTask(title: "说明去重", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("任务出现在 today") { !self.viewModel.tasks(in: .today).isEmpty }
        var task = try XCTUnwrap(viewModel.tasks(in: .today).first)

        viewModel.setNote(task, "备注")
        await waitUntil("说明写入") {
            self.viewModel.tasks(in: .today).first?.note == "备注"
        }
        task = try XCTUnwrap(viewModel.tasks(in: .today).first)

        viewModel.setNote(task, "  备注  ") // trim 后与现值相同

        let edited = try store.activity(forTaskId: task.id!).filter { $0.type == .edited }
        XCTAssertEqual(edited.count, 1, "重复 setNote 不应产生第二条 edited 日志")
    }

    // MARK: - 子任务

    func testAddSubtaskAndProgress() async throws {
        viewModel.addTask(title: "父任务", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("父任务出现") { !self.viewModel.tasks(in: .today).isEmpty }
        let parent = try XCTUnwrap(viewModel.tasks(in: .today).first)

        viewModel.addSubtask(to: parent, title: "子任务A")
        viewModel.addSubtask(to: parent, title: "  子任务B  ")
        viewModel.addSubtask(to: parent, title: "   ") // 空白标题被拒绝

        await waitUntil("两个子任务") { self.viewModel.subtasks(of: parent).count == 2 }

        let progress = viewModel.subtaskProgress(of: parent)
        XCTAssertEqual(progress.done, 0)
        XCTAssertEqual(progress.total, 2)
        // 子任务随父卡展示，不进看板列
        XCTAssertEqual(viewModel.tasks(in: .today).count, 1)

        let sub = try XCTUnwrap(viewModel.subtasks(of: parent).first)
        XCTAssertEqual(sub.status, .today)
        viewModel.setStatus(sub, to: .done)
        await waitUntil("子任务完成度 1/2") {
            self.viewModel.subtaskProgress(of: parent).done == 1
        }
    }

    // MARK: - 完成与删除

    func testToggleDoneFlipsStatusAndCompletedAt() async throws {
        viewModel.addTask(title: "切换完成", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("任务出现") { !self.viewModel.tasks(in: .today).isEmpty }
        var task = try XCTUnwrap(viewModel.tasks(in: .today).first)

        viewModel.toggleDone(task)
        await waitUntil("任务进入 done 列") {
            self.viewModel.tasks(in: .done).contains { $0.id == task.id }
        }
        XCTAssertNotNil(try store.task(id: task.id!)?.completedAt)

        task = try XCTUnwrap(viewModel.tasks(in: .done).first)
        viewModel.toggleDone(task)
        await waitUntil("任务回到 today 列") {
            self.viewModel.tasks(in: .today).contains { $0.id == task.id }
        }
        XCTAssertNil(try store.task(id: task.id!)?.completedAt)
    }

    func testDeleteParentCascadesSubtasks() async throws {
        viewModel.addTask(title: "父任务", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("父任务出现") { !self.viewModel.tasks(in: .today).isEmpty }
        let parent = try XCTUnwrap(viewModel.tasks(in: .today).first)
        viewModel.addSubtask(to: parent, title: "子一")
        viewModel.addSubtask(to: parent, title: "子二")
        await waitUntil("子任务就位") { self.viewModel.subtasks(of: parent).count == 2 }

        viewModel.delete(parent)

        await waitUntil("父子全部删除") { self.viewModel.tasks.isEmpty }
        XCTAssertEqual(try store.allTasks().count, 0)
        let deleted = try await store.dbQueue.read { db in
            try ActivityLog.filter(Column("type") == ActivityType.deleted.rawValue).fetchCount(db)
        }
        XCTAssertEqual(deleted, 3, "父卡 + 两个子卡各记一条 deleted 日志")
    }

    // MARK: - Brain Dump 提案确认流

    func testConfirmProposalPersistsAndDiscards() async throws {
        let proposal = TaskProposal(title: "提案任务", status: .backlog)
        viewModel.proposals = [proposal]

        viewModel.confirmProposal(proposal)

        XCTAssertTrue(viewModel.proposals.isEmpty)
        await waitUntil("提案入库") {
            self.viewModel.tasks(in: .backlog).contains { $0.title == "提案任务" }
        }
        let task = try XCTUnwrap(viewModel.tasks(in: .backlog).first)
        XCTAssertEqual(task.source, .braindump)
        let corrections = try await corrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].kind, .braindump)
    }

    /// confirmProposal 会就地移除已入库提案；confirmAll 先拍快照再迭代，确保全部入库不遗漏。
    func testConfirmAllProposalsIteratesSnapshot() async throws {
        viewModel.proposals = [
            TaskProposal(title: "提案一", status: .today),
            TaskProposal(title: "提案二", status: .backlog),
            TaskProposal(title: "提案三", status: .waiting, waitingOn: "Peter")
        ]

        viewModel.confirmAllProposals()

        XCTAssertTrue(viewModel.proposals.isEmpty)
        await waitUntil("三条提案全部入库") { self.viewModel.tasks.count == 3 }
        let titles = try store.allTasks().map(\.title)
        XCTAssertEqual(Set(titles), ["提案一", "提案二", "提案三"])
        let waiting = try XCTUnwrap(store.allTasks().first { $0.status == .waiting })
        XCTAssertEqual(waiting.waitingOn, "Peter")
        let correctionCount = try await corrections().count
        XCTAssertEqual(correctionCount, 3)
    }

    // MARK: - 错误路径

    /// 失败写 errorMessage，后续成功操作清除。
    func testFailureSetsErrorMessageAndSuccessClearsIt() async throws {
        viewModel.addTask(title: "将被删除", status: .today, dueDate: nil, waitingOn: nil)
        await waitUntil("任务出现") { !self.viewModel.tasks(in: .today).isEmpty }
        let task = try XCTUnwrap(viewModel.tasks(in: .today).first)
        viewModel.delete(task)
        await waitUntil("任务删除") { self.viewModel.tasks.isEmpty }

        viewModel.delete(task) // 已删除的 id，二次删除失败
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.addTask(title: "新任务", status: .backlog, dueDate: nil, waitingOn: nil)
        XCTAssertNil(viewModel.errorMessage)
    }
}
