import AppKit

// 开发期自检：`BoardApp --selftest` 探测 Apple Intelligence 并跑真实解析样例，不进 App。
// 注意：不能信号量阻塞主线程——FoundationModels 内部依赖主 runloop/主队列，阻塞会死锁。
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
