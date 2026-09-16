import Foundation
import Testing
@testable import TBMFileKit

struct LocalFileProviderTests {
    private func makeTempDirectory() throws -> FilePath {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TBMFileKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FilePath(url.path)
    }

    @Test func listReflectsCreatedFilesAndDirectories() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()

        try await provider.createDirectory(root.appending("Sub"))
        try await provider.createFile(root.appending("note.txt"))

        let items = try await provider.list(root, includeHidden: false)
        #expect(items.count == 2)
        #expect(items.contains { $0.name == "Sub" && $0.isDirectory })
        #expect(items.contains { $0.name == "note.txt" && !$0.isDirectory })
    }

    @Test func hiddenFilesAreFilteredUnlessRequested() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        try await provider.createFile(root.appending(".hidden"))

        let withoutHidden = try await provider.list(root, includeHidden: false)
        #expect(withoutHidden.isEmpty)

        let withHidden = try await provider.list(root, includeHidden: true)
        #expect(withHidden.count == 1)
    }

    @Test func createFileThrowsWhenAlreadyExists() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let target = root.appending("dup.txt")
        try await provider.createFile(target)

        await #expect(throws: FileProviderError.self) {
            try await provider.createFile(target)
        }
    }

    @Test func moveThrowsRatherThanSilentlyOverwriting() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let source = root.appending("a.txt")
        let destination = root.appending("b.txt")
        try await provider.createFile(source)
        try await provider.createFile(destination)

        await #expect(throws: FileProviderError.self) {
            try await provider.move(from: source, to: destination)
        }
    }

    @Test func renameMovesWithinSameDirectory() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let original = root.appending("old.txt")
        try await provider.createFile(original)

        let renamed = try await provider.rename(original, to: "new.txt")
        #expect(renamed.lastComponent == "new.txt")
        let items = try await provider.list(root, includeHidden: false)
        #expect(items.map(\.name) == ["new.txt"])
    }

    @Test func statReportsSymlinkTarget() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let target = root.appending("target.txt")
        try await provider.createFile(target)
        let linkPath = root.string + "/link.txt"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target.string)

        let item = try await provider.stat(FilePath(linkPath))
        #expect(item.isSymlink)
        #expect(item.symlinkTarget?.string == target.string)
    }

    @Test func pathAppendingRejectsTraversalSegments() {
        let base = FilePath("/home/techbymoe")
        let joined = base.appending("../../etc/passwd")
        #expect(joined.string == "/home/techbymoe/etc/passwd")
    }

    @Test func streamedWriteAndReadRoundTripsExactBytes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let path = root.appending("streamed.bin")
        // Larger than one 256 KB chunk, to exercise the loop.
        let payload = Data((0..<(300 * 1024)).map { UInt8($0 % 256) })

        let sink = try await provider.openWriteSink(path, mode: .createFailIfExists)
        for chunk in stride(from: 0, to: payload.count, by: 64 * 1024) {
            let end = min(chunk + 64 * 1024, payload.count)
            try await sink.write(payload.subdata(in: chunk..<end))
        }
        try await sink.finish()

        var readBack = Data()
        for try await chunk in await provider.readChunks(path, startingAt: 0) {
            readBack.append(chunk)
        }
        #expect(readBack == payload)
    }

    @Test func createFailIfExistsThrowsRatherThanOverwriting() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let path = root.appending("existing.bin")
        try await provider.createFile(path)

        await #expect(throws: FileProviderError.self) {
            _ = try await provider.openWriteSink(path, mode: .createFailIfExists)
        }
    }

    @Test func resumeAppendContinuesFromExistingEndOfFile() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let path = root.appending("resumed.bin")

        let firstHalf = Data("first half ".utf8)
        let firstSink = try await provider.openWriteSink(path, mode: .createFailIfExists)
        try await firstSink.write(firstHalf)
        try await firstSink.finish()

        let secondHalf = Data("second half".utf8)
        let resumedSink = try await provider.openWriteSink(path, mode: .resumeAppend)
        try await resumedSink.write(secondHalf)
        try await resumedSink.finish()

        var readBack = Data()
        for try await chunk in await provider.readChunks(path, startingAt: 0) {
            readBack.append(chunk)
        }
        #expect(readBack == firstHalf + secondHalf)
    }

    @Test func readChunksStartingAtOffsetSkipsLeadingBytes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let provider = LocalFileProvider()
        let path = root.appending("offset.bin")
        let payload = Data("0123456789".utf8)
        let sink = try await provider.openWriteSink(path, mode: .createFailIfExists)
        try await sink.write(payload)
        try await sink.finish()

        var readBack = Data()
        for try await chunk in await provider.readChunks(path, startingAt: 5) {
            readBack.append(chunk)
        }
        #expect(readBack == Data("56789".utf8))
    }
}
