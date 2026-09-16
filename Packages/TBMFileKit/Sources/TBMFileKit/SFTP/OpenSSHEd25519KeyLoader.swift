import Crypto
import Foundation

public enum OpenSSHKeyError: Error, LocalizedError, Equatable {
    case notOpenSSHFormat
    case encrypted
    case unsupportedKeyType(String)
    case corrupted

    public var errorDescription: String? {
        switch self {
        case .notOpenSSHFormat: "That doesn't look like an OpenSSH private key file."
        case .encrypted: "This key is passphrase-protected. Encrypted-key support isn't implemented yet — see DEPENDENCIES.md (Citadel doesn't expose passphrase decryption publicly). Run `ssh-keygen -p -N \"\" -f <keyfile>` to remove the passphrase, or use password authentication instead."
        case .unsupportedKeyType(let type): "\(type) keys aren't supported yet — only ed25519 (Phase 4). RSA/ECDSA are planned."
        case .corrupted: "The key file is corrupted or truncated."
        }
    }
}

/// Parses an **unencrypted** OpenSSH-format ed25519 private key (the default
/// `ssh-keygen -t ed25519` output with no passphrase) into a usable signing
/// key. Format reference: https://dnaeon.github.io/openssh-private-key-binary-format/
///
/// Deliberately narrow scope: Citadel (see `DEPENDENCIES.md`) has no public
/// API for decrypting a passphrase-protected key or for RSA/ECDSA private
/// keys today, so rather than silently failing on those or reimplementing a
/// second crypto stack, this loader handles exactly the one format Citadel's
/// own `SSHAuthenticationMethod.ed25519` can consume, and throws a clear,
/// actionable error for everything else.
public enum OpenSSHEd25519KeyLoader {
    public static func load(pem: String) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
              trimmed.hasSuffix("-----END OPENSSH PRIVATE KEY-----") else {
            throw OpenSSHKeyError.notOpenSSHFormat
        }

        let base64 = trimmed
            .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: base64) else {
            throw OpenSSHKeyError.corrupted
        }
        let bytes = [UInt8](data)
        var cursor = 0

        func readBytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, cursor + count <= bytes.count else { throw OpenSSHKeyError.corrupted }
            defer { cursor += count }
            return Array(bytes[cursor..<(cursor + count)])
        }
        func readUInt32() throws -> UInt32 {
            let b = try readBytes(4)
            return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        }
        func readSSHString() throws -> [UInt8] {
            let length = try readUInt32()
            return try readBytes(Int(length))
        }

        let magic = Array("openssh-key-v1\0".utf8)
        guard try readBytes(magic.count) == magic else { throw OpenSSHKeyError.notOpenSSHFormat }

        let cipherName = String(decoding: try readSSHString(), as: UTF8.self)
        _ = try readSSHString() // kdfname
        _ = try readSSHString() // kdfoptions

        let keyCount = try readUInt32()
        guard keyCount == 1 else { throw OpenSSHKeyError.unsupportedKeyType("multiple keys in one file") }

        _ = try readSSHString() // public key section (redundant with the copy inside the private section)

        guard cipherName == "none" else {
            throw OpenSSHKeyError.encrypted
        }

        let privateSection = try readSSHString()
        var inner = 0
        func readInnerUInt32() throws -> UInt32 {
            guard inner + 4 <= privateSection.count else { throw OpenSSHKeyError.corrupted }
            let b = privateSection[inner..<(inner + 4)]
            inner += 4
            return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func readInnerSSHString() throws -> [UInt8] {
            let length = try readInnerUInt32()
            guard inner + Int(length) <= privateSection.count else { throw OpenSSHKeyError.corrupted }
            defer { inner += Int(length) }
            return Array(privateSection[inner..<(inner + Int(length))])
        }

        let checksum1 = try readInnerUInt32()
        let checksum2 = try readInnerUInt32()
        guard checksum1 == checksum2 else { throw OpenSSHKeyError.corrupted }

        let keyType = String(decoding: try readInnerSSHString(), as: UTF8.self)
        guard keyType == "ssh-ed25519" else { throw OpenSSHKeyError.unsupportedKeyType(keyType) }

        _ = try readInnerSSHString() // public key bytes (32) — not needed, derived from the seed below
        let privateKeyBlob = try readInnerSSHString() // seed (32 bytes) + public key (32 bytes)
        guard privateKeyBlob.count == 64 else { throw OpenSSHKeyError.corrupted }
        let seed = Data(privateKeyBlob.prefix(32))

        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}
