import SwiftUI

struct PaneToolbarView: View {
    @Bindable var tab: TabViewModel
    var onBack: () -> Void
    var onForward: () -> Void
    var onUp: () -> Void
    var onRefresh: () -> Void
    var onNewFolder: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
            Button(action: onForward) { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
            Button(action: onUp) { Image(systemName: "arrow.up") }
                .disabled(!tab.canGoUp)
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }

            Divider().frame(height: 14)

            Button(action: onNewFolder) { Image(systemName: "folder.badge.plus") }
                .help("New Folder")

            Toggle(isOn: $tab.showHidden) {
                Image(systemName: tab.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help("Show Hidden Files")
            .onChange(of: tab.showHidden) {
                Task { await tab.refresh() }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $tab.searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 120)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            if tab.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
