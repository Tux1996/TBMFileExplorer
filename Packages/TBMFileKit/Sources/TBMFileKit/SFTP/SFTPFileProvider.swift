import Citadel
import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH

public enum SFTPConnectionError: Error, LocalizedError, Sendable, Equatable {
    case hostKeyRejected
    case authenticationFailed
    case missingCredential
    case timedOut
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyRejected: "The server's identity was not confirmed, so the connection was cancelled."
        case .authenticationFailed: "The username, password, or key was rejected by the server."
        case .missingCredential: "No saved password or key was found for this connection."
        case .timedOut: "The connection timed out."
        case .underlying(let message): message
        }
    }
}

/// Presented when a host's key is unknown or has changed, so the UI can show a
/// confirmation dialog before the connection proceeds — this is the "host
/// fingerprint confirmation" requirement, backed by `KnownHostsStore`.
public protocol SFTPHostKeyConfirming: Sendable {
    /// Return `true` to trust this key (persisted to `KnownHostsStore`) and proceed,
    /// `false` to abort the connection.
    func confirmHostKey(host: String, port: Int, fingerprint: String, isChanged: Bool) async -> Bool
}

/// `FileProvider` backed by a real SFTP connection via Citadel. An actor (not a
/// class) because it owns mutable connection state (`client`/`sftp`) that must
/// stay consistent across concurrent calls from the UI.
public actor SFTPFileProvider: FileProvider {
    public nonisolated let identifier: FileProviderIdentifier
    public nonisolated let displayName: String
    public nonisolated let capabilities = FileProviderCapabilities(
        canSetPermissions: true,
        canSetOwnership: false,
        canSymlink: false, // Citadel's SFTP client doesn't expose readlink/symlink creation today
        canTrash: false,   // no server-side Trash over SFTP; delete is permanent
        canResumeTransfers: true
    )

    private let profile: ConnectionProfile
    private let knownHosts: KnownHostsStore
    private let hostKeyConfirmer: SFTPHostKeyConfirming
    private var client: SSHClient?
    private var sftp: SFTPClient?

    public init(
        profile: ConnectionProfile,
        knownHosts: KnownHostsStore = KnownHostsStore(storeURL: KnownHostsStore.defaultStoreURL),
        hostKeyConfirmer: SFTPHostKeyConfirming
    ) {
        self.profile = profile
        self.identifier = .sftp(connectionID: profile.id)
        self.displayName = profile.name
        self.knownHosts = knownHosts
        self.hostKeyConfirmer = hostKeyConfirmer
    }

    public func disconnect() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }

    // MARK: - FileProvider

    public func list(_ path: FilePath, includeHidden: Bool) async throws -> [FileItem] {
        let sftp = try await ensureConnected()
        do {
            let names = try await sftp.listDirectory(atPath: path.string)
            return names.flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .filter { includeHidden || !$0.filename.hasPrefix(".") }
                .map { Self.makeItem(parent: path, component: $0) }
        } catch {
            throw map(error, path: path)
        }
    }

    public func stat(_ path: FilePath) async throws -> FileItem {
        let sftp = try await ensureConnected()
        do {
            let attributes = try await sftp.getAttributes(at: path.string)
            return Self.makeItem(path: path, name: path.lastComponent, attributes: attributes)
        } catch {
            throw map(error, path: path)
        }
    }

    public func createDirectory(_ path: FilePath) async throws {
        let sftp = try await ensureConnected()
        do {
            try await sftp.createDirectory(atPath: path.string)
        } catch {
            throw map(error, path: path, treatGenericFailureAsAlreadyExists: true)
        }
    }

    public func createFile(_ path: FilePath) async throws {
        let sftp = try await ensureConnected()
        do {
            let file = try await sftp.openFile(filePath: path.string, flags: [.write, .create, .forceCreate])
            try await file.close()
        } catch {
            throw map(error, path: path, treatGenericFailureAsAlreadyExists: true)
        }
    }

    public func delete(_ path: FilePath, recursive: Bool) async throws {
        let sftp = try await ensureConnected()
        let item: FileItem
        do {
            item = try await stat(path)
        } catch {
            throw map(error, path: path)
        }
        do {
            if item.isDirectory {
                if recursive {
                    let children = try await list(path, includeHidden: true)
                    for child in children {
                        try await delete(child.path, recursive: true)
                    }
                }
                try await sftp.rmdir(at: path.string)
            } else {
                try await sftp.remove(at: path.string)
            }
        } catch {
            throw map(error, path: path)
        }
    }

    public func moveToTrash(_ path: FilePath) async throws {
        throw FileProviderError.unsupported("SFTP has no Trash — use Delete instead.")
    }

    public func move(from source: FilePath, to destination: FilePath) async throws {
        let sftp = try await ensureConnected()
        do {
            try await sftp.rename(at: source.string, to: destination.string)
        } catch {
            throw map(error, path: destination, treatGenericFailureAsAlreadyExists: true)
        }
    }

    public func copy(from source: FilePath, to destination: FilePath) async throws {
        let sftp = try await ensureConnected()
        do {
            if (try? await sftp.getAttributes(at: destination.string)) != nil {
                throw FileProviderError.alreadyExists(destination)
            }
            let sourceFile = try await sftp.openFile(filePath: source.string, flags: .read)
            let destinationFile = try await sftp.openFile(
                filePath: destination.string,
                flags: [.write, .create, .forceCreate]
            )
            defer {
                Task { try? await sourceFile.close(); try? await destinationFile.close() }
            }
            var offset: UInt64 = 0
            let chunkSize: UInt32 = 256 * 1024
            // A short read is NOT end-of-file per the SFTP spec — servers may
            // return fewer bytes than requested for reasons unrelated to EOF
            // (this container's happened to cap responses at 64 KB). Only a
            // genuinely empty response means "done".
            while true {
                let chunk = try await sourceFile.read(from: offset, length: chunkSize)
                if chunk.readableBytes == 0 { break }
                try await destinationFile.write(chunk, at: offset)
                offset += UInt64(chunk.readableBytes)
            }
        } catch let error as FileProviderError {
            throw error
        } catch {
            throw map(error, path: destination)
        }
    }

    public func rename(_ path: FilePath, to newName: String) async throws -> FilePath {
        let destination = path.parent.appending(newName)
        try await move(from: path, to: destination)
        return destination
    }

    public func setPermissions(_ path: FilePath, mode: UInt16) async throws {
        let sftp = try await ensureConnected()
        do {
            var attributes = SFTPFileAttributes()
            attributes.permissions = UInt32(mode)
            try await sftp.setAttributes(at: path.string, to: attributes)
        } catch {
            throw map(error, path: path)
        }
    }

    public func volumeInfo(for path: FilePath) async throws -> VolumeInfo? {
        nil // SFTP has no standard "free space" query; see server info panel, Phase 8.
    }

    // MARK: - Streaming (Phase 5 Transfer Engine)

    public func readChunks(_ path: FilePath, startingAt offset: Int64) async -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let sftp = try await self.ensureConnected()
                    let file = try await sftp.openFile(filePath: path.string, flags: .read)
                    var currentOffset = UInt64(offset)
                    let chunkSize: UInt32 = 256 * 1024
                    while !Task.isCancelled {
                        let chunk = try await file.read(from: currentOffset, length: chunkSize)
                        if chunk.readableBytes == 0 { break }
                        currentOffset += UInt64(chunk.readableBytes)
                        continuation.yield(Data(buffer: chunk))
                    }
                    try? await file.close()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: self.map(error, path: path))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func openWriteSink(_ path: FilePath, mode: WriteMode) async throws -> any FileWriteSink {
        let sftp = try await ensureConnected()
        var startOffset: UInt64 = 0
        var flags: SFTPOpenFileFlags = [.write, .create]
        switch mode {
        case .createFailIfExists:
            if (try? await sftp.getAttributes(at: path.string)) != nil {
                throw FileProviderError.alreadyExists(path)
            }
            flags.insert(.forceCreate)
        case .resumeAppend:
            if let attributes = try? await sftp.getAttributes(at: path.string), let size = attributes.size {
                startOffset = size
            }
        }
        do {
            let file = try await sftp.openFile(filePath: path.string, flags: flags)
            return SFTPFileWriteSink(file: file, startOffset: startOffset)
        } catch {
            throw map(error, path: path)
        }
    }

    // MARK: - Connection lifecycle

    private func ensureConnected() async throws -> SFTPClient {
        if let sftp, sftp.isActive, let client, client.isConnected {
            return sftp
        }

        let hostKeyValidator = try await resolveHostKeyValidator()
        let authenticationMethod = try resolveAuthenticationMethod()
        let settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authenticationMethod },
            hostKeyValidator: hostKeyValidator
        )

        let newClient: SSHClient
        do {
            newClient = try await SSHClient.connect(to: settings)
        } catch is AuthenticationFailed {
            throw SFTPConnectionError.authenticationFailed
        } catch SSHClientError.allAuthenticationOptionsFailed {
            // What Citadel actually throws for a rejected password/key today,
            // confirmed against a live server — `AuthenticationFailed` above
            // covers a different internal path, and both need mapping.
            throw SFTPConnectionError.authenticationFailed
        } catch let error as SFTPConnectionError {
            throw error
        } catch {
            throw SFTPConnectionError.underlying(
                "Couldn't connect to \(profile.host):\(profile.port) — \(error.localizedDescription)"
            )
        }

        let newSFTP = try await newClient.openSFTP()
        self.client = newClient
        self.sftp = newSFTP
        return newSFTP
    }

    /// Decides how the *real, timed* connection attempt below should validate
    /// the server's host key — without ever making that attempt wait on an
    /// interactive decision. Discovered against a live server: Citadel gives
    /// the whole handshake-plus-authentication sequence a hardcoded, non-
    /// configurable 10-second budget (`ClientHandshakeHandler`'s
    /// `loginTimeout`). Host-key validation runs *inside* that window, so the
    /// original design — asking the user to confirm a fingerprint from
    /// directly within `validateHostKey`'s callback — reliably failed with
    /// `NIOCore.ChannelError.connectTimeout` the moment a real human took
    /// longer than 10 seconds to read a dialog and click a button (see
    /// `ARCHITECTURE.md` §10 for the full writeup).
    ///
    /// The fix: for an already-trusted host, validate synchronously against
    /// the stored key (`.trustedKeys`, no waiting, comfortably inside 10s).
    /// For a new or changed host, run a throwaway probe connection first —
    /// bogus credentials, whose only job is to capture the presented key
    /// during key exchange and then fail authentication a moment later —
    /// entirely outside of any timing constraint that matters to the UI. The
    /// confirmation dialog runs against that already-completed probe, with no
    /// clock running, and only once that's resolved does the real, timed
    /// connection attempt begin, already knowing exactly which key to trust.
    private func resolveHostKeyValidator() async throws -> SSHHostKeyValidator {
        if let storedLine = knownHosts.trustedLine(host: profile.host, port: profile.port),
           let storedKey = try? NIOSSHPublicKey(openSSHPublicKey: storedLine) {
            return .trustedKeys([storedKey])
        }

        let presentedKey = try await probeHostKey()
        let line = HostKeyFingerprint.openSSHLine(for: presentedKey)
        let status = knownHosts.status(host: profile.host, port: profile.port, presentedKeyLine: line)
        let isChanged: Bool
        if case .changed = status { isChanged = true } else { isChanged = false }
        let fingerprint = HostKeyFingerprint.sha256Fingerprint(for: presentedKey) ?? line

        let trusted = await hostKeyConfirmer.confirmHostKey(
            host: profile.host, port: profile.port, fingerprint: fingerprint, isChanged: isChanged
        )
        guard trusted else { throw SFTPConnectionError.hostKeyRejected }
        try? knownHosts.trust(host: profile.host, port: profile.port, keyLine: line)
        return .trustedKeys([presentedKey])
    }

    /// A short-lived connection using intentionally-wrong credentials, made
    /// solely to see the server's host key during key exchange (which happens
    /// before authentication) without yet deciding whether to trust it. The
    /// expected outcome is an authentication failure a fraction of a second
    /// later, which is treated as success here — the key was already captured
    /// by then. Only a failure to reach the server *at all* (no key ever
    /// captured) is reported as an error.
    private func probeHostKey() async throws -> NIOSSHPublicKey {
        let host = profile.host
        let port = profile.port
        return try await withCheckedThrowingContinuation { continuation in
            let box = SingleResumeContinuation(continuation)
            let captureDelegate = CapturingHostKeyDelegate { key in box.resume(returning: key) }
            let probeSettings = SSHClientSettings(
                host: host,
                port: port,
                authenticationMethod: { .passwordBased(username: "tbm-hostkey-probe", password: UUID().uuidString) },
                hostKeyValidator: .custom(captureDelegate)
            )
            Task {
                do {
                    let client = try await SSHClient.connect(to: probeSettings)
                    try? await client.close()
                    box.resume(throwing: SFTPConnectionError.underlying(
                        "Unexpected: verifying \(host)'s identity connected with placeholder credentials."
                    ))
                } catch {
                    // Expected path: the probe's bogus credentials get rejected —
                    // a no-op if the capture delegate already resumed `box`.
                    box.resume(throwing: SFTPConnectionError.underlying(
                        "Couldn't reach \(host):\(port) to verify its identity — \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    private func resolveAuthenticationMethod() throws -> SSHAuthenticationMethod {
        switch profile.authentication {
        case .password:
            guard let password = try CredentialManager.read(for: profile.id, kind: .password) else {
                throw SFTPConnectionError.missingCredential
            }
            return .passwordBased(username: profile.username, password: password)
        case .privateKey:
            guard let path = profile.privateKeyPath else {
                throw SFTPConnectionError.underlying("No private key file is set for \(profile.name).")
            }
            let pem: String
            do {
                pem = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw SFTPConnectionError.underlying("Couldn't read the private key file at \(path).")
            }
            let key = try OpenSSHEd25519KeyLoader.load(pem: pem)
            return .ed25519(username: profile.username, privateKey: key)
        }
    }

    // MARK: - Error mapping

    private func map(_ error: Error, path: FilePath, treatGenericFailureAsAlreadyExists: Bool = false) -> Error {
        // Citadel throws `SFTPMessage.Status` directly from most request paths
        // (confirmed against a live server — it does NOT always wrap it in
        // `SFTPError.errorStatus`), so both shapes need handling here.
        if let status = error as? SFTPMessage.Status {
            return mapStatusCode(status.errorCode, path: path, treatGenericFailureAsAlreadyExists: treatGenericFailureAsAlreadyExists)
        }
        guard let sftpError = error as? SFTPError else { return error }
        switch sftpError {
        case .errorStatus(let status):
            return mapStatusCode(status.errorCode, path: path, treatGenericFailureAsAlreadyExists: treatGenericFailureAsAlreadyExists)
        case .connectionClosed:
            return FileProviderError.connectionLost
        default:
            return FileProviderError.underlying("\(sftpError)")
        }
    }

    private func mapStatusCode(_ code: SFTPStatusCode, path: FilePath, treatGenericFailureAsAlreadyExists: Bool) -> Error {
        switch code {
        case .noSuchFile: return FileProviderError.notFound(path)
        case .permissionDenied: return FileProviderError.permissionDenied(path)
        case .connectionLost, .noConnection: return FileProviderError.connectionLost
        case .failure where treatGenericFailureAsAlreadyExists: return FileProviderError.alreadyExists(path)
        default: return FileProviderError.underlying(code.debugDescription)
        }
    }

    // MARK: - Metadata assembly

    private static func makeItem(parent: FilePath, component: SFTPPathComponent) -> FileItem {
        makeItem(path: parent.appending(component.filename), name: component.filename, attributes: component.attributes)
    }

    private static func makeItem(path: FilePath, name: String, attributes: SFTPFileAttributes) -> FileItem {
        let mode = attributes.permissions
        let typeBits = mode.map { $0 & 0o170000 }
        return FileItem(
            path: path,
            name: name,
            isDirectory: typeBits == 0o040000,
            isSymlink: typeBits == 0o120000,
            symlinkTarget: nil, // Citadel doesn't expose SSH_FXP_READLINK publicly today
            isHidden: name.hasPrefix("."),
            size: attributes.size.map { Int64($0) },
            createdAt: nil, // SFTP v3 has no creation-time field
            modifiedAt: attributes.accessModificationTime?.modificationTime,
            posixPermissions: mode.map { UInt16($0 & 0o7777) },
            ownerName: attributes.uidgid.map { String($0.userId) },
            groupName: attributes.uidgid.map { String($0.groupId) }
        )
    }
}

/// Captures whatever host key is presented and accepts it immediately
/// (synchronously — no async, no waiting) so `probeHostKey()`'s throwaway
/// connection can get through key exchange fast. This delegate never decides
/// whether the key is *trustworthy* — `resolveHostKeyValidator()` does that,
/// afterward, with no timing pressure.
final class CapturingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let onCapture: @Sendable (NIOSSHPublicKey) -> Void

    init(onCapture: @escaping @Sendable (NIOSSHPublicKey) -> Void) {
        self.onCapture = onCapture
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        onCapture(hostKey)
        validationCompletePromise.succeed(())
    }
}

/// A `CheckedContinuation` may only be resumed once; `probeHostKey()` has two
/// independent code paths that might each try (the capture delegate on
/// success, the connection's `catch` block on failure) racing each other in
/// the ordinary case where the key was already captured before auth fails a
/// moment later. This makes the second resume attempt a safe no-op instead of
/// the fatal error `CheckedContinuation` raises on a double resume.
final class SingleResumeContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var isResumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return }
        isResumed = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return }
        isResumed = true
        continuation.resume(throwing: error)
    }
}

/// `@unchecked Sendable`: writes must be issued sequentially by contract (see
/// `FileWriteSink`), so the lack of internal locking around `offset` is safe
/// under that usage, not despite it.
final class SFTPFileWriteSink: FileWriteSink, @unchecked Sendable {
    private let file: SFTPFile
    private var offset: UInt64

    init(file: SFTPFile, startOffset: UInt64) {
        self.file = file
        self.offset = startOffset
    }

    func write(_ data: Data) async throws {
        try await file.write(ByteBuffer(data: data), at: offset)
        offset += UInt64(data.count)
    }

    func finish() async throws {
        try await file.close()
    }
}
