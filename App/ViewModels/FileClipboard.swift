import TBMFileKit

/// Cross-pane copy/cut clipboard. Deliberately holds `FileItem`s plus the
/// provider they came from (not yet used for cross-provider paste — that's
/// the Transfer Engine's job from Phase 5 onward — but the shape already
/// supports it so "cut here, paste there" won't need a rewrite later).
struct FileClipboard {
    var items: [FileItem]
    var sourceProvider: any FileProvider
    var isCut: Bool
}
