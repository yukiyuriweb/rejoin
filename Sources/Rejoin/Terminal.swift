import AppKit

let ghosttyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")

/// Ghostty when it is installed, otherwise Terminal
var terminalName: String { ghosttyURL == nil ? "Terminal" : "Ghostty" }

func appleScriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Opens a new terminal tab in the session's directory and types the resume command into its shell,
/// so the shell stays open after the agent exits
@MainActor
func openInTerminal(_ session: Session) {
    let script: String
    if ghosttyURL != nil {
        let cwd = session.cwd.isEmpty ? home.path : session.cwd
        script = """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration
                set initial working directory of cfg to \(appleScriptString(cwd))
                set initial input of cfg to \(appleScriptString(session.command)) & linefeed
                if (count of windows) > 0 then
                    new tab in front window with configuration cfg
                else
                    new window with configuration cfg
                end if
            end tell
            """
    } else {
        script = """
            tell application "Terminal"
                activate
                do script \(appleScriptString(session.commandWithCd))
            end tell
            """
    }
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
    if let error {
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not open \(terminalName)")
        alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? ""
        alert.runModal()
    }
}
