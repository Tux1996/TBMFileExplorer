import Foundation
import TBMFileKit
import UniformTypeIdentifiers

extension FileProviderIdentifier {
    /// A stable string identity for looking up a live provider instance
    /// later — used only for matching drag payloads back to an open tab's
    /// provider, never persisted.
    var stableKey: String {
        switch self {
        case .local: "local"
        case .sftp(let id): "sftp:\(id.uuidString)"
        case .ftp(let id): "ftp:\(id.uuidString)"
        case .smb(let id): "smb:\(id.uuidString)"
        }
    }
}

/// What a drag actually carries: a real local file (draggable to/from Finder
/// as an ordinary file URL) or a reference into a remote provider (meaningful
/// only within this running app — dragging a server row produces a `file://`
/// URL that doesn't exist locally, so remote rows need their own payload
/// carrying which provider and path they came from).
enum DragPayloadItem {
    case local(URL)
    case remote(providerKey: String, path: String)
}

/// Wire format for the remote case, carried as a private, in-process-only
/// `NSItemProvider` data representation alongside (or instead of) a `URL`.
struct DraggedFileReference: Codable {
    let providerKey: String
    let path: String
}

enum DragPayloadKind {
    static let internalReferenceType = UTType(exportedAs: "com.techbymoe.TBMFileExplorer.internal-file-ref", conformingTo: .data)

    static func makeItemProvider(item: FileItem, providerIdentifier: FileProviderIdentifier) -> NSItemProvider {
        let provider = NSItemProvider()
        if case .local = providerIdentifier {
            provider.registerObject(item.path.localURL as NSURL, visibility: .all)
        }
        let reference = DraggedFileReference(providerKey: providerIdentifier.stableKey, path: item.path.string)
        if let data = try? JSONEncoder().encode(reference) {
            provider.registerDataRepresentation(forTypeIdentifier: internalReferenceType.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    /// Resolves a drop's `NSItemProvider`s, preferring the internal reference
    /// (so a same-app remote-row drag round-trips its true source) and
    /// falling back to a plain file `URL` for local files and Finder imports.
    static func resolve(_ providers: [NSItemProvider], completion: @escaping ([DragPayloadItem]) -> Void) {
        var results = [DragPayloadItem?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(internalReferenceType.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: internalReferenceType.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data, let reference = try? JSONDecoder().decode(DraggedFileReference.self, from: data) else { return }
                    results[index] = .remote(providerKey: reference.providerKey, path: reference.path)
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    results[index] = .local(url)
                }
            }
        }
        group.notify(queue: .main) {
            completion(results.compactMap { $0 })
        }
    }
}
