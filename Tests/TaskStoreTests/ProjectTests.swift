import Foundation
import GRDB
@testable import TaskStore
import XCTest

final class ProjectTests: XCTestCase {
    private var store: TaskStore!
    /// 固定时间，避免测试依赖运行时刻。
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 整秒，规避存储精度问题

    override func setUpWithError() throws {
        store = try TaskStore.inMemory()
    }

    private func payloadDict(_ entry: ActivityLog) -> [String: String]? {
        guard let payload = entry.payload,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return object
    }

    // MARK: - 项目 CRUD

    func testCreateProjectWritesBackId() throws {
        let project = try store.createProject(name: "BBBoard", at: now)
        XCTAssertNotNil(project.id)
        XCTAssertEqual(project.name, "BBBoard")
        XCTAssertEqual(project.createdAt, now)
    }

    func testProjectsSortedByName() throws {
        let b = try store.createProject(name: "Beta", at: now)
        let a = try store.createProject(name: "Alpha", at: now)
        XCTAssertEqual(try store.projects().map(\.id), [a.id!, b.id!])
        XCTAssertTrue(try store.projects().allSatisfy { $0.createdAt == now })
    }

    func testProjectById() throws {
        let project = try store.createProject(name: "BBBoard", at: now)
        XCTAssertEqual(try store.project(id: project.id!), project)
        XCTAssertNil(try store.project(id: 999))
    }

    // MARK: - 任务关联

    func testAssignAndUnassignProject() throws {
        let project = try store.createProject(name: "BBBoard", at: now)
        let task = try store.createTask(title: "t", at: now)
        XCTAssertNil(task.projectId)

        let assignedAt = now.addingTimeInterval(600)
        try store.assignTaskToProject(taskId: task.id!, projectId: project.id!, at: assignedAt)
        var fetched = try store.task(id: task.id!)
        XCTAssertEqual(fetched?.projectId, project.id)
        XCTAssertEqual(fetched?.updatedAt, assignedAt)

        let unassignedAt = now.addingTimeInterval(1200)
        try store.assignTaskToProject(taskId: task.id!, projectId: nil, at: unassignedAt)
        fetched = try store.task(id: task.id!)
        XCTAssertNil(fetched?.projectId)
        XCTAssertEqual(fetched?.updatedAt, unassignedAt)
    }

    func testAssignLogsEditedWithProjectIdField() throws {
        let project = try store.createProject(name: "BBBoard", at: now)
        let task = try store.createTask(title: "t", at: now)
        let assignedAt = now.addingTimeInterval(60)
        try store.assignTaskToProject(taskId: task.id!, projectId: project.id!, at: assignedAt)

        let edited = try store.activity(forTaskId: task.id!).filter { $0.type == .edited }
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(payloadDict(edited[0])?["fields"], "project_id")
        XCTAssertEqual(edited[0].createdAt, assignedAt)
    }

    func testAssignWithoutChangeWritesNothing() throws {
        let project = try store.createProject(name: "BBBoard", at: now)
        let task = try store.createTask(title: "t", at: now)
        try store.assignTaskToProject(taskId: task.id!, projectId: project.id!, at: now)

        // 重复关联同一项目：no-op
        try store.assignTaskToProject(taskId: task.id!, projectId: project.id!, at: now.addingTimeInterval(3600))
        XCTAssertEqual(try store.activity(forTaskId: task.id!).filter { $0.type == .edited }.count, 1)
        XCTAssertEqual(try store.task(id: task.id!)?.updatedAt, now)

        // 未关联任务上解除关联：no-op，不抛错
        let other = try store.createTask(title: "u", at: now)
        try store.assignTaskToProject(taskId: other.id!, projectId: nil, at: now.addingTimeInterval(3600))
        XCTAssertTrue(try store.activity(forTaskId: other.id!).filter { $0.type == .edited }.isEmpty)
        XCTAssertEqual(try store.task(id: other.id!)?.updatedAt, now)
    }

    func testAssignOnMissingTaskThrows() throws {
        XCTAssertThrowsError(try store.assignTaskToProject(taskId: 42, projectId: 1)) { error in
            XCTAssertEqual(error as? TaskStoreError, .taskNotFound(42))
        }
        XCTAssertThrowsError(try store.assignTaskToProject(taskId: 42, projectId: nil)) { error in
            XCTAssertEqual(error as? TaskStoreError, .taskNotFound(42))
        }
    }
}
