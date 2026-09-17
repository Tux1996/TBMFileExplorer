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

    /// Native AppKit tables defer collapsing a multi-selection to just the
    /// clicked row until *mouse-up* specifically so a drag started on an
    /// already-selected row (mouse-down, then move before releasing) can
    /// still carry the whole selection. SwiftUI's `List(selection:)` binding
    /// appears to collapse it immediately on the click instead, before
    /// `.onDrag`'s closure ever runs — which broke multi-item drag (only the
    /// clicked row's path survived in `tab.selection` by the time we could
    /// read it) and made the drag preview flicker away (the list re-renders
    /// that row as the selection binding changes mid-drag). Tracking the
    /// selection just before it shrinks lets `.onDrag` recover what the user
    /// actually had selected.
    @State private var priorMultiSelection: Set<FilePath> = []

    var body: some View {
        VStack(spacing: 0) {
            FileListHeaderView(tab: tab)
            Divider()
            List(selection: $tab.selection) {
                ForEach(tab.displayedItems) { item in
                    FileRowView(item: item)
                        .tag(item.path)
                        .contentShape(Rectangle())
                        // `.simultaneousGesture` rather than `.onTapGesture`:
                        // an exclusive tap gesture on the same view as
                        // `.onDrag` makes AppKit wait out the double-click
                        // disambiguation window before it can commit to
                        // starting a drag instead — which is what made
                        // dragging feel like it needed a long press first.
                        // Recognizing the double-tap non-exclusively removes
                        // that wait.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(item) })
                        .onDrag {
                            // SwiftUI's per-row .onDrag only ever fires for
                            // the exact row the drag started on — it doesn't
                            // automatically bundle the rest of a multi-
                            // selection the way Finder does. If the dragged
                            // row is (or just was, see `priorMultiSelection`
                            // above) part of a larger selection, carry the
                            // whole selection in this one drag session instead
                            // of just the one row.
                            let effectiveSelection = tab.selection.count > 1 ? tab.selection : priorMultiSelection
                            let selected = tab.displayedItems.filter { effectiveSelection.contains($0.path) }
                            let items = (effectiveSelection.contains(item.path) && selected.count > 1) ? selected : [item]
                            return DragPayloadKind.makeItemProvider(items: items, providerIdentifier: tab.provider.identifier)
                        }
                        .onDrop(of: [.fileURL, DragPayloadKind.internalReferenceType], isTargeted: nil) { providers in
                            // A non-directory row can't itself be a drop
                            // target, but rejecting the drop entirely made it
                            // look like dropping anywhere in a populated list
                            // was broken — rows cover the whole list surface,
                            // leaving no empty background to catch the drop
                            // instead. Falling back to "current directory"
                            // here matches Finder's own list-view behavior
                            // (dropping between icons still drops into the
                            // folder they're in).
                            if item.isDirectory {
                                DragPayloadKind.resolve(providers) { payloads in onDropIntoFolder(item, payloads) }
                            } else {
                                DragPayloadKind.resolve(providers) { payloads in onDropIntoCurrentDirectory(payloads) }
                            }
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
            .onChange(of: tab.selection) { oldValue, _ in
                if oldValue.count > 1 {
                    priorMultiSelection = oldValue
                }
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
