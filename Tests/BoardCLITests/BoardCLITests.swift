import Foundation
import RuleEngine
import TaskStore
@testable import BoardCLI
import XCTest

final class BoardCLIParseTests: XCTestCase {
    private func parse(_ args: [String], now: Date = Date()) throws -> BoardCLI.Invocation {
        try BoardCLI.parse(["bbboard"] + args, now: now)
    }

    private func assertError(_ args: [String], contains fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(args), file: file, line: line) { error in
            guard let cliError = error as? BoardCLI.CLIError else {
                return XCTFail("期望 CLIError，得到 \(error)", file: file, line: line)
            }
            XCTAssertTrue(cliError.description.contains(fragment), "「\(cliError.description)」应包含「\(fragment)」", file: file, line: line)
        }
    }

    func testAddDefaults() throws {
        let invocation = try parse(["add", "写周报"])
        guard case .add(let add) = invocation.command else { return XCTFail("期望 add") }
        XCTAssertEqual(add.title, "写周报")
        XCTAssertEqual(add.status, .today)
        XCTAssertEqual(add.area, .work)
        XCTAssertNil(add.dueDate)
        XCTAssertNil(add.waitingOn)
        XCTAssertNil(add.parentId)
        XCTAssertFalse(invocation.json)
    }

    func testAddAllFlags() throws {
        let now = Date()
        let invocation = try parse([
            "add", "对齐方案",
            "--status", "waiting", "--area", "personal",
            "--note", "带上次纪要", "--due", "明天",
            "--waiting-on", "张三", "--parent", "7", "--json"
        ], now: now)
        guard case .add(let add) = invocation.command else { return XCTFail("期望 add") }
        XCTAssertEqual(add.status, .waiting)
        XCTAssertEqual(add.area, .personal)
        XCTAssertEqual(add.note, "带上次纪要")
        XCTAssertEqual(add.waitingOn, "张三")
        XCTAssertEqual(add.parentId, 7)
        XCTAssertTrue(invocation.json)
        let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
        XCTAssertEqual(add.dueDate, tomorrow)
    }

    func testAddDueISODate() throws {
        let invocation = try parse(["add", "缴费", "--due", "2026-09-20"])
        guard case .add(let add) = invocation.command else { return XCTFail("期望 add") }
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 20
        XCTAssertEqual(add.dueDate, Calendar.current.date(from: components))
    }

    func testAddErrors() {
        assertError(["add"], contains: "缺任务标题")
        assertError(["add", "x", "--status", "todoo"], contains: "未知状态")
        assertError(["add", "x", "--area", "home"], contains: "未知领域")
        assertError(["add", "x", "--due", "随便哪天"], contains: "无法解析截止时间")
        assertError(["add", "x", "--note"], contains: "缺值")
        assertError(["add", "x", "--nope", "1"], contains: "未知选项")
    }

    func testListFlags() throws {
        let invocation = try parse(["list", "--status", "doing", "--all", "--json"])
        guard case .list(let status, let includeDone) = invocation.command else { return XCTFail("期望 list") }
        XCTAssertEqual(status, .doing)
        XCTAssertTrue(includeDone)
        XCTAssertTrue(invocation.json)
    }

    func testListDefaultsExcludeDone() throws {
        let invocation = try parse(["list"])
        guard case .list(let status, let includeDone) = invocation.command else { return XCTFail("期望 list") }
        XCTAssertNil(status)
        XCTAssertFalse(includeDone)
    }

    func testDoneAndMove() throws {
        let done = try parse(["done", "12"])
        XCTAssertEqual(done.command, .done(id: 12))
        let move = try parse(["move", "12", "waiting", "--waiting-on", "李四"])
        XCTAssertEqual(move.command, .move(id: 12, status: .waiting, waitingOn: "李四"))
    }

    func testIDErrors() {
        assertError(["done"], contains: "需要任务 id")
        assertError(["done", "abc"], contains: "需要任务 id")
        assertError(["move", "1"], contains: "缺目标状态")
    }

    func testNoCommandShowsHelp() throws {
        let invocation = try parse([])
        XCTAssertEqual(invocation.command, .help)
    }

    func testUnknownCommand() {
        assertError(["frobnicate"], contains: "未知命令")
    }

    func testGlobalDBOverride() throws {
        let invocation = try parse(["--db", "/tmp/x.sqlite", "list"])
        XCTAssertEqual(invocation.dbOverride, "/tmp/x.sqlite")
    }
}

