# Security

See `ARCHITECTURE.md` §6 for the full posture and rationale. Summary of the rules this codebase follows as remote features land:

- **Credentials.** Passwords and SSH key passphrases go in the macOS Keychain only, referenced by an opaque identifier from `ConnectionProfile` — never inlined in a settings file, never logged. Not applicable yet (no `ConnectionProfile` exists — Phase 4).
- **SSH keys.** Referenced by filesystem path; never copied into app-managed plaintext config.
- **Host verification.** SFTP will validate host fingerprints against `known_hosts` and prompt on first-seen/changed hosts (Phase 4) rather than silently trusting.
- **TLS.** FTPS will validate certificates by default; no silent bypass (Phase 6).
- **Path handling.** `FilePath.appending(_:)` (`Packages/TBMFileKit/Sources/TBMFileKit/FilePath.swift`) strips `.`/`..`/empty segments before joining, so a filename can't be used to escape the intended directory.
- **Shell/SSH commands.** Always invoked with argument arrays (`Process`, SSH `exec` channels) — never string-interpolated into `/bin/sh -c` or an SFTP command line.
- **No silent overwrites.** `LocalFileProvider.move`/`.copy` throw `.alreadyExists` rather than clobbering a destination; the UI is expected to surface a conflict dialog (Replace/Skip/Keep Both/Cancel — full version lands with the Transfer Engine in Phase 5).
- **No automatic privilege escalation.** No `sudo`, no automatic ownership changes — `LocalFileProvider.capabilities.canSetOwnership` is `false` today.
- **Sandbox.** Currently disabled (`App/TBMFileExplorer.entitlements`) — documented tradeoff in `ARCHITECTURE.md` §6, revisit before wider distribution.

## Reporting

Personal project; no external reporting channel yet.
