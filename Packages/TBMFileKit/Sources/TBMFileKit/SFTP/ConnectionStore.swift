import Foundation

/// Persists `ConnectionProfile`s (non-secret fields only — see
/// `ARCHITECTURE.md` §5) as a plain JSON array. A single small file is enough
/// for a personal list of servers; this is the "simplest reliable option"
/// decision that doc's persistence section deferred to Phase 4.
public final class ConnectionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var profiles: [ConnectionProfile]

    public init(fileURL: URL = ConnectionStore.defaultFileURL) {
        self.fileURL = fileURL
        self.profiles = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([ConnectionProfile].self, from: $0) } ?? []
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TBM File Explorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }

    public func all() -> [ConnectionProfile] {
        lock.lock()
        defer { lock.unlock() }
        return profiles
    }

    public func save(_ profile: ConnectionProfile) throws {
        lock.lock()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        let snapshot = profiles
        lock.unlock()
        try persist(snapshot)
    }

    /// Deletes the profile and its Keychain-stored credentials together, so a
    /// removed connection never leaves an orphaned secret behind.
    public func delete(_ profile: ConnectionProfile) throws {
        lock.lock()
        profiles.removeAll { $0.id == profile.id }
        let snapshot = profiles
        lock.unlock()
        try persist(snapshot)
        try CredentialManager.deleteAll(for: profile.id)
    }

    private func persist(_ profiles: [ConnectionProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }
}
