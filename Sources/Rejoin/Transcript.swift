import Foundation
import SQLite3
import SwiftUI

enum Role: Sendable { case user, assistant, tools }

struct Message: Identifiable, Sendable {
    let id: Int
    let role: Role
    var text: String
    var toolCount = 0
}

/// Collects messages, folding runs of assistant text into one message and runs of tool calls into one count
struct TranscriptBuilder {
    var messages: [Message] = []

    mutating func say(_ role: Role, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if role == .assistant, let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text += "\n\n" + text
        } else {
            messages.append(Message(id: messages.count, role: role, text: text))
        }
    }

    mutating func tool() {
        if let last = messages.indices.last, messages[last].role == .tools {
            messages[last].toolCount += 1
        } else {
            messages.append(Message(id: messages.count, role: .tools, text: "", toolCount: 1))
        }
    }
}

func loadTranscript(_ session: Session) throws -> [Message] {
    switch session.tool {
    case .codex: try codexTranscript(session.transcriptPath)
    case .claude: try claudeTranscript(session.transcriptPath)
    case .antigravity: try antigravityTranscript(session.sessionID)
    case .copilot: try copilotTranscript(session.sessionID)
    }
}

func jsonLines(_ path: String) throws -> [[String: Any]] {
    try jsonLines(Data(contentsOf: URL(fileURLWithPath: path)))
}

func jsonLines(_ data: Data) -> [[String: Any]] {
    data.split(separator: UInt8(ascii: "\n")).compactMap {
        (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
    }
}

/// Codex compresses older rollouts to .jsonl.zst, which only the zstd command can read
func codexRollout(_ path: String) throws -> [[String: Any]] {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) { return try jsonLines(path) }
    let zst = path + ".zst"
    guard fm.fileExists(atPath: zst) else { throw fail(String(localized: "The conversation file is gone")) }
    guard let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].first(where: fm.isExecutableFile) else {
        throw fail(String(localized: "Reading older Codex sessions needs zstd (brew install zstd)"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: zstd)
    process.arguments = ["-dcq", zst]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw fail(String(localized: "zstd could not read the conversation file")) }
    return jsonLines(data)
}

/// Codex keeps the conversation in a rollout JSONL; the user messages it injects itself start with a tag or AGENTS.md
func codexTranscript(_ path: String) throws -> [Message] {
    var b = TranscriptBuilder()
    for line in try codexRollout(path) where line["type"] as? String == "response_item" {
        guard let p = line["payload"] as? [String: Any] else { continue }
        switch p["type"] as? String {
        case "message":
            let parts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            switch p["role"] as? String {
            case "user":
                for t in parts {
                    let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.hasPrefix("<") && !s.hasPrefix("# AGENTS.md") { b.say(.user, s) }
                }
            case "assistant": b.say(.assistant, parts.joined(separator: "\n\n"))
            default: break
            }
        case "function_call", "custom_tool_call", "local_shell_call", "web_search_call": b.tool()
        default: break
        }
    }
    return b.messages
}

/// Turns Claude Code's own wrappers into what the user typed; nil for lines Claude adds by itself
func claudeUserText(_ s: String) -> String? {
    guard s.hasPrefix("<") else { return s }
    if s.hasPrefix("<command-name>") {
        func tag(_ name: String) -> String {
            guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return "" }
            return String(s[a.upperBound..<b.lowerBound])
        }
        return [tag("command-name"), tag("command-args")].filter { !$0.isEmpty }.joined(separator: " ")
    }
    return s.hasPrefix("<pasted_content") ? s : nil
}

