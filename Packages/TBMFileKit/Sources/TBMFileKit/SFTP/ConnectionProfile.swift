import Foundation

public enum ConnectionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case sftp
    // .ftp, .ftps, .smb join this once their providers exist (Phase 6/9).

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .sftp: "SFTP"
        }
    }
}

public enum AuthenticationMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case password
    case privateKey

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .password: "Password"
        case .privateKey: "SSH Key"
        }
    }
}

/// A saved server connection. Never holds a secret directly — passwords live
/// in the Keychain via `CredentialManager`, keyed by `id`. Everything here is
/// safe to serialize to a plain JSON file (see `ConnectionStore`).
public struct ConnectionProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: ConnectionKind
    public var host: String
    public var port: Int
    public var username: String
    public var authentication: AuthenticationMethod
    public var privateKeyPath: String?
    public var defaultRemotePath: String
    public var isFavorite: Bool
    public var timeoutSeconds: Int
    public var keepAlive: Bool
    public var iconName: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ConnectionKind = .sftp,
        host: String,
        port: Int = 22,
        username: String,
        authentication: AuthenticationMethod = .password,
        privateKeyPath: String? = nil,
        defaultRemotePath: String = "/",
        isFavorite: Bool = false,
        timeoutSeconds: Int = 15,
        keepAlive: Bool = true,
        iconName: String = "server.rack"
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.privateKeyPath = privateKeyPath
        self.defaultRemotePath = defaultRemotePath
        self.isFavorite = isFavorite
        self.timeoutSeconds = timeoutSeconds
        self.keepAlive = keepAlive
        self.iconName = iconName
    }
}
