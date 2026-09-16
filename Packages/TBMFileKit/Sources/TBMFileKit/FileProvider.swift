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
}
