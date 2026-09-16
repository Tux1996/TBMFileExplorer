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

## Manual verification done for Phase 2

- Built via `xcodebuild` (Debug), zero errors/warnings in app code
- Launched the built app, confirmed both panes list the real home directory correctly, tabs/toolbar/path bar render
- **Not yet verified by automation or a human click-through in this session:** drag-and-drop (pane-to-pane, Finder-to-pane), context menu actions (rename/duplicate/trash/get info), Quick Look (Space), new-folder/rename dialogs. These are implemented against the same patterns as the tested code paths but should be clicked through by hand before being called done — flagging explicitly rather than claiming full coverage.

## Planned (as remote protocols land)

Per the project brief, still to add: interrupted upload/download, authentication failure, permission denied, missing files, network interruption, large files, Unicode filenames, spaces/special characters, nested directories — against real (test) SFTP/FTP targets once those providers exist (Phase 4/6), never against unknown production data.
