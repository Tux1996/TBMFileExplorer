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
                Task { await pane.openTab(at: tab.currentPath) }
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
            GetInfoView(item: item) { infoItem = nil }
        }
        .onKeyPress(.space) {
            if let selected = tab.displayedItems.first(where: { tab.selection.contains($0.path) }) {
                QuickLookCoordinator.shared.toggle(selected.path.localURL)
                return .handled
            }
            return .ignored
        }
    }

    private func open(_ item: FileItem, tab: TabViewModel) {
        if item.isDirectory {
            Task { await tab.navigate(to: item.path) }
        } else {
            WorkspaceActions.open(item.path)
        }
    }

    private func handleDrop(_ urls: [URL], into destination: FilePath, tab: TabViewModel) {
        Task {
            for url in urls {
                let target = destination.appending(url.lastPathComponent)
                guard FilePath(url.path) != target else { continue }
                do {
                    try await pane.provider.copy(from: FilePath(url.path), to: target)
                } catch {
                    tab.errorMessage = error.localizedDescription
                }
            }
            await tab.refresh()
        }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem, tab: TabViewModel) -> some View {
        Button("Open") { open(item, tab: tab) }
        Menu("Open With") {
            ForEach(WorkspaceActions.openWithMenuItems(for: item.path), id: \.url) { app in
                Button(app.name) { WorkspaceActions.open(item.path, with: app.url) }
            }
        }
        Divider()
        Button("Copy") { appModel.copy(selectedOrItem(item, tab: tab), from: pane.provider, cut: false) }
        Button("Cut") { appModel.copy(selectedOrItem(item, tab: tab), from: pane.provider, cut: true) }
        Button("Duplicate") { Task { await tab.duplicate(item) } }
        Button("Rename…") { renamingItem = item; renameText = item.name }
        Divider()
        Button("Move to Trash", role: .destructive) {
            Task { await tab.moveToTrash(selectedOrItem(item, tab: tab)) }
        }
        Divider()
        Button("Get Info") { infoItem = item }
        Button("Reveal in Finder") { WorkspaceActions.revealInFinder(item.path) }
        Menu("Copy Path") {
            Button("Copy Path") { WorkspaceActions.copyToPasteboard(item.path.string) }
            Button("Copy Name") { WorkspaceActions.copyToPasteboard(item.name) }
        }
        Button("Open Terminal Here") {
            WorkspaceActions.openTerminal(at: item.isDirectory ? item.path : item.path.parent)
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
        Button("Open Terminal Here") { WorkspaceActions.openTerminal(at: tab.currentPath) }
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
