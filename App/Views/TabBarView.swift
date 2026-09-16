import SwiftUI

struct TabBarView: View {
    @Bindable var pane: PaneViewModel
    var onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(pane.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isActive: tab.id == pane.activeTabID,
                            canClose: pane.tabs.count > 1
                        ) {
                            pane.activeTabID = tab.id
                        } onClose: {
                            pane.closeTab(tab)
                        }
                    }
                }
            }
            Button(action: onNewTab) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.thinMaterial)
    }
}

private struct TabChip: View {
    @Bindable var tab: TabViewModel
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 11.5))
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
