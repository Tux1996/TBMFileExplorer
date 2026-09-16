import SwiftUI
import TBMFileKit

struct SidebarView: View {
    @Environment(AppViewModel.self) private var appModel
    @State private var editingProfile: ConnectionProfile?
    @State private var isAddingProfile = false
    @State private var errorMessage: String?
    @State private var isShowingTransfers = false

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
                if appModel.transferManager.jobs.isEmpty {
                    Text("No transfers yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Label("\(activeTransferCount) Active", systemImage: "arrow.down.circle")
                        .contentShape(Rectangle())
                        .onTapGesture { isShowingTransfers = true }
                    Label("\(completedTransferCount) Completed", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { isShowingTransfers = true }
                    if failedTransferCount > 0 {
                        Label("\(failedTransferCount) Failed", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .contentShape(Rectangle())
                            .onTapGesture { isShowingTransfers = true }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { appModel.refreshVolumes() }
        .sheet(isPresented: $isShowingTransfers) {
            TransfersView()
        }
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

    private var activeTransferCount: Int {
        appModel.transferManager.jobs.filter { $0.status == .running || $0.status == .queued || $0.status == .paused }.count
    }

    private var completedTransferCount: Int {
        appModel.transferManager.jobs.filter { $0.status == .completed }.count
    }

    private var failedTransferCount: Int {
        appModel.transferManager.jobs.filter { if case .failed = $0.status { true } else { false } }.count
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
