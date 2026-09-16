import SwiftUI
import TBMFileKit

struct TransfersView: View {
    @Environment(AppViewModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Completed") { appModel.transferManager.removeCompleted() }
                    .disabled(!appModel.transferManager.jobs.contains { $0.status == .completed })
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if appModel.transferManager.jobs.isEmpty {
                VStack {
                    Spacer()
                    Text("No transfers yet").foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(appModel.transferManager.jobs) { job in
                    TransferRowView(job: job, manager: appModel.transferManager)
                }
                .listStyle(.plain)
            }

            Divider()
            TransferStatusSummaryView()
        }
        .frame(width: 560, height: 420)
    }
}

/// Presented from `MainWindowView`, not `TransfersView` — a collision can
/// happen from a drag-drop or paste even when the user hasn't opened the
/// Transfers panel, so the prompt needs to live somewhere always in the view
/// hierarchy, not inside an optional sheet.
struct CollisionSheet: View {
    let request: TransferCollisionRequest
    var onRespond: (CollisionResolution, Bool) -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Item Already Exists").font(.headline)
            Text("\"\(request.filename)\" already exists at the destination.")
            HStack(spacing: 20) {
                sizeLabel("Source", request.sourceSize)
                sizeLabel("Destination", request.destinationSize)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Toggle("Apply this choice to all remaining collisions in this batch", isOn: $applyToAll)
                .font(.system(size: 12))

            Spacer()
            HStack {
                Button("Cancel", role: .cancel) { onRespond(.cancel, applyToAll) }
                Spacer()
                Button("Skip") { onRespond(.skip, applyToAll) }
                Button("Keep Both") { onRespond(.keepBoth, applyToAll) }
                Button("Resume") { onRespond(.resume, applyToAll) }
                Button("Replace") { onRespond(.replace, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }

    private func sizeLabel(_ title: String, _ size: Int64?) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown")
                .foregroundStyle(.primary)
        }
    }
}

private struct TransferRowView: View {
    let job: TransferJob
    let manager: TransferManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(job.sourceDisplayName) → \(job.destinationDisplayName)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actionButtons
            }
            if job.status == .running || job.status == .paused {
                ProgressView(value: job.progress ?? 0)
                    .progressViewStyle(.linear)
                HStack {
                    Text(progressText).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if let eta = job.estimatedTimeRemaining, job.status == .running {
                        Text(formattedDuration(eta) + " remaining").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else if case .failed(let message) = job.status {
                Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.status {
        case .running:
            Button { manager.pause(job.id) } label: { Image(systemName: "pause.fill") }
                .buttonStyle(.borderless)
            Button { manager.cancel(job.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        case .paused:
            Button { manager.resumePaused(job.id) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
            Button { manager.cancel(job.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        case .queued:
            Button { manager.cancel(job.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        case .failed, .cancelled:
            Button { manager.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
            Button { manager.remove(job.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        case .completed:
            Button { manager.remove(job.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private var statusIcon: String {
        switch job.status {
        case .queued: "clock"
        case .running: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .running: .blue
        default: .secondary
        }
    }

    private var progressText: String {
        let transferred = ByteCountFormatter.string(fromByteCount: job.transferredBytes, countStyle: .file)
        if let total = job.totalBytes {
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let speed = ByteCountFormatter.string(fromByteCount: Int64(job.speedBytesPerSecond), countStyle: .file)
            return "\(transferred) of \(totalText) — \(speed)/s"
        }
        return transferred
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "—"
    }
}

struct TransferStatusSummaryView: View {
    @Environment(AppViewModel.self) private var appModel

    var body: some View {
        let manager = appModel.transferManager
        HStack(spacing: 12) {
            if manager.activeCount > 0 {
                Text("\(manager.activeCount) transfer\(manager.activeCount == 1 ? "" : "s")")
                Text(ByteCountFormatter.string(fromByteCount: Int64(manager.totalSpeedBytesPerSecond), countStyle: .file) + "/s")
                Text(ByteCountFormatter.string(fromByteCount: manager.totalRemainingBytes, countStyle: .file) + " remaining")
            } else {
                Text("No active transfers")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
