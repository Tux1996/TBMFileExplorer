import SwiftUI

@main
struct TBMFileExplorerApp: App {
    @State private var appModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appModel)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    Task { await appModel.focusedPane.openTab(at: appModel.focusedPane.activeTab.currentPath) }
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}
