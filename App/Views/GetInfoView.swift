import SwiftUI
import TBMFileKit

/// Basic Get Info panel. Permissions are shown read-only for now (Phase 4's
/// interactive chmod UI is designed for the remote case in `ROADMAP.md`;
/// local read-only display is what's implemented today).
struct GetInfoView: View {
    let item: FileItem
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .font(.title)
                    .foregroundStyle(item.isDirectory ? .blue : .secondary)
                Text(item.name).font(.headline)
                Spacer()
            }
            Divider()
            row("Full Path", item.path.string)
            row("Kind", item.isDirectory ? "Folder" : (item.fileExtension.isEmpty ? "Document" : "\(item.fileExtension.uppercased()) File"))
            if let size = item.size, !item.isDirectory {
                row("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            row("Created", item.createdAt.map(formatted) ?? "—")
            row("Modified", item.modifiedAt.map(formatted) ?? "—")
            row("Permissions", item.permissionsString.isEmpty ? "—" : item.permissionsString)
            row("Owner", item.ownerName ?? "—")
            row("Group", item.groupName ?? "—")
            if item.isSymlink, let target = item.symlinkTarget {
                row("Symlink Target", target.string)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 340)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.system(size: 12))
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
