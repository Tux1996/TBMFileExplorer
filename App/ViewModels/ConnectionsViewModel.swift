import Observation
import TBMFileKit

@Observable
@MainActor
final class ConnectionsViewModel {
    private let store = ConnectionStore()
    private(set) var profiles: [ConnectionProfile] = []

    init() {
        reload()
    }

    func reload() {
        profiles = store.all().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves the profile's non-secret fields, and — only when the caller passes
    /// a non-empty new password — updates the Keychain too. Editing a
    /// connection without retyping its password leaves the stored one alone.
    func save(_ profile: ConnectionProfile, newPassword: String?) throws {
        try store.save(profile)
        if let newPassword, !newPassword.isEmpty {
            try CredentialManager.save(newPassword, for: profile.id, kind: .password)
        }
        reload()
    }

    func delete(_ profile: ConnectionProfile) throws {
        try store.delete(profile)
        reload()
    }
}
