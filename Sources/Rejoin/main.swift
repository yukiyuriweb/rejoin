import AppKit
import SQLite3
import SwiftUI

enum Tool: String, CaseIterable, Sendable {
    case codex, claude, antigravity, copilot

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

    var command: String { tool.resumeCommand(sessionID) }
    var commandWithCd: String { cwd.isEmpty ? command : "cd \(shellQuote(cwd)) && \(command)" }
}

struct Group: Identifiable {
    var id: String { cwd }
    let cwd: String
    let sessions: [Session]
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
        SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), preview), cwd, recency_at_ms
        FROM threads
        WHERE archived = 0 AND preview <> '' AND source NOT LIKE '{%'
        """) { stmt in
        result.append(Session(tool: .codex, sessionID: text(stmt, 0), title: text(stmt, 1), cwd: text(stmt, 2),
                              updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000)))
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
                           title: title, cwd: cwd, updated: updated)
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

    func reload() {
        Task {
            let (sessions, errors) = await Task.detached { loadAll() }.value
            self.sessions = sessions
            self.errors = errors
        }
    }

    func groups(showing tools: Set<Tool>) -> [Group] {
        // Sessions are newest first, so grouping in order of first appearance puts the most recently used directory first
        var order: [String] = []
        var byCwd: [String: [Session]] = [:]
        for s in sessions where tools.contains(s.tool) {
            if byCwd[s.cwd] == nil { order.append(s.cwd) }
            byCwd[s.cwd, default: []].append(s)
        }
        return order.map { Group(cwd: $0, sessions: byCwd[$0]!) }
    }
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

struct ToolBadge: View {
    let tool: Tool

    var body: some View {
        Text(tool.name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tool.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tool.color.opacity(0.15), in: Capsule())
    }
}

struct SessionRow: View {
    let session: Session
    @Binding var copiedID: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                HStack(spacing: 6) {
                    ToolBadge(tool: session.tool)
                    Text(session.updated, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                copy(session.command)
                copiedID = session.id
            } label: {
                Label(copiedID == session.id ? "Copied" : "Copy",
                      systemImage: copiedID == session.id ? "checkmark" : "doc.on.doc")
            }
            .help(session.command)
        }
        .contextMenu {
            Button("Copy Resume Command") { copy(session.command) }
            Button("Copy with cd") { copy(session.commandWithCd) }
            Button("Copy ID") { copy(session.sessionID) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var copiedID: String?
    // Comma-separated raw values of the tools the user has hidden
    @AppStorage("hiddenTools") private var hiddenTools = ""

    var shown: Set<Tool> {
        let hidden = Set(hiddenTools.split(separator: ",").map(String.init))
        return Set(Tool.allCases.filter { !hidden.contains($0.rawValue) })
    }

    func binding(for tool: Tool) -> Binding<Bool> {
        Binding {
            shown.contains(tool)
        } set: { show in
            var s = shown
            if show { s.insert(tool) } else { s.remove(tool) }
            hiddenTools = Tool.allCases.filter { !s.contains($0) }.map(\.rawValue).joined(separator: ",")
        }
    }

    var body: some View {
        List {
            ForEach(store.errors, id: \.self) { Text($0).foregroundStyle(.red) }
            ForEach(store.groups(showing: shown)) { group in
                Section {
                    ForEach(group.sessions) { SessionRow(session: $0, copiedID: $copiedID) }
                } header: {
                    HStack {
                        Text(group.cwd.isEmpty ? String(localized: "No Directory") : URL(fileURLWithPath: group.cwd).lastPathComponent).bold()
                        Text(displayPath(group.cwd)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(group.sessions.count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 460, minHeight: 300)
        .toolbar {
            Menu {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Toggle(tool.name, isOn: binding(for: tool))
                }
            } label: {
                Label("Tools", systemImage: "line.3.horizontal.decrease.circle")
            }
            Button { store.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
    }
}

struct RejoinApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Rejoin", id: "main") {
            ContentView().environmentObject(store)
        }
    }
}

RejoinApp.main()
