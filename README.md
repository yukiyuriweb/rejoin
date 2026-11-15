# Rejoin

A lightweight, native macOS list of your coding-agent sessions — [Codex](https://github.com/openai/codex), [Claude Code](https://github.com/anthropics/claude-code), [Antigravity CLI](https://antigravity.google) and [GitHub Copilot CLI](https://github.com/github/copilot-cli) — grouped by working directory, so you can pick one up again in the terminal.

- Sessions from every tool in one list, with a sidebar of working directories, the most recently used first
- Pick a session to read its conversation — your messages and the agent's replies, with tool calls folded into a count
- Double-click a session (or press Return) to resume it in a new [Ghostty](https://ghostty.org) tab in its directory; without Ghostty, in a new Terminal window
- ⌘C copies a one-line reference to the session — tool, ID, title, directory and transcript file — to paste into a new session so the agent can look it up; right-click for the ID, title or resume command alone
- Filter by tool and search titles and directories from the toolbar
- Reloads when the app comes to the front, or with ⌘R
- Written in Swift with SwiftUI only — no Electron, no dependencies

| Tool | Read from | Resume command |
|---|---|---|
| Codex | `~/.codex/state_*.sqlite` (unarchived, user-started threads) | `codex resume <id>` |
| Claude Code | `~/.claude/projects/*/<id>.jsonl` (sub-agents left out) | `claude --resume <id>` |
| Antigravity CLI | `~/.gemini/antigravity-cli/conversation_summaries.db` (top-level conversations) | `agy --conversation <id>` |
| Copilot CLI | `~/.copilot/session-store.db` | `copilot --resume=<id>` |

A tool that is not installed is simply skipped. Codex compresses older conversations to `.jsonl.zst`; reading those needs the `zstd` command (`brew install zstd`). Antigravity keeps its conversations as undocumented protobuf, so Rejoin shows the plain text Antigravity stores for search, which may lose some formatting.

The first time Rejoin opens a terminal tab, macOS asks to let it control Ghostty or Terminal.

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
