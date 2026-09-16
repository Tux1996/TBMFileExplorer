import Foundation
import TBMFileKit

/// A fast, deterministic in-memory `FileProvider` fake for testing
/// `TransferManager` without touching real disk or network — the streaming
/// primitives themselves (`LocalFileProvider`/`SFTPFileProvider`) already have
/// their own real-filesystem/real-server test coverage in `TBMFileKitTests`.
actor InMemoryFileProvider: FileProvider {
    nonisolated let identifier: FileProviderIdentifier
    nonisolated let displayName: String
    nonisolated let capabilities = FileProviderCapabilities(
        canSetPermissions: true, canSetOwnership: false, canSymlink: false, canTrash: false, canResumeTransfers: true
    )

    private var files: [String: Data] = [:]
    private var directories: Set<String> = ["/"]
    /// Artificial per-chunk delay, only for tests that need a transfer to
    /// still be running when they call `cancel`/`pause`.
    private var delayPerChunkNanoseconds: UInt64 = 0

    init(identifier: FileProviderIdentifier, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }

    func seedFile(_ path: FilePath, contents: Data) {
        files[path.string] = contents
    }

    func setDelayPerChunk(_ nanoseconds: UInt64) {
        delayPerChunkNanoseconds = nanoseconds
    }

    func contents(of path: FilePath) -> Data? {
        files[path.string]
    }

    func list(_ path: FilePath, includeHidden: Bool) async throws -> [FileItem] { [] }

    func stat(_ path: FilePath) async throws -> FileItem {
        if let data = files[path.string] {
            return FileItem(path: path, name: path.lastComponent, isDirectory: false, size: Int64(data.count))
        }
        if directories.contains(path.string) {
            return FileItem(path: path, name: path.lastComponent, isDirectory: true)
        }
        throw FileProviderError.notFound(path)
    }

    func createDirectory(_ path: FilePath) async throws { directories.insert(path.string) }

    func createFile(_ path: FilePath) async throws {
        guard files[path.string] == nil else { throw FileProviderError.alreadyExists(path) }
        files[path.string] = Data()
    }

    func delete(_ path: FilePath, recursive: Bool) async throws {
        files.removeValue(forKey: path.string)
        directories.remove(path.string)
    }

    func moveToTrash(_ path: FilePath) async throws {
        throw FileProviderError.unsupported("InMemoryFileProvider has no Trash")
    }

    func move(from source: FilePath, to destination: FilePath) async throws {
        guard let data = files[source.string] else { throw FileProviderError.notFound(source) }
        guard files[destination.string] == nil else { throw FileProviderError.alreadyExists(destination) }
        files[destination.string] = data
        files.removeValue(forKey: source.string)
    }

    func copy(from source: FilePath, to destination: FilePath) async throws {
        guard let data = files[source.string] else { throw FileProviderError.notFound(source) }
        guard files[destination.string] == nil else { throw FileProviderError.alreadyExists(destination) }
        files[destination.string] = data
    }

    func rename(_ path: FilePath, to newName: String) async throws -> FilePath {
        let destination = path.parent.appending(newName)
        try await move(from: path, to: destination)
        return destination
    }

    func setPermissions(_ path: FilePath, mode: UInt16) async throws {}

    func volumeInfo(for path: FilePath) async throws -> VolumeInfo? { nil }

    func readChunks(_ path: FilePath, startingAt offset: Int64) async -> AsyncThrowingStream<Data, Error> {
        let data = files[path.string]
        let delay = delayPerChunkNanoseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let data else {
                    continuation.finish(throwing: FileProviderError.notFound(path))
                    return
                }
                let chunkSize = 4096
                var index = Int(offset)
                while index < data.count {
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    if Task.isCancelled { break }
                    let end = min(index + chunkSize, data.count)
                    continuation.yield(data.subdata(in: index..<end))
                    index = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func openWriteSink(_ path: FilePath, mode: WriteMode) async throws -> any FileWriteSink {
        switch mode {
        case .createFailIfExists:
            guard files[path.string] == nil else { throw FileProviderError.alreadyExists(path) }
            files[path.string] = Data()
        case .resumeAppend:
            if files[path.string] == nil { files[path.string] = Data() }
        }
        return InMemoryWriteSink(provider: self, path: path)
    }

    fileprivate func append(_ data: Data, to path: FilePath) {
        files[path.string, default: Data()].append(data)
    }
}

final class InMemoryWriteSink: FileWriteSink, @unchecked Sendable {
    private let provider: InMemoryFileProvider
    private let path: FilePath

    init(provider: InMemoryFileProvider, path: FilePath) {
        self.provider = provider
        self.path = path
    }

    func write(_ data: Data) async throws {
        await provider.append(data, to: path)
    }

    func finish() async throws {}
}
