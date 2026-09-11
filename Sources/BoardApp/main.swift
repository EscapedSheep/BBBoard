import AppKit

// 开发期自检：`BoardApp --selftest` 跑样例解析与通知探针，不进 App。
if CommandLine.arguments.contains("--selftest") {
    setbuf(stdout, nil) // 管道输出不缓冲，实时可见
    _Concurrency.Task {
        await SelfTest.run()
        exit(0)
    }
    RunLoop.main.run()
    exit(0)
}

/// 手动入口：保证 NSApplication 单例是 BoardApplication（首个调用 shared 的类决定实例类型）。
let app = BoardApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
