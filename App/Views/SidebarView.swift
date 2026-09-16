import SwiftUI
import TBMFileKit

struct SidebarView: View {
    @Environment(AppViewModel.self) private var appModel
    @State private var editingProfile: ConnectionProfile?
    @State private var isAddingProfile = false
    @State private var errorMessage: String?

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
            Section {
                if appModel.connections.profiles.isEmpty {
                    Text("No servers yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(appModel.connections.profiles) { profile in
                    Label(profile.name, systemImage: profile.iconName)
                        .contentShape(Rectangle())
                        .onTapGesture { connect(to: profile) }
                        .contextMenu {
                            Button("Connect in Left Pane") { connect(to: profile, pane: appModel.leftPane) }
                            Button("Connect in Right Pane") { connect(to: profile, pane: appModel.rightPane) }
                            Divider()
                            Button("Edit…") { editingProfile = profile }
                            Button("Delete", role: .destructive) { delete(profile) }
                        }
                }
            } header: {
                HStack {
                    Text("Servers")
                    Spacer()
                    Button { isAddingProfile = true } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Transfers") {
                Text("No active transfers")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onAppear { appModel.refreshVolumes() }
        .sheet(isPresented: $isAddingProfile) {
            ConnectionEditorView(profile: nil) { profile, password in
                save(profile, password: password)
                isAddingProfile = false
            } onCancel: {
                isAddingProfile = false
            }
        }
        .sheet(item: $editingProfile) { profile in
            ConnectionEditorView(profile: profile) { updated, password in
                save(updated, password: password)
                editingProfile = nil
            } onCancel: {
                editingProfile = nil
            }
        }
        .alert("Couldn't Save Connection", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func navigate(to path: FilePath) {
        Task { await appModel.navigateFocusedPane(to: path) }
    }

    private func connect(to profile: ConnectionProfile, pane: PaneViewModel? = nil) {
        Task { await appModel.connect(to: profile, in: pane ?? appModel.focusedPane) }
    }

    private func save(_ profile: ConnectionProfile, password: String?) {
        do {
            try appModel.connections.save(profile, newPassword: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ profile: ConnectionProfile) {
        do {
            try appModel.connections.delete(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
