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
                    if session.isArchived {
                        Label("Archived", systemImage: "archivebox")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .help("Archived")
                    }
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
        if session.canResume {
            Divider()
            Button("Copy Resume Command") { copy(session.command) }
            Button("Copy with cd") { copy(session.commandWithCd) }
        }
    }
}

struct ArchiveButton: View {
    @EnvironmentObject var store: Store
    let session: Session

    var title: LocalizedStringKey { session.isArchived ? "Restore from Archive" : "Archive" }

    var body: some View {
        Button { store.toggleArchive(session) } label: {
            Label(title, systemImage: session.isArchived ? "arrow.up.bin" : "archivebox")
        }
        .disabled(store.changingSessions.contains(session.id))
        .help(Text(title))
    }
}

enum SidebarItem: Hashable {
    case all
    case tool(Tool)
    case folder(String)
}

enum SessionFilter: CaseIterable, Hashable {
    case active, archived, all

    var label: LocalizedStringKey {
        switch self {
        case .active: "Active"
        case .archived: "Archived"
        case .all: "All"
        }
    }

    var symbol: String {
        switch self {
        case .active: "tray"
        case .archived: "archivebox"
        case .all: "square.stack"
        }
    }

    func includes(_ session: Session) -> Bool {
        switch self {
        case .active: !session.isArchived
        case .archived: session.isArchived
        case .all: true
        }
    }
}

struct SessionFilterBar: View {
    @Binding var selection: SessionFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedFilter: SessionFilter?
    @State private var hasReceivedFocus = false

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(SessionFilter.allCases, id: \.self) { filter in
                    let selected = selection == filter
                    Button { selection = filter } label: {
                        HStack(spacing: 7) {
                            Image(systemName: filter.symbol)
                                .font(.system(size: 14, weight: .semibold))
                            if selected {
                                Text(filter.label)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                    .transition(.opacity)
                            }
                        }
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(minWidth: 42, maxWidth: selected ? .infinity : 42, minHeight: 32)
                        .contentShape(.rect(cornerRadius: 10))
                        .glassEffect(
                            .regular.tint(selected ? Color.teal.opacity(0.35) : nil).interactive(),
                            in: .rect(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedFilter, equals: filter)
                    .help(Text(filter.label))
                    .accessibilityLabel(Text(filter.label))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .onChange(of: focusedFilter) { _, focused in
            guard focused != nil, !hasReceivedFocus else { return }
            hasReceivedFocus = true
            // The first button can receive focus automatically when the window opens.
            switch NSApp.currentEvent?.type {
            case .keyDown, .leftMouseDown, .leftMouseUp: break
            default: focusedFilter = nil
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session Filter")
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selection: SidebarItem? = .all
    @State private var selectedSessionID: String?
    @State private var search = ""
    @State private var filter: SessionFilter = .active
    @State private var pendingDelete: Session?

    var sidebarSessions: [Session] {
        store.sessions.filter(filter.includes)
    }

    func isShown(_ session: Session) -> Bool {
        guard filter.includes(session) else { return false }
        switch selection {
        case .tool(let tool): if session.tool != tool { return false }
        case .folder(let cwd): if session.cwd != cwd { return false }
        case .all, nil: break
        }
        return search.isEmpty || session.title.localizedCaseInsensitiveContains(search)
            || session.cwd.localizedCaseInsensitiveContains(search)
    }

    var selectedSession: Session? { session(selectedSessionID) }

    var hasSelectedFolder: Bool {
        guard case .folder(let cwd) = selection else { return true }
        return store.sessions.contains { $0.cwd == cwd }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                SessionFilterBar(selection: $filter)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                sessionList
                    .frame(maxHeight: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
            .navigationTitle(title)
        } detail: {
            if let session = selectedSession {
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
                if let session = selectedSession { ArchiveButton(session: session) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { pendingDelete = selectedSession } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete)
                    .disabled(!canDelete(selectedSession))
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
        .alert("Could not change the archive status", isPresented: Binding(get: { store.archiveError != nil }, set: { if !$0 { store.archiveError = nil } })) {
        } message: {
            Text(store.archiveError ?? "")
        }
        .frame(minWidth: 1000, minHeight: 520)
        .onChange(of: selectedSession?.id) { _, id in
            if id == nil { selectedSessionID = nil }
        }
        .onChange(of: hasSelectedFolder) { _, exists in
            if !exists { selection = .all }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
    }

    var sidebar: some View {
        let sessions = sidebarSessions
        var dirs = directories(sessions)
        if case .folder(let cwd) = selection, hasSelectedFolder, !dirs.contains(where: { $0.cwd == cwd }) {
            dirs.append((cwd: cwd, count: 0))
        }
        // Folder names that occur more than once get their parent folder alongside
        let names = Dictionary(grouping: dirs.map { folderName($0.cwd) }, by: { $0 }).filter { $0.value.count > 1 }
        return List(selection: $selection) {
            Section {
                Label("All Sessions", systemImage: "tray.full")
                    .badge(sessions.count)
                    .tag(SidebarItem.all)
                ForEach(Tool.allCases, id: \.self) { tool in
                    Label {
                        Text(tool.name)
                    } icon: {
                        ToolIcon(tool: tool, size: 18)
                    }
                    .badge(sessions.filter { $0.tool == tool }.count)
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
        let sessions = store.sessions.filter(isShown)
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
                    if s.canResume {
                        Button("Open in \(terminalName)") { openInTerminal(s) }
                        Divider()
                    }
                    CopyMenuItems(session: s)
                    Divider()
                    ArchiveButton(session: s)
                    if s.tool.canDelete {
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = s }
                            .keyboardShortcut(.delete, modifiers: [])
                            .disabled(!canDelete(s))
                    }
                }
            } primaryAction: { ids in
                if let s = session(ids.first), s.canResume { openInTerminal(s) }
            }
            .onDeleteCommand {
                if let session = selectedSession, canDelete(session) { pendingDelete = session }
            }
            .onCopyCommand {
                selectedSession.map { [NSItemProvider(object: $0.reference as NSString)] } ?? []
            }
        }
    }

    /// Inside a directory the directory is already known, so the row names the tool instead
    func subtitle(for s: Session) -> String {
        if case .folder = selection { return s.tool.name }
        return folderName(s.cwd)
    }

    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return store.sessions.first { $0.id == id && isShown($0) }
    }

    func canDelete(_ session: Session?) -> Bool {
        guard let session else { return false }
        return session.tool.canDelete && !store.changingSessions.contains(session.id)
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