func claudeTranscript(_ path: String) throws -> [Message] {
    var b = TranscriptBuilder()
    for line in try jsonLines(path) {
        guard let type = line["type"] as? String, type == "user" || type == "assistant",
              line["isSidechain"] as? Bool != true, line["isMeta"] as? Bool != true,
              line["isCompactSummary"] as? Bool != true,
              let message = line["message"] as? [String: Any] else { continue }
        if let s = message["content"] as? String {
            if type == "user", let t = claudeUserText(s.trimmingCharacters(in: .whitespacesAndNewlines)) { b.say(.user, t) }
            continue
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch (type, block["type"] as? String) {
            case ("user", "text"):
                if let t = claudeUserText((block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { b.say(.user, t) }
            case ("user", "image"): b.say(.user, String(localized: "[Image]"))
            case ("assistant", "text"): b.say(.assistant, block["text"] as? String ?? "")
            case ("assistant", "tool_use"): b.tool()
            default: break
            }
        }
    }
    return b.messages
}

func copilotTranscript(_ id: String) throws -> [Message] {
    var b = TranscriptBuilder()
    let escaped = id.replacingOccurrences(of: "'", with: "''")
    try query(home.appending(path: ".copilot/session-store.db"), """
        SELECT COALESCE(user_message, ''), COALESCE(assistant_response, '')
        FROM turns WHERE session_id = '\(escaped)' ORDER BY turn_index
        """) { stmt in
        b.say(.user, text(stmt, 0))
        b.say(.assistant, text(stmt, 1))
    }
    return b.messages
}

/// Antigravity's own records are undocumented protobuf, so this reads the text it keeps for search:
/// each chunk holds the user and agent text with [step, byte offset] pairs marking where each step starts
func antigravityTranscript(_ id: String) throws -> [Message] {
    var steps: [(step: Int, role: Role, text: String)] = []
    func split(_ body: String, _ offsets: String, _ role: Role) {
        let bytes = Array(body.utf8)
        let pairs = ((try? JSONSerialization.jsonObject(with: Data(offsets.utf8))) as? [[Int]] ?? []).filter { $0.count == 2 }
        for (i, pair) in pairs.enumerated() {
            let start = min(max(pair[1], 0), bytes.count)
            let end = i + 1 < pairs.count ? min(max(pairs[i + 1][1], start), bytes.count) : bytes.count
            steps.append((pair[0], role, String(decoding: bytes[start..<end], as: UTF8.self)))
        }
    }
    let escaped = id.replacingOccurrences(of: "'", with: "''")
    try query(home.appending(path: ".gemini/antigravity-cli/conversation_summaries.db"), """
        SELECT user_body, user_step_byte_offsets, agent_body, agent_step_byte_offsets
        FROM conversations_fts WHERE conversation_id = '\(escaped)' AND chunk_index >= 0 ORDER BY chunk_index
        """) { stmt in
        split(text(stmt, 0), text(stmt, 1), .user)
        split(text(stmt, 2), text(stmt, 3), .assistant)
    }
    var b = TranscriptBuilder()
    for s in steps.sorted(by: { $0.step < $1.step }) { b.say(s.role, s.text) }
    return b.messages
}

// MARK: - Views

struct MessageView: View {
    let message: Message
    let fontSize: Double
    @State private var hovering = false
    @State private var copied = false

    /// Shown while the pointer is over the message; copies the whole message as its Markdown source
    var copyButton: some View {
        Button {
            copy(message.text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy Message")
        .opacity(hovering || copied ? 1 : 0)
    }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 80)
                    MarkdownText(source: message.text, fontSize: fontSize)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                copyButton
            }
            .onHover { hovering = $0 }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(source: message.text, fontSize: fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                copyButton
            }
            .onHover { hovering = $0 }
        case .tools:
            Label("^[\(message.toolCount) tool call](inflect: true)", systemImage: "wrench.and.screwdriver")
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TranscriptView: View {
    let session: Session
    @State private var messages: [Message]?
    @State private var error: String?
    /// Bumped by Reload Conversation to read the file again
    @State private var reloads = 0
    @State private var loadedID: String?
    @AppStorage("fontSize") private var fontSize = defaultFontSize

    var body: some View {
        content
            .task(id: "\(session.id)#\(reloads)") {
                // A reload keeps the old messages on screen until the new ones are in
                if loadedID != session.id {
                    messages = nil
                    error = nil
                    loadedID = session.id
                }
                let session = session
                do {
                    messages = try await Task.detached { try loadTranscript(session) }.value
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        reloads += 1
                    } label: {
                        Label("Reload Conversation", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Reload Conversation")
                    Menu {
                        CopyMenuItems(session: session)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    } primaryAction: {
                        copy(session.reference)
                    }
                    .help(String(localized: "Copy Reference") + ": " + session.reference)
                    Button {
                        openInTerminal(session)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help(String(localized: "Open in \(terminalName)") + ": " + session.command)
                }
            }
    }

    @ViewBuilder var content: some View {
        if let error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else if let messages {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: fontSize * 1.4) {
                    header
                    if messages.isEmpty {
                        Text("No Messages").foregroundStyle(.secondary)
                    }
                    ForEach(messages) { MessageView(message: $0, fontSize: fontSize) }
                }
                .textSelection(.enabled)
                // A readable measure, centered in wide windows
                .frame(maxWidth: fontSize * 58)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            // Open at the latest messages, where the session left off
            .defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title)
                .font(.system(size: fontSize * 1.6, weight: .bold))
            HStack(spacing: 6) {
                ToolIcon(tool: session.tool, size: fontSize * 1.3)
                Text(session.tool.name)
                Text("·")
                Text(displayPath(session.cwd)).lineLimit(1).truncationMode(.middle)
                Text("·")
                Text(session.updated.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.system(size: fontSize - 1))
            .foregroundStyle(.secondary)
            Divider().padding(.top, 6)
        }
    }
}
