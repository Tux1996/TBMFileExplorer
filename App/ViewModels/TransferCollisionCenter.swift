import Foundation
import Observation
import TBMFileKit

enum CollisionResolution: Sendable {
    case replace
    case skip
    case keepBoth
    case resume
    case cancel
}

struct TransferCollisionRequest: Identifiable {
    let id = UUID()
    let filename: String
    let sourceSize: Int64?
    let destinationSize: Int64?
}

protocol TransferCollisionResolving: Sendable {
    /// `applyToAll` means "use this same resolution for the rest of this batch
    /// without asking again" — the spec's "Apply to All" checkbox.
    func resolveCollision(filename: String, sourceSize: Int64?, destinationSize: Int64?) async -> (resolution: CollisionResolution, applyToAll: Bool)
}

/// Bridges the collision decision to a SwiftUI dialog, the same
/// continuation-based pattern as `HostKeyConfirmationCenter`.
@Observable
@MainActor
final class TransferCollisionCenter: TransferCollisionResolving {
    private(set) var pendingRequest: TransferCollisionRequest?
    private var continuation: CheckedContinuation<(resolution: CollisionResolution, applyToAll: Bool), Never>?

    nonisolated func resolveCollision(filename: String, sourceSize: Int64?, destinationSize: Int64?) async -> (resolution: CollisionResolution, applyToAll: Bool) {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.continuation = continuation
                self.pendingRequest = TransferCollisionRequest(filename: filename, sourceSize: sourceSize, destinationSize: destinationSize)
            }
        }
    }

    func respond(_ resolution: CollisionResolution, applyToAll: Bool) {
        pendingRequest = nil
        continuation?.resume(returning: (resolution: resolution, applyToAll: applyToAll))
        continuation = nil
    }
}
