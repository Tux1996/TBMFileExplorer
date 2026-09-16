import SwiftUI
import TBMFileKit

struct StatusBarView: View {
    @Environment(AppViewModel.self) private var appModel

    var body: some View {
        let tab = appModel.focusedPane.activeTab
        let manager = appModel.transferManager
        HStack {
            Text(itemCountText(tab))
            if !tab.selection.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(selectionText(tab))
            }
            Spacer()
            if manager.activeCount > 0 {
                Text("\(manager.activeCount) transfer\(manager.activeCount == 1 ? "" : "s")")
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(manager.totalSpeedBytesPerSecond), countStyle: .file) + "/s")
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: manager.totalRemainingBytes, countStyle: .file) + " remaining")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial)
    }

    private func itemCountText(_ tab: TabViewModel) -> String {
        let count = tab.displayedItems.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private func selectionText(_ tab: TabViewModel) -> String {
        let selected = tab.displayedItems.filter { tab.selection.contains($0.path) }
        let totalBytes = selected.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let sizeText = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return selected.count == 1 ? "1 selected, \(sizeText)" : "\(selected.count) selected, \(sizeText)"
    }
}
