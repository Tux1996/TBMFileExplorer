# Dependencies

For every candidate: Name, Repository, Purpose, Language, Maintenance state, License, Decision. Researched 2026-09-16.

Nothing in this table is vendored/copied source — everything marked "Selected" is a Swift Package Manager dependency resolved at build time, or an Apple system framework.

## Reference only (not a dependency)

| Name | Repository | Purpose | Language | Maintenance | License | Decision |
|---|---|---|---|---|---|---|
| muCommander | github.com/mucommander/mucommander | Dual-pane file manager | Java/Swing | Active (commits/issues through Sept 2026) | GPL-3.0-or-later | **Reference only.** GPLv3 would force this whole app GPL if any source were reused; Swing also fails the "modern native macOS" requirement outright. Its `AbstractFile`/virtual-filesystem *idea* informed `FileProvider` in `ARCHITECTURE.md`; no code copied. |

## SSH / SFTP (Phase 4)

| Name | Repository | Purpose | Language | Maintenance | License | Decision |
|---|---|---|---|---|---|---|
| **Citadel** | github.com/orlandos-nl/Citadel | SSH client (+ SFTP client, exec, shell) | Swift | Active | MIT | **Selected and in use** since Phase 4 (pinned `from: "0.8.0"`, resolved to 0.12.1). Pure Swift, gives us SFTP file ops *and* `exec` in one dependency — the `exec` channel is exactly what Phase 8 (remote `df`, `uptime`, Docker Compose commands, server info panel) needs, so we don't need a second SSH library for that. Two real gaps found by using it against a live server, tracked in `ARCHITECTURE.md` §10: no public API for encrypted-key/RSA/ECDSA private keys, and no public `SSH_FXP_READLINK`/`SSH_FXP_SYMLINK`. |
| swift-nio-ssh | github.com/Wellz26/swift-nio-ssh (fork of apple/swift-nio-ssh) | Low-level SSH protocol transport | Swift | Active — the fork exists only to carry ~2-year-old PRs Apple hasn't merged; its own description says it'll be archived once that happens | Apache-2.0 | **Pulled in transitively** by Citadel (not a direct dependency of this project, and not chosen directly — Citadel's `Package.swift` pins this fork rather than `apple/swift-nio-ssh`). Worth re-checking when Citadel updates its own dependency, since a fork with no independent long-term maintenance plan is a thinner guarantee than Apple's own repo. |
| mft | github.com/mplpl/mft | SFTP client wrapping libssh2/OpenSSL | Swift + C | Low commit volume | Unclear/unconfirmed at time of research | **Rejected.** Wraps a C library (libssh2) instead of being NIO-native; license wasn't clearly confirmable from the repo metadata surfaced, which alone is disqualifying next to a clean MIT/Apache alternative. |
| SwiftSH / SSH2Kit / swift-libssh2 forks | various | SSH wrapping libssh2 | Swift + C | Mixed, several are unmaintained forks | Mixed | **Rejected.** Same C-dependency drawback as `mft`, less active than Citadel. |

## FTP / FTPS (Phase 6)

| Name | Repository | Purpose | Language | Maintenance | License | Decision |
|---|---|---|---|---|---|---|
| **FilesProvider** (`amosavian/FileProvider`) | github.com/amosavian/FileProvider | `FileManager`-like façade over WebDAV/FTP/Dropbox/OneDrive | Swift | Moderate — long history, releases have slowed | Apache-2.0 | **Tentatively selected for Phase 6.** Reimplements FTP directly (doesn't depend on deprecated CFNetwork FTP APIs); Apache-2.0 is compatible. Flagged as moderate-maintenance — if it proves unmaintained when Phase 6 starts, fallback is a small FTP client written directly on `Network.framework`/NIO, since the FTP command protocol itself is simple text-based RFC 959, unlike SSH/TLS crypto which we categorically don't want to reimplement. |

## SMB (Phase 9, deliberately deferred — see `ARCHITECTURE.md` §7)

| Name | Repository | Purpose | Language | Maintenance | License | Decision |
|---|---|---|---|---|---|---|
| macOS `NetFS` framework | Apple system framework | Mount `smb://` shares the same way Finder does | C/Swift-bridgeable | Apple system framework | Apple system license | **Selected for first attempt.** Zero extra dependency, zero license entanglement — mounted share then behaves like any other local volume through `LocalFileProvider`. |
| AMSMB2 | github.com/amosavian/AMSMB2 | Direct SMB2/3 client (no mount required) | Swift + C (libsmb2) | Active | MIT wrapper, but statically links libsmb2 (**LGPL-2.1**) → whole module becomes LGPL-2.1; must dynamically link for redistribution | **Fallback only**, and only if unmounted-share browsing turns out to be required. Kept isolated to its own optional module so the LGPL scope doesn't spread if adopted. |

## Archives (Phase 2/6 — ZIP is needed early since it's a common transfer/inspection format)

| Name | Repository | Purpose | Language | Maintenance | License | Decision |
|---|---|---|---|---|---|---|
| **ZIPFoundation** | github.com/weichsel/ZIPFoundation | ZIP read/write/stream | Swift | Active | MIT | **Selected** for ZIP. Mature, widely used, streaming API fits the "never load a whole file into RAM" requirement. |
| **SWCompression** | github.com/tsolomko/SWCompression | TAR, GZIP, TAR.GZ, 7-Zip (read), etc. | Swift | Active — 9 years, 60+ releases | MIT | **Selected** for TAR/GZIP/TAR.GZ, the other formats the prompt requires at minimum. Also gives an optional path to 7z later without a new dependency. |

## Syntax highlighting / editor (Phase 7)

| Name | Repository | Purpose | Language | Maintenance | License | Decision |
|---|---|---|---|---|---|---|
| **Highlightr** | github.com/raspu/Highlightr | `NSAttributedString` syntax highlighting via highlight.js | Swift (wraps JS via JavaScriptCore) | Mature, low churn (stable, not abandoned) | MIT | **Selected for v1.** The spec calls for a *lightweight* config-file editor (YAML/JSON/.env/nginx.conf/shell/logs), not a full IDE — Highlightr covers all of those languages today with minimal integration surface. |
| CodeEditSourceEditor | github.com/CodeEditApp/CodeEditSourceEditor | Tree-sitter-backed `NSTextView` code editor | Swift | Active, but the project's own README states it is "not ready for production use" | MIT | **Rejected for now, revisit later.** More powerful (real incremental parsing, minimap, LSP-shaped features) but explicitly pre-production; not worth the risk for a Phase 7 utility editor. Reconsider once it stabilizes or once the editor's ambitions grow past what Highlightr covers. |

## System frameworks used directly (no third-party dependency)

| Framework | Purpose |
|---|---|
| `QuickLook` / `Quick LookUI` | File previews — the prompt explicitly says to use system Quick Look rather than recreate preview tech. |
| `Security` (Keychain Services) | Credential storage. Implemented directly against the system API rather than adding a wrapper library (e.g. KeychainAccess) — the surface we need (generic password items, keyed by connection ID) is small, and this is the one area of the app where auditability of every line matters most. |
| `Foundation.FileManager` / `URLResourceValues` / POSIX (`lstat`, `getpwuid_r`, `getgrgid_r`, `chmod`) | Local filesystem provider. |
| `NSWorkspace` | Open/Open With, reveal in Finder, launching Terminal. |
| `Network`/`Process` | Fallback FTP implementation path and shelling out to `ssh`/Terminal.app respectively, if/when needed. |

## Explicitly not reused

Per the prompt's "do not reinvent" list — SFTP, FTP, SSH crypto, TLS, archive parsing, syntax highlighting, Quick Look, and Keychain integration are all satisfied by the table above (either a library or a system framework). Nothing in this project hand-rolls a crypto primitive, a TLS stack, or an archive format parser.
