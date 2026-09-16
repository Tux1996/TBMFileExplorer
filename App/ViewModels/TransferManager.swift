import Foundation
import Observation
import TBMFileKit
import UserNotifications

/// One item to transfer, as requested by the UI (drag-drop, paste). Carries
/// the live source path/name only — the destination directory and any
/// collision handling are resolved by `TransferManager.enqueueBatch`.
struct TransferRequest {
    let sourcePath: FilePath
    let name: String
}

/// Drives the actual transfer queue: concurrency limiting, progress/speed
/// tracking, pause/resume/cancel/retry, and collision resolution. Holds no
/// FileProvider state that isn't `Sendable`-safe to use from `@MainActor` —
/// providers are reference types (classes/actors) already, so storing them
/// directly is fine.
@Observable
@MainActor
final class TransferManager {
    private(set) var jobs: [TransferJob] = []
    var maxConcurrentTransfers: Int = 3

    /// Bytes above which a completion/failure notification is posted — the
    /// spec's "notification when a large transfer completes", not every one.
    private let notifiableSizeThreshold: Int64 = 20 * 1024 * 1024

    private var providers: [UUID: (source: any FileProvider, destination: any FileProvider)] = [:]
    private var writeModes: [UUID: WriteMode] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var pausedJobIDs: Set<UUID> = []
    private var resumeContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Called once with `true`/`false` when a job finishes — used by "Cut"
    /// across providers to delete the source only after a successful copy.
    private var completionHandlers: [UUID: (Bool) -> Void] = [:]

    var activeCount: Int {
        jobs.filter { $0.status == .running }.count
    }

    var totalSpeedBytesPerSecond: Double {
        jobs.filter { $0.status == .running }.reduce(0) { $0 + $1.speedBytesPerSecond }
    }

