import ServiceManagement
import SwiftUI

struct UsageMenu: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var openAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage Limits")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if store.isRefreshingUsage {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing Usage")
                }
                Button {
                    store.reloadUsage()
                } label: {
                    Label("Refresh Usage", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .disabled(store.isRefreshingUsage)
                .help("Refresh Usage")
            }

            TimelineView(.periodic(from: .now, by: 15)) { context in
                GlassEffectContainer(spacing: 0) {
                    VStack(spacing: 10) {
                        UsageCard(tool: .codex, snapshot: store.codexUsage, now: context.date)
                        UsageCard(tool: .claude, snapshot: store.claudeUsage, now: context.date)
                    }
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(WindowVisibility { visible in
            guard visible else { return }
            store.reloadUsage()
            openAtLogin = Self.isOpenAtLogin
        })
    }

    private var footer: some View {
        HStack {
            Button {
                NSApp.activate()
                openWindow(id: "main")
            } label: {
                Label("Open Rejoin", systemImage: "macwindow")
            }
            Spacer()
            Menu {
                Button("Refresh") { store.refresh() }
                Toggle("Open at Login", isOn: Binding(
                    get: { openAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSApp.activate()
                            NSAlert(error: error).runModal()
                        }
                        openAtLogin = Self.isOpenAtLogin
                    }))
                Divider()
                Button("Quit Rejoin") { NSApp.terminate(nil) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.glass)
    }

    /// Waiting for approval in System Settings counts as on, so the toggle turns it off
    private static var isOpenAtLogin: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }
}

/// Reports whether the window holding it is on screen, from the window's occlusion state. The menu bar
/// panel is hidden rather than closed, so this is how it learns that it has been opened again.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Tracker { Tracker(onChange: onChange) }
    func updateNSView(_ view: Tracker, context: Context) { view.onChange = onChange }

    final class Tracker: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return report() }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        /// Deferred, since this view joins its window in the middle of a SwiftUI update, when changing state
        /// isn't allowed
        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onChange(window?.occlusionState.contains(.visible) == true)
            }
        }
    }
}

private struct UsageCard: View {
    let tool: Tool
    let snapshot: UsageSnapshot?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolIcon(tool: tool, size: 24)
                    .accessibilityHidden(true)
                Text(tool == .claude ? "Claude Code" : tool.name)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if tool == .claude, let executable = Bundle.main.executableURL {
                    if let receivedAt = snapshot?.receivedAt {
                        Text("Received \(shortTime(receivedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(Text("Received \(receivedAt.formatted(date: .abbreviated, time: .standard))"))
                    }
                    Menu {
                        Button("Copy Claude Code Usage Command") {
                            copy("\(shellQuote(executable.path)) --record-claude-usage")
                        }
                        Button("Copy Claude Code Usage Pipe") {
                            copy("\(shellQuote(executable.path)) --record-claude-usage --passthrough | ")
                        }
                    } label: {
                        Label("Claude Code Setup", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Claude Code Setup")
                }
            }

            quota("5h", label: "5h left", snapshot?.fiveHour)
            quota("wk", label: "Weekly left", snapshot?.weekly)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func quota(_ period: String, label: LocalizedStringKey, _ usage: UsageWindow?) -> some View {
        let current = usage.flatMap { $0.isCurrent(at: now) ? $0 : nil }
        let remaining = current.map { $0.remainingPercent / 100 }
        let percent = remaining.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "—"

        return VStack(spacing: 5) {
            HStack {
                Text(verbatim: "\(percent) / \(period)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .accessibilityLabel(Text(label))
                    .accessibilityValue(Text(verbatim: percent))
                Spacer()
                if let reset = current?.resetsAt {
                    let time = shortTime(reset)
                    Label(time, systemImage: "arrow.clockwise")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Resets \(time)"))
                        .help(Text("Resets \(reset.formatted(date: .abbreviated, time: .standard))"))
                }
            }

            GeometryReader { geometry in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        if let remaining {
                            Capsule()
                                .fill(tool.color)
                                .frame(width: geometry.size.width * remaining)
                        }
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
    }

    private func shortTime(_ date: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
    }
}
