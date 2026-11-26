import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class RejoinAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var openMainWindow: (() -> Void)?

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let statusMenu = NSMenu()
    private let loginItem = NSMenuItem(
        title: String(localized: "Open at Login"), action: #selector(toggleOpenAtLogin), keyEquivalent: ""
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let title = String(localized: "Rejoin Usage")
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: title)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = title
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        statusMenu.delegate = self
        statusMenu.addItem(withTitle: String(localized: "Open Rejoin"), action: #selector(showMainWindow), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: String(localized: "Refresh"), action: #selector(refresh), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        loginItem.target = self
        statusMenu.addItem(loginItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: String(localized: "Quit Rejoin"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: UsageMenu(openMainWindow: { [weak self] in
            self?.showMainWindow()
        }).environmentObject(store))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.close()
            // AppKit tracks the menu for this click and restores the button action when it closes.
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown {
            popover.close()
        } else {
            store.reloadUsage()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    @objc private func showMainWindow() {
        popover.close()
        NSApp.activate()
        openMainWindow?()
    }

    @objc private func refresh() {
        store.refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        default: loginItem.state = .off
        }
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled, .requiresApproval: try service.unregister()
            default: try service.register()
            }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }
}
