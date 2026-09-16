import SwiftUI
import TBMFileKit

struct PaneView: View {
    @Bindable var pane: PaneViewModel
    @Environment(AppViewModel.self) private var appModel

    @State private var showingNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var renamingItem: FileItem?
    @State private var renameText = ""
    @State private var infoItem: FileItem?

    var body: some View {
        let tab = pane.activeTab
        VStack(spacing: 0) {
            TabBarView(pane: pane) {
                Task { await pane.openTab(provider: tab.provider, at: tab.currentPath) }
            }
            Divider()
            PaneToolbarView(
                tab: tab,
                onBack: { Task { await tab.goBack() } },
                onForward: { Task { await tab.goForward() } },
                onUp: { Task { await tab.goUp() } },
                onRefresh: { Task { await tab.refresh() } },
                onNewFolder: { newFolderName = "untitled folder"; showingNewFolderPrompt = true }
            )
            Divider()
            PathBarView(tab: tab) { path in
                await tab.navigate(to: path)
            }
            Divider()

            if let errorMessage = tab.errorMessage {
                ErrorBanner(message: errorMessage) { tab.errorMessage = nil }
            }

            FileListView(
                tab: tab,
                onOpen: { item in open(item, tab: tab) },
                onDropIntoFolder: { folder, urls in handleDrop(urls, into: folder.path, tab: tab) },
                onDropIntoCurrentDirectory: { urls in handleDrop(urls, into: tab.currentPath, tab: tab) },
                contextMenu: { item in AnyView(contextMenu(for: item, tab: tab)) },
                backgroundContextMenu: { AnyView(backgroundContextMenu(tab: tab)) }
            )
        }
        .background(pane.isFocused ? Color.accentColor.opacity(0.04) : Color.clear)
        .onTapGesture { appModel.focusedPaneID = pane.id }
        .task(id: tab.id) { await tab.load() }
        .alert("New Folder", isPresented: $showingNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await tab.createFolder(named: newFolderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $renamingItem) { item in
            RenameSheet(originalName: item.name, text: $renameText) {
                renamingItem = nil
                Task { await tab.rename(item, to: renameText) }
            } onCancel: {
                renamingItem = nil
            }
        }
        .sheet(item: $infoItem) { item in
            GetInfoView(
                item: item,
                canEditPermissions: tab.provider.capabilities.canSetPermissions
            ) { mode in
                Task { await applyPermissions(item, mode: mode, tab: tab) }
            } onDismiss: {
                infoItem = nil
            }
        }
        .onKeyPress(.space) {
            guard tab.provider.identifier == .local,
                  let selected = tab.displayedItems.first(where: { tab.selection.contains($0.path) }) else {
                return .ignored
            }
            QuickLookCoordinator.shared.toggle(selected.path.localURL)
            return .handled
        }
    }

    private func open(_ item: FileItem, tab: TabViewModel) {
        if item.isDirectory {
            Task { await tab.navigate(to: item.path) }
        } else if tab.provider.identifier == .local {
            WorkspaceActions.open(item.path)
        } else {
            tab.errorMessage = "Opening remote files isn't supported yet — download-and-edit is coming in Phase 7."
        }
    }

    private func applyPermissions(_ item: FileItem, mode: UInt16, tab: TabViewModel) async {
        do {
            try await tab.provider.setPermissions(item.path, mode: mode)
            let updated = try await tab.provider.stat(item.path)
            infoItem = updated
        } catch {
            tab.errorMessage = error.localizedDescription
        }
        await tab.refresh()
    }

    private func handleDrop(_ payloads: [DragPayloadItem], into destination: FilePath, tab: TabViewModel) {
        Task {
            var sameProviderSources: [FilePath] = []
            var crossProvider: (provider: any FileProvider, displayName: String)?
            var crossProviderRequests: [TransferRequest] = []

            for payload in payloads {
                let sourcePath: FilePath
                let sourceProviderKey: String
                let resolvedProvider: any FileProvider
                let resolvedDisplayName: String

                switch payload {
                case .local(let url):
                    sourcePath = FilePath(url.path)
                    sourceProviderKey = FileProviderIdentifier.local.stableKey
                    resolvedProvider = appModel.localProvider
                    resolvedDisplayName = appModel.localProvider.displayName
                case .remote(let providerKey, let path):
                    sourcePath = FilePath(path)
                    sourceProviderKey = providerKey
                    guard let found = appModel.liveProvider(forKey: providerKey) else {
                        tab.errorMessage = "That file's connection is no longer open."
                        continue
                    }
                    resolvedProvider = found
                    resolvedDisplayName = found.displayName
                }

                if sourceProviderKey == tab.provider.identifier.stableKey {
                    sameProviderSources.append(sourcePath)
                } else {
                    crossProvider = (resolvedProvider, resolvedDisplayName)
                    crossProviderRequests.append(TransferRequest(sourcePath: sourcePath, name: sourcePath.lastComponent))
                }
            }

            for sourcePath in sameProviderSources {
                let target = destination.appending(sourcePath.lastComponent)
                guard sourcePath != target else { continue }
                do {
                    try await tab.provider.copy(from: sourcePath, to: target)
                } catch {
                    tab.errorMessage = error.localizedDescription
                }
            }
            if !sameProviderSources.isEmpty {
                await tab.refresh()
            }

            if let crossProvider, !crossProviderRequests.isEmpty {
                await appModel.transferManager.enqueueBatch(
                    crossProviderRequests,
                    source: crossProvider.provider,
                    sourceDisplayName: crossProvider.displayName,
                    destination: tab.provider,
                    destinationDisplayName: tab.provider.displayName,
                    destinationDirectory: destination,
                    collisionResolver: appModel.transferCollisionCenter
                )
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem, tab: TabViewModel) -> some View {
        let isLocal = tab.provider.identifier == .local
        if isLocal {
            Button("Open") { open(item, tab: tab) }
            Menu("Open With") {
                ForEach(WorkspaceActions.openWithMenuItems(for: item.path), id: \.url) { app in
                    Button(app.name) { WorkspaceActions.open(item.path, with: app.url) }
                }
            }
            Divider()
        } else if item.isDirectory {
            Button("Open") { open(item, tab: tab) }
            Divider()
        }
        Button("Copy") { appModel.copy(selectedOrItem(item, tab: tab), from: tab.provider, cut: false) }
        Button("Cut") { appModel.copy(selectedOrItem(item, tab: tab), from: tab.provider, cut: true) }
        Button("Duplicate") { Task { await tab.duplicate(item) } }
        Button("Rename…") { renamingItem = item; renameText = item.name }
        Divider()
        if tab.provider.capabilities.canTrash {
            Button("Move to Trash", role: .destructive) {
                Task { await tab.moveToTrash(selectedOrItem(item, tab: tab)) }
            }
        } else {
            Button("Delete", role: .destructive) {
                Task { await tab.deletePermanently(selectedOrItem(item, tab: tab)) }
            }
        }
        Divider()
        Button("Get Info") { infoItem = item }
        if isLocal {
            Button("Reveal in Finder") { WorkspaceActions.revealInFinder(item.path) }
        }
        Menu("Copy Path") {
            Button("Copy Path") { WorkspaceActions.copyToPasteboard(item.path.string) }
            Button("Copy Name") { WorkspaceActions.copyToPasteboard(item.name) }
            if let profile = connectionProfile(for: tab) {
                Button("Copy SFTP URL") {
                    WorkspaceActions.copyToPasteboard(WorkspaceActions.sftpURL(username: profile.username, host: profile.host, port: profile.port, path: item.path.string))
                }
                Button("Copy SSH Command") {
                    WorkspaceActions.copyToPasteboard(WorkspaceActions.sshCommand(username: profile.username, host: profile.host, port: profile.port))
                }
            }
        }
        if isLocal {
            Button("Open Terminal Here") {
                WorkspaceActions.openTerminal(at: item.isDirectory ? item.path : item.path.parent)
            }
        } else if let profile = connectionProfile(for: tab) {
            Button("Open SSH Session") {
                WorkspaceActions.openSSHSession(username: profile.username, host: profile.host, port: profile.port, remotePath: (item.isDirectory ? item.path : item.path.parent).string)
            }
        }
    }

    @ViewBuilder
    private func backgroundContextMenu(tab: TabViewModel) -> some View {
        Button("New Folder") { newFolderName = "untitled folder"; showingNewFolderPrompt = true }
        if appModel.clipboard != nil {
            Button("Paste") { Task { await appModel.paste(into: tab) } }
        }
        Divider()
        Button("Refresh") { Task { await tab.refresh() } }
        if tab.provider.identifier == .local {
            Button("Open Terminal Here") { WorkspaceActions.openTerminal(at: tab.currentPath) }
        } else if let profile = connectionProfile(for: tab) {
            Button("Open SSH Session") {
                WorkspaceActions.openSSHSession(username: profile.username, host: profile.host, port: profile.port, remotePath: tab.currentPath.string)
            }
        }
    }

    private func connectionProfile(for tab: TabViewModel) -> ConnectionProfile? {
        guard case .sftp(let connectionID) = tab.provider.identifier else { return nil }
        return appModel.connections.profiles.first { $0.id == connectionID }
    }

    private func selectedOrItem(_ item: FileItem, tab: TabViewModel) -> [FileItem] {
        if tab.selection.contains(item.path), tab.selection.count > 1 {
            return tab.displayedItems.filter { tab.selection.contains($0.path) }
        }
        return [item]
    }
}

private struct RenameSheet: View {
    let originalName: String
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \"\(originalName)\"").font(.headline)
            TextField("New name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommit)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Rename", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct ErrorBanner: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }
}
