import AppKit
import TBMFileKit

/// Thin wrappers around `NSWorkspace`/`Process` for the local-only actions the
/// context menu needs. Kept out of the view models so those stay UI-toolkit-free.
enum WorkspaceActions {
    static func open(_ path: FilePath) {
        NSWorkspace.shared.open(path.localURL)
    }

    static func revealInFinder(_ path: FilePath) {
        NSWorkspace.shared.activateFileViewerSelecting([path.localURL])
    }

    static func openWithMenuItems(for path: FilePath) -> [(name: String, url: URL)] {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: path.localURL)
        return apps.map { url in
            let name = FileManager.default.displayName(atPath: url.path)
            return (name, url)
        }
    }

    static func open(_ path: FilePath, with appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([path.localURL], withApplicationAt: appURL, configuration: configuration)
    }

    /// Opens Terminal.app at the given local directory. Argument is passed as
    /// a single `Process` argument, never interpolated into a shell string.
    static func openTerminal(at path: FilePath) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path.string]
        try? process.run()
    }

    static func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func sftpURL(username: String, host: String, port: Int, path: String) -> String {
        port == 22 ? "sftp://\(username)@\(host)\(path)" : "sftp://\(username)@\(host):\(port)\(path)"
    }

    /// Never includes a password — matches the "Copy SSH Command" requirement's
    /// explicit "do not include passwords in copied URLs" rule.
    static func sshCommand(username: String, host: String, port: Int) -> String {
        port == 22 ? "ssh \(username)@\(host)" : "ssh -p \(port) \(username)@\(host)"
    }

    /// Opens Terminal.app and starts an SSH session there, `cd`-ing to the
    /// given remote directory first. Builds the AppleScript payload from a
    /// fixed template with each value substituted via a dedicated quoting
    /// step — never raw string concatenation of the path into the script.
    static func openSSHSession(username: String, host: String, port: Int, remotePath: String) {
        let remoteShellCommand = "cd \(shellQuoted(remotePath)) 2>/dev/null; exec \\$SHELL -l"
        let sshInvocation = "ssh \(port == 22 ? "" : "-p \(port) ")\(shellQuoted("\(username)@\(host)")) -t \(shellQuoted(remoteShellCommand))"
        let script = "tell application \"Terminal\"\nactivate\ndo script \(appleScriptQuoted(sshInvocation))\nend tell"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
