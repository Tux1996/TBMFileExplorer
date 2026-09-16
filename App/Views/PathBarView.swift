import SwiftUI
import TBMFileKit

/// Breadcrumb by default; click the field icon to switch to a directly-editable
/// path field (Enter navigates, Escape cancels), per the "editable address/path
/// field" + "breadcrumb navigation" requirements.
struct PathBarView: View {
    @Bindable var tab: TabViewModel
    var onNavigate: (FilePath) async -> Void

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("Path", text: $editText, onCommit: submit)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onExitCommand { isEditing = false }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(breadcrumbs, id: \.path.string) { crumb in
                            Button(crumb.name) {
                                Task { await onNavigate(crumb.path) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: crumb.path == tab.currentPath ? .semibold : .regular))
                            if crumb.path != breadcrumbs.last?.path {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            Button {
                editText = tab.currentPath.string
                isEditing.toggle()
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func submit() {
        let path = FilePath(editText)
        isEditing = false
        Task { await onNavigate(path) }
    }

    private var breadcrumbs: [(name: String, path: FilePath)] {
        var result: [(String, FilePath)] = [("/", FilePath("/"))]
        var accumulated = ""
        for component in tab.currentPath.string.split(separator: "/") {
            accumulated += "/\(component)"
            result.append((String(component), FilePath(accumulated)))
        }
        return result
    }
}
