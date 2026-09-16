import SwiftUI

struct MainWindowView: View {
    @Environment(AppViewModel.self) private var appModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    PaneView(pane: appModel.leftPane)
                        .frame(minWidth: 320)
                    PaneView(pane: appModel.rightPane)
                        .frame(minWidth: 320)
                }
                Divider()
                StatusBarView()
            }
        }
        .onAppear {
            appModel.leftPane.isFocused = true
        }
        .onChange(of: appModel.focusedPaneID) {
            appModel.leftPane.isFocused = appModel.focusedPaneID == appModel.leftPane.id
            appModel.rightPane.isFocused = appModel.focusedPaneID == appModel.rightPane.id
        }
    }
}
