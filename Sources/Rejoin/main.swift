import AppKit
import SQLite3
import SwiftUI

enum Tool: String, CaseIterable, Sendable {
    case claude, codex, antigravity, copilot

    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        }
    }

    var color: Color {
        switch self {
        case .codex: .teal
        case .claude: .orange
        case .antigravity: .blue
        case .copilot: .purple
        }
    }

    func resumeCommand(_ id: String) -> String {
        switch self {
        case .codex: "codex resume \(id)"
        case .claude: "claude --resume \(id)"
        case .antigravity: "agy --conversation \(id)"
        case .copilot: "copilot --resume=\(id)"
        }
    }
}

struct Session: Identifiable, Sendable {
    var id: String { "\(tool.rawValue):\(sessionID)" }
    let tool: Tool
    let sessionID: String
    let title: String
    let cwd: String
    let updated: Date
    /// The JSONL holding the conversation, for the tools that keep one per session
    var transcriptPath = ""

    var command: String { tool.resumeCommand(sessionID) }
    var commandWithCd: String { cwd.isEmpty ? command : "cd \(shellQuote(cwd)) && \(command)" }

    /// One line to paste into a new session so the agent can find this one, including the transcript file when there is one
    var reference: String {
        var details: [String] = []
        if !cwd.isEmpty { details.append("cwd: \(cwd)") }
        if !transcriptPath.isEmpty {
            // Codex may have compressed the rollout since the list was loaded
            let zst = transcriptPath + ".zst"
            let path = !FileManager.default.fileExists(atPath: transcriptPath) && FileManager.default.fileExists(atPath: zst) ? zst : transcriptPath
            details.append("transcript: \(path)")
        }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "\(tool.name) session \(sessionID) \u{201C}\(title)\u{201D}\(suffix)"
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser

func fail(_ message: String) -> NSError {
    NSError(domain: "Rejoin", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
    sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
}

/// Runs a query against another app's database without ever writing to it
func query(_ path: URL, _ sql: String, row: (OpaquePointer?) -> Void) throws {
    // A WAL database with no -shm file (its app is not running) cannot be opened with mode=ro,
    // and with no writer around it is safe to read as immutable instead
    for params in ["mode=ro", "immutable=1"] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path.absoluteString + "?" + params, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw fail(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 2000)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc == SQLITE_CANTOPEN { continue }
        guard rc == SQLITE_OK else { throw fail(String(cString: sqlite3_errmsg(db))) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        return
    }
    throw fail(String(localized: "Could not open \(displayPath(path.path))"))
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Codex: unarchived, user-started threads in ~/.codex/state_*.sqlite
func loadCodex() throws -> [Session] {
    let dir = home.appending(path: ".codex")
    guard exists(dir) else { return [] }
    // A schema update may bump state_5 to state_6 and so on, so take the highest number
    guard let dbName = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") })
        .max(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    else { return [] }
    var result: [Session] = []
    try query(dir.appending(path: dbName), """
        SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), preview), cwd, recency_at_ms, rollout_path
        FROM threads
        WHERE archived = 0 AND preview <> '' AND source NOT LIKE '{%'
        """) { stmt in
        result.append(Session(tool: .codex, sessionID: text(stmt, 0), title: text(stmt, 1), cwd: text(stmt, 2),
                              updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000),
                              transcriptPath: text(stmt, 4)))
    }
    return result
}

/// Claude Code: one JSONL per session in ~/.claude/projects/<dir>/. Sub-agents live in subfolders and are left out.
func loadClaude() throws -> [Session] {
    let dir = home.appending(path: ".claude/projects")
    guard exists(dir) else { return [] }
    let fm = FileManager.default
    var result: [Session] = []
    for project in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        let files = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            if let s = claudeSession(file) { result.append(s) }
        }
    }
    return result
}

/// Claude re-appends the title and last prompt as the session goes on, so the tail of the file is enough.
/// Reads a growing tail until it finds a title and a cwd; a session with no prompt at all is skipped.
func claudeSession(_ file: URL) -> Session? {
    guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else { return nil }
    defer { try? handle.close() }
    var chunk: UInt64 = 256 * 1024
    while true {
        let start = size > chunk ? size - chunk : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line
        var custom: String?, ai: String?, prompt: String?, cwd: String?
        for line in lines.reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "custom-title": custom = custom ?? obj["customTitle"] as? String
            case "ai-title": ai = ai ?? obj["aiTitle"] as? String
            case "last-prompt": prompt = prompt ?? obj["lastPrompt"] as? String
            default: break
            }
            if cwd == nil { cwd = obj["cwd"] as? String }
        }
        let title = [custom, ai, prompt].compactMap { $0 }.first { !$0.isEmpty }
        if let title, let cwd {
            let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Session(tool: .claude, sessionID: file.deletingPathExtension().lastPathComponent,
                           title: title, cwd: cwd, updated: updated, transcriptPath: file.path)
        }
        if start == 0 { return nil }
        chunk *= 4
    }
}

