# BBBoard — Desktop AI Board

**中文文档 → [README.zh-CN.md](README.zh-CN.md)**

A task board that doesn't live in an app. It lives on your desktop.

BBBoard is a macOS-native ambient task board: it hangs on your desktop as a compact widget, expands on hover, and uses a rule-based parser to turn messy brain dumps into structured tasks. No window to open, no app to switch to.

## Features

- **Desktop widget** — lives above desktop icons, below your windows (same layer as Apple's own widgets). Hover to expand, drag from the header to move, position persists.
- **Horizontal kanban** — TODAY | DOING | WAITING columns, BACKLOG and DONE as collapsible sections. Drag cards between columns to change status.
- **Brain dump** — paste messy thoughts ("明天跟进 PRG 的 API key，等 Peter 回复"), get structured task proposals (title / status / due date / waiting-on) from a rule-based parser (Chinese date rules + NSDataDetector + waiting-clause detection), confirm card by card. Works in Chinese, English, and mixed input.
- **Daily Focus** — rule engine picks today's top tasks with explainable reasons (overdue, waiting too long, stalled). Snapshotted per day.
- **Notes & subtasks** — per-card notes, nested subtasks with progress badges (2/5).
- **Peek panel** — ⌥Space global hotkey summons the same board anywhere, even over fullscreen apps.
- **Local-first** — everything in a local SQLite database (GRDB), full activity log. No account, no cloud.
- **CLI (bbboard)** — read/write the board from the terminal or an AI agent; the app refreshes live.

## CLI (bbboard)

Building produces a `BoardCLI` executable (`./dev.sh` / `./install.sh` install it as `~/.local/bin/bbboard`).
Handy for letting a person or an AI agent put work on the board — e.g. hand an agent a screenshot and let it record the to-dos itself:

```bash
bbboard list --json                                    # current board (agent-friendly)
bbboard add "Follow up PRG API key" --due 明天 --status waiting --waiting-on Peter
bbboard move 12 doing                                  # change status
bbboard done 12                                        # complete
```

Writes go through the same path as the app (TaskStore + activity_log); a running app refreshes via a distributed notification.
`--due` reuses the board's rule-based date parser (今天/明天/next Friday/9月20日/9/20/2026-09-20…); `--db` overrides the database path.

## Requirements

- macOS 26+ on Apple Silicon

## Build & Run

```bash
git clone https://github.com/EscapedSheep/BBBoard.git
cd BBBoard
swift run BoardApp        # debug, runs from terminal
```

Release install (creates `~/Applications/BBBoard.app`):

```bash
swift build -c release
mkdir -p ~/Applications/BBBoard.app/Contents/MacOS
cp .build/release/BoardApp ~/Applications/BBBoard.app/Contents/MacOS/BBBoard
# add a minimal Info.plist (LSUIElement=true), then:
codesign --force --sign - ~/Applications/BBBoard.app
```

> Note: command-line builds need the full Xcode toolchain (`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) — Command Line Tools alone lack XCTest.

## Architecture

```
BoardApp        macOS app: desktop widget (AppKit NSPanel), peek panel, hotkey, SwiftUI views
BoardCLI        bbboard CLI: read/write the board from terminal/agents (same database; notifies the app to refresh)
  ├─ RuleEngine Pure functions: deadline/waiting/staleness rules + focus scoring + brain-dump/date parsing + duplicate detection. Fully unit-tested.
  └─ TaskStore  GRDB/SQLite: migrations, CRUD, activity log, focus snapshots, corrections
```

Design principles:

- **Parser output is always a proposal** — nothing enters the board without user confirmation; every edit is logged to a `corrections` table.
- **Every write is logged** — `activity_log` (created/edited/status_changed/completed/deleted) feeds Daily Focus and cleanup quality.

## Tests

```bash
swift test    # 159 tests: rule engine, date resolver, brain-dump parser, store, CLI
```

## License

MIT — see [LICENSE](LICENSE).
