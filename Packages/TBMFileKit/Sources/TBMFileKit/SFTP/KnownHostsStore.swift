import Foundation

/// Trust-on-first-use host key store. This is **not** the user's real
/// `~/.ssh/known_hosts` (that file uses per-line hashed hostnames in a format
/// that's non-trivial to parse/match reliably) — it's an app-managed
/// equivalent, serving the same purpose: don't silently trust a server whose
/// key changed since the last connection. Documented gap: this app won't see
/// hosts already trusted via `ssh`/`scp` on the same Mac, and vice versa.
public enum HostTrustStatus: Equatable, Sendable {
    case trusted
    case unknown
    /// The server's key doesn't match what we trusted before — classic
    /// man-in-the-middle warning sign. Carries the previously-trusted
    /// fingerprint so the UI can show "was X, now Y".
    case changed(previousFingerprint: String)
}

public final class KnownHostsStore: @unchecked Sendable {
    private let storeURL: URL
    private let lock = NSLock()
    private var entries: [String: String] // "host:port" -> full OpenSSH public-key line

    public init(storeURL: URL) {
        self.storeURL = storeURL
        self.entries = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    public static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("TBM File Explorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("known_hosts.json")
    }

    /// The stored OpenSSH public-key line for a host, if we've trusted one before.
    public func trustedLine(host: String, port: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key(host: host, port: port)]
    }

    public func status(host: String, port: Int, presentedKeyLine: String) -> HostTrustStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let trustedLine = entries[key(host: host, port: port)] else { return .unknown }
        if blob(of: trustedLine) == blob(of: presentedKeyLine) {
            return .trusted
        }
        return .changed(previousFingerprint: trustedLine)
    }

    public func trust(host: String, port: Int, keyLine: String) throws {
        lock.lock()
        entries[key(host: host, port: port)] = keyLine
        let snapshot = entries
        lock.unlock()

        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: storeURL, options: .atomic)
    }

    private func key(host: String, port: Int) -> String { "\(host):\(port)" }

    private func blob(of openSSHLine: String) -> String? {
        openSSHLine.split(separator: " ").dropFirst().first.map(String.init)
    }
}