final class BoardCLIDueDateTests: XCTestCase {
    func testISOParsesToStartOfDay() throws {
        let date = try XCTUnwrap(BoardCLI.parseDueDate("2026/9/5"))
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 5
        XCTAssertEqual(date, Calendar.current.date(from: components))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(BoardCLI.parseDueDate("没有日期的文本随便"))
    }
}

final class BoardCLIExecuteTests: XCTestCase {
    private var store: TaskStore!

    override func setUp() async throws {
        store = try TaskStore.inMemory()
    }

    func testAddThenListRoundTrip() throws {
        let output = try BoardCLI.execute(
            .add(.init(title: "写周报", status: .doing, note: "周五前")),
            store: store
        )
        XCTAssertTrue(output.contains("写周报"))
        XCTAssertTrue(output.contains("已添加"))

        let list = try BoardCLI.execute(.list(status: nil, includeDone: false), store: store)
        XCTAssertTrue(list.contains("写周报"))
        XCTAssertTrue(list.contains("[doing·work]"))
        XCTAssertTrue(list.contains("周五前"))

        let tasks = try store.allTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].source, .cli)
        // 纪律：写操作必须记 activity_log
        let activity = try store.activity(forTaskId: tasks[0].id!)
        XCTAssertEqual(activity.map(\.type), [.created])
    }

    func testListExcludesDoneAndSubtasks() throws {
        try store.createTask(title: "未完成", status: .today)
        try store.createTask(title: "已完成", status: .done)
        let parent = try store.createTask(title: "父任务", status: .today)
        try store.createTask(title: "子任务", status: .today, parentId: parent.id)

        let list = try BoardCLI.execute(.list(status: nil, includeDone: false), store: store)
        XCTAssertTrue(list.contains("未完成"))
        XCTAssertFalse(list.contains("已完成"))
        XCTAssertFalse(list.contains("子任务"))

        let all = try BoardCLI.execute(.list(status: nil, includeDone: true), store: store)
        XCTAssertTrue(all.contains("已完成"))
    }

    func testDoneAndMoveUpdateStore() throws {
        let task = try store.createTask(title: "推进一下", status: .today)
        let id = task.id!

        let doneOutput = try BoardCLI.execute(.done(id: id), store: store)
        XCTAssertTrue(doneOutput.contains("已完成"))
        XCTAssertEqual(try store.task(id: id)?.status, .done)

        let moveOutput = try BoardCLI.execute(.move(id: id, status: .waiting, waitingOn: "张三"), store: store)
        XCTAssertTrue(moveOutput.contains("waiting"))
        let moved = try store.task(id: id)
        XCTAssertEqual(moved?.status, .waiting)
        XCTAssertEqual(moved?.waitingOn, "张三")
    }

    func testMissingTaskThrows() {
        XCTAssertThrowsError(try BoardCLI.execute(.done(id: 999), store: store)) { error in
            XCTAssertTrue((error as? BoardCLI.CLIError)?.description.contains("不存在") ?? false)
        }
    }

    func testListJSON() throws {
        try store.createTask(title: "JSON任务", status: .today, dueDate: Date(timeIntervalSince1970: 1_790_000_000))
        let json = try BoardCLI.execute(.list(status: nil, includeDone: false), store: store, json: true)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array[0]["title"] as? String, "JSON任务")
        XCTAssertNotNil(array[0]["dueDate"])
    }

    func testEmptyListHumanReadable() throws {
        let output = try BoardCLI.execute(.list(status: nil, includeDone: false), store: store)
        XCTAssertTrue(output.contains("没有符合条件的任务"))
    }
}
