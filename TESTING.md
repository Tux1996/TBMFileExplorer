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

`AppTests/TransferManagerTests.swift` (run with `xcodebuild -project TBMFileExplorer.xcodeproj -scheme TBMFileExplorer test`, or Xcode's Test navigator) — 9 tests against `AppTests/InMemoryFileProvider.swift`, a fast/deterministic in-memory `FileProvider` fake purpose-built for this suite (the real streaming I/O already has its own real-disk/real-server coverage above; these tests are about `TransferManager`'s own control flow — queueing, collisions, pause/cancel/retry — which doesn't need real I/O to exercise correctly, and runs in well under a second because it doesn't have any): single-file transfer completes with matching bytes; collision → skip leaves the destination untouched; collision → replace overwrites; collision → keep-both creates a uniquely-named file; collision → resume appends from the destination's existing size; "Apply to All" reuses the first resolution for the rest of a batch; cancelling a running transfer actually stops it; pausing then resuming still completes; retrying a failed job resets state and can succeed once the underlying issue is fixed. The last two — cancel and pause — use a version of the fake with an artificial per-chunk delay, so the test can reliably interact with a transfer while it's still in flight instead of racing a transfer that would otherwise finish instantly.

This suite is what's registered in a separate Xcode target (`TBMFileExplorerTests`, `type: bundle.unit-test` in `project.yml`) that `@testable import`s the app itself — getting that wired up needed `TEST_HOST`/`BUNDLE_LOADER` pointed at the actual product path (the default assumes `PRODUCT_NAME` has no spaces, which ours does) and the module import spelled `TBM_File_Explorer` (Xcode sanitizes the space in `PRODUCT_NAME` to an underscore for the Swift module name — a five-minute mystery the first time `@testable import TBMFileExplorer` failed to resolve).

### Two real bugs this test suite caught (see `ARCHITECTURE.md` §12 for the full writeup)

1. Cancelling a running transfer reported `.completed`, not `.cancelled` — because `for try await` over an `AsyncThrowingStream` exits silently, not by throwing, when the consuming `Task` is cancelled while awaiting the next value. A general Swift Concurrency gotcha, not specific to this codebase; reproduced first in a ~15-line standalone script to confirm the mechanism before fixing the real code.
2. A transfer that failed because the source was missing still left a stray empty file at the destination, because the destination write sink was opened (creating the file as a side effect) before the source was confirmed readable. Found via a retry test: retrying the *same* failure produced a *different*, more confusing error the second time (`.alreadyExists` instead of `.notFound`).

### SFTP integration test server

A disposable local SFTP server for the tests above, real credentials that only exist inside a container that never leaves localhost:

```bash
docker run -d --name tbm-sftp-test -p 2223:22 \
  -v "$(pwd)/sftp_test_data:/home/testuser/data" \
  atmoz/sftp testuser:testpass123:1001:100:data
```

Then install the matching key from `TestSFTPServer.privateKeyPEM` as that container's `/home/testuser/.ssh/authorized_keys` (see the comment at the top of `TestSFTPServer.swift` for the exact `docker cp`/`chown`/`chmod` steps). Tear down with `docker rm -f tbm-sftp-test` — nothing it creates persists outside that container and the bind-mounted `sftp_test_data/` directory.

## Manual verification done

**Phase 2:** Built via `xcodebuild` (Debug), zero errors/warnings. Launched the built app, confirmed both panes list the real home directory correctly, tabs/toolbar/path bar render. Drag-and-drop (dragging a file into a subfolder) has since been clicked through by hand and confirmed working — this is what surfaced a real bug: the original `.draggable`/`.dropDestination` implementation silently failed to complete any drop inside the macOS `List`, fixed by switching to `.onDrag`/`.onDrop` (see `ARCHITECTURE.md` §11). Context menus, Quick Look, and the new-folder/rename dialogs are still only implemented against the same tested patterns, not yet clicked through by hand — given the drag-and-drop lesson, "looks right in code" isn't being treated as equivalent to "verified" for any of these anymore.

**Phase 4:** Same build/launch verification, plus confirmation the sidebar's new Servers/Transfers sections render without crashing. The user manually clicked through the Connection Manager sheet, connected to their real server (not the disposable test container), renamed a remote file, and deleted one — this surfaced the login-timeout bug documented above, then confirmed it fixed, on a freshly rebuilt-and-relaunched app (the first "it connected" report turned out to be the old binary still running from before the fix — a rebuilt binary on disk doesn't affect an already-running process, so it needed an explicit quit-and-relaunch to actually test the fix). Then confirmed permissions and local drag-and-drop working too — the latter turned up the `List`/`.dropDestination` bug documented in `ARCHITECTURE.md` §11. Remaining unverified-by-hand: drag-and-drop into/within a remote tab specifically, and the "host key changed" re-confirmation path (only exercised by the automated tests so far, not by a human clicking through an actual key rotation).

**Phase 5:** The user dragged a file from their real SFTP server into a local Documents folder and it transferred successfully — real end-to-end proof the cross-provider pipeline works, not just the unit-tested control flow. Getting there took two more rounds of "doesn't work" → fix: first, a file row was rejecting drops outright instead of falling back to "drop into the current directory" (real bug, fixed, but not the one blocking this case); then the actual blocker — the custom UTI used to carry a remote row's true source provider through a drag session was only declared dynamically at runtime, which logged a `[Type Declaration Issues]` warning on every launch and meant the OS never recognized a remote item as droppable *anywhere* (matching the reported symptom: no cursor change, nothing). Fixed by properly declaring the UTI in `Info.plist`. See `ARCHITECTURE.md` §12, bug 3.

Two more UX bugs surfaced right after, from the same hands-on session, and were fixed but **not re-confirmed by the user before moving on** — flagging explicitly rather than claiming verified:
1. Dragging felt like it needed a long press before it would move — an exclusive `.onTapGesture(count: 2)` (for double-click-to-open) on the same row as `.onDrag` made the system wait out the double-click disambiguation window before it could commit to starting a drag. Switched to `.simultaneousGesture(TapGesture(count: 2)...)`, which doesn't compete for gesture exclusivity.
2. Dragging 2+ selected items only transferred one, and the drag preview visibly vanished mid-drag. Root cause (inferred, not confirmed against SwiftUI's source): `List(selection:)` appears to collapse a multi-selection down to just the clicked row immediately on click, rather than deferring that to mouse-up the way native `NSTableView` does specifically to let a drag started on an already-selected row carry the whole selection. Worked around by remembering the selection just before it shrinks (`FileListView.priorMultiSelection`) and using that instead when `.onDrag` finds only one item selected.

Still unverified by hand: the two fixes just above (multi-select drag, drag responsiveness), the Transfers panel UI itself (progress bars, pause/cancel/retry buttons), the collision dialog, and same-provider (not cross-provider) drag scenarios beyond what Phase 2/4 already covered.

## Planned (as remaining protocols land)

Per the project brief, still to add: encrypted/RSA/ECDSA key auth once Citadel supports it (or a vendored decrypt routine is added), a real large-file (multi-GB) transfer test, network-interruption/reconnect tests, Unicode/space/special-character filename tests, and the same live-server integration approach used for SFTP repeated for FTP (Phase 6) once that provider exists.
