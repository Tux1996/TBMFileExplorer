import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing
@testable import TBMFileKit

/// Exercises `SFTPFileProvider` against a real SFTP server (a disposable
/// local Docker container — see `TestSFTPServer`), not mocks. Every test is
/// `.enabled(if: TestSFTPServer.isReachable)` so `swift test` still passes
/// cleanly on a machine that doesn't have the container running (including
/// CI, until Phase 4 wires a container into that pipeline) — see `TESTING.md`.
struct SFTPFileProviderIntegrationTests {
    private func withKeyFile<R>(_ body: (String) async throws -> R) async throws -> R {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tbm-test-\(UUID().uuidString)")
        try TestSFTPServer.privateKeyPEM.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url.path)
    }

    private func makePasswordProvider(id: UUID = UUID()) throws -> SFTPFileProvider {
        let profile = ConnectionProfile(id: id, name: "Test", host: TestSFTPServer.host, port: TestSFTPServer.port, username: TestSFTPServer.username, authentication: .password, defaultRemotePath: "/data")
        try CredentialManager.save(TestSFTPServer.password, for: profile.id, kind: .password)
        let store = KnownHostsStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json"))
        return SFTPFileProvider(profile: profile, knownHosts: store, hostKeyConfirmer: RecordingHostKeyConfirmer())
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func passwordAuthConnectsAndListsRoot() async throws {
        let provider = try makePasswordProvider()
        defer { Task { await provider.disconnect() } }

        let items = try await provider.list(FilePath("/data"), includeHidden: false)
        // Not asserting exact contents (other tests may run concurrently against
        // the same container) — just that a real, well-formed listing came back.
        #expect(items.allSatisfy { !$0.name.isEmpty })
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func keyAuthConnectsSuccessfully() async throws {
        try await withKeyFile { keyPath in
            let profile = TestSFTPServer.makeProfile(auth: .privateKey, privateKeyPath: keyPath)
            let provider = SFTPFileProvider(
                profile: profile,
                knownHosts: KnownHostsStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")),
                hostKeyConfirmer: RecordingHostKeyConfirmer()
            )
            let items = try await provider.list(FilePath("/data"), includeHidden: false)
            #expect(items.allSatisfy { !$0.name.isEmpty })
            await provider.disconnect()
        }
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func wrongPasswordFailsAuthentication() async throws {
        let profile = ConnectionProfile(name: "Bad Auth", host: TestSFTPServer.host, port: TestSFTPServer.port, username: TestSFTPServer.username, authentication: .password, defaultRemotePath: "/data")
        try CredentialManager.save("definitely-wrong", for: profile.id, kind: .password)
        defer { try? CredentialManager.deleteAll(for: profile.id) }
        let provider = SFTPFileProvider(
            profile: profile,
            knownHosts: KnownHostsStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")),
            hostKeyConfirmer: RecordingHostKeyConfirmer()
        )

        await #expect(throws: SFTPConnectionError.authenticationFailed) {
            _ = try await provider.list(FilePath("/data"), includeHidden: false)
        }
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func hostKeyIsTrustedOnceThenRemembered() async throws {
        let store = KnownHostsStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json"))
        let confirmer = RecordingHostKeyConfirmer()
        let profile = ConnectionProfile(name: "TOFU", host: TestSFTPServer.host, port: TestSFTPServer.port, username: TestSFTPServer.username, authentication: .password, defaultRemotePath: "/data")
        try CredentialManager.save(TestSFTPServer.password, for: profile.id, kind: .password)
        defer { try? CredentialManager.deleteAll(for: profile.id) }

        let first = SFTPFileProvider(profile: profile, knownHosts: store, hostKeyConfirmer: confirmer)
        _ = try await first.list(FilePath("/data"), includeHidden: false)
        await first.disconnect()
        #expect(confirmer.confirmations.count == 1)
        #expect(confirmer.confirmations.first?.isChanged == false)

        let second = SFTPFileProvider(profile: profile, knownHosts: store, hostKeyConfirmer: confirmer)
        _ = try await second.list(FilePath("/data"), includeHidden: false)
        await second.disconnect()
        #expect(confirmer.confirmations.count == 1) // not asked again — already trusted
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func rejectingTheHostKeyAbortsTheConnection() async throws {
        struct RejectingConfirmer: SFTPHostKeyConfirming {
            func confirmHostKey(host: String, port: Int, fingerprint: String, isChanged: Bool) async -> Bool { false }
        }
        let profile = ConnectionProfile(name: "Reject", host: TestSFTPServer.host, port: TestSFTPServer.port, username: TestSFTPServer.username, authentication: .password, defaultRemotePath: "/data")
        try CredentialManager.save(TestSFTPServer.password, for: profile.id, kind: .password)
        defer { try? CredentialManager.deleteAll(for: profile.id) }
        let provider = SFTPFileProvider(
            profile: profile,
            knownHosts: KnownHostsStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")),
            hostKeyConfirmer: RejectingConfirmer()
        )

        await #expect(throws: SFTPConnectionError.hostKeyRejected) {
            _ = try await provider.list(FilePath("/data"), includeHidden: false)
        }
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func fullFileLifecycle() async throws {
        let provider = try makePasswordProvider()
        defer { Task { await provider.disconnect() } }

        let dir = FilePath("/data/lifecycle-\(UUID().uuidString)")
        try await provider.createDirectory(dir)
        let file = dir.appending("hello.txt")
        try await provider.createFile(file)

        var attrs = try await provider.stat(file)
        #expect(attrs.size == 0)
        #expect(!attrs.isDirectory)

        try await provider.setPermissions(file, mode: 0o640)
        attrs = try await provider.stat(file)
        #expect(attrs.posixPermissions == 0o640)

        let renamed = try await provider.rename(file, to: "renamed.txt")
        #expect(renamed.lastComponent == "renamed.txt")

        let listing = try await provider.list(dir, includeHidden: false)
        #expect(listing.map(\.name) == ["renamed.txt"])

        try await provider.delete(renamed, recursive: false)
        try await provider.delete(dir, recursive: false)

        await #expect(throws: FileProviderError.self) {
            _ = try await provider.stat(dir)
        }
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func creatingADirectoryThatAlreadyExistsThrowsAlreadyExists() async throws {
        let provider = try makePasswordProvider()
        defer { Task { await provider.disconnect() } }
        let dir = FilePath("/data/dup-\(UUID().uuidString)")
        try await provider.createDirectory(dir)
        defer { Task { try? await provider.delete(dir, recursive: false) } }

        await #expect(throws: FileProviderError.self) {
            try await provider.createDirectory(dir)
        }
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func movingOntoAnExistingDestinationDoesNotSilentlyOverwrite() async throws {
        let provider = try makePasswordProvider()
        defer { Task { await provider.disconnect() } }
        let dir = FilePath("/data/collision-\(UUID().uuidString)")
        try await provider.createDirectory(dir)
        defer { Task { try? await provider.delete(dir, recursive: true) } }

        let a = dir.appending("a.txt")
        let b = dir.appending("b.txt")
        try await provider.createFile(a)
        try await provider.createFile(b)

        await #expect(throws: FileProviderError.self) {
            try await provider.move(from: a, to: b)
        }
    }

    @Test(.enabled(if: TestSFTPServer.isReachable))
    func statOnMissingPathThrowsNotFound() async throws {
        let provider = try makePasswordProvider()
        defer { Task { await provider.disconnect() } }

        await #expect(throws: FileProviderError.self) {
            _ = try await provider.stat(FilePath("/data/does-not-exist-\(UUID().uuidString)"))
        }
    }

    /// `SFTPFileProvider` has no `writeStream` yet (that's Phase 5's job), so
    /// this test drives Citadel directly to create real multi-chunk content —
    /// purely as fixture setup/verification — and puts the provider's `copy`
    /// under test the same way `PaneView`'s duplicate/paste actions would use it.
    @Test(.enabled(if: TestSFTPServer.isReachable))
    func copyStreamsMultiChunkFileWithoutLoadingItAllAtOnce() async throws {
        let provider = try makePasswordProvider()
        defer { Task { await provider.disconnect() } }
        let dir = FilePath("/data/copy-\(UUID().uuidString)")
        try await provider.createDirectory(dir)
        defer { Task { try? await provider.delete(dir, recursive: true) } }

        let sourcePath = dir.appending("source.bin")
        // Larger than SFTPFileProvider's 256 KB copy chunk size, to exercise the loop.
        let payload = Data((0..<(300 * 1024)).map { UInt8($0 % 256) })
        try await writeFixtureFile(at: sourcePath, contents: payload)

        let destinationPath = dir.appending("destination.bin")
        try await provider.copy(from: sourcePath, to: destinationPath)

        let destinationAttrs = try await provider.stat(destinationPath)
        #expect(destinationAttrs.size == Int64(payload.count))
        let copiedContents = try await readFixtureFile(at: destinationPath)
        #expect(copiedContents == payload)
    }

    // MARK: - Fixture helpers (bypass SFTPFileProvider — it has no read/write content
    // methods yet — to set up and verify test data directly against the SFTP server)

    private func writeFixtureFile(at path: FilePath, contents: Data) async throws {
        let client = try await SSHClient.connect(to: SSHClientSettings(
            host: TestSFTPServer.host,
            port: TestSFTPServer.port,
            authenticationMethod: { .passwordBased(username: TestSFTPServer.username, password: TestSFTPServer.password) },
            hostKeyValidator: .acceptAnything()
        ))
        defer { Task { try? await client.close() } }
        let sftp = try await client.openSFTP()
        let file = try await sftp.openFile(filePath: path.string, flags: [.write, .create, .forceCreate])
        try await file.write(ByteBuffer(data: contents))
        try await file.close()
    }

    private func readFixtureFile(at path: FilePath) async throws -> Data {
        let client = try await SSHClient.connect(to: SSHClientSettings(
            host: TestSFTPServer.host,
            port: TestSFTPServer.port,
            authenticationMethod: { .passwordBased(username: TestSFTPServer.username, password: TestSFTPServer.password) },
            hostKeyValidator: .acceptAnything()
        ))
        defer { Task { try? await client.close() } }
        let sftp = try await client.openSFTP()
        let file = try await sftp.openFile(filePath: path.string, flags: .read)
        let buffer = try await file.readAll()
        try await file.close()
        return Data(buffer: buffer)
    }
}
