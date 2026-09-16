import SwiftUI
import TBMFileKit

struct SidebarView: View {
    @Environment(AppViewModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        List {
            Section("Favorites") {
                ForEach(appModel.favorites) { favorite in
                    Label(favorite.name, systemImage: favorite.systemImage)
                        .contentShape(Rectangle())
                        .onTapGesture { navigate(to: favorite.path) }
                }
            }
            Section("Locations") {
                ForEach(appModel.volumes) { volume in
                    Label(volume.name, systemImage: volume.isRemovable ? "externaldrive" : "internaldrive")
                        .contentShape(Rectangle())
                        .onTapGesture { navigate(to: volume.path) }
                }
            }
            Section("Servers") {
                Text("No servers yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Transfers") {
                Text("No active transfers")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onAppear { appModel.refreshVolumes() }
    }

    private func navigate(to path: FilePath) {
        Task { await appModel.navigateFocusedPane(to: path) }
    }
}
