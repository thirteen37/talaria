import Crypto
import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import HermesKit

/// Exercises the in-tree OpenSSH private-key parser. We generate keys in
/// process and assemble the OpenSSH-format blob ourselves rather than
/// shipping fixtures, so the test is self-contained and survives any
/// future re-key.
@Suite
struct OpenSSHPrivateKeyParserTests {
    @Test
    func parsesUnencryptedEd25519() throws {
        let priv = Curve25519.Signing.PrivateKey()
        let pem = makeOpenSSHEd25519PEM(privateKey: priv)
        let parsed = try OpenSSHPrivateKeyParser.parse(pem)
        // Round-trip through public key: the derived public should match
        // the one Crypto computes from the original private. We compare
        // the OpenSSH public-key strings, which is the canonical
        // ecosystem-wide identity.
        let expectedPublic = NIOSSHPrivateKey(ed25519Key: priv).publicKey
        #expect(String(openSSHPublicKey: parsed.publicKey) == String(openSSHPublicKey: expectedPublic))
    }

    @Test
    func rejectsEncryptedKeyWithTypedError() {
        let pem = makeFakeEncryptedHeader()
        do {
            _ = try OpenSSHPrivateKeyParser.parse(pem)
            Issue.record("Expected encryptedKeyNotSupported")
        } catch OpenSSHPrivateKeyParser.ParseError.encryptedKeyNotSupported {
            // ok
        } catch {
            Issue.record("Expected encryptedKeyNotSupported, got \(error)")
        }
    }

    @Test
    func rejectsLegacyPEM() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIBOQIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu
        ...
        -----END RSA PRIVATE KEY-----
        """
        do {
            _ = try OpenSSHPrivateKeyParser.parse(pem)
            Issue.record("Expected unsupportedKeyFormat")
        } catch OpenSSHPrivateKeyParser.ParseError.unsupportedKeyFormat {
            // ok
        } catch {
            Issue.record("Expected unsupportedKeyFormat, got \(error)")
        }
    }

    @Test
    func rejectsMissingArmor() {
        do {
            _ = try OpenSSHPrivateKeyParser.parse("not a key at all")
            Issue.record("Expected missingArmor")
        } catch OpenSSHPrivateKeyParser.ParseError.missingArmor {
            // ok
        } catch {
            Issue.record("Expected missingArmor, got \(error)")
        }
    }
}

// MARK: - Test fixture construction

/// Builds the bytes of the OpenSSH `none`-cipher format for an ed25519
/// private key. This is the same wire format `ssh-keygen -t ed25519 -N ''`
/// produces, sans the comment fields (which the parser ignores anyway).
private func makeOpenSSHEd25519PEM(privateKey: Curve25519.Signing.PrivateKey) -> String {
    let pub = privateKey.publicKey
    let pubBytes = pub.rawRepresentation
    let privBytes = privateKey.rawRepresentation
    // OpenSSH stores ed25519 private as 64B (seed || pub).
    var privCombined = privBytes
    privCombined.append(pubBytes)

    var outer = Data()
    outer.append(Data("openssh-key-v1\0".utf8))
    outer.append(sshString(Data("none".utf8))) // ciphername
    outer.append(sshString(Data("none".utf8))) // kdfname
    outer.append(sshString(Data()))            // kdfoptions
    outer.append(uint32(1))                    // number of keys

    // Public key blob: string "ssh-ed25519", string pubBytes
    var pubBlob = Data()
    pubBlob.append(sshString(Data("ssh-ed25519".utf8)))
    pubBlob.append(sshString(pubBytes))
    outer.append(sshString(pubBlob))

    // Private section (unencrypted)
    var privSection = Data()
    let check: UInt32 = 0xDEAD_BEEF
    privSection.append(uint32(check))
    privSection.append(uint32(check))
    privSection.append(sshString(Data("ssh-ed25519".utf8)))
    privSection.append(sshString(pubBytes))
    privSection.append(sshString(privCombined))
    privSection.append(sshString(Data("test@host".utf8))) // comment
    // Pad to 8-byte boundary with 1,2,3,...
    let padNeeded = (8 - (privSection.count % 8)) % 8
    for i in 0..<padNeeded {
        privSection.append(UInt8(i + 1))
    }
    outer.append(sshString(privSection))

    let body = outer.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return """
    -----BEGIN OPENSSH PRIVATE KEY-----
    \(body)
    -----END OPENSSH PRIVATE KEY-----
    """
}

private func makeFakeEncryptedHeader() -> String {
    // Build a parseable-but-encrypted skeleton: real magic + non-"none"
    // cipher so the parser reaches the encryption check and throws.
    var outer = Data()
    outer.append(Data("openssh-key-v1\0".utf8))
    outer.append(sshString(Data("aes256-ctr".utf8)))
    outer.append(sshString(Data("bcrypt".utf8)))
    outer.append(sshString(Data()))
    outer.append(uint32(1))
    outer.append(sshString(Data())) // empty pub
    outer.append(sshString(Data())) // empty encrypted blob

    let body = outer.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return """
    -----BEGIN OPENSSH PRIVATE KEY-----
    \(body)
    -----END OPENSSH PRIVATE KEY-----
    """
}

private func sshString(_ data: Data) -> Data {
    var out = uint32(UInt32(data.count))
    out.append(data)
    return out
}

private func uint32(_ value: UInt32) -> Data {
    var be = value.bigEndian
    return withUnsafeBytes(of: &be) { Data($0) }
}
