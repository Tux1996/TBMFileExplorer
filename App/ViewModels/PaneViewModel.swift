import Foundation
import Observation
import TBMFileKit

/// One side of the dual-pane window. Owns a set of tabs (each an independent
/// `TabViewModel`), and tracks which one is active. A pane has no fixed
/// provider of its own — each tab carries its own (`TabViewModel.provider`),
/// so one pane can hold a mix of local and server tabs side by side, and
/// "Connect to Server" just opens a new tab pointed at an `SFTPFileProvider`.
@Observable
final class PaneViewModel: Identifiable {
    let id = UUID()
    private(set) var tabs: [TabViewModel]
    var activeTabID: UUID
    var isFocused = false

    var activeTab: TabViewModel {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    init(provider: any FileProvider, startPath: FilePath) {
        let firstTab = TabViewModel(provider: provider, path: startPath)
        self.tabs = [firstTab]
        self.activeTabID = firstTab.id
    }

    @MainActor
    func openTab(provider: any FileProvider, at path: FilePath, makeActive: Bool = true) async {
        let tab = TabViewModel(provider: provider, path: path)
        tabs.append(tab)
        if makeActive { activeTabID = tab.id }
        await tab.load()
    }

    func closeTab(_ tab: TabViewModel) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if activeTabID == tab.id {
            activeTabID = tabs[max(0, index - 1)].id
        }
    }

    @MainActor
    func navigateActiveTab(to path: FilePath) async {
        await activeTab.navigate(to: path)
    }
}
