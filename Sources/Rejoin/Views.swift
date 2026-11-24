import AppKit
import SwiftUI

extension Tool {
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "terminal.fill"
        case .antigravity: "arrow.up"
        case .copilot: "airplane"
        }
    }
}

/// A rounded square in the tool's color with a symbol for it
struct ToolIcon: View {
    let tool: Tool
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tool.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Mail-style date: the time today, then Yesterday, the weekday within a week, and the date beyond that
func shortDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
    if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(date: .numeric, time: .omitted)
}

struct SessionRow: View {
    let session: Session
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ToolIcon(tool: session.tool, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(shortDate(session.updated))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .help(session.title)
    }
}

struct CopyMenuItems: View {
    let session: Session

    var body: some View {
        Button("Copy Reference") { copy(session.reference) }
        Button("Copy ID") { copy(session.sessionID) }
        Button("Copy Title") { copy(session.title) }
        Divider()
        Button("Copy Resume Command") { copy(session.command) }
        Button("Copy with cd") { copy(session.commandWithCd) }
    }
}

enum SidebarItem: Hashable {
    case all
    case tool(Tool)
    case folder(String)
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selection: SidebarItem? = .all
    @State private var selectedSessionID: String?
    @State private var search = ""
    @State private var pendingDelete: Session?

    var shownSessions: [Session] {
        store.sessions.filter { s in
            switch selection {
            case .tool(let tool): if s.tool != tool { return false }
            case .folder(let cwd): if s.cwd != cwd { return false }
            case .all, nil: break
            }
            return search.isEmpty || s.title.localizedCaseInsensitiveContains(search) || s.cwd.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } content: {
            sessionList
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
                .navigationTitle(title)
        } detail: {
            if let session = session(selectedSessionID) {
                TranscriptView(session: session)
                    // Lets other apps (such as time trackers) read the session's directory through the Accessibility API.
                    .navigationDocument(URL(fileURLWithPath: session.cwd.isEmpty ? home.path : session.cwd))
            } else {
                ContentUnavailableView("Select a Session", systemImage: "text.bubble")
            }
        }
        .searchable(text: $search, placement: .sidebar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Reload")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { pendingDelete = session(selectedSessionID) } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete)
                    .disabled(!(session(selectedSessionID)?.tool.canDelete ?? false))
                    .help("Delete")
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { s in
            Button("Delete", role: .destructive) {
                if selectedSessionID == s.id { selectedSessionID = nil }
                store.delete(s)
            }
        } message: { s in
            Text(s.tool == .codex
                 ? "The session is deleted permanently with codex delete. This cannot be undone."
                 : "The conversation file is moved to the Trash.")
        }
        .alert("Could not delete the session", isPresented: Binding(get: { store.deleteError != nil }, set: { if !$0 { store.deleteError = nil } })) {
        } message: {
            Text(store.deleteError ?? "")
        }
        .frame(minWidth: 1000, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
    }

    var sidebar: some View {
        let dirs = directories(store.sessions)
        // Folder names that occur more than once get their parent folder alongside
        let names = Dictionary(grouping: dirs.map { folderName($0.cwd) }, by: { $0 }).filter { $0.value.count > 1 }
        return List(selection: $selection) {
            Section {
                Label("All Sessions", systemImage: "tray.full")
                    .badge(store.sessions.count)
                    .tag(SidebarItem.all)
                ForEach(Tool.allCases, id: \.self) { tool in
                    Label {
                        Text(tool.name)
                    } icon: {
                        ToolIcon(tool: tool, size: 18)
                    }
                    .badge(store.sessions.filter { $0.tool == tool }.count)
                    .tag(SidebarItem.tool(tool))
                }
            }
            Section("Directories") {
                ForEach(dirs, id: \.cwd) { dir in
                    let name = folderName(dir.cwd)
                    Label {
                        HStack(spacing: 4) {
                            Text(name)
                            if names[name] != nil, !dir.cwd.isEmpty {
                                Text(URL(fileURLWithPath: dir.cwd).deletingLastPathComponent().lastPathComponent)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .badge(dir.count)
                    .help(displayPath(dir.cwd))
                    .tag(SidebarItem.folder(dir.cwd))
                }
            }
        }
    }

    @ViewBuilder var sessionList: some View {
        let sessions = shownSessions
        if sessions.isEmpty && store.errors.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "tray")
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            List(selection: $selectedSessionID) {
                ForEach(store.errors, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                ForEach(sessions) { s in
                    SessionRow(session: s, subtitle: subtitle(for: s))
                        .tag(s.id)
                }
            }
            // Double-click or Return resumes the session in the terminal
            .contextMenu(forSelectionType: String.self) { ids in
                if let s = session(ids.first) {
                    Button("Open in \(terminalName)") { openInTerminal(s) }
                    Divider()
                    CopyMenuItems(session: s)
                    if s.tool.canDelete {
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = s }
                    }
                }
            } primaryAction: { ids in
                if let s = session(ids.first) { openInTerminal(s) }
            }
            .onCopyCommand {
                session(selectedSessionID).map { [NSItemProvider(object: $0.reference as NSString)] } ?? []
            }
        }
    }

    /// Inside a directory the directory is already known, so the row names the tool instead
    func subtitle(for s: Session) -> String {
        if case .folder = selection { return s.tool.name }
        return folderName(s.cwd)
    }

    func session(_ id: String?) -> Session? {
        store.sessions.first { $0.id == id }
    }

    var deleteTitle: String {
        pendingDelete.map { String(localized: "Delete \u{201C}\($0.title)\u{201D}?") } ?? ""
    }

    var title: String {
        switch selection {
        case .tool(let tool): tool.name
        case .folder(let cwd): folderName(cwd)
        case .all, nil: String(localized: "All Sessions")
        }
    }
}
