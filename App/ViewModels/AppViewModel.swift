import Foundation
import Observation
import TBMFileKit

/// Top-level state for the main window: the two panes, which one is focused
/// (sidebar clicks and pastes target the focused pane), sidebar contents, and
/// the shared copy/cut clipboard.
@Observable
@MainActor
final class AppViewModel {
    let localProvider = LocalFileProvider()
    let leftPane: PaneViewModel
    let rightPane: PaneViewModel
    var focusedPaneID: UUID

    var favorites: [FavoriteLocation] = FavoriteLocation.standardFavorites()
    var volumes: [MountedVolume] = MountedVolume.currentVolumes()

    let connections = ConnectionsViewModel()
    let hostKeyConfirmation = HostKeyConfirmationCenter()
    let transferManager = TransferManager()
    let transferCollisionCenter = TransferCollisionCenter()

    var clipboard: FileClipboard?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let provider = localProvider
        leftPane = PaneViewModel(provider: provider, startPath: FilePath(home))
        rightPane = PaneViewModel(provider: provider, startPath: FilePath(home))
        focusedPaneID = leftPane.id
    }

    var focusedPane: PaneViewModel {
        focusedPaneID == leftPane.id ? leftPane : rightPane
    }

    /// Finds a live provider matching a drag payload's `stableKey` among
    /// currently open tabs — a drag session only carries that key (not a
    /// serialized provider), so the drop side has to look the real instance
    /// back up. Any tab connected to the same server works equally well; they
    /// share credentials and host, just not the same live SSH session object.
    func liveProvider(forKey key: String) -> (any FileProvider)? {
        if key == FileProviderIdentifier.local.stableKey { return localProvider }
        for pane in [leftPane, rightPane] {
            if let match = pane.tabs.first(where: { $0.provider.identifier.stableKey == key }) {
                return match.provider
            }
        }
        return nil
    }

    @MainActor
    func refreshVolumes() {
        volumes = MountedVolume.currentVolumes()
    }

    @MainActor
    func navigateFocusedPane(to path: FilePath) async {
        await focusedPane.navigateActiveTab(to: path)
    }

    /// Opens a new tab in the given pane connected to `profile`. Connecting
    /// itself is lazy (the first `list()` call triggers it — see
    /// `SFTPFileProvider.ensureConnected`), so this returns immediately and
    /// any connection/auth/host-key error surfaces as the new tab's error banner.
    @MainActor
    func connect(to profile: ConnectionProfile, in pane: PaneViewModel) async {
        let provider = SFTPFileProvider(profile: profile, hostKeyConfirmer: hostKeyConfirmation)
        await pane.openTab(provider: provider, at: FilePath(profile.defaultRemotePath))
    }

    func copy(_ items: [FileItem], from provider: any FileProvider, cut: Bool) {
        clipboard = FileClipboard(items: items, sourceProvider: provider, isCut: cut)
    }

    @MainActor
    func paste(into tab: TabViewModel) async {
        guard let clipboard else { return }

        if clipboard.sourceProvider.identifier == tab.provider.identifier {
            for item in clipboard.items {
                let destination = tab.currentPath.appending(item.name)
                do {
                    if clipboard.isCut {
                        try await clipboard.sourceProvider.move(from: item.path, to: destination)
                    } else {
                        try await clipboard.sourceProvider.copy(from: item.path, to: destination)
                    }
                } catch {
                    tab.errorMessage = error.localizedDescription
                }
            }
            if clipboard.isCut { self.clipboard = nil }
            await tab.refresh()
            return
        }

        // Cross-provider: hand off to the Transfer Manager. Folders aren't
        // supported by the streaming transfer path yet (see ROADMAP.md) — skip
        // them with a clear message rather than silently dropping them.
        let files = clipboard.items.filter { !$0.isDirectory }
        if files.count != clipboard.items.count {
            tab.errorMessage = "Skipped \(clipboard.items.count - files.count) folder(s) — folder transfers between different locations aren't supported yet."
        }
        guard !files.isEmpty else { return }

        let requests = files.map { TransferRequest(sourcePath: $0.path, name: $0.name) }
        await transferManager.enqueueBatch(
            requests,
            source: clipboard.sourceProvider,
            sourceDisplayName: clipboard.sourceProvider.displayName,
            destination: tab.provider,
            destinationDisplayName: tab.provider.displayName,
            destinationDirectory: tab.currentPath,
            collisionResolver: transferCollisionCenter,
            deleteSourceAfterSuccess: clipboard.isCut
        )
        if clipboard.isCut { self.clipboard = nil }
    }
}
