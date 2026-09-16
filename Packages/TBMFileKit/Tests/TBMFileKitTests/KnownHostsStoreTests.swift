import Foundation
import Testing
@testable import TBMFileKit

struct KnownHostsStoreTests {
    private func makeStore() -> (KnownHostsStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("known_hosts-\(UUID().uuidString).json")
        return (KnownHostsStore(storeURL: url), url)
    }

    @Test func unknownHostReportsUnknown() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let status = store.status(host: "example.com", port: 22, presentedKeyLine: "ssh-ed25519 AAAA")
        #expect(status == .unknown)
    }

    @Test func trustedHostWithSameKeyIsTrusted() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.trust(host: "example.com", port: 22, keyLine: "ssh-ed25519 AAAA comment")
        let status = store.status(host: "example.com", port: 22, presentedKeyLine: "ssh-ed25519 AAAA othercomment")
        #expect(status == .trusted) // comment differs, key blob doesn't — still trusted
    }

    @Test func changedKeyIsReportedAsChanged() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.trust(host: "example.com", port: 22, keyLine: "ssh-ed25519 AAAA")
        let status = store.status(host: "example.com", port: 22, presentedKeyLine: "ssh-ed25519 BBBB")
        guard case .changed(let previous) = status else {
            Issue.record("expected .changed, got \(status)")
            return
        }
        #expect(previous == "ssh-ed25519 AAAA")
    }

    @Test func trustPersistsAcrossInstances() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.trust(host: "gibson.local", port: 22, keyLine: "ssh-ed25519 CCCC")
        let reloaded = KnownHostsStore(storeURL: url)
        #expect(reloaded.status(host: "gibson.local", port: 22, presentedKeyLine: "ssh-ed25519 CCCC") == .trusted)
    }

    @Test func differentPortsAreTrackedSeparately() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.trust(host: "example.com", port: 22, keyLine: "ssh-ed25519 AAAA")
        #expect(store.status(host: "example.com", port: 2222, presentedKeyLine: "ssh-ed25519 AAAA") == .unknown)
    }
}
