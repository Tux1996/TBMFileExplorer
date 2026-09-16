# Testing

## What exists today

`Packages/TBMFileKit/Tests/TBMFileKitTests/LocalFileProviderTests.swift` (Swift Testing, run with `cd Packages/TBMFileKit && swift test`), against real temp directories under `FileManager.default.temporaryDirectory` (never against real user data — each test creates and tears down its own directory):

- Listing reflects created files/directories
- Hidden files filtered unless explicitly requested
- Creating a file that already exists throws rather than overwriting
- Moving onto an existing destination throws rather than silently overwriting
- Rename moves within the same directory and the new name shows up in a re-list
- `stat` correctly reports a symlink and its resolved target
- `FilePath.appending` strips `..`/`.`/empty traversal segments

`Packages/TBMFileKit/Tests/TBMFileKitTests/KnownHostsStoreTests.swift` — trust-on-first-use logic against temp JSON files: unknown → trusted → changed-key detection → persistence across instances → per-port isolation.

`Packages/TBMFileKit/Tests/TBMFileKitTests/OpenSSHEd25519KeyLoaderTests.swift` — parses a real (throwaway, committed-safe) unencrypted ed25519 fixture key and verifies the derived public key matches byte-for-byte; confirms an encrypted-key fixture throws the documented `.encrypted` error instead of silently mishandling it; confirms garbage input is rejected.

`Packages/TBMFileKit/Tests/TBMFileKitTests/SFTPFileProviderIntegrationTests.swift` — **against a real SFTP server, not mocks.** See "SFTP integration test server" below. 11 tests: password auth, key auth, wrong-password rejection, host-key trust-on-first-use (asked once, remembered second time), host-key rejection aborting the connection, full file lifecycle (mkdir → create → stat → chmod → rename → list → delete), create-existing-directory → `.alreadyExists`, move-onto-existing → not silently overwritten, stat-on-missing → `.notFound`, and a 300 KB chunked copy verified byte-for-byte (this is the test that caught the short-read/truncation bug — see `ARCHITECTURE.md` §10). Every test is `.enabled(if: TestSFTPServer.isReachable)`, so `swift test` still passes cleanly when the container isn't running.

### SFTP integration test server

A disposable local SFTP server for the tests above, real credentials that only exist inside a container that never leaves localhost:

```bash
docker run -d --name tbm-sftp-test -p 2223:22 \
  -v "$(pwd)/sftp_test_data:/home/testuser/data" \
  atmoz/sftp testuser:testpass123:1001:100:data
```

Then install the matching key from `TestSFTPServer.privateKeyPEM` as that container's `/home/testuser/.ssh/authorized_keys` (see the comment at the top of `TestSFTPServer.swift` for the exact `docker cp`/`chown`/`chmod` steps). Tear down with `docker rm -f tbm-sftp-test` — nothing it creates persists outside that container and the bind-mounted `sftp_test_data/` directory.

## Manual verification done

**Phase 2:** Built via `xcodebuild` (Debug), zero errors/warnings. Launched the built app, confirmed both panes list the real home directory correctly, tabs/toolbar/path bar render. Drag-and-drop, context menus, Quick Look, and the new-folder/rename dialogs are implemented against the same patterns as the tested `LocalFileProvider` code but were not clicked through by hand.

**Phase 4:** Same build/launch verification, plus confirmation the sidebar's new Servers/Transfers sections render without crashing. The Connection Manager sheet, the host-key confirmation dialog, and browsing a live connection **in the running app** have not been clicked through — this environment has no way to script clicks into a native AppKit window (no Accessibility permission, and the available browser-automation tools only reach a browser pane, not native apps). The `SFTPFileProvider` code all of that UI calls is covered by the 11 live-server integration tests above, which is real end-to-end proof the backend works; the UI glue code itself is unverified beyond "it compiles and the app doesn't crash on launch." Worth a manual pass before calling Phase 4 done.

## Planned (as remaining protocols land)

Per the project brief, still to add: encrypted/RSA/ECDSA key auth once Citadel supports it (or a vendored decrypt routine is added), a real large-file (multi-GB) transfer test, network-interruption/reconnect tests, Unicode/space/special-character filename tests, and the same live-server integration approach used for SFTP repeated for FTP (Phase 6) once that provider exists.
