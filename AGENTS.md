# AGENTS.md — BBBoard

macOS 常驻任务看板（Swift 6 / SwiftUI + AppKit，Swift Package，依赖仅 GRDB）。
看板数据在本地 SQLite，agent 可以通过 `bbboard` 命令行直接读写。

## 构建与测试

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # 必须，CLT 缺 XCTest
swift build && swift test
```

提交前必须全绿。注意：不要在 Package.swift 里显式声明 `products:` 给可执行产物起
与目标不同的名字（swiftbuild 引擎会搞混中间产物目录导致编译失败）。

## 用 bbboard CLI 操作看板

`./dev.sh` / `./install.sh` 会把 CLI 装到 `~/.local/bin/bbboard`；
未安装时用 `.build/debug/BoardCLI` 代替。

典型场景：用户给你一张截图，让你把要做的事记上看板。

```bash
bbboard list --json        # 先看板上已有什么（去重、拿任务 id）
bbboard add "跟进 PRG 的 API key" --due 明天 --status waiting --waiting-on Peter
bbboard add "写周报" --area personal --note "周五前"
bbboard move 12 doing      # 改状态：today|doing|waiting|backlog|done
bbboard done 12            # 完成
```

- `--due` 支持自然语言（今天/明天/下周三/9月20日/9/20/tomorrow…）和 ISO 日期。
- `--db <路径>` 指定数据库；默认自动定位 `~/Library/Application Support/BBBoard/board.sqlite`。
- 运行中的 App 会实时刷新（CLI 写后广播分布式通知），无需重启。

## 纪律

- **写看板只走 `bbboard` CLI 或 TaskStore API，不要直接改 SQLite**——所有写操作必须
  同事务记 `activity_log`（Focus 打分和智能清理依赖它）。
- 分层：BoardApp / BoardCLI → RuleEngine（纯函数，不碰数据库）→ TaskStore（GRDB）。
- 日期一律走 RuleEngine 的规则解析，不要另写日期逻辑。
- 内部文档（HANDOVER.md、MVP 实施计划.md、项目概念 md）在 .gitignore 里，不进仓库。
