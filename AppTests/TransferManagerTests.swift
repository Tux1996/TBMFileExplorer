import Foundation
import Testing
import TBMFileKit
@testable import TBM_File_Explorer

private struct FixedCollisionResolver: TransferCollisionResolving {
    let resolution: CollisionResolution
    let applyToAll: Bool

    func resolveCollision(filename: String, sourceSize: Int64?, destinationSize: Int64?) async -> (resolution: CollisionResolution, applyToAll: Bool) {
        (resolution, applyToAll)
    }
}

@MainActor
private func waitUntilAllTerminal(_ manager: TransferManager, timeoutSeconds: Double = 5) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while manager.jobs.contains(where: { !$0.status.isTerminal }) && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
struct TransferManagerTests {
    private func makeProviders() -> (source: InMemoryFileProvider, destination: InMemoryFileProvider) {
        (
            InMemoryFileProvider(identifier: .local, displayName: "Source"),
            InMemoryFileProvider(identifier: .sftp(connectionID: UUID()), displayName: "Destination")
        )
    }

    @Test func singleFileTransferCompletesWithMatchingContent() async throws {
        let (source, destination) = makeProviders()
        await source.seedFile(FilePath("/src/file.txt"), contents: Data("hello world".utf8))
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/file.txt"), name: "file.txt")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .replace, applyToAll: false)
        )
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.count == 1)
        #expect(manager.jobs.first?.status == .completed)
        let written = await destination.contents(of: FilePath("/dst/file.txt"))
        #expect(written == Data("hello world".utf8))
    }

    @Test func collisionSkipLeavesDestinationUntouched() async throws {
        let (source, destination) = makeProviders()
        await source.seedFile(FilePath("/src/file.txt"), contents: Data("new".utf8))
        await destination.seedFile(FilePath("/dst/file.txt"), contents: Data("original".utf8))
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/file.txt"), name: "file.txt")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .skip, applyToAll: false)
        )
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.isEmpty) // skipped — never even enqueued as a job
        let untouched = await destination.contents(of: FilePath("/dst/file.txt"))
        #expect(untouched == Data("original".utf8))
    }

    @Test func collisionReplaceOverwritesExistingContent() async throws {
        let (source, destination) = makeProviders()
        await source.seedFile(FilePath("/src/file.txt"), contents: Data("new".utf8))
        await destination.seedFile(FilePath("/dst/file.txt"), contents: Data("original".utf8))
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/file.txt"), name: "file.txt")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .replace, applyToAll: false)
        )
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.first?.status == .completed)
        let replaced = await destination.contents(of: FilePath("/dst/file.txt"))
        #expect(replaced == Data("new".utf8))
    }

    @Test func collisionKeepBothCreatesUniquelyNamedFile() async throws {
        let (source, destination) = makeProviders()
        await source.seedFile(FilePath("/src/file.txt"), contents: Data("new".utf8))
        await destination.seedFile(FilePath("/dst/file.txt"), contents: Data("original".utf8))
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/file.txt"), name: "file.txt")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .keepBoth, applyToAll: false)
        )
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.first?.status == .completed)
        #expect(manager.jobs.first?.filename != "file.txt")
        let original = await destination.contents(of: FilePath("/dst/file.txt"))
        #expect(original == Data("original".utf8))
        let newContents = await destination.contents(of: manager.jobs.first!.destinationPath)
        #expect(newContents == Data("new".utf8))
    }

    @Test func collisionResumeAppendsFromExistingDestinationSize() async throws {
        let (source, destination) = makeProviders()
        let fullContent = Data("0123456789".utf8)
        await source.seedFile(FilePath("/src/file.txt"), contents: fullContent)
        await destination.seedFile(FilePath("/dst/file.txt"), contents: Data("01234".utf8)) // first half already there
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/file.txt"), name: "file.txt")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .resume, applyToAll: false)
        )
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.first?.status == .completed)
        let final = await destination.contents(of: FilePath("/dst/file.txt"))
        #expect(final == fullContent)
    }

    @Test func applyToAllReusesFirstResolutionForRestOfBatch() async throws {
        let (source, destination) = makeProviders()
        for name in ["a.txt", "b.txt", "c.txt"] {
            await source.seedFile(FilePath("/src/\(name)"), contents: Data("new-\(name)".utf8))
            await destination.seedFile(FilePath("/dst/\(name)"), contents: Data("old-\(name)".utf8))
        }
        let manager = TransferManager()

        await manager.enqueueBatch(
            ["a.txt", "b.txt", "c.txt"].map { TransferRequest(sourcePath: FilePath("/src/\($0)"), name: $0) },
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .skip, applyToAll: true)
        )
        await waitUntilAllTerminal(manager)

        // "Apply to All" on the first collision (skip) means the resolver is
        // only consulted once — every file should be skipped, none transferred.
        #expect(manager.jobs.isEmpty)
        for name in ["a.txt", "b.txt", "c.txt"] {
            let contents = await destination.contents(of: FilePath("/dst/\(name)"))
            #expect(contents == Data("old-\(name)".utf8))
        }
    }

    @Test func cancellingARunningTransferStopsIt() async throws {
        let (source, destination) = makeProviders()
        await source.setDelayPerChunk(10_000_000) // 10ms/chunk so cancel has time to land
        await source.seedFile(FilePath("/src/big.bin"), contents: Data(repeating: 0x42, count: 4096 * 50))
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/big.bin"), name: "big.bin")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .replace, applyToAll: false)
        )
        try await Task.sleep(nanoseconds: 50_000_000) // let it get partway through
        guard let jobID = manager.jobs.first?.id else {
            Issue.record("expected a job to have been enqueued")
            return
        }
        manager.cancel(jobID)
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.first?.status == .cancelled)
    }

    @Test func pauseThenResumeStillCompletes() async throws {
        let (source, destination) = makeProviders()
        await source.setDelayPerChunk(10_000_000)
        await source.seedFile(FilePath("/src/big.bin"), contents: Data(repeating: 0x7, count: 4096 * 20))
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/big.bin"), name: "big.bin")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .replace, applyToAll: false)
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let jobID = manager.jobs.first?.id else {
            Issue.record("expected a job to have been enqueued")
            return
        }
        manager.pause(jobID)
        #expect(manager.jobs.first?.status == .paused)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.jobs.first?.status == .paused) // still paused, hasn't silently kept going

        manager.resumePaused(jobID)
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.first?.status == .completed)
        let final = await destination.contents(of: FilePath("/dst/big.bin"))
        #expect(final?.count == 4096 * 20)
    }

    @Test func retryResetsAFailedJobAndCanSucceed() async throws {
        let (source, destination) = makeProviders()
        // Nothing seeded at the source path yet — first attempt fails with notFound.
        let manager = TransferManager()

        await manager.enqueueBatch(
            [TransferRequest(sourcePath: FilePath("/src/missing.txt"), name: "missing.txt")],
            source: source, sourceDisplayName: "Source",
            destination: destination, destinationDisplayName: "Destination",
            destinationDirectory: FilePath("/dst"),
            collisionResolver: FixedCollisionResolver(resolution: .replace, applyToAll: false)
        )
        await waitUntilAllTerminal(manager)
        guard let jobID = manager.jobs.first?.id else {
            Issue.record("expected a job to have been enqueued")
            return
        }
        guard case .failed = manager.jobs.first!.status else {
            Issue.record("expected the first attempt to fail since nothing was seeded")
            return
        }

        // Now the file exists — retrying the same job should succeed this time.
        await source.seedFile(FilePath("/src/missing.txt"), contents: Data("now it exists".utf8))
        manager.retry(jobID)
        await waitUntilAllTerminal(manager)

        #expect(manager.jobs.first?.status == .completed)
        #expect(manager.jobs.first?.retryCount == 1)
        let final = await destination.contents(of: FilePath("/dst/missing.txt"))
        #expect(final == Data("now it exists".utf8))
    }
}
