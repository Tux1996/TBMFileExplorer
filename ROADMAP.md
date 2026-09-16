# Roadmap

Phases as specified for this project. Status reflects reality as of each update — see `ARCHITECTURE.md` for the status-key definitions.

## Phase 1 — Research & docs — **Implemented**
`ARCHITECTURE.md`, `DEPENDENCIES.md`, `ROADMAP.md` created. Architecture decided: native Swift/SwiftUI + AppKit, not a muCommander fork (GPLv3 + Swing both disqualifying). Candidate libraries identified and license-checked for SFTP/SSH, FTP, archives, and syntax highlighting.

## Phase 2 — Core macOS application — **Partially Implemented**
Target: main window, sidebar, dual-pane interface, local filesystem browsing, tabs, navigation, file operations, drag/drop, Quick Look.

Done:
- Main window with sidebar + dual pane (`NavigationSplitView`)
- Local filesystem browsing through `LocalFileProvider` (not raw `FileManager` in the UI — see Phase 3 note)
- Per-pane tabs (add/close/switch)
- Per-pane navigation: back/forward/up, editable path bar, refresh
- Sorting (name/size/modified/kind), folders-first toggle, hidden-file toggle
- File operations: new folder, rename, duplicate, move to Trash, copy, cut, paste, reveal in Finder, copy path
- Drag & drop: between panes, from Finder, into a subfolder — verified by hand (the original `.draggable`/`.dropDestination` implementation looked right but silently failed to complete drops on macOS `List`; fixed by switching to `.onDrag`/`.onDrop`, see `ARCHITECTURE.md` §4)
- Quick Look preview (Space) via `QLPreviewPanel`
- Basic Get Info panel

Not yet done (tracked below, not silently skipped):
- Icon/column view modes (List view only for now, as the spec allows: "Start with List view as the primary polished implementation")
- A checkbox-per-bit permissions UI — Get Info gained a numeric/octal chmod field in Phase 4 (works for local and SFTP, verified by hand against a real server), but not yet the owner/group/other × read/write/execute checkbox grid the original spec also asks for
- Tags
- Batch rename
- Local search UI (provider-level `list` exists; no search index/UI yet)

## Phase 3 — Common `FileProvider` abstraction — **Implemented** (pulled forward)
Originally sequenced after Phase 2, but built alongside it: the UI in Phase 2 already talks only to the `FileProvider` protocol (`Packages/TBMFileKit`), never to `FileManager` directly. Building the throwaway direct-`FileManager` version first and refactoring afterward would have cost more than doing the abstraction once. `LocalFileProvider` is the only concrete implementation so far.

## Phase 4 — SFTP — **Partially Implemented**

Done, and verified against a real server (see `ARCHITECTURE.md` §10 and `TESTING.md`):
- Citadel dependency added; `SFTPFileProvider` implements the full `FileProvider` protocol (list/stat/mkdir/create/rename/move/delete/setPermissions/same-server copy)
- Password authentication
- Unencrypted-ed25519 SSH-key authentication (`OpenSSHEd25519KeyLoader`)
- Host key trust-on-first-use + re-confirmation on change (`KnownHostsStore` + `SFTPHostKeyConfirming`, wired to a SwiftUI alert)
- `ConnectionProfile` model + JSON `ConnectionStore` + Keychain-backed `CredentialManager`
- Server Connection Manager UI: add/edit/delete sheet in the sidebar, connect into either pane — clicked through by hand against a real server, not just built
- 12 integration tests against a disposable local Docker SFTP server, plus unit tests for the key loader and known-hosts store — 3 real bugs caught this way, not by inspection: error-mapping, a copy-loop truncation bug, and a login-timeout bug that broke every real first connection until the host-key confirmation was moved outside Citadel's fixed 10-second handshake budget (see `ARCHITECTURE.md` §10)

Not yet done:
- Encrypted (passphrase-protected) keys, and RSA/ECDSA keys — blocked on a real gap in Citadel's public API (see `ARCHITECTURE.md` §10); not silently broken, throws a clear error pointing at a workaround
- Reconnect / keep-alive policy beyond "reconnect lazily on the next call if the connection dropped" (`ensureConnected()` already does that much; no exponential backoff or explicit keep-alive ping yet)
- Manual click-through of remaining remote-specific operations (drag-drop into/within a server tab — expected to show the "not supported yet" message by design, untested whether it actually does; the "host key changed" re-confirmation) — connecting, renaming, deleting, and setting permissions on a remote file have all been verified by hand against a real server, see `ARCHITECTURE.md` §10
- A large (multi-GB) transfer test — the copy path is chunked and doesn't buffer whole files, but hasn't been exercised past a few hundred KB test fixture

## Phase 5 — Transfer manager — **Partially Implemented**

