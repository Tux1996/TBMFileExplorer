import Foundation

/// A single file or directory entry, as returned by any `FileProvider`.
/// Deliberately protocol-agnostic: nothing here reveals whether it came from
/// the local disk or a remote server.
public struct FileItem: Identifiable, Hashable, Sendable {
    public var path: FilePath
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var symlinkTarget: FilePath?
    public var isHidden: Bool
    public var size: Int64?
    public var createdAt: Date?
    public var modifiedAt: Date?
    /// Raw POSIX mode bits (e.g. 0o755), when known.
    public var posixPermissions: UInt16?
    public var ownerName: String?
    public var groupName: String?

    public var id: FilePath { path }

    public init(
        path: FilePath,
        name: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        symlinkTarget: FilePath? = nil,
        isHidden: Bool = false,
        size: Int64? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        posixPermissions: UInt16? = nil,
        ownerName: String? = nil,
        groupName: String? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.isHidden = isHidden
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.posixPermissions = posixPermissions
        self.ownerName = ownerName
        self.groupName = groupName
    }

    public var fileExtension: String {
        path.pathExtension
    }

    /// `rwxr-xr-x`-style rendering of `posixPermissions`, or "" if unknown.
    public var permissionsString: String {
        guard let mode = posixPermissions else { return "" }
        let flags: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        return String(flags.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }
}
