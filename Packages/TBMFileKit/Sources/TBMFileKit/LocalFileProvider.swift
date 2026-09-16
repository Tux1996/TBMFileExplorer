import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `FileProvider` backed by the local macOS filesystem. Uses batched
/// `URLResourceValues` for directory listings (one round-trip per entry
/// instead of one per column) and POSIX calls for the metadata `FileManager`
/// doesn't expose (owner/group names, raw permission bits, symlink targets).
public final class LocalFileProvider: FileProvider {
    public let identifier: FileProviderIdentifier = .local
    public let displayName = "Local Mac"
    public let capabilities = FileProviderCapabilities(
        canSetPermissions: true,
        canSetOwnership: false, // chown requires privileges we don't want to silently escalate to
        canSymlink: true,
        canTrash: true,
        canResumeTransfers: false // local copy is not resumable the way a network transfer is
    )

    public init() {}

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey
    ]

    public func list(_ path: FilePath, includeHidden: Bool) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            let url = path.localURL
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Self.keys,
                    options: []
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                throw FileProviderError.notFound(path)
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                throw FileProviderError.permissionDenied(path)
            }

            var items: [FileItem] = []
            items.reserveCapacity(contents.count)
            for entryURL in contents {
                let item = try Self.makeItem(at: entryURL)
                if !includeHidden && item.isHidden { continue }
                items.append(item)
            }
            return items
        }.value
    }

    public func stat(_ path: FilePath) async throws -> FileItem {
        try await Task.detached(priority: .userInitiated) {
            try Self.makeItem(at: path.localURL)
        }.value
    }

    public func createDirectory(_ path: FilePath) async throws {
        try await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: path.localURL, withIntermediateDirectories: false
                )
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw FileProviderError.alreadyExists(path)
            }
        }.value
    }

    public func createFile(_ path: FilePath) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: path.string) {
                throw FileProviderError.alreadyExists(path)
            }
            guard fm.createFile(atPath: path.string, contents: Data()) else {
                throw FileProviderError.underlying("Could not create \(path.lastComponent).")
            }
        }.value
    }

    public func delete(_ path: FilePath, recursive: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if !recursive {
                let children = try? fm.contentsOfDirectory(atPath: path.string)
                if let children, !children.isEmpty {
                    throw FileProviderError.unsupported("\(path.lastComponent) is not empty.")
                }
            }
            do {
                try fm.removeItem(at: path.localURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                throw FileProviderError.notFound(path)
            }
        }.value
    }

    public func moveToTrash(_ path: FilePath) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.trashItem(at: path.localURL, resultingItemURL: nil)
        }.value
    }

    public func move(from source: FilePath, to destination: FilePath) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.string) {
                throw FileProviderError.alreadyExists(destination)
            }
            try fm.moveItem(at: source.localURL, to: destination.localURL)
        }.value
    }

    public func copy(from source: FilePath, to destination: FilePath) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.string) {
                throw FileProviderError.alreadyExists(destination)
            }
            try fm.copyItem(at: source.localURL, to: destination.localURL)
        }.value
    }

    public func rename(_ path: FilePath, to newName: String) async throws -> FilePath {
        let destination = path.parent.appending(newName)
        try await move(from: path, to: destination)
        return destination
    }

    public func setPermissions(_ path: FilePath, mode: UInt16) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: path.string
            )
        }.value
    }

    public func volumeInfo(for path: FilePath) async throws -> VolumeInfo? {
        await Task.detached(priority: .userInitiated) {
            let values = try? path.localURL.resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            )
            guard let values else { return nil }
            let total = values.volumeTotalCapacity.map { Int64($0) }
            let available = values.volumeAvailableCapacityForImportantUsage
            return VolumeInfo(totalBytes: total, availableBytes: available)
        }.value
    }

    // MARK: - Streaming (Phase 5 Transfer Engine)

    public func readChunks(_ path: FilePath, startingAt offset: Int64) async -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    guard let handle = FileHandle(forReadingAtPath: path.string) else {
                        continuation.finish(throwing: FileProviderError.notFound(path))
                        return
                    }
                    defer { try? handle.close() }
                    if offset > 0 {
                        try handle.seek(toOffset: UInt64(offset))
                    }
                    let chunkSize = 256 * 1024
                    while !Task.isCancelled {
                        guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func openWriteSink(_ path: FilePath, mode: WriteMode) async throws -> any FileWriteSink {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            switch mode {
            case .createFailIfExists:
                if fm.fileExists(atPath: path.string) {
                    throw FileProviderError.alreadyExists(path)
                }
                guard fm.createFile(atPath: path.string, contents: nil) else {
                    throw FileProviderError.underlying("Could not create \(path.lastComponent).")
                }
            case .resumeAppend:
                if !fm.fileExists(atPath: path.string) {
                    guard fm.createFile(atPath: path.string, contents: nil) else {
                        throw FileProviderError.underlying("Could not create \(path.lastComponent).")
                    }
                }
            }
            guard let handle = FileHandle(forWritingAtPath: path.string) else {
                throw FileProviderError.underlying("Could not open \(path.lastComponent) for writing.")
            }
            if case .resumeAppend = mode {
                handle.seekToEndOfFile()
            }
            return LocalFileWriteSink(handle: handle) as any FileWriteSink
        }.value
    }

    // MARK: - Metadata assembly

    private static func makeItem(at url: URL) throws -> FileItem {
        let path = FilePath(url.path)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(keys))
        } catch {
            throw FileProviderError.notFound(path)
        }

        var st = Darwin.stat()
        let hasLstat = lstat(url.path, &st) == 0
        let isSymlink = values.isSymbolicLink ?? false
        var symlinkTarget: FilePath?
        if isSymlink, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let resolved = dest.hasPrefix("/") ? dest : url.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL.path
            symlinkTarget = FilePath(resolved)
        }

        let mode: UInt16? = hasLstat ? UInt16(st.st_mode & 0o7777) : nil
        let ownerName = hasLstat ? Self.userName(uid: st.st_uid) : nil
        let groupName = hasLstat ? Self.groupName(gid: st.st_gid) : nil

        return FileItem(
            path: path,
            name: url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            isSymlink: isSymlink,
            symlinkTarget: symlinkTarget,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            size: values.fileSize.map { Int64($0) },
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            posixPermissions: mode,
            ownerName: ownerName,
            groupName: groupName
        )
    }

    private static func userName(uid: uid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: 1024)
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil else {
            return nil
        }
        return String(cString: pwd.pw_name)
    }

    private static func groupName(gid: gid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: 1024)
        var grp = group()
        var result: UnsafeMutablePointer<group>?
        guard getgrgid_r(gid, &grp, &buffer, buffer.count, &result) == 0, result != nil else {
            return nil
        }
        return String(cString: grp.gr_name)
    }
}

/// `@unchecked Sendable`: writes must be issued sequentially by contract (see
/// `FileWriteSink`), so the lack of internal locking is safe under that usage,
/// not despite it.
final class LocalFileWriteSink: FileWriteSink, @unchecked Sendable {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) async throws {
        try handle.write(contentsOf: data)
    }

    func finish() async throws {
        try handle.close()
    }
}
