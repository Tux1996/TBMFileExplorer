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

/// Wire format for the remote case (and for a multi-selection drag of any
/// kind), carried as a private, in-process-only `NSItemProvider` data
/// representation alongside (or instead of) a `URL`. A single dragged row
/// only ever produces one `NSItemProvider` via SwiftUI's `.onDrag`, so
/// dragging a multi-item selection has to bundle every selected path into
/// that one provider rather than one-provider-per-file — `paths` is why this
/// is an array even for a single-item drag.
struct DraggedFileReference: Codable {
    let providerKey: String
    let paths: [String]
}

enum DragPayloadKind {
    static let internalReferenceType = UTType(exportedAs: "com.techbymoe.TBMFileExplorer.internal-file-ref", conformingTo: .data)

    /// `items` is everything this one drag session should carry — the whole
    /// current selection if the dragged row is part of a multi-selection,
    /// or just that one row otherwise (see call site in `FileListView`).
    static func makeItemProvider(items: [FileItem], providerIdentifier: FileProviderIdentifier) -> NSItemProvider {
        let provider = NSItemProvider()
        // Only a single local file gets the real file-URL representation —
        // Finder-style multi-file drag-out isn't supported by this one-
        // provider-per-session approach, only multi-file drag *within* the app.
        if case .local = providerIdentifier, items.count == 1, let first = items.first {
            provider.registerObject(first.path.localURL as NSURL, visibility: .all)
        }
        let reference = DraggedFileReference(providerKey: providerIdentifier.stableKey, paths: items.map { $0.path.string })
        if let data = try? JSONEncoder().encode(reference) {
            provider.registerDataRepresentation(forTypeIdentifier: internalReferenceType.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    /// Resolves a drop's `NSItemProvider`s into individual file references,
    /// preferring the internal reference (so a same-app drag — remote or a
    /// multi-selection — round-trips its true source and every selected
    /// path) and falling back to a plain file `URL` for a single local file
    /// or a Finder import.
    static func resolve(_ providers: [NSItemProvider], completion: @escaping ([DragPayloadItem]) -> Void) {
        var results = [[DragPayloadItem]?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(internalReferenceType.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: internalReferenceType.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data, let reference = try? JSONDecoder().decode(DraggedFileReference.self, from: data) else { return }
                    results[index] = reference.paths.map { .remote(providerKey: reference.providerKey, path: $0) }
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    results[index] = [.local(url)]
                }
            }
        }
        group.notify(queue: .main) {
            completion(results.compactMap { $0 }.flatMap { $0 })
        }
    }
}
