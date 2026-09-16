import Darwin
import Foundation
@testable import TBMFileKit

/// Connection details for the disposable local SFTP server used by
/// `SFTPFileProviderIntegrationTests`. Start it with:
///
/// ```bash
/// docker run -d --name tbm-sftp-test -p 2223:22 \
///   -v "$(pwd)/sftp_test_data:/home/testuser/data" \
///   atmoz/sftp testuser:testpass123:1001:100:data
/// ```
///
/// and install `TestSFTPServer.publicKeyLine`'s matching private key
/// (`TestSFTPServer.privateKeyPEM`) as `/home/testuser/.ssh/authorized_keys`
/// inside the container. These are throwaway fixture credentials for a
/// container that only exists on the developer's machine during a test run —
/// not a real server, and not reachable from outside localhost.
///
/// Integration tests skip themselves (via `.enabled(if:)`) when this server
/// isn't reachable, so `swift test` still passes on a machine without Docker
/// running — see `TESTING.md`.
enum TestSFTPServer {
    static let host = "127.0.0.1"
    static let port = 2223
    static let username = "testuser"
    static let password = "testpass123"

    static let privateKeyPEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACAiF+XKp+urayIy9hYI/FHawvsxcTSvF6IMRXGQ9SP4QgAAAJA0REW1NERF
    tQAAAAtzc2gtZWQyNTUxOQAAACAiF+XKp+urayIy9hYI/FHawvsxcTSvF6IMRXGQ9SP4Qg
    AAAEBwKJv/icVBwh2/dXmLqfAaisW347YCIhPXf6s27KMraCIX5cqn66trIjL2Fgj8UdrC
    +zFxNK8XogxFcZD1I/hCAAAADXRibS1zZnRwLXRlc3Q=
    -----END OPENSSH PRIVATE KEY-----
    """

    /// A quick, synchronous reachability probe so integration tests can opt
    /// out with `.enabled(if:)` instead of failing when the disposable Docker
    /// container isn't running.
    static var isReachable: Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(sock, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Shared across every test that doesn't specifically exercise the
    /// unknown-host path, so the group of them collectively pays for the
    /// probe-then-connect dance (see `ARCHITECTURE.md` §10) once, not once
    /// per test. Tests that DO care about first-contact behavior
    /// (`hostKeyIsTrustedOnceThenRemembered`, `rejectingTheHostKeyAbortsTheConnection`,
    /// `slowHostKeyConfirmationDoesNotBlowTheLoginTimeout`) still use their own
    /// fresh store instead of this one.
    /// A fresh file each time the test binary runs (`static let` evaluates once
    /// per process) — never a fixed filename, since the disposable container
    /// gets a brand-new random host key on every `docker run`, and a store left
    /// over from a previous container would cause every test using it to fail
    /// host-key validation against the new one.
    static let sharedKnownHostsStore = KnownHostsStore(
        storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("tbm-shared-known-hosts-\(UUID().uuidString).json")
    )

    static func makeProfile(auth: AuthenticationMethod, privateKeyPath: String? = nil) -> ConnectionProfile {
        ConnectionProfile(
            name: "Test Server",
            host: host,
            port: port,
            username: username,
            authentication: auth,
            privateKeyPath: privateKeyPath,
            defaultRemotePath: "/data"
        )
    }
}

/// Always trusts host keys and records how many times it was asked, so tests
/// can assert TOFU behavior (asked once, then `KnownHostsStore` remembers).
final class RecordingHostKeyConfirmer: SFTPHostKeyConfirming, @unchecked Sendable {
    private(set) var confirmations: [(host: String, isChanged: Bool)] = []

    func confirmHostKey(host: String, port: Int, fingerprint: String, isChanged: Bool) async -> Bool {
        confirmations.append((host, isChanged))
        return true
    }
}

/// Simulates a real user who takes a while to read the fingerprint dialog and
/// click "Trust" — used to regression-test that a slow interactive decision
/// can no longer blow Citadel's fixed 10-second SSH login timeout (see
/// `ARCHITECTURE.md` §10; this is exactly the bug `resolveHostKeyValidator()`'s
/// two-phase probe-then-connect design exists to avoid).
final class DelayedHostKeyConfirmer: SFTPHostKeyConfirming, @unchecked Sendable {
    let delaySeconds: UInt64
    init(delaySeconds: UInt64) { self.delaySeconds = delaySeconds }

    func confirmHostKey(host: String, port: Int, fingerprint: String, isChanged: Bool) async -> Bool {
        try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        return true
    }
}
