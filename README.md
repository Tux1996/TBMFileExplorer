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

Phase 2 (local dual-pane browser) working; Phase 3 (the `FileProvider`
abstraction the UI is built on) done alongside it. Nothing remote yet —
see `ROADMAP.md`.

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
Packages/TBMFileKit/   Local Swift package: FileProvider protocol, models, LocalFileProvider
App/                   SwiftUI app target: Views, ViewModels, Models, QuickLook, Utilities
project.yml            XcodeGen spec — source of truth for the Xcode project
```

## Testing

```bash
cd Packages/TBMFileKit && swift test
```

Runs `LocalFileProvider`'s test suite (directory listing, hidden files, collision handling, symlinks, path traversal safety). See [`TESTING.md`](TESTING.md).

## Connecting to a server

Not implemented yet — SFTP is Phase 4. See `ROADMAP.md` for the plan (Citadel, Keychain-backed credentials, host fingerprint confirmation).

## Security

No plaintext credentials anywhere in this codebase or on disk — see [`SECURITY.md`](SECURITY.md).
