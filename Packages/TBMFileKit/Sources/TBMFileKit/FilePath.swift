import Foundation

/// A protocol-agnostic POSIX-style path. Not a `URL` — remote providers (SFTP/FTP)
/// deal in plain POSIX paths on the remote host, and routing those through `URL`'s
/// scheme/host/percent-encoding model buys nothing and risks subtle bugs.
public struct FilePath: Hashable, Sendable, CustomStringConvertible {
    public var string: String

    public init(_ string: String) {
        self.string = string.isEmpty ? "/" : string
    }

    public var description: String { string }

    public var isRoot: Bool { string == "/" }

    public var lastComponent: String {
        (string as NSString).lastPathComponent
    }

    public var parent: FilePath {
        if isRoot { return self }
        let parent = (string as NSString).deletingLastPathComponent
        return FilePath(parent.isEmpty ? "/" : parent)
    }

    public var pathExtension: String {
        (string as NSString).pathExtension
    }

    /// Appends a single path component, normalizing away any `.`/`..`/empty
    /// segments the component might contain so a caller can never smuggle a
    /// traversal sequence into a server-side path via a "filename".
    public func appending(_ component: String) -> FilePath {
        let sanitized = component
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .joined(separator: "/")
        if isRoot {
            return FilePath("/" + sanitized)
        }
        return FilePath(string + "/" + sanitized)
    }

    public var localURL: URL {
        URL(fileURLWithPath: string)
    }
}
