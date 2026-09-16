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
- Drag & drop: between panes, from Finder
- Quick Look preview (Space) via `QLPreviewPanel`
- Basic Get Info panel

Not yet done (tracked below, not silently skipped):
- Icon/column view modes (List view only for now, as the spec allows: "Start with List view as the primary polished implementation")
- Interactive permissions editor (checkbox/chmod UI) — local Get Info shows permissions read-only today
- Tags
- Batch rename
- Local search UI (provider-level `list` exists; no search index/UI yet)

## Phase 3 — Common `FileProvider` abstraction — **Implemented** (pulled forward)
Originally sequenced after Phase 2, but built alongside it: the UI in Phase 2 already talks only to the `FileProvider` protocol (`Packages/TBMFileKit`), never to `FileManager` directly. Building the throwaway direct-`FileManager` version first and refactoring afterward would have cost more than doing the abstraction once. `LocalFileProvider` is the only concrete implementation so far.

## Phase 4 — SFTP — **Planned**
- Add Citadel dependency; implement `SFTPFileProvider`
- Password and SSH-key (incl. encrypted key + passphrase) authentication
- `known_hosts` validation / host fingerprint confirmation UI
- `ConnectionProfile` model + Keychain-backed `CredentialManager`
- Server Connection Manager UI (add/edit/test SFTP hosts)
- Remote listing, upload, download, rename, move, delete, permissions
- Reconnect / keep-alive / connection timeout
- Test against a real large transfer, and against disconnect/reconnect

## Phase 5 — Transfer manager — **Planned**
- `TransferJob`/`TransferQueue` models, persistent across navigation (background transfers)
- Progress, speed, ETA; pause/resume where the protocol supports it; retry; cancel
- Collision handling: Replace / Skip / Keep Both / Resume / Compare / Cancel / Apply to All
- Configurable concurrency limit
- Optional post-transfer hash verification (MD5/SHA-1/SHA-256, opt-in for large files)
- Completion/failure/disconnect notifications

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

## Phase 10 — Polish, performance, accessibility, packaging — **Planned**
VoiceOver labels, keyboard navigation/focus, contrast, customizable shortcuts, app icon/branding, notarization/packaging for distribution outside the App Store (no sandbox yet — see `ARCHITECTURE.md` §6).

## Milestones (as specified)

1. **First usable milestone:** a polished dual-pane local Mac file manager, architecture already prepared for SFTP/FTP. → Target of Phase 2/3, in progress.
2. **Second usable milestone:** Mac ↔ home server SFTP transfers (password or key auth) with a real transfer queue. → Target of Phase 4/5.