/// Antigravity CLI (agy): top-level conversations in ~/.gemini/antigravity-cli/conversation_summaries.db
func loadAntigravity() throws -> [Session] {
    let db = home.appending(path: ".gemini/antigravity-cli/conversation_summaries.db")
    guard exists(db) else { return [] }
    var result: [Session] = []
    try query(db, """
        SELECT conversation_id, COALESCE(NULLIF(title, ''), preview), workspace_uris,
               CAST(strftime('%s', last_modified_time) AS INTEGER)
        FROM conversation_summaries
        WHERE step_count > 0 AND parent_conversation_id = '' AND nesting_depth = 0
        """) { stmt in
        // workspace_uris is a JSON array of file:// URIs
        let uris = (try? JSONSerialization.jsonObject(with: Data(text(stmt, 2).utf8))) as? [String]
        let cwd = uris?.first.flatMap { URL(string: $0)?.path } ?? ""
        result.append(Session(tool: .antigravity, sessionID: text(stmt, 0), title: text(stmt, 1), cwd: cwd,
                              updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)))))
    }
    return result
}

/// GitHub Copilot CLI: sessions with at least one turn in ~/.copilot/session-store.db
func loadCopilot() throws -> [Session] {
    let db = home.appending(path: ".copilot/session-store.db")
    guard exists(db) else { return [] }
    var result: [Session] = []
    try query(db, """
        SELECT s.id,
               COALESCE(NULLIF(s.summary, ''),
                        (SELECT user_message FROM turns t WHERE t.session_id = s.id ORDER BY turn_index LIMIT 1), ''),
               COALESCE(s.cwd, ''), CAST(strftime('%s', s.updated_at) AS INTEGER)
        FROM sessions s
        WHERE EXISTS (SELECT 1 FROM turns t WHERE t.session_id = s.id)
        """) { stmt in
        result.append(Session(tool: .copilot, sessionID: text(stmt, 0), title: text(stmt, 1), cwd: text(stmt, 2),
                              updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)))))
    }
    return result
}

extension Tool {
    /// Only tools whose sessions can be removed without writing to their private databases
    var canDelete: Bool { self == .codex || self == .claude }
}

/// Codex deletes its own session for good with `codex delete`; a Claude Code transcript and
/// its folder of sub-agents and tool results go to the Trash
func deleteSession(_ session: Session) throws {
    switch session.tool {
    case .codex:
        // A login shell, so codex is found on the user's PATH as in the terminal
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "codex delete --force \"$1\"", "rejoin", session.sessionID]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw fail(message.isEmpty ? String(localized: "codex delete failed") : message)
        }
    case .claude:
        let file = URL(fileURLWithPath: session.transcriptPath)
        let folder = file.deletingPathExtension()
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        if exists(folder) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
    case .antigravity, .copilot:
        throw fail(String(localized: "\(session.tool.name) sessions cannot be deleted"))
    }
}

func loadAll() -> (sessions: [Session], errors: [String]) {
    let loaders: [(Tool, () throws -> [Session])] = [
        (.codex, loadCodex), (.claude, loadClaude), (.antigravity, loadAntigravity), (.copilot, loadCopilot),
    ]
    var sessions: [Session] = [], errors: [String] = []
    for (tool, load) in loaders {
        do { sessions += try load() } catch { errors.append("\(tool.name): \(error.localizedDescription)") }
    }
    return (sessions.sorted { $0.updated > $1.updated }, errors)
}

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var errors: [String] = []
    @Published var deleteError: String?

    func reload() {
        Task {
            let (sessions, errors) = await Task.detached { loadAll() }.value
            self.sessions = sessions
            self.errors = errors
        }
    }

    func delete(_ session: Session) {
        Task {
            do {
                try await Task.detached { try deleteSession(session) }.value
            } catch {
                deleteError = error.localizedDescription
            }
            reload()
        }
    }
}

/// Directories in order of their most recent session, with how many sessions each has
func directories(_ sessions: [Session]) -> [(cwd: String, count: Int)] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for s in sessions {
        if counts[s.cwd] == nil { order.append(s.cwd) }
        counts[s.cwd, default: 0] += 1
    }
    return order.map { ($0, counts[$0]!) }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func displayPath(_ path: String) -> String {
    path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
}

func folderName(_ cwd: String) -> String {
    cwd.isEmpty ? String(localized: "No Directory") : URL(fileURLWithPath: cwd).lastPathComponent
}


/// Base text size for the conversation; View > Bigger / Smaller change it
let defaultFontSize = 13.0
let fontSizeRange = 10.0...24.0

struct FontSizeCommands: Commands {
    @AppStorage("fontSize") private var fontSize = defaultFontSize

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger") { fontSize = min(fontSize + 1, fontSizeRange.upperBound) }
                .keyboardShortcut("+")
            Button("Smaller") { fontSize = max(fontSize - 1, fontSizeRange.lowerBound) }
                .keyboardShortcut("-")
            Button("Actual Size") { fontSize = defaultFontSize }
                .keyboardShortcut("0")
        }
    }
}

struct RejoinApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Rejoin", id: "main") {
            ContentView().environmentObject(store)
        }
        .commands { FontSizeCommands() }
    }
}

RejoinApp.main()