    var totalRemainingBytes: Int64 {
        jobs.filter { $0.status == .running || $0.status == .queued || $0.status == .paused }
            .reduce(Int64(0)) { total, job in
                guard let totalBytes = job.totalBytes else { return total }
                return total + max(0, totalBytes - job.transferredBytes)
            }
    }

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Enqueues a batch of same-directory items (one drag-drop or paste
    /// operation), resolving collisions one at a time unless the user picks
    /// "Apply to All", in which case the rest of the batch reuses that answer.
    /// `deleteSourceAfterSuccess` is how cross-provider "Cut" is implemented:
    /// the transfer itself is always a copy; a successful one is followed by
    /// deleting the original from the source.
    func enqueueBatch(
        _ requests: [TransferRequest],
        source: any FileProvider,
        sourceDisplayName: String,
        destination: any FileProvider,
        destinationDisplayName: String,
        destinationDirectory: FilePath,
        collisionResolver: TransferCollisionResolving,
        deleteSourceAfterSuccess: Bool = false
    ) async {
        var appliedResolution: CollisionResolution?

        for request in requests {
            let destinationPath = destinationDirectory.appending(request.name)
            let sourceAttrs = try? await source.stat(request.sourcePath)
            let destinationExisting = try? await destination.stat(destinationPath)

            var resolution: CollisionResolution = .replace
            if destinationExisting != nil {
                if let appliedResolution {
                    resolution = appliedResolution
                } else {
                    let (chosen, applyToAll) = await collisionResolver.resolveCollision(
                        filename: request.name,
                        sourceSize: sourceAttrs?.size,
                        destinationSize: destinationExisting?.size
                    )
                    resolution = chosen
                    if applyToAll { appliedResolution = chosen }
                }
            }

            let onCompletion: ((Bool) -> Void)? = deleteSourceAfterSuccess ? { success in
                guard success else { return }
                Task { try? await source.delete(request.sourcePath, recursive: false) }
            } : nil

            switch resolution {
            case .skip:
                continue
            case .cancel:
                return
            case .replace:
                if destinationExisting != nil {
                    try? await destination.delete(destinationPath, recursive: false)
                }
                enqueue(
                    sourcePath: request.sourcePath, filename: request.name,
                    source: source, sourceDisplayName: sourceDisplayName,
                    destinationPath: destinationPath, destination: destination, destinationDisplayName: destinationDisplayName,
                    mode: .createFailIfExists, knownTotalBytes: sourceAttrs?.size, onCompletion: onCompletion
                )
            case .keepBoth:
                let uniquePath = await uniqueDestinationPath(destinationPath, in: destination)
                enqueue(
                    sourcePath: request.sourcePath, filename: uniquePath.lastComponent,
                    source: source, sourceDisplayName: sourceDisplayName,
                    destinationPath: uniquePath, destination: destination, destinationDisplayName: destinationDisplayName,
                    mode: .createFailIfExists, knownTotalBytes: sourceAttrs?.size, onCompletion: onCompletion
                )
            case .resume:
                enqueue(
                    sourcePath: request.sourcePath, filename: request.name,
                    source: source, sourceDisplayName: sourceDisplayName,
                    destinationPath: destinationPath, destination: destination, destinationDisplayName: destinationDisplayName,
                    mode: .resumeAppend, knownTotalBytes: sourceAttrs?.size, onCompletion: onCompletion
                )
            }
        }
    }

    private func uniqueDestinationPath(_ path: FilePath, in provider: any FileProvider) async -> FilePath {
        let ns = path.lastComponent as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var attempt = 1
        while true {
            attempt += 1
            let candidateName = ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
            let candidate = path.parent.appending(candidateName)
            if (try? await provider.stat(candidate)) == nil {
                return candidate
            }
        }
    }

    private func enqueue(
        sourcePath: FilePath, filename: String,
        source: any FileProvider, sourceDisplayName: String,
        destinationPath: FilePath, destination: any FileProvider, destinationDisplayName: String,
        mode: WriteMode, knownTotalBytes: Int64?, onCompletion: ((Bool) -> Void)? = nil
    ) {
        let job = TransferJob(
            sourceDisplayName: sourceDisplayName,
            destinationDisplayName: destinationDisplayName,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            filename: filename,
            totalBytes: knownTotalBytes
        )
        jobs.append(job)
        providers[job.id] = (source, destination)
        writeModes[job.id] = mode
        if let onCompletion {
            completionHandlers[job.id] = onCompletion
        }
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard activeTasks.count < maxConcurrentTransfers else { return }
        guard let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let jobID = jobs[index].id
        activeTasks[jobID] = Task { [weak self] in
            await self?.run(jobID)
        }
    }

    private func updateJob(_ id: UUID, _ mutate: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    private func run(_ jobID: UUID) async {
        guard let (source, destination) = providers[jobID] else { return }
        let mode = writeModes[jobID] ?? .createFailIfExists
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let sourcePath = job.sourcePath
        let destinationPath = job.destinationPath
        let filename = job.filename
        let totalBytes = job.totalBytes

        updateJob(jobID) { $0.status = .running; $0.startedAt = Date() }

        do {
            // Verify the source is actually there *before* touching the
            // destination — otherwise a missing/unreadable source still left
            // a stray empty file behind (openWriteSink's job is done, then
            // the read fails), found by testing a retry-after-failure case.
            _ = try await source.stat(sourcePath)

            var startOffset: Int64 = 0
            if case .resumeAppend = mode {
                startOffset = (try? await destination.stat(destinationPath))?.size ?? 0
            }
            updateJob(jobID) { $0.transferredBytes = startOffset }

            let sink = try await destination.openWriteSink(destinationPath, mode: mode)
            let stream = await source.readChunks(sourcePath, startingAt: startOffset)

            var windowStart = Date()
            var bytesAtWindowStart = startOffset
            var totalWritten = startOffset

            for try await chunk in stream {
                try Task.checkCancellation()
                await waitWhilePaused(jobID)
                try await sink.write(chunk)
                totalWritten += Int64(chunk.count)

                let now = Date()
                let elapsed = now.timeIntervalSince(windowStart)
                if elapsed >= 0.4 {
                    let speed = Double(totalWritten - bytesAtWindowStart) / elapsed
                    updateJob(jobID) { $0.transferredBytes = totalWritten; $0.speedBytesPerSecond = speed }
                    windowStart = now
                    bytesAtWindowStart = totalWritten
                } else {
                    updateJob(jobID) { $0.transferredBytes = totalWritten }
                }
            }
            // `for try await` over an AsyncThrowingStream exits *silently* when
            // the consuming Task is cancelled while awaiting the next value —
            // it does not throw. Without this recheck, cancelling a transfer
            // mid-flight was reported as a successful (but truncated)
            // completion instead of `.cancelled`, found by testing (see
            // ARCHITECTURE.md's Phase 5 write-up).
            try Task.checkCancellation()
            try await sink.finish()
            updateJob(jobID) {
                $0.status = .completed
                $0.completedAt = Date()
                $0.transferredBytes = totalWritten
                $0.speedBytesPerSecond = 0
            }
            if let totalBytes, totalBytes >= notifiableSizeThreshold {
                postNotification(title: "Transfer Complete", body: filename)
            }
            completionHandlers.removeValue(forKey: jobID)?(true)
        } catch is CancellationError {
            updateJob(jobID) { $0.status = .cancelled }
            completionHandlers.removeValue(forKey: jobID)
        } catch {
            updateJob(jobID) { $0.status = .failed(error.localizedDescription) }
            postNotification(title: "Transfer Failed", body: "\(filename): \(error.localizedDescription)")
            completionHandlers.removeValue(forKey: jobID)?(false)
        }

        activeTasks.removeValue(forKey: jobID)
        pausedJobIDs.remove(jobID)
        startNextIfPossible()
    }

    private func waitWhilePaused(_ id: UUID) async {
        while pausedJobIDs.contains(id) {
            await withCheckedContinuation { continuation in
                resumeContinuations[id] = continuation
            }
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - User actions

    func pause(_ id: UUID) {
        guard activeTasks[id] != nil else { return }
        pausedJobIDs.insert(id)
        updateJob(id) { $0.status = .paused }
    }

    func resumePaused(_ id: UUID) {
        pausedJobIDs.remove(id)
        updateJob(id) { $0.status = .running }
        resumeContinuations.removeValue(forKey: id)?.resume()
    }

    func cancel(_ id: UUID) {
        if let task = activeTasks[id] {
            task.cancel()
            resumeContinuations.removeValue(forKey: id)?.resume() // unblock a paused job so cancellation can land
        } else {
            updateJob(id) { $0.status = .cancelled }
        }
    }

    /// Re-enqueues a failed or cancelled job from the beginning (not from
    /// where it left off — that's what `resume`/`.resumeAppend` is for).
    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].status.isTerminal else { return }
        jobs[index].status = .queued
        jobs[index].transferredBytes = 0
        jobs[index].speedBytesPerSecond = 0
        jobs[index].startedAt = nil
        jobs[index].completedAt = nil
        jobs[index].retryCount += 1
        writeModes[id] = .createFailIfExists
        startNextIfPossible()
    }

    func removeCompleted() {
        jobs.removeAll { $0.status == .completed }
    }

    func remove(_ id: UUID) {
        guard jobs.first(where: { $0.id == id })?.status.isTerminal == true else { return }
        jobs.removeAll { $0.id == id }
        providers.removeValue(forKey: id)
        writeModes.removeValue(forKey: id)
    }
}
