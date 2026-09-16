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
│  Credential Manager     (Implemented — Keychain-backed)        │
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
}
```

`copy` is same-provider only (e.g. duplicating a file within one SFTP server) — each provider streams it internally in fixed-size chunks rather than buffering the whole file, but there's no protocol-level `readStream`/`writeStream` yet. That's deliberately deferred to Phase 5: the Transfer Engine is what actually needs a generic streaming read/write surface (to drive progress/pause/resume across *different* providers), and designing that surface before a second concrete provider (`SFTPFileProvider`) existed to validate it against would have been guessing. `SFTPFileProvider.copy` already found a real protocol subtlety worth recording here: SFTP servers may return **short reads that are not EOF** (this Docker test server caps a single read response at 64 KB regardless of the requested length) — a copy loop must keep reading from the new offset until a truly empty response, not stop early on `bytesRead < requested`. Whatever streaming API Phase 5 introduces needs to preserve that behavior.

Design notes:
- `FilePath` is a plain string wrapper, not `URL` — remote paths are POSIX paths on the remote host and forcing them through `URL`'s scheme/host model buys nothing and risks subtle percent-encoding bugs.
- Every method is `async throws`; there is no synchronous entry point, so a provider can never be called in a way that blocks the main actor. Directory enumeration, hashing, and network calls all happen off the main thread by construction.
- `moveToTrash` is intentionally on the protocol (not local-only outside it) so the UI can call one method and let the provider decide (`.unsupported` for remote — the UI then falls back to a permanent-delete confirmation instead of silently doing something else). `PaneView` picks the right context-menu item and the right `TabViewModel` method (`moveToTrash` vs. `deletePermanently`) by checking `capabilities.canTrash`.

`LocalFileProvider` (Implemented, `Packages/TBMFileKit/Sources/TBMFileKit/LocalFileProvider.swift`) implements this today using `FileManager` + batched `URLResourceValues` for directory listings (fast with thousands of entries) and `lstat`/`getpwuid_r`/`getgrgid_r` for permissions/owner/group/symlink data that `FileManager` doesn't expose directly.

`SFTPFileProvider` (Implemented, `Packages/TBMFileKit/Sources/TBMFileKit/SFTP/SFTPFileProvider.swift`) implements this over a real Citadel SSH/SFTP connection — see §10 below for what it does and doesn't cover yet.

## 4. Concurrency & performance

- All `FileProvider` calls are `async`. Directory listing for local folders runs on a background `Task`; `SFTPFileProvider` is a Swift `actor` (not a class) so its mutable connection state (the live `SSHClient`/`SFTPClient`) can't be corrupted by concurrent calls from the UI, and its I/O rides on Citadel/SwiftNIO's own non-blocking event loop.
- View models (`@Observable`) hold only already-fetched, `Sendable` data (`[FileItem]`); no protocol types leak into SwiftUI views.
- Large-directory responsiveness: local listing loads metadata via a single batched `URLResourceValues` fetch per entry (no repeated `stat` round-trips per column).

## 5. Persistence

- **Non-sensitive** app state: `ConnectionProfile`s (Implemented) persist as a plain JSON array via `ConnectionStore` (`Packages/TBMFileKit/Sources/TBMFileKit/SFTP/ConnectionStore.swift`) at `~/Library/Application Support/TBM File Explorer/connections.json`. Decided in Phase 4 rather than guessed in Phase 1: a personal list of a handful of servers doesn't need SwiftData/SQLite's query surface — that call is worth revisiting once `TransferJob` history (Phase 5) needs to be queried/filtered rather than just round-tripped, at which point a structured store may replace this for that specific model, not necessarily for `ConnectionProfile` too. Window layout, tabs, favorites, and recent locations remain `UserDefaults`-appropriate simple state, not yet wired up.
- **Sensitive** data (passwords) → macOS Keychain only, via `CredentialManager` (`Packages/TBMFileKit/Sources/TBMFileKit/SFTP/CredentialManager.swift`), referenced from a `ConnectionProfile` by its `id` (a generic-password item keyed by `"<id>.password"`), never inlined into the JSON file above. No plaintext secret ever touches disk. SSH key *passphrases* have the same storage path designed in (`CredentialKind.keyPassphrase`) but nothing writes to it yet — see §10, encrypted-key support isn't implemented.
- **Host keys**: a separate small JSON file (`KnownHostsStore`, `known_hosts.json` in the same directory) tracks trust-on-first-use state per `host:port`. Deliberately not the user's real `~/.ssh/known_hosts` — see §10.

## 6. Security posture (see also `SECURITY.md`)

- No sandbox is enabled yet (`com.apple.security.app-sandbox = false` in the generated project). A file manager whose entire purpose is arbitrary local/remote filesystem access gets little from the sandbox without also shipping security-scoped bookmarks for every external volume/share, which is real work with no user yet to benefit from it. This is a deliberate, documented Phase-1 tradeoff, not an oversight — revisit before any wider distribution.
- Path traversal: remote path joins go through `FilePath.appending(_:)`, which normalizes `.`/`..` server-side-safely rather than string-concatenating user input into shell/SFTP commands.
- Shell commands: local Terminal-here uses `Process` with an argument array (never `/bin/sh -c` + a concatenated string). "Open SSH Session" (`WorkspaceActions.openSSHSession`) has a stricter bar — it has to hand a *string* to `osascript`/Terminal, so the remote path is shell-quoted (`'...'` with embedded quotes escaped) before being embedded in the `ssh -t` command, and that whole invocation is separately AppleScript-string-escaped before being embedded in the `do script` payload. Two distinct escaping steps for two distinct layers, not one that happens to work for today's inputs.
- Host identity is never taken on faith: every new SFTP host goes through `KnownHostsStore` + a confirmation dialog showing the SHA256 fingerprint (§10), the same trust-on-first-use model `ssh` itself uses.
- Docker Compose actions (Phase 8) aren't implemented yet; the confirmation requirement for destructive ones carries forward to whenever they land.

## 7. SMB note

`AMSMB2` (the standard Swift wrapper for SMB2/3) statically links `libsmb2`, which is LGPL-2.1 — that would make the SMB module LGPL and require dynamic linking for redistribution. Rather than take that on now, Phase 9 plans to first try mounting SMB shares via macOS's own `NetFS` APIs (same mechanism as Finder's "Connect to Server") and exposing the resulting `/Volumes/...` mount through `LocalFileProvider`, which needs zero extra dependencies and zero license entanglement. `AMSMB2` stays documented in `DEPENDENCIES.md` as a fallback if browsing *unmounted* SMB shares turns out to be required.

## 8. Data models (see `DEPENDENCIES.md` for nothing here — these are ours)

Implemented today: `FilePath`, `FileItem`, `FileProviderCapabilities`, `VolumeInfo`, `ConnectionProfile`, `FavoriteLocation` *(minimal version, for the sidebar)*.

Planned (designed, not yet coded — they don't exist until a phase needs them, per the project's "no placeholder implementations" rule):
`ServerBookmark`, `TransferJob`, `TransferQueue`, `TransferProgress`, `RecentLocation`, `FilePermission` (UI-facing chmod model, distinct from the raw `UInt16` mode on `FileItem`), `ServerInfo`, `ApplicationSettings`.

## 9. What exists right now vs. the phase plan

See `ROADMAP.md` for the full phase breakdown. In one line: Phase 1–3 are done; Phase 4 (SFTP) has a working, tested `SFTPFileProvider` plus a Connection Manager UI, with real gaps documented in §10 rather than silently papered over; Phases 5+ are planned.

## 10. SFTP specifics (Phase 4)

`SFTPFileProvider` (`Packages/TBMFileKit/Sources/TBMFileKit/SFTP/`) is built on Citadel (see `DEPENDENCIES.md`) and is a Swift `actor`, not a class — see §4.

**What works, verified against a real server** (not mocks — see `TESTING.md` for the disposable local Docker SFTP container this was tested against): password authentication; unencrypted-ed25519-key authentication; trust-on-first-use host key confirmation (and re-confirmation when a key *changes*, not just when it's new); list/stat/mkdir/create-file/rename/move/delete/set-permissions; same-server file duplication via chunked copy; every "never silently overwrite" path (create-existing, move-onto-existing) actually throwing instead of clobbering.

**Three real Citadel behaviors this project had to discover by testing against a live server, not from its docs** (recorded here so nobody re-derives them the hard way):
1. Citadel throws `SFTPMessage.Status` **directly** from most request paths, not always wrapped in `SFTPError.errorStatus(_:)` — `SFTPFileProvider`'s error mapping checks for both shapes.
2. A short SFTP read is **not** end-of-file — a server may return fewer bytes than requested for reasons unrelated to EOF (the test container caps single reads at 64 KB). `SFTPFileProvider.copy`'s chunk loop only stops on a truly empty response; an earlier version that also stopped on `bytesRead < requested` silently truncated files past the first short read, and the integration test suite caught it.
3. **`ClientHandshakeHandler` gives the whole handshake-plus-authentication sequence a hardcoded 10-second budget, with no public way to configure it.** Host-key validation runs inside that window. The original design called the async host-key confirmation UI directly from `validateHostKey`'s callback — which worked fine against the always-instant test-suite confirmers, and then failed on the very first real connection to an actual server, every time, with `NIOCore.ChannelError.connectTimeout`, because a real person takes longer than 10 seconds to read a fingerprint and click a button. The fix (`SFTPFileProvider.resolveHostKeyValidator()`): for an already-trusted host, validate synchronously against the stored key (`.trustedKeys`, no waiting). For a new or changed host, run a throwaway probe connection *first* — bogus credentials, whose only job is to capture the presented key during key exchange before failing auth a moment later — so the confirmation dialog runs against an already-completed connection attempt with no clock running, and only the *real*, timed connection (now using `.trustedKeys([confirmedKey])`, a synchronous check) begins afterward. `SFTPFileProviderIntegrationTests.slowHostKeyConfirmationDoesNotBlowTheLoginTimeout` simulates a 12-second-slow confirmation and asserts the connection still succeeds. This is also why the integration test suite is `@Suite(.serialized)` and shares one `KnownHostsStore` across most tests (see `TESTING.md`) — the probe step doubles the connection count for any not-yet-trusted host, and running many of those concurrently tripped the disposable test container's own connection throttling.

**Known gaps — Planned, not silently unsupported:**
- **Encrypted (passphrase-protected) private keys, and RSA/ECDSA keys of any kind.** Citadel has no public API to decrypt an OpenSSH private key or to parse non-ed25519 key material into its `SSHAuthenticationMethod` factories today (confirmed by reading its source — `SSHKeyDetection` can *detect* an encrypted key but nothing decrypts one). `OpenSSHEd25519KeyLoader` handles exactly the one format Citadel can consume (unencrypted ed25519) and throws a clear, actionable error — pointing at `ssh-keygen -p -N ""` as a workaround — for everything else, rather than pretending to support it. Revisit if Citadel adds this upstream, or if it becomes worth vendoring a decrypt routine.
- **Symlink target resolution and creation.** Citadel doesn't expose `SSH_FXP_READLINK`/`SSH_FXP_SYMLINK` publicly; `capabilities.canSymlink = false` and `FileItem.symlinkTarget` is always `nil` for SFTP items (the item is still correctly flagged `isSymlink` via the permission-bits type mask).
- **Free space / `df`-equivalent.** `volumeInfo(for:)` returns `nil` for SFTP — there's no standard SFTP query for it; that's what the Phase 8 server-info panel (via SSH `exec`) is for.
- **Cross-provider operations** (Mac↔server drag-drop, copy/paste, upload-from-Finder-drop into a server tab) are explicitly guarded to fail with a friendly "coming in the Transfer Manager" message rather than attempting something that would silently do the wrong thing — `FileProvider.copy`/`.move` are same-provider-only by design (§3), and real cross-provider transfer is Phase 5's job.
- **Manual UI click-through beyond connect/rename/delete/permissions/drag-drop.** The Add Server sheet, host-key confirmation dialog, connecting to a real server, renaming, deleting, setting permissions on a remote file, and local drag-and-drop have all been clicked through by hand against the user's actual server and Mac (this is what surfaced the login-timeout bug above and the drag-and-drop bug in §11, and confirmed both fixed). Drag-and-drop into/within a remote tab and the "host key changed" re-confirmation dialog specifically have not been — this environment has no way to script further clicks into the native window (see `TESTING.md`), so that's on the user or a future session with hands on the app.

## 11. A real macOS SwiftUI bug found by testing: `List` + `.draggable`/`.dropDestination`

Drag-and-drop (Phase 2, local files) looked complete in code — `.draggable`/`.dropDestination` (the newer, `Transferable`-based API) on both file rows and the containing `List`, matching Apple's own examples. It did not actually work: dragging showed the normal macOS "accept" cursor, but releasing over any target — a subfolder row, the pane background, a drop from Finder — silently did nothing. No error, no crash, no file moved.

This is a real, reported limitation of `.draggable`/`.dropDestination` nested inside a macOS `List` (which is backed by `NSTableView`, not a plain `ScrollView`) — the newer Transferable-based drag machinery doesn't reliably hand off to SwiftUI's per-row and per-container drop handlers there, even though the identical pattern works on iOS. The fix (`App/Views/FileListView.swift`) was to drop back to the older, `NSItemProvider`-based `.onDrag`/`.onDrop` pair, which has been part of SwiftUI since its first release and is far more thoroughly exercised against `List` on macOS specifically. Resolving the dropped `NSItemProvider`s back into `URL`s needs its own small async fan-in (`loadObject(ofClass: URL.self)` per provider, joined with a `DispatchGroup`) since the older API predates Swift concurrency.

Worth remembering for any *other* `List`-hosted drag-and-drop added later in this app (e.g. dragging transfer-queue rows in Phase 5): prefer `.onDrag`/`.onDrop` over `.draggable`/`.dropDestination` inside a `List` on macOS until Apple's own bug tracker shows this fixed.
