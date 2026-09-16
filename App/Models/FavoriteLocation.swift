import Foundation
import TBMFileKit

/// A sidebar shortcut into a location on some provider. Only `.local` favorites
/// exist today; remote favorites become meaningful once `ConnectionProfile`
/// exists (Phase 4) — the `providerID` field is already shaped for that.
struct FavoriteLocation: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var path: FilePath
    var systemImage: String
    var providerID: FileProviderIdentifier

    static func standardFavorites() -> [FavoriteLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func favorite(_ name: String, _ url: URL, _ icon: String) -> FavoriteLocation {
            FavoriteLocation(name: name, path: FilePath(url.path), systemImage: icon, providerID: .local)
        }
        var favorites: [FavoriteLocation] = [
            favorite("Home", home, "house"),
            favorite("Desktop", home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            favorite("Documents", home.appendingPathComponent("Documents"), "doc"),
            favorite("Downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            favorite("Applications", URL(fileURLWithPath: "/Applications"), "square.grid.2x2")
        ]
        let projects = home.appendingPathComponent("Projects")
        if fm.fileExists(atPath: projects.path) {
            favorites.append(favorite("Projects", projects, "hammer"))
        }
        return favorites
    }
}

/// A mounted local volume (internal drive, external SSD, USB) for the sidebar's
/// "Locations" section.
struct MountedVolume: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var path: FilePath
    var isRemovable: Bool

    static func currentVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = values.volumeName ?? url.lastPathComponent
            return MountedVolume(
                name: name,
                path: FilePath(url.path),
                isRemovable: values.volumeIsRemovable ?? false
            )
        }
    }
}
