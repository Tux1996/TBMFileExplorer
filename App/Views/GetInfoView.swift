import SwiftUI
import TBMFileKit

/// Get Info panel. Permissions are editable (a numeric/octal field, e.g.
/// "644") whenever the owning provider's `capabilities.canSetPermissions` is
/// true — both `LocalFileProvider` and `SFTPFileProvider` support it today.
/// A checkbox-per-bit interface is still Planned (see `ROADMAP.md`); the
/// numeric field is what the original spec calls the minimum viable version.
struct GetInfoView: View {
    let item: FileItem
    let canEditPermissions: Bool
    var onApplyPermissions: (UInt16) -> Void
    var onDismiss: () -> Void

    @State private var permissionsText: String
    @State private var applyError: String?

    init(item: FileItem, canEditPermissions: Bool, onApplyPermissions: @escaping (UInt16) -> Void, onDismiss: @escaping () -> Void) {
        self.item = item
        self.canEditPermissions = canEditPermissions
        self.onApplyPermissions = onApplyPermissions
        self.onDismiss = onDismiss
        self._permissionsText = State(initialValue: item.posixPermissions.map { String($0, radix: 8) } ?? "")
    }

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
            permissionsRow
            if let applyError {
                Text(applyError).font(.caption).foregroundStyle(.red).padding(.leading, 114)
            }
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
        .frame(width: 380, height: 380)
    }

    private var permissionsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Permissions").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            if canEditPermissions {
                TextField("e.g. 644", text: $permissionsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit(apply)
                Text(item.permissionsString.isEmpty ? "" : item.permissionsString)
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12, design: .monospaced))
                Button("Apply", action: apply)
                    .disabled(UInt16(permissionsText, radix: 8) == nil)
            } else {
                Text(item.permissionsString.isEmpty ? "—" : item.permissionsString)
            }
            Spacer()
        }
        .font(.system(size: 12))
    }

    private func apply() {
        guard let mode = UInt16(permissionsText, radix: 8) else {
            applyError = "Enter an octal value like 644 or 755."
            return
        }
        applyError = nil
        onApplyPermissions(mode)
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
