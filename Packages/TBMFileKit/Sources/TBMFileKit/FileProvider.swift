import Foundation

/// Identifies which backend a `FileProvider` talks to. Remote cases carry the
/// owning connection's id once `ConnectionProfile` exists (Phase 4) — kept as
/// a plain UUID for now so the type is ready without inventing an unused model.
public enum FileProviderIdentifier: Hashable, Sendable {
    case local
    case sftp(connectionID: UUID)
    case ftp(connectionID: UUID)
    case smb(connectionID: UUID)
}

public struct FileProviderCapabilities: Sendable {
    public var canSetPermissions: Bool
    public var canSetOwnership: Bool
    public var canSymlink: Bool
    public var canTrash: Bool
    public var canResumeTransfers: Bool

    public init(
        canSetPermissions: Bool,
        canSetOwnership: Bool,
        canSymlink: Bool,
        canTrash: Bool,
        canResumeTransfers: Bool
    ) {
        self.canSetPermissions = canSetPermissions
        self.canSetOwnership = canSetOwnership
        self.canSymlink = canSymlink
        self.canTrash = canTrash
        self.canResumeTransfers = canResumeTransfers
    }
}

public struct VolumeInfo: Sendable {
    public var totalBytes: Int64?
    public var availableBytes: Int64?

    public init(totalBytes: Int64?, availableBytes: Int64?) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

/// A destination opened for streamed writing — the write side of cross-provider
/// transfers (Phase 5's Transfer Engine). Writes are sequential by contract:
/// callers must `await` each `write` before issuing the next one, and must call
/// `finish()` exactly once when done (or the destination may be left truncated
/// or, for SFTP, with its handle never closed).
public protocol FileWriteSink: Sendable {
    func write(_ data: Data) async throws
    func finish() async throws
}

public enum WriteMode: Sendable {
    /// Fail with `.alreadyExists` if the destination is already there — the
    /// "never silently overwrite" default.
    case createFailIfExists
    /// Create the destination if it doesn't exist, or open the existing one
    /// and position writes at its current end — for resuming an interrupted
    /// transfer, paired with reading the source starting at that same offset.
    case resumeAppend
}

public enum FileProviderError: Error, LocalizedError, Sendable {
    case notFound(FilePath)
    case alreadyExists(FilePath)
    case permissionDenied(FilePath)
    case unsupported(String)
    case connectionLost
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "\(path.lastComponent) could not be found."
        case .alreadyExists(let path): "\(path.lastComponent) already exists."
        case .permissionDenied(let path): "You don't have permission to access \(path.lastComponent)."
        case .unsupported(let reason): reason
        case .connectionLost: "The connection was lost."
        case .underlying(let message): message
        }
    }
}

/// The single interface every part of the app (browser, transfer engine, search)
/// talks to. Nothing outside a concrete `*FileProvider` implementation is allowed
/// to know whether a file is local, SFTP, FTP, or SMB.
public protocol FileProvider: Sendable {
    var identifier: FileProviderIdentifier { get }
    var capabilities: FileProviderCapabilities { get }
    /// Human-readable root label for breadcrumbs/tabs, e.g. "Local Mac" or "Home Server".
    var displayName: String { get }

    func list(_ path: FilePath, includeHidden: Bool) async throws -> [FileItem]
    func stat(_ path: FilePath) async throws -> FileItem
    func createDirectory(_ path: FilePath) async throws
    func createFile(_ path: FilePath) async throws
    func delete(_ path: FilePath, recursive: Bool) async throws
    func moveToTrash(_ path: FilePath) async throws
    func move(from source: FilePath, to destination: FilePath) async throws
    func copy(from source: FilePath, to destination: FilePath) async throws
    func rename(_ path: FilePath, to newName: String) async throws -> FilePath
    func setPermissions(_ path: FilePath, mode: UInt16) async throws
    func volumeInfo(for path: FilePath) async throws -> VolumeInfo?

    /// Streams a file's contents in fixed-size chunks without loading the
    /// whole file into memory — the read side of cross-provider transfers.
    /// `offset` lets a caller resume a previously-interrupted transfer by
    /// skipping the bytes the destination already has.
    func readChunks(_ path: FilePath, startingAt offset: Int64) async -> AsyncThrowingStream<Data, Error>
    func openWriteSink(_ path: FilePath, mode: WriteMode) async throws -> any FileWriteSink
}