Done, and covered by a real test suite (`AppTests/TransferManagerTests.swift`, 9 tests against an in-memory `FileProvider` fake — fast/deterministic, since the streaming primitives underneath already have their own real-disk/real-server tests in `TBMFileKitTests`):
- `FileProvider` gained `readChunks`/`openWriteSink` (chunked streaming read/write, with offset support for resuming) — the actual thing that makes cross-provider transfer possible, implemented for both `LocalFileProvider` and `SFTPFileProvider`
- `TransferJob` model + `TransferManager` (queue, concurrency limit, progress/speed/ETA tracking, pause/resume, cancel, retry)
- Collision handling: Replace / Skip / Keep Both / Resume / Cancel, with an "Apply to All" checkbox for the rest of a batch — Compare is not implemented (see below)
- Drag-and-drop and clipboard copy/paste between *different* providers (Mac↔server) now actually transfer, instead of showing "not supported yet" — same-provider operations still go through the direct `FileProvider.copy`/`.move` path unchanged
- A Transfers panel (sidebar → progress list with pause/resume/cancel/retry/remove) and a transfer summary in the main status bar
- Basic completion/failure notifications via `UserNotifications`, for transfers above a size threshold
- Two real concurrency bugs found by testing, not inspection: cancelling a transfer reported `.completed` instead of `.cancelled`, because `for try await` over an `AsyncThrowingStream` exits *silently* (not by throwing) when the consuming Task is cancelled — a genuine, easy-to-miss Swift Concurrency gotcha, fixed by re-checking `Task.checkCancellation()` immediately after the loop. And a failed transfer (bad source) could leave a stray empty file at the destination, because the destination write sink was opened before the source was verified readable.

Not yet done:
- Folder transfers between different providers (same-provider folder copy on SFTP was already a known Phase-4 gap; cross-provider folder transfer needs recursive enumeration + per-file job creation, not built yet) — currently skipped with a clear message rather than silently dropped
- "Compare" as a collision option (would need a checksum or byte-level diff before deciding)
- Hash verification after transfer (MD5/SHA-1/SHA-256) — not implemented
- A configurable concurrency-limit UI (the `maxConcurrentTransfers` property exists and defaults to 3, but nothing in the UI lets the user change it yet)
- Disconnect-specific notifications (only completion/failure are wired up)
- Manual click-through of the Transfers panel UI itself (progress bars, pause/cancel/retry buttons) and the collision dialog — a real Mac↔server drag transfer has been verified by hand and works (see `ARCHITECTURE.md` §12), but that only exercised the transfer completing quickly with no collision, not the rest of the panel

## Phase 6 — FTP/FTPS — **Planned**
`FTPFileProvider` via FilesProvider (see `DEPENDENCIES.md` for the fallback plan if it proves unmaintained), passive/active mode, TLS cert validation for FTPS.

## Phase 7 — Editor & Inspector — **Planned**
- Full Inspector panel (hash, image/video/audio metadata via `AVFoundation`/`ImageIO`)
- Built-in text editor (Highlightr-backed syntax highlighting) for config files
- Remote-file edit flow: download to temp → edit → verify unchanged remotely → upload → conflict warning

## Phase 8 — Custom server integrations — **Planned**
- A "Server Type: Custom" flag on a `ConnectionProfile` unlocking user-configurable sidebar shortcuts (e.g. Docker, Media, Backups, Logs, System, or whatever else the user's self-hosted setup includes) — paths and labels configured by the user, never hardcoded
- Server info panel (hostname, OS, kernel, uptime, CPU, memory, storage, load, IPs, Docker version) via SSH `exec`, fetched on demand only
- Docker Compose awareness (indicator on folders containing `docker-compose.yml`/`compose.yml`; Up/Down/Restart/Pull/Logs/Inspect via SSH exec, with confirmation on destructive actions)
- Copy SSH Command / Copy SFTP URL (never embedding a password)
- Open Terminal Here (local Terminal.app, or SSH session for remote)

## Phase 9 — SMB / network shares — **Planned**
Mount via `NetFS` first (see `ARCHITECTURE.md` §7); `AMSMB2` only if unmounted browsing is later required.

## Phase 10 — Polish, performance, accessibility, packaging — **Partially Implemented**
Custom app icon done. Still planned: VoiceOver labels, keyboard navigation/focus, contrast, customizable shortcuts, notarization/packaging for distribution outside the App Store (no sandbox yet — see `ARCHITECTURE.md` §6).

## Milestones (as specified)

1. **First usable milestone:** a polished dual-pane local Mac file manager, architecture already prepared for SFTP/FTP. → Achieved (Phase 2/3).
2. **Second usable milestone:** Mac ↔ home server SFTP transfers (password or key auth) with a real transfer queue. → Achieved in substance (Phase 4/5: connect/browse/rename/delete/permissions verified by hand against a real server; the transfer queue itself is built and unit-tested but not yet clicked through by hand for an actual cross-provider file move).
