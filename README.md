# Rejoin

A lightweight, native macOS list of your coding-agent sessions — [Codex](https://github.com/openai/codex), [Claude Code](https://github.com/anthropics/claude-code), [Antigravity CLI](https://antigravity.google) and [GitHub Copilot CLI](https://github.com/github/copilot-cli) — grouped by working directory, so you can pick one up again in the terminal.

- Sessions from every tool in one list, the most recently used first, with a sidebar to narrow them to one tool or one working directory
- Pick a session to read its conversation — your messages and the agent's replies with their Markdown (headings, lists, tables, code), and tool calls folded into a count
- Double-click a session (or press Return) to resume it in a new [Ghostty](https://ghostty.org) tab in its directory; without Ghostty, in a new Terminal window
- ⌘C copies a one-line reference to the session — tool, ID, title, directory and transcript file — to paste into a new session so the agent can look it up; right-click for the ID, title or resume command alone
- Archive or restore sessions from the toolbar or right-click menu. Switch between **Active**, **Archived**, and **All** at the top of the session list. The list opens in **Active**.
- Delete a Codex or Claude Code session from the toolbar, with ⌘⌫, by pressing Delete (⌫) in the session list, or by right-clicking: Codex sessions are deleted for good with `codex delete`, and a Claude Code transcript goes to the Trash with its folder of sub-agents and tool results
- Search titles and directories; View › Bigger / Smaller (⌘+ / ⌘−) change the conversation's text size
- Reloads when the app comes to the front, or with ⌘R
- Shows 5-hour and weekly subscription quota remaining and reset times for Codex and Claude Code from the macOS menu bar
- Written in Swift with SwiftUI only — no Electron, no dependencies

| Tool | Read from | Resume command |
|---|---|---|
| Codex | `~/.codex/state_*.sqlite` (user-started threads) | `codex resume <id>` |
| Claude Code | `~/.claude/projects/*/<id>.jsonl` (sub-agents left out) | `claude --resume <id>` |
| Antigravity CLI | `~/.gemini/antigravity-cli/conversation_summaries.db` (top-level conversations) | `agy --conversation <id>` |
| Copilot CLI | `~/.copilot/session-store.db` | `copilot --resume=<id>` |

A tool that is not installed is simply skipped. Codex compresses older conversations to `.jsonl.zst`; reading those needs the `zstd` command (`brew install zstd`). Antigravity keeps its conversations as undocumented protobuf, so Rejoin shows the plain text Antigravity stores for search, which may lose some formatting.

The first time Rejoin opens a terminal tab, macOS asks to let it control Ghostty or Terminal.

Rejoin opens each tool's databases read-only. Codex archiving and restoring use `codex archive` and `codex unarchive`, so those changes are shared with Codex. Restore an archived Codex session in Rejoin before resuming it. Rejoin stores archive status for Claude Code, Antigravity, and Copilot in its own preferences.

Rejoin deletes Codex sessions through `codex delete --force` and moves Claude Code's files to the Trash. It runs all Codex commands in a login shell so `codex` is found on your PATH. Antigravity and Copilot sessions cannot be deleted. The files Rejoin reads are internal to each tool, so a future update may change their format.

## Usage limits

Click the gauge icon in the macOS menu bar to see your usage and reset times in local time. Codex reads the active ChatGPT account's limits through `codex app-server`. Open the panel or click its refresh button to reload usage. A missing or expired window displays `—` until a current value arrives.

Right-click or Control-click the gauge to open the Rejoin window, refresh sessions and usage, toggle Open at Login, or quit.

Claude Code reports limits through its [status line](https://code.claude.com/docs/en/statusline) after an API response on supported plans. Set up the connection once in your Claude Code settings, normally `~/.claude/settings.json`.

- If you already have a `statusLine.command`, open the **Claude Code** setup menu in the usage panel and choose **Copy Claude Code Usage Pipe**. Prepend the copied text to the existing command. If the existing command contains several shell statements, group those statements with `{ …; }` so that the original command block receives the input. Keep the other settings in `statusLine`.
- If you have no status line, choose **Copy Claude Code Usage Command** and set `statusLine` to an object with `"type": "command"` and the copied text as its `"command"` value.

Start a new Claude Code session and let it finish a response, then open or refresh the usage panel. Rejoin shows the last quota data it received and its receipt time. The bridge stores only quota values, reset times, and the receipt time. If the app moves, copy the command again from its new location.

## Requirements

- macOS 26 or later
- Xcode or the Xcode Command Line Tools (Swift 6)

## Build

```sh
./build.sh
```

This produces `build/Rejoin.app`. `./build.sh --install` also copies it to `~/Applications`.

The app icon is drawn by `scripts/make-icon.swift` at build time. UI strings are English in code; other languages live in `Localization/*.lproj`.

## License

[MIT](LICENSE)
