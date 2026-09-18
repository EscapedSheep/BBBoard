import Foundation
import RuleEngine
import TaskStore

/// bbboard 命令行：从终端（人或 agent）读写看板。
/// 解析（parse）与执行（execute）分离，execute 接受注入的 TaskStore 以便测试。
/// 纪律与 App 一致：写操作全走 TaskStore（同事务记 activity_log），写后广播
/// `.bbboardExternalChange` 让正在运行的 App 重载。
enum BoardCLI {

    struct CLIError: Error, CustomStringConvertible, Equatable {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - 命令模型

    struct AddCommand: Equatable {
        var title: String
        var status: TaskStatus = .today
        var area: TaskArea = .work
        var note: String?
        var dueDate: Date?
        var waitingOn: String?
        var parentId: Int64?
    }

    enum Command: Equatable {
        case add(AddCommand)
        case list(status: TaskStatus?, includeDone: Bool)
        case done(id: Int64)
        case move(id: Int64, status: TaskStatus, waitingOn: String?)
        case help
    }

    struct Invocation: Equatable {
        var command: Command
        var dbOverride: String?
        var json: Bool
    }

    // MARK: - 入口

    static let usage = """
    bbboard — BBBoard 看板命令行

    用法：
      bbboard list [--status today] [--all] [--json]
      bbboard add "任务标题" [--status today|doing|waiting|backlog|done]
                  [--area work|personal] [--note "说明"] [--due "明天|9/20|2026-09-20"]
                  [--waiting-on "某人"] [--parent 父任务id]
      bbboard done <id>
      bbboard move <id> <status> [--waiting-on "某人"]

    全局选项：
      --db <路径>   指定数据库（默认自动定位看板库；回退 ~/.bbboard-dev/board.sqlite）
      --json        JSON 输出（list / add）
    """

    /// 进程入口。返回退出码：0 成功，1 用法/参数错误，2 执行失败。
    static func main(_ arguments: [String]) -> Int32 {
        let invocation: Invocation
        do {
            invocation = try parse(arguments)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("错误：\(error.description)\n\n\(usage)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
            return 1
        }
        if case .help = invocation.command {
            print(usage)
            return 0
        }
        do {
            let store = try TaskStore.open(at: databaseURL(override: invocation.dbOverride))
            let output = try execute(invocation.command, store: store, json: invocation.json)
            if !output.isEmpty { print(output) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("执行失败：\(error.localizedDescription)\n".utf8))
            return 2
        }
    }

    /// 库路径：--db 指定优先；否则默认路径存在用默认，否则回退 ~/.bbboard-dev（与 App 回退路径一致），
    /// 两者都不存在时用默认路径（新建）。
    static func databaseURL(override: String?) -> URL {
        if let override {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let defaultURL = TaskStore.defaultDatabaseURL()
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".bbboard-dev/board.sqlite")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: defaultURL.path(percentEncoded: false)) { return defaultURL }
        if fileManager.fileExists(atPath: fallback.path(percentEncoded: false)) { return fallback }
        return defaultURL
    }

    // MARK: - 解析

    /// now 可注入，便于测试 --due 的自然语言解析。
    static func parse(_ arguments: [String], now: Date = Date()) throws -> Invocation {
        let valueFlags: Set<String> = ["--status", "--area", "--note", "--due", "--waiting-on", "--parent", "--db"]
        var values: [String: String] = [:]
        var json = false
        var includeDone = false
        var help = false
        var positional: [String] = []

        var index = 1 // arguments[0] 是可执行名
        while index < arguments.count {
            let arg = arguments[index]
            if valueFlags.contains(arg) {
                guard index + 1 < arguments.count else { throw CLIError("选项 \(arg) 缺值") }
                values[arg] = arguments[index + 1]
                index += 2
            } else if arg == "--json" {
                json = true
                index += 1
            } else if arg == "--all" {
                includeDone = true
                index += 1
            } else if arg == "--help" || arg == "-h" {
                help = true
                index += 1
            } else if arg.hasPrefix("-") {
                throw CLIError("未知选项 \(arg)")
            } else {
                positional.append(arg)
                index += 1
            }
        }

        let dbOverride = values["--db"]
        guard let name = positional.first else {
            return Invocation(command: .help, dbOverride: dbOverride, json: json)
        }
        if help { return Invocation(command: .help, dbOverride: dbOverride, json: json) }

        func optionalStatus() throws -> TaskStatus? {
            guard let raw = values["--status"] else { return nil }
            return try parseStatus(raw)
        }

        let command: Command
        switch name {
        case "add":
            guard positional.count >= 2 else { throw CLIError("add 缺任务标题") }
            let title = positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw CLIError("任务标题不能为空") }
            var add = AddCommand(title: title)
            add.status = try optionalStatus() ?? .today
            if let raw = values["--area"] {
                guard let area = TaskArea(rawValue: raw.lowercased()) else {
                    throw CLIError("未知领域 \"\(raw)\"，可选：work|personal")
                }
                add.area = area
            }
            add.note = values["--note"]
            if let due = values["--due"] {
                guard let date = parseDueDate(due, now: now) else {
                    throw CLIError("无法解析截止时间 \"\(due)\"（支持：今天/明天/下周X/9月20日/9/20/2026-09-20/tomorrow…）")
                }
                add.dueDate = date
            }
            add.waitingOn = values["--waiting-on"]
            if let raw = values["--parent"] {
                guard let parentId = Int64(raw) else { throw CLIError("--parent 需要任务 id（数字）") }
                add.parentId = parentId
            }
            command = .add(add)
        case "list", "ls":
            command = .list(status: try optionalStatus(), includeDone: includeDone)
        case "done":
            command = .done(id: try parseID(positional, command: "done"))
        case "move":
            let id = try parseID(positional, command: "move")
            guard positional.count >= 3 else { throw CLIError("move 缺目标状态（today|doing|waiting|backlog|done）") }
            command = .move(id: id, status: try parseStatus(positional[2]), waitingOn: values["--waiting-on"])
        case "help":
            command = .help
        default:
            throw CLIError("未知命令 \"\(name)\"")
        }
        return Invocation(command: command, dbOverride: dbOverride, json: json)
    }

