# Architecture

Status key used throughout this document and the rest of the repo:
**Implemented** — working code, exercised by the app or a test.
**Partially Implemented** — a real but incomplete slice exists.
**Planned** — designed here, no code yet.

## 1. Decision: native macOS app, not a muCommander fork

### Candidates evaluated

| Option | Verdict |
|---|---|
| Fork/embed muCommander (Java/Swing) | **Rejected** |
| Native Swift/SwiftUI + AppKit, reusing permissively-licensed protocol libraries | **Selected** |

### Why muCommander was rejected as a base

muCommander (`github.com/mucommander/mucommander`) is a real, still-active dual-pane manager with local/FTP/SFTP/SMB/archive/bookmark support — architecturally it is a good *reference*. But as a base it fails this project on three independent grounds, any one of which would be disqualifying:

1. **License.** muCommander is GPL-3.0-or-later. Embedding or linking its source would put the whole application under GPLv3. The prompt for this project requires that to be clearly documented if chosen — it is documented here as the reason it was *not* chosen. We keep it strictly as a design reference; no muCommander source is copied into this repository.
2. **Toolkit.** It's Java/Swing. The project explicitly calls for a modern native macOS look (SF Symbols, translucent materials, native context menus, native drag/drop) and explicitly says to avoid "an old Java/Linux utility appearance." Swing cannot produce that; there is no incremental path from Swing to AppKit/SwiftUI.
3. **Language boundary.** There is no practical way to reuse Java filesystem/transfer code from a Swift/AppKit UI without a JNI or subprocess bridge, which would add more complexity than it saves given that mature, permissively-licensed Swift-native equivalents exist for every protocol muCommander covers (see `DEPENDENCIES.md`).

**What we do take from muCommander:** the conceptual shape of its virtual filesystem abstraction (a single `AbstractFile`-like interface implemented per protocol) validates this project's own `FileProvider` protocol design (§3 below). That idea is not copyrightable, and our implementation is written from scratch against Swift's own concurrency and type system.

### Why native Swift/SwiftUI + AppKit

- Native Keychain, Quick Look, Finder-compatible drag & drop, and NSWorkspace integration are first-class only from within an AppKit/SwiftUI app.
- Every remote protocol this project needs has a mature, permissively-licensed, actively maintained Swift-native library (or an Apple system framework) — see `DEPENDENCIES.md`. Nothing here requires reinventing SSH crypto, TLS, or archive parsing.
- SwiftUI (`NavigationSplitView`, `Table`, `Observation`) gives us the dual-pane/sidebar/inspector layout the spec asks for with far less code than hand-rolled AppKit, while dropping to AppKit (`NSViewRepresentable`, `QLPreviewPanel`, `NSWorkspace`) exactly where SwiftUI doesn't reach.
- Performance and memory control for multi-gigabyte streaming transfers is easier to reason about in Swift than through a JVM bridge.

### License posture of the resulting app

Because no GPL code is incorporated, this project uses the MIT license (see `LICENSE`), matching most of its dependencies. The one dependency to watch is SMB (see §7) — it is deliberately kept out of the license-critical path for now.

## 2. Layering

```
┌─────────────────────────────────────────────────────────────┐
│  App (SwiftUI + AppKit)                                      │
│  Views · ViewModels · Sidebar · Tabs · Inspector · Editor     │
├─────────────────────────────────────────────────────────────┤
│  TBMFileKit (local Swift package)                             │
│                                                                │
│  FileProvider protocol  ◄── the one thing the UI depends on   │
│    ├─ LocalFileProvider        (Implemented)                  │
│    ├─ SFTPFileProvider         (Planned, Phase 4)              │
│    ├─ FTPFileProvider          (Planned, Phase 6)              │
│    └─ SMBFileProvider          (Planned, Phase 9)              │
│                                                                │
│  Models: FileItem, FilePath, FilePermissions, VolumeInfo       │
│  (ConnectionProfile, TransferJob, etc. — see §8, Planned)      │
├─────────────────────────────────────────────────────────────┤
│  Transfer Engine        (Planned, Phase 5)                     │
│  Credential Manager     (Planned, Phase 4 — Keychain-backed)   │
│  Preview Engine         (Partially — QuickLook wrapper only)   │
│  Editor                 (Planned, Phase 7)                     │
│  Server Integration     (Planned, Phase 8 — custom server mode)│
│  Logging                (Planned)                               │
│  Settings               (Planned)                               │
└─────────────────────────────────────────────────────────────┘
```

