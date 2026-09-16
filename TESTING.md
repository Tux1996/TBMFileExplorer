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

`Packages/TBMFileKit/Tests/TBMFileKitTests/SFTPFileProviderIntegrationTests.swift` — **against a real SFTP server, not mocks.** See "SFTP integration test server" below. 12 tests: password auth, key auth, wrong-password rejection, a slow (12s) host-key confirmation that must still succeed (regression test for the login-timeout bug below), host-key trust-on-first-use (asked once, remembered second time), host-key rejection aborting the connection, full file lifecycle (mkdir → create → stat → chmod → rename → list → delete), create-existing-directory → `.alreadyExists`, move-onto-existing → not silently overwritten, stat-on-missing → `.notFound`, and a 300 KB chunked copy verified byte-for-byte (this is the test that caught the short-read/truncation bug — see `ARCHITECTURE.md` §10). Every test is `.enabled(if: TestSFTPServer.isReachable)`, so `swift test` still passes cleanly when the container isn't running. The suite is `@Suite(.serialized)` and most tests share one `TestSFTPServer.sharedKnownHostsStore` — see the comments on both for why (running many of these concurrently, each doing its own fresh-host probe, reliably tripped the disposable container's OpenSSH `MaxStartups` throttling and produced misleading `Disconnected` failures that had nothing to do with the code under test).

### A real bug this caught: the SSH login timeout includes the host-key dialog

First real-world use of the Connection Manager (against the user's actual server, not the test container) failed every time with `NIOCore.ChannelError.connectTimeout` shortly after showing the host-key confirmation dialog. Root cause, found by reading Citadel's source: `ClientHandshakeHandler` gives the *entire* handshake-plus-authentication sequence a hardcoded, non-configurable 10-second budget — and the original design ran the interactive confirmation dialog *inside* that window, so any real human taking longer than 10 seconds to read a fingerprint and click a button guaranteed a failure that looked like a network problem but wasn't one. Fixed in `SFTPFileProvider.resolveHostKeyValidator()`: a throwaway probe connection (bogus credentials, whose only job is to capture the presented key during key exchange) runs *before* the timed connection attempt, so the confirmation dialog has no clock running against it. `slowHostKeyConfirmationDoesNotBlowTheLoginTimeout` simulates a 12-second-slow user and asserts the connection still succeeds — reproduced and verified fixed against both the disposable test container and the real reported server.

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

**Phase 4:** Same build/launch verification, plus confirmation the sidebar's new Servers/Transfers sections render without crashing. The user manually clicked through the Connection Manager sheet and connected to their real server (not the disposable test container) — this surfaced the login-timeout bug documented above, which is now fixed and confirmed working against that same real server. Remaining unverified-by-hand: browsing/file operations beyond the initial connection, drag-and-drop for remote tabs, and the "host key changed" re-confirmation path (only exercised by the automated tests so far, not by a human clicking through an actual key rotation).

## Planned (as remaining protocols land)

Per the project brief, still to add: encrypted/RSA/ECDSA key auth once Citadel supports it (or a vendored decrypt routine is added), a real large-file (multi-GB) transfer test, network-interruption/reconnect tests, Unicode/space/special-character filename tests, and the same live-server integration approach used for SFTP repeated for FTP (Phase 6) once that provider exists.