    static func parseStatus(_ raw: String) throws -> TaskStatus {
        guard let status = TaskStatus(rawValue: raw.lowercased()) else {
            throw CLIError("未知状态 \"\(raw)\"，可选：\(TaskStatus.allCases.map(\.rawValue).joined(separator: "|"))")
        }
        return status
    }

    private static func parseID(_ positional: [String], command: String) throws -> Int64 {
        guard positional.count >= 2, let id = Int64(positional[1]) else {
            throw CLIError("\(command) 需要任务 id（数字），用 bbboard list 查看")
        }
        return id
    }

    /// ISO（2026-09-20 / 2026/9/20）优先精确解析，其余交 DateResolver 的自然语言规则；失败返回 nil。
    static func parseDueDate(_ text: String, now: Date = Date()) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy/M/d"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return Calendar.current.startOfDay(for: date)
            }
        }
        return DateResolver.resolve(text, now: now)
    }

    // MARK: - 执行

    /// 执行命令，返回要打印到 stdout 的文本。写操作完成后广播外部变更通知。
    static func execute(_ command: Command, store: TaskStore, json: Bool = false) throws -> String {
        switch command {
        case .add(let add):
            let task = try store.createTask(
                title: add.title,
                status: add.status,
                area: add.area,
                dueDate: add.dueDate,
                waitingOn: add.waitingOn,
                note: add.note,
                parentId: add.parentId,
                source: .cli
            )
            notifyExternalChange()
            if json { return jsonString(taskJSONObject(task)) }
            return "已添加 #\(task.id ?? 0) \(task.title)（\(task.status.rawValue)）"

        case .list(let status, let includeDone):
            let tasks = try store.allTasks()
                .filter { $0.parentId == nil }
                .filter { includeDone || $0.status != .done }
                .filter { status == nil || $0.status == status }
            if json { return jsonString(tasks.map(taskJSONObject)) }
            if tasks.isEmpty { return "（没有符合条件的任务）" }
            return tasks.map { line($0) }.joined(separator: "\n")

        case .done(let id):
            let title = try taskTitle(id, store: store)
            try store.setStatus(id, to: .done)
            notifyExternalChange()
            return "已完成 #\(id) \(title)"

        case .move(let id, let status, let waitingOn):
            let title = try taskTitle(id, store: store)
            try store.setStatus(id, to: status, waitingOn: waitingOn)
            notifyExternalChange()
            return "已移动 #\(id) \(title) → \(status.rawValue)"

        case .help:
            return usage
        }
    }

    /// 广播分布式通知：正在运行的 App 收到后重载任务
    /// （GRDB 的 ValueObservation 只覆盖本进程写入，跨进程变更必须显式重取）。
    static func notifyExternalChange() {
        DistributedNotificationCenter.default().postNotificationName(
            .bbboardExternalChange, object: nil, deliverImmediately: true
        )
    }

    // MARK: - 输出格式

    private static func taskTitle(_ id: Int64, store: TaskStore) throws -> String {
        guard let task = try store.task(id: id) else { throw CLIError("任务 #\(id) 不存在") }
        return task.title
    }

    private static func line(_ task: Task) -> String {
        var text = "#\(task.id ?? 0) [\(task.status.rawValue)·\(task.area.rawValue)] \(task.title)"
        var extras: [String] = []
        if let due = task.dueDate {
            extras.append("截止 \(due.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits)))")
        }
        if let waitingOn = task.waitingOn { extras.append("等 \(waitingOn)") }
        if !extras.isEmpty { text += "（\(extras.joined(separator: "，"))）" }
        if let note = task.note, !note.isEmpty {
            text += "\n    \(note.replacingOccurrences(of: "\n", with: "\n    "))"
        }
        return text
    }

    static func taskJSONObject(_ task: Task) -> [String: Any] {
        var object: [String: Any] = [
            "id": task.id ?? 0,
            "title": task.title,
            "status": task.status.rawValue,
            "area": task.area.rawValue
        ]
        if let note = task.note { object["note"] = note }
        if let due = task.dueDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            object["dueDate"] = formatter.string(from: due)
        }
        if let waitingOn = task.waitingOn { object["waitingOn"] = waitingOn }
        if let parentId = task.parentId { object["parentId"] = parentId }
        return object
    }

    static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        ) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