`TBMFileKit` is a **local Swift package** (`Packages/TBMFileKit`), not just a folder of files inside the app target. That gives us a real compiler-enforced boundary: the App target can only see what `TBMFileKit` exports publicly, so "the UI doesn't know whether a file is local or remote" (a hard requirement from the prompt) is enforced by the module system, not just convention. As SFTP/FTP/SMB providers are added they become additional files in the same package (or split into `TBMFileKit`, `TBMTransferKit`, `TBMCredentialKit` if/when that split earns its keep — not done preemptively).

## 3. The `FileProvider` abstraction

This is the load-bearing type of the whole application. Every protocol implements it; the UI, transfer engine, and search never touch `FileManager`, `Citadel`, or any protocol-specific type directly.

```swift
public struct FilePath: Hashable, Sendable, CustomStringConvertible {
    public var string: String   // POSIX-style, protocol-relative (not a file:// URL)
}

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
    public var posixPermissions: UInt16?
    public var ownerName: String?
    public var groupName: String?
    public var id: FilePath { path }
}

public protocol FileProvider: Sendable {
    var identifier: FileProviderIdentifier { get }      // .local, .sftp(profileID), .ftp(profileID), ...
    var capabilities: FileProviderCapabilities { get }  // canSetPermissions, canSymlink, canResume, ...

    func list(_ path: FilePath, includeHidden: Bool) async throws -> [FileItem]
    func stat(_ path: FilePath) async throws -> FileItem
    func createDirectory(_ path: FilePath) async throws
    func createFile(_ path: FilePath) async throws
    func delete(_ path: FilePath, recursive: Bool) async throws
    func moveToTrash(_ path: FilePath) async throws        // local only; remote providers throw .unsupported
    func move(from: FilePath, to: FilePath) async throws
    func copy(from: FilePath, to: FilePath) async throws
    func rename(_ path: FilePath, to newName: String) async throws -> FilePath
    func setPermissions(_ path: FilePath, mode: UInt16) async throws
    func volumeInfo(for path: FilePath) async throws -> VolumeInfo?

    // Streaming read/write is what the Transfer Engine (Phase 5) drives; a provider
    // that can't stream throws .unsupported rather than buffering a whole file in RAM.
    func readStream(_ path: FilePath) async throws -> AsyncThrowingStream<Data, Error>
    func writeStream(_ path: FilePath) async throws -> FileWriteSink
}
```

Design notes:
- `FilePath` is a plain string wrapper, not `URL` — remote paths are POSIX paths on the remote host and forcing them through `URL`'s scheme/host model buys nothing and risks subtle percent-encoding bugs.
- Every method is `async throws`; there is no synchronous entry point, so a provider can never be called in a way that blocks the main actor. Directory enumeration, hashing, and network calls all happen off the main thread by construction.
- `moveToTrash` is intentionally on the protocol (not local-only outside it) so the UI can call one method and let the provider decide (`.unsupported` for remote — the UI then falls back to a "Delete permanently?" confirmation instead of silently doing something else).
- Streaming methods return `AsyncThrowingStream`/a sink rather than `Data`, per the prompt's explicit "never load an entire large file into RAM" requirement.

`LocalFileProvider` (Implemented, `Packages/TBMFileKit/Sources/TBMFileKit/LocalFileProvider.swift`) implements this today using `FileManager` + batched `URLResourceValues` for directory listings (fast with thousands of entries) and `lstat`/`getpwuid_r`/`getgrgid_r` for permissions/owner/group/symlink data that `FileManager` doesn't expose directly.

