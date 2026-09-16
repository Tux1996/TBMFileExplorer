import Foundation
import Observation
import TBMFileKit

struct HostKeyConfirmationRequest: Identifiable {
    let id = UUID()
    let host: String
    let port: Int
    let fingerprint: String
    let isChanged: Bool
}

/// Bridges `SFTPFileProvider`'s async, protocol-level host-key confirmation
/// callback to a SwiftUI alert. `MainWindowView` observes `pendingRequest` and
/// shows the confirmation dialog whenever it becomes non-nil; the dialog's
/// buttons call `respond(trusted:)` to resume the connection attempt that's
/// suspended waiting for an answer.
@Observable
@MainActor
final class HostKeyConfirmationCenter: SFTPHostKeyConfirming {
    private(set) var pendingRequest: HostKeyConfirmationRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    nonisolated func confirmHostKey(host: String, port: Int, fingerprint: String, isChanged: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.continuation = continuation
                self.pendingRequest = HostKeyConfirmationRequest(host: host, port: port, fingerprint: fingerprint, isChanged: isChanged)
            }
        }
    }

    func respond(trusted: Bool) {
        pendingRequest = nil
        continuation?.resume(returning: trusted)
        continuation = nil
    }
}
