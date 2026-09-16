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
}
