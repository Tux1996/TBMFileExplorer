import Foundation
import Observation
import TBMFileKit

/// Top-level state for the main window: the two panes, which one is focused
/// (sidebar clicks and pastes target the focused pane), sidebar contents, and
/// the shared copy/cut clipboard.
@Observable
final class AppViewModel {
    let localProvider = LocalFileProvider()
    let leftPane: PaneViewModel
    let rightPane: PaneViewModel
    var focusedPaneID: UUID

    var favorites: [FavoriteLocation] = FavoriteLocation.standardFavorites()
    var volumes: [MountedVolume] = MountedVolume.currentVolumes()

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

    @MainActor
    func refreshVolumes() {
        volumes = MountedVolume.currentVolumes()
    }

    @MainActor
    func navigateFocusedPane(to path: FilePath) async {
        await focusedPane.navigateActiveTab(to: path)
    }

    func copy(_ items: [FileItem], from provider: any FileProvider, cut: Bool) {
        clipboard = FileClipboard(items: items, sourceProvider: provider, isCut: cut)
    }

    @MainActor
    func paste(into tab: TabViewModel) async {
        guard let clipboard else { return }
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
    }
}
