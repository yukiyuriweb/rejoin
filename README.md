# Rejoin

A lightweight, native macOS list of your coding-agent sessions — [Codex](https://github.com/openai/codex), [Claude Code](https://github.com/anthropics/claude-code), [Antigravity CLI](https://antigravity.google) and [GitHub Copilot CLI](https://github.com/github/copilot-cli) — grouped by working directory, so you can pick one up again in the terminal.

- Sessions from every tool in one list, grouped by directory, the most recently used first; each row is tagged with its tool
- Show or hide each tool from the toolbar
- One click copies the resume command; right-click to copy just the ID, or the command with a `cd` into the session's directory
- Reloads when the app comes to the front, or with ⌘R
- Written in Swift with SwiftUI only — no Electron, no dependencies

| Tool | Read from | Copied command |
|---|---|---|
| Codex | `~/.codex/state_*.sqlite` (unarchived, user-started threads) | `codex resume <id>` |
| Claude Code | `~/.claude/projects/*/<id>.jsonl` (sub-agents left out) | `claude --resume <id>` |
| Antigravity CLI | `~/.gemini/antigravity-cli/conversation_summaries.db` (top-level conversations) | `agy --conversation <id>` |
| Copilot CLI | `~/.copilot/session-store.db` | `copilot --resume=<id>` |

A tool that is not installed is simply skipped.

Rejoin is read-only: it opens each tool's files read-only and never changes them. Those files are internal to each tool, so a future update of any of them may change the format and break that part of this app.

## Requirements

- macOS 14 or later
- Xcode or the Xcode Command Line Tools (Swift 6)

## Build

```sh
./build.sh
```

This produces `build/Rejoin.app`. `./build.sh --install` also copies it to `~/Applications`.

The app icon is drawn by `scripts/make-icon.swift` at build time. UI strings are English in code; other languages live in `Localization/*.lproj`.

## License

[MIT](LICENSE)
