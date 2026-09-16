import SwiftUI
import TBMFileKit
import UniformTypeIdentifiers

private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

struct FileListHeaderView: View {
    @Bindable var tab: TabViewModel

    var body: some View {
        HStack(spacing: 0) {
            headerButton("Name", field: .name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton("Size", field: .size).frame(width: 90, alignment: .trailing)
            headerButton("Modified", field: .modified).frame(width: 150, alignment: .leading)
            headerButton("Kind", field: .kind).frame(width: 70, alignment: .leading)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    private func headerButton(_ title: String, field: SortField) -> some View {
        Button {
            if tab.sortField == field {
                tab.sortAscending.toggle()
            } else {
                tab.sortField = field
                tab.sortAscending = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if tab.sortField == field {
                    Image(systemName: tab.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct FileListView: View {
    @Bindable var tab: TabViewModel
    var onOpen: (FileItem) -> Void
    var onDropIntoFolder: (FileItem, [DragPayloadItem]) -> Void
    var onDropIntoCurrentDirectory: ([DragPayloadItem]) -> Void
    var contextMenu: (FileItem) -> AnyView
    var backgroundContextMenu: () -> AnyView

    var body: some View {
        VStack(spacing: 0) {
            FileListHeaderView(tab: tab)
            Divider()
            List(selection: $tab.selection) {
                ForEach(tab.displayedItems) { item in
                    FileRowView(item: item)
                        .tag(item.path)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onOpen(item) }
                        .onDrag {
                            DragPayloadKind.makeItemProvider(item: item, providerIdentifier: tab.provider.identifier)
                        }
                        .onDrop(of: [.fileURL, DragPayloadKind.internalReferenceType], isTargeted: nil) { providers in
                            guard item.isDirectory else { return false }
                            DragPayloadKind.resolve(providers) { payloads in onDropIntoFolder(item, payloads) }
                            return true
                        }
                        .contextMenu { contextMenu(item) }
                }
            }
            .listStyle(.plain)
            .contextMenu { backgroundContextMenu() }
            .onDrop(of: [.fileURL, DragPayloadKind.internalReferenceType], isTargeted: nil) { providers in
                DragPayloadKind.resolve(providers) { payloads in onDropIntoCurrentDirectory(payloads) }
                return true
            }
        }
    }
}

// `.onDrag`/`.onDrop` (NSItemProvider-based) instead of the newer
// `.draggable`/`.dropDestination` (Transferable-based) pair — the newer API
// reliably failed to deliver drops here when nested at both the row and List
// level inside a macOS `List`/`NSTableView` (drag would start, show the
// accept cursor, and the drop would silently no-op on release). This older
// pairing is far more battle-tested for exactly this case. See
// `DragPayloadKind` for how a remote row's drag carries its true source
// provider instead of a bogus local file URL.

struct FileRowView: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(item.isDirectory ? .blue : .secondary)
                    .frame(width: 16)
                Text(item.name)
                    .lineLimit(1)
                    .foregroundStyle(item.isHidden ? .secondary : .primary)
                if item.isSymlink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(sizeText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            Text(item.modifiedAt.map { dateFormatter.string(from: $0) } ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            Text(item.isDirectory ? "Folder" : (item.fileExtension.isEmpty ? "File" : item.fileExtension.uppercased()))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 2)
    }

    private var sizeText: String {
        guard !item.isDirectory, let size = item.size else { return "—" }
        return byteFormatter.string(fromByteCount: size)
    }

    private var iconName: String {
        if item.isSymlink { return "link" }
        if item.isDirectory { return "folder.fill" }
        switch item.fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic": return "photo"
        case "mp4", "mov", "mkv": return "film"
        case "mp3", "wav", "flac": return "music.note"
        case "zip", "tar", "gz": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log": return "doc.text"
        case "json", "yml", "yaml", "xml": return "curlybraces"
        case "sh": return "terminal"
        default: return "doc"
        }
    }
}
