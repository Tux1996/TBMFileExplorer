import Foundation
import Observation
import TBMFileKit

enum SortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case modified = "Modified"
    case kind = "Kind"
    var id: String { rawValue }
}

enum ConflictResolution {
    case replace, skip, keepBoth, cancel
}

/// The browsing state for a single tab: current path, navigation history,
/// listing, selection, sort/filter options. One `FileBrowserPaneView` shows
/// exactly one `TabViewModel` at a time (the active tab of its `PaneViewModel`).
@Observable
final class TabViewModel: Identifiable {
    let id = UUID()
    let provider: any FileProvider

    private(set) var currentPath: FilePath
    private(set) var items: [FileItem] = []
    var selection: Set<FilePath> = []
    var isLoading = false
    var errorMessage: String?

    var sortField: SortField = .name
    var sortAscending = true
    var foldersFirst = true
    var showHidden = false
    var searchText = ""

    private var backStack: [FilePath] = []
    private var forwardStack: [FilePath] = []

    var title: String { currentPath.isRoot ? provider.displayName : currentPath.lastComponent }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !currentPath.isRoot }

    init(provider: any FileProvider, path: FilePath) {
        self.provider = provider
        self.currentPath = path
    }

    var displayedItems: [FileItem] {
        var result = items
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        result.sort { lhs, rhs in
            if foldersFirst && lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let ascending = sortAscending
            switch sortField {
            case .name:
                let cmp = lhs.name.localizedStandardCompare(rhs.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            case .size:
                let l = lhs.size ?? -1, r = rhs.size ?? -1
                return ascending ? l < r : l > r
            case .modified:
                let l = lhs.modifiedAt ?? .distantPast, r = rhs.modifiedAt ?? .distantPast
                return ascending ? l < r : l > r
            case .kind:
                let cmp = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
        return result
    }

    @MainActor
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await provider.list(currentPath, includeHidden: showHidden)
        } catch {
            errorMessage = error.localizedDescription
            items = []
        }
        isLoading = false
    }

    @MainActor
    func navigate(to path: FilePath, recordHistory: Bool = true) async {
        guard path != currentPath else { return }
        if recordHistory {
            backStack.append(currentPath)
            forwardStack.removeAll()
        }
        currentPath = path
        selection.removeAll()
        await load()
    }

    @MainActor
    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        currentPath = previous
        selection.removeAll()
        await load()
    }

    @MainActor
    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        currentPath = next
        selection.removeAll()
        await load()
    }

    @MainActor
    func goUp() async {
        await navigate(to: currentPath.parent)
    }

    @MainActor
    func refresh() async {
        await load()
    }

    @MainActor
    func createFolder(named name: String) async {
        do {
            try await provider.createDirectory(currentPath.appending(name))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func rename(_ item: FileItem, to newName: String) async {
        do {
            _ = try await provider.rename(item.path, to: newName)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func moveToTrash(_ items: [FileItem]) async {
        for item in items {
            do {
                try await provider.moveToTrash(item.path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await refresh()
    }

    /// Permanent delete — used directly (skipping Trash) on providers like
    /// SFTP that have no Trash concept (`capabilities.canTrash == false`).
    @MainActor
    func deletePermanently(_ items: [FileItem]) async {
        for item in items {
            do {
                try await provider.delete(item.path, recursive: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await refresh()
    }

    @MainActor
    func duplicate(_ item: FileItem) async {
        let base = item.path.parent
        var candidate = base.appending(duplicateName(for: item.name, attempt: 1))
        var attempt = 1
        while (try? await provider.stat(candidate)) != nil {
            attempt += 1
            candidate = base.appending(duplicateName(for: item.name, attempt: attempt))
        }
        do {
            try await provider.copy(from: item.path, to: candidate)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicateName(for name: String, attempt: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let suffix = attempt == 1 ? "copy" : "copy \(attempt)"
        return ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
    }
}
