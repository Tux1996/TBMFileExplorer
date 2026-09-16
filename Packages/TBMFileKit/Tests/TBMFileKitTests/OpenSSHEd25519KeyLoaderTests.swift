import Crypto
import Foundation
import Testing
@testable import TBMFileKit

struct OpenSSHEd25519KeyLoaderTests {
    // Freshly generated throwaway fixture keys — not used anywhere else, safe to commit.
    static let unencryptedKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDuQDTTJy5Jxyfh3dgr9smKJA1tGyO0D9/EJrviPmvuyAAAAJD8gjQm/II0
    JgAAAAtzc2gtZWQyNTUxOQAAACDuQDTTJy5Jxyfh3dgr9smKJA1tGyO0D9/EJrviPmvuyA
    AAAEBO78v7gGhnhiysDlib7R7pVHhhjefTrrQM8+omIX08Ze5ANNMnLknHJ+Hd2Cv2yYok
    DW0bI7QP38Qmu+I+a+7IAAAAB2ZpeHR1cmUBAgMEBQY=
    -----END OPENSSH PRIVATE KEY-----
    """
    static let matchingPublicKeyBase64 = "AAAAC3NzaC1lZDI1NTE5AAAAIO5ANNMnLknHJ+Hd2Cv2yYokDW0bI7QP38Qmu+I+a+7I"

    static let encryptedKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBi9UJRnY
    FNIJIzK7ZZVz2jAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIPSEXAKtuR4Q1qd+
    TmZAWMY7XVFwoRocFRHNNK/FgZYIAAAAkFTM9MKC8BE7AQaLUcWl2Fr9Ybv5gRqG/xwmC1
    ijmK+45IUnBZi4RKhOg0/YgYOtIynf3FEW/MPQk74dzyOMOdnEeyC6M0yQjnbsGQuLdiZS
    2YQS/azsuay8GvoC7I0Rt9pTMsRkCWuB0Qlv4We3sANjsCAqDr4Je7E/4VFFUYJOasZXuL
    6HzeHphd3yOUIlQw==
    -----END OPENSSH PRIVATE KEY-----
    """

    @Test func loadsUnencryptedKeyAndDerivesMatchingPublicKey() throws {
        let key = try OpenSSHEd25519KeyLoader.load(pem: Self.unencryptedKey)

        // The OpenSSH public-key blob is `string "ssh-ed25519" + string <32 raw bytes>`
        // (SSH wire format: 4-byte big-endian length prefix per string); the last
        // 32 bytes of the decoded blob are the raw Curve25519 public key.
        let blob = try #require(Data(base64Encoded: Self.matchingPublicKeyBase64))
        let rawPublicKeyFromFixture = blob.suffix(32)

        #expect(rawPublicKeyFromFixture == key.publicKey.rawRepresentation)
    }

    @Test func encryptedKeyThrowsClearActionableError() {
        #expect(throws: OpenSSHKeyError.encrypted) {
            try OpenSSHEd25519KeyLoader.load(pem: Self.encryptedKey)
        }
    }

    @Test func garbageInputThrowsNotOpenSSHFormat() {
        #expect(throws: OpenSSHKeyError.notOpenSSHFormat) {
            try OpenSSHEd25519KeyLoader.load(pem: "not a key")
        }
    }
}
