import Foundation
import Observation
import TBMFileKit

/// One side of the dual-pane window. Owns a set of tabs (each an independent
/// `TabViewModel`) and tracks which one is active. Local-only for now — a pane
/// will gain the ability to point its tabs at a remote `FileProvider` once
/// connections exist (Phase 4), with no change to this type's shape.
@Observable
final class PaneViewModel: Identifiable {
    let id = UUID()
    let provider: any FileProvider
    private(set) var tabs: [TabViewModel]
    var activeTabID: UUID
    var isFocused = false

    var activeTab: TabViewModel {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    init(provider: any FileProvider, startPath: FilePath) {
        self.provider = provider
        let firstTab = TabViewModel(provider: provider, path: startPath)
        self.tabs = [firstTab]
        self.activeTabID = firstTab.id
    }

    @MainActor
    func openTab(at path: FilePath, makeActive: Bool = true) async {
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
