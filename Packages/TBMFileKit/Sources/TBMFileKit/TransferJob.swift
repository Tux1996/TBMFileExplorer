import Foundation

public enum TransferStatus: Sendable, Equatable {
    case queued
    case running
    case paused
    case completed
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running, .paused: false
        }
    }
}

/// A single file transfer, tracked for the UI. Deliberately holds no live
/// `FileProvider` reference (those aren't easily `Sendable`/serializable in a
/// way that fits a plain UI model) — `TransferManager` (the App-layer engine
/// that actually moves bytes) keeps its own side table mapping a job's `id`
/// to the source/destination providers it needs.
public struct TransferJob: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var sourceDisplayName: String
    public var destinationDisplayName: String
    public var sourcePath: FilePath
    public var destinationPath: FilePath
    public var filename: String
    public var totalBytes: Int64?
    public var transferredBytes: Int64
    public var status: TransferStatus
    public var startedAt: Date?
    public var completedAt: Date?
    public var speedBytesPerSecond: Double
    public var retryCount: Int

    public init(
        id: UUID = UUID(),
        sourceDisplayName: String,
        destinationDisplayName: String,
        sourcePath: FilePath,
        destinationPath: FilePath,
        filename: String,
        totalBytes: Int64?,
        transferredBytes: Int64 = 0,
        status: TransferStatus = .queued,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        speedBytesPerSecond: Double = 0,
        retryCount: Int = 0
    ) {
        self.id = id
        self.sourceDisplayName = sourceDisplayName
        self.destinationDisplayName = destinationDisplayName
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.filename = filename
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.speedBytesPerSecond = speedBytesPerSecond
        self.retryCount = retryCount
    }

    public var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard let totalBytes, speedBytesPerSecond > 0 else { return nil }
        let remaining = Double(totalBytes - transferredBytes)
        return remaining > 0 ? remaining / speedBytesPerSecond : 0
    }

    public var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(startedAt)
    }
}
