# BBBoard — Desktop AI Board

**中文文档 → [README.zh-CN.md](README.zh-CN.md)**

A task board that doesn't live in an app. It lives on your desktop.

BBBoard is a macOS-native ambient task board: it hangs on your desktop as a compact widget, expands on hover, and uses Apple's on-device Foundation Models to turn messy brain dumps into structured tasks. No window to open, no app to switch to.

## Features

- **Desktop widget** — lives above desktop icons, below your windows (same layer as Apple's own widgets). Hover to expand, drag from the header to move, position persists.
- **Horizontal kanban** — TODAY | DOING | WAITING columns, BACKLOG and DONE as collapsible sections. Drag cards between columns to change status.
- **Brain dump** — paste messy thoughts ("明天跟进 PRG 的 API key，等 Peter 回复"), get structured task proposals (title / status / due date / waiting-on), confirm card by card. Works in Chinese, English, and mixed input.
- **Degradation is a feature** — without Apple Intelligence, a rule-based fallback parser (NSDataDetector + Chinese date rules + waiting-clause detection) produces the same proposals. Manual entry always works.
- **Daily Focus** — rule engine picks today's top tasks with explainable reasons (overdue, waiting too long, stalled). Snapshotted per day.
- **Notes & subtasks** — per-card notes, nested subtasks with progress badges (2/5).
- **Peek panel** — ⌥Space global hotkey summons the same board anywhere, even over fullscreen apps.
- **Local-first** — everything in a local SQLite database (GRDB), full activity log. No account, no cloud.

## Requirements

- macOS 26+ on Apple Silicon
- Apple Intelligence enabled for AI parsing (optional — the fallback parser covers you)

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

> Note: command-line builds need the full Xcode toolchain (`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) — Command Line Tools alone lack the FoundationModels macro plugin and XCTest.

## Architecture

```
BoardApp        macOS app: desktop widget (AppKit NSPanel), peek panel, hotkey, SwiftUI views
  ├─ AIParser   Foundation Models wrapper (@Generable), availability gating, rule-based fallback parser, date resolver
  ├─ RuleEngine Pure functions: deadline/waiting/staleness rules + focus scoring. Fully unit-tested.
  └─ TaskStore  GRDB/SQLite: migrations, CRUD, activity log, focus snapshots, corrections
```

Design principles:

- **LLM does semantics only** — task extraction, classification, dedup judgment. Dates, timeouts, and scoring are always plain code.
- **AI output is always a proposal** — nothing enters the board without user confirmation; every edit is logged to a `corrections` table.
- **Every write is logged** — `activity_log` (created/edited/status_changed/completed/deleted) feeds Daily Focus and cleanup quality.

## Tests

```bash
swift test    # 80 tests: rule engine, date resolver, fallback parser, store
```

## License

MIT — see [LICENSE](LICENSE).
