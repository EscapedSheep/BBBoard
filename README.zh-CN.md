# BBBoard — Desktop AI Board

**English → [README.md](README.md)**

一个不需要打开的任务管理系统。它不住在 App 里，它住在你的桌面上。

BBBoard 是 macOS 原生的常驻任务看板：以紧凑挂件形态挂在桌面上，悬停展开，用规则解析把混乱的脑内想法变成结构化任务。没有要打开的窗口，没有要切换的 App。

## 功能

- **桌面挂件** — 位于桌面图标之上、普通窗口之下（与 Apple 桌面小组件同层）。悬停展开，头部拖动换位，位置持久化。
- **横向看板** — TODAY | DOING | WAITING 三列，BACKLOG / DONE 为折叠区。卡片拖拽改状态。
- **Brain Dump** — 粘贴混乱想法（"明天跟进 PRG 的 API key，等 Peter 回复"），规则解析器（中文日期规则 + NSDataDetector + 等待语识别）拆成结构化提案（标题/状态/日期/等待对象），逐条确认入库。支持中英混输。
- **Daily Focus** — 规则引擎每天选出最该关注的任务，理由可解释（逾期/等待过久/停滞），按天快照。
- **说明与子任务** — 卡片备注、嵌套子任务与进度徽标（2/5）。
- **Peek 面板** — ⌥Space 全局快捷键随时呼出，全屏 App 之上也可用。
- **纯本地** — 全部数据在本地 SQLite（GRDB），完整活动日志。无账号、无云同步。

## 环境要求

- macOS 26+ / Apple Silicon

## 构建与运行

```bash
git clone https://github.com/EscapedSheep/BBBoard.git
cd BBBoard
swift run BoardApp        # debug，从终端运行
```

Release 安装（生成 `~/Applications/BBBoard.app`）：

```bash
swift build -c release
mkdir -p ~/Applications/BBBoard.app/Contents/MacOS
cp .build/release/BoardApp ~/Applications/BBBoard.app/Contents/MacOS/BBBoard
# 补一个最小 Info.plist（LSUIElement=true），然后：
codesign --force --sign - ~/Applications/BBBoard.app
```

> 注意：命令行构建需要完整 Xcode 工具链（`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）——Command Line Tools 缺 XCTest。

## 架构

```
BoardApp        macOS App：桌面挂件（AppKit NSPanel）、Peek 面板、全局快捷键、SwiftUI 视图
  ├─ RuleEngine 纯函数：截止/等待/停滞规则 + Focus 打分 + Brain Dump/日期解析 + 重复检测，全单测
  └─ TaskStore  GRDB/SQLite：迁移、CRUD、activity_log、Focus 快照、corrections
```

设计原则：

- **解析产出永远是提案** — 不经用户确认不入库；每次修改记入 `corrections` 表。
- **所有写操作记日志** — `activity_log`（created/edited/status_changed/completed/deleted）是 Daily Focus 和智能清理质量的上限。

## 测试

```bash
swift test    # 140 个测试：规则引擎、日期解析、Brain Dump 解析器、存储层
```

## 许可证

MIT — 见 [LICENSE](LICENSE)。
