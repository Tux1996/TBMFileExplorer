import Crypto
import Foundation
import NIOSSH

/// Renders a host key the same way OpenSSH does (`ssh-keygen -lf`), so a user
/// comparing what this app shows against what their server admin printed sees
/// a match. Pure data transformation — no network/Keychain access — so it's
/// unit-testable against a fixed known key.
public enum HostKeyFingerprint {
    /// `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...` — the standard OpenSSH public-key line.
    public static func openSSHLine(for key: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: key)
    }

    /// `SHA256:xxxxxxxx...` (base64, unpadded) — OpenSSH's default fingerprint format.
    public static func sha256Fingerprint(for key: NIOSSHPublicKey) -> String? {
        guard let blob = base64Blob(from: openSSHLine(for: key)) else { return nil }
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        let unpadded = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(unpadded)"
    }

    /// Extracts and base64-decodes the key-blob field (the 2nd whitespace-separated
    /// token) out of an OpenSSH public-key line.
    static func base64Blob(from openSSHLine: String) -> Data? {
        let parts = openSSHLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }
}