## 4. Concurrency & performance

- All `FileProvider` calls are `async`. Directory listing for local folders runs on a background `Task`; remote providers will run their I/O on whatever executor their underlying library uses (Citadel/SwiftNIO are already non-blocking).
- View models (`@Observable`) hold only already-fetched, `Sendable` data (`[FileItem]`); no protocol types leak into SwiftUI views.
- Large-directory responsiveness: local listing loads metadata via a single batched `URLResourceValues` fetch per entry (no repeated `stat` round-trips per column).

## 5. Persistence

- **Non-sensitive** app state (window layout, tabs, favorites, recent locations, per-connection non-secret settings, UI preferences) → `UserDefaults` for simple key/value settings now; a structured store (SwiftData or a small SQLite table) will replace it once `ConnectionProfile`/`TransferJob` history exist (Phase 4–5) and the data actually needs querying rather than just round-tripping. Decision deferred to Phase 4 rather than guessed now.
- **Sensitive** data (passwords, SSH key passphrases) → macOS Keychain only, referenced from `ConnectionProfile` by an opaque Keychain item identifier, never inlined. No plaintext secret ever touches disk. (Planned — Phase 4, no connections exist yet to store credentials for.)

## 6. Security posture (see also `SECURITY.md`)

- No sandbox is enabled yet (`com.apple.security.app-sandbox = false` in the generated project). A file manager whose entire purpose is arbitrary local/remote filesystem access gets little from the sandbox without also shipping security-scoped bookmarks for every external volume/share, which is real work with no user yet to benefit from it. This is a deliberate, documented Phase-1 tradeoff, not an oversight — revisit before any wider distribution.
- Path traversal: remote path joins go through `FilePath.appending(_:)`, which normalizes `.`/`..` server-side-safely rather than string-concatenating user input into shell/SFTP commands.
- Shell commands (Terminal integration, Docker Compose actions, Phase 8) are invoked via `Process`/SSH `exec` with argument arrays, never via a string passed to `/bin/sh -c`, and remote paths are never interpolated into a shell string without quoting.

## 7. SMB note

`AMSMB2` (the standard Swift wrapper for SMB2/3) statically links `libsmb2`, which is LGPL-2.1 — that would make the SMB module LGPL and require dynamic linking for redistribution. Rather than take that on now, Phase 9 plans to first try mounting SMB shares via macOS's own `NetFS` APIs (same mechanism as Finder's "Connect to Server") and exposing the resulting `/Volumes/...` mount through `LocalFileProvider`, which needs zero extra dependencies and zero license entanglement. `AMSMB2` stays documented in `DEPENDENCIES.md` as a fallback if browsing *unmounted* SMB shares turns out to be required.

## 8. Data models (see `DEPENDENCIES.md` for nothing here — these are ours)

Implemented today: `FilePath`, `FileItem`, `FileProviderCapabilities`, `VolumeInfo`.

Planned (designed, not yet coded — they don't exist until a phase needs them, per the project's "no placeholder implementations" rule):
`ConnectionProfile`, `ServerBookmark`, `TransferJob`, `TransferQueue`, `TransferProgress`, `FavoriteLocation` *(a minimal version is Implemented for the sidebar today)*, `RecentLocation`, `FilePermission` (UI-facing chmod model, distinct from the raw `UInt16` mode on `FileItem`), `ServerInfo`, `ApplicationSettings`.

## 9. What exists right now vs. the phase plan

See `ROADMAP.md` for the full phase breakdown. In one line: Phase 1 (this document + `DEPENDENCIES.md` + `ROADMAP.md`) is done; Phase 2 (local dual-pane browser) is started with the `FileProvider` boundary from Phase 3 already in place underneath it, because building the throwaway direct-`FileManager` version first and then refactoring would cost more than doing it right once.
