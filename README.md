# TBM File Explorer

A dual-pane macOS file manager for moving files between a MacBook, external
drives, and remote servers (SFTP/FTP/SMB) — starting with local Mac browsing
and built to grow into SFTP support for your own Linux server or homelab.

Native Swift/SwiftUI + AppKit. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for why
(short version: no GPL code, no Java/Swing — see that doc for the muCommander
evaluation), [`DEPENDENCIES.md`](DEPENDENCIES.md) for every third-party library
considered and its license, and [`ROADMAP.md`](ROADMAP.md) for what's done vs.
planned.

## Status

Phase 2 (local dual-pane browser) and Phase 3 (the `FileProvider` abstraction
the UI is built on) are done. Phase 4 (SFTP) has a working, tested
`SFTPFileProvider` and a Connection Manager UI — password and unencrypted-key
auth, host-key trust-on-first-use, list/upload/download/rename/move/delete —
with real, documented gaps (encrypted keys, RSA/ECDSA) rather than silent
failures. See `ROADMAP.md` for the full breakdown.

## Requirements

- macOS 14+ to run the app; Xcode 16+ / Swift 5.10+ to build it
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the `.xcodeproj` is generated, not committed

## Build & run

```bash
xcodegen generate
xcodebuild -project TBMFileExplorer.xcodeproj -scheme TBMFileExplorer -configuration Debug build
open "$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'TBMFileExplorer-*' | head -1)/Build/Products/Debug/TBM File Explorer.app"
```

Or just open `TBMFileExplorer.xcodeproj` in Xcode after running `xcodegen generate` and hit Run.

Re-run `xcodegen generate` any time `project.yml` changes, or after pulling changes that touched it.

## Project layout

```
Packages/TBMFileKit/   Local Swift package: FileProvider protocol, models, LocalFileProvider, SFTP/
App/                   SwiftUI app target: Views, ViewModels, Models, QuickLook, Utilities
project.yml            XcodeGen spec — source of truth for the Xcode project
```

## Testing

```bash
cd Packages/TBMFileKit && swift test
```

Runs the full suite — `LocalFileProvider` (directory listing, hidden files, collision handling, symlinks, path traversal safety), the OpenSSH key loader and known-hosts store, and (if the disposable local Docker SFTP server from `TESTING.md` is running) 11 integration tests against a **real SFTP server**, not mocks. See [`TESTING.md`](TESTING.md) for how to start that server.

## Connecting to a server

Click the **+** next to "Servers" in the sidebar to add an SFTP connection (password or an unencrypted ed25519 key — see `ARCHITECTURE.md` §10 for why encrypted keys and RSA/ECDSA aren't supported yet). Click a saved server, or use its context menu, to connect it into either pane. First connection to a new host shows its fingerprint for you to verify before trusting it.

## Security

No plaintext credentials anywhere in this codebase or on disk — see [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) — matches the license of most of the third-party libraries this project builds on (see `DEPENDENCIES.md`). No GPL code is incorporated; see `ARCHITECTURE.md` §1 for why muCommander (GPLv3) was evaluated and not used as a base.
