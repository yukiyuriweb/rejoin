import AppKit

@MainActor
final class RejoinAppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
