import Crypto
import Foundation
import NIOSSH

/// Minimal parser for OpenSSH-format private keys (the
/// `-----BEGIN OPENSSH PRIVATE KEY-----` armor introduced in OpenSSH 6.5).
///
/// Scope:
/// - Unencrypted (`cipher == "none"`) ed25519 / ECDSA P-256 / P-384 / P-521.
/// - Encrypted keys raise ``ParseError/encryptedKeyNotSupported`` so the
///   credential provider can convert it to ``SSHTransportError/needsPassphrase``.
/// - RSA and the legacy PEM `-----BEGIN RSA PRIVATE KEY-----` formats are
///   out of scope for v1 — they raise ``ParseError/unsupportedKeyFormat``.
///
/// The format is documented in OpenSSH's `PROTOCOL.key`; this implementation
/// covers only the unencrypted variants we need. We accept the cost of
/// hand-parsing because `NIOSSHPrivateKey` does not ship an OpenSSH parser
/// at the version we depend on.
enum OpenSSHPrivateKeyParser {
    enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingArmor
        case malformed(String)
        case encryptedKeyNotSupported
        case unsupportedKeyFormat(String)

        var description: String {
            switch self {
            case .missingArmor: return "OpenSSH armor not found"
            case let .malformed(message): return "Malformed OpenSSH key: \(message)"
            case .encryptedKeyNotSupported:
                return "Encrypted OpenSSH keys are not supported by this transport yet"
            case let .unsupportedKeyFormat(message):
                return "Unsupported OpenSSH key format: \(message)"
            }
        }
    }

    static func parse(_ pem: String) throws -> NIOSSHPrivateKey {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex) else {
            // Heuristic check for legacy PEM formats so the error message
            // tells the user which path they're hitting.
            if pem.contains("-----BEGIN RSA PRIVATE KEY-----")
                || pem.contains("-----BEGIN EC PRIVATE KEY-----")
                || pem.contains("-----BEGIN PRIVATE KEY-----") {
                throw ParseError.unsupportedKeyFormat("legacy PEM private keys are not supported; convert with `ssh-keygen -p -m OPENSSH`")
            }
            throw ParseError.missingArmor
        }
        let base64Block = pem[beginRange.upperBound..<endRange.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let blob = Data(base64Encoded: base64Block) else {
            throw ParseError.malformed("base64 body is not decodable")
        }
        var reader = ByteReader(blob)
        let magic = try reader.read(count: 15)
        guard magic == Data("openssh-key-v1\0".utf8) else {
            throw ParseError.malformed("bad magic")
        }
        let cipher = try reader.readSSHString()
        _ = try reader.readSSHString() // kdfName
        _ = try reader.readSSHString() // kdfOptions
        let keyCount: UInt32 = try reader.readUInt32()
        guard keyCount == 1 else {
            throw ParseError.unsupportedKeyFormat("\(keyCount)-key files are not supported")
        }
        _ = try reader.readSSHString() // public key blob (unused — we recover it from the private key)
        let privateSection = try reader.readSSHString()
        guard String(decoding: cipher, as: UTF8.self) == "none" else {
            throw ParseError.encryptedKeyNotSupported
        }

        var inner = ByteReader(privateSection)
        let check1: UInt32 = try inner.readUInt32()
        let check2: UInt32 = try inner.readUInt32()
        guard check1 == check2 else {
            throw ParseError.malformed("checkint mismatch")
        }
        let keyType = String(decoding: try inner.readSSHString(), as: UTF8.self)

        switch keyType {
        case "ssh-ed25519":
            _ = try inner.readSSHString() // public 32B
            let priv = try inner.readSSHString()
            // OpenSSH stores ed25519 private as 64B (seed || pub). Crypto wants the 32B seed.
            guard priv.count == 64 else {
                throw ParseError.malformed("ed25519 private key has unexpected length \(priv.count)")
            }
            let seed = priv.prefix(32)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: key)
        case "ecdsa-sha2-nistp256":
            return try Self.parseECDSA(reader: &inner, expectedScalarBytes: 32) { d in
                try NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey(rawRepresentation: d))
            }
        case "ecdsa-sha2-nistp384":
            return try Self.parseECDSA(reader: &inner, expectedScalarBytes: 48) { d in
                try NIOSSHPrivateKey(p384Key: P384.Signing.PrivateKey(rawRepresentation: d))
            }
        case "ecdsa-sha2-nistp521":
            return try Self.parseECDSA(reader: &inner, expectedScalarBytes: 66) { d in
                try NIOSSHPrivateKey(p521Key: P521.Signing.PrivateKey(rawRepresentation: d))
            }
        default:
            throw ParseError.unsupportedKeyFormat(keyType)
        }
    }

    private static func parseECDSA(
        reader: inout ByteReader,
        expectedScalarBytes: Int,
        construct: (Data) throws -> NIOSSHPrivateKey
    ) throws -> NIOSSHPrivateKey {
        _ = try reader.readSSHString() // curve name (e.g. "nistp256")
        _ = try reader.readSSHString() // Q (uncompressed public point)
        // OpenSSH stores the private scalar as an `mpint` — uses a leading
        // 0x00 sign byte when MSB is set. swift-crypto wants exactly
        // `expectedScalarBytes` of raw scalar; normalize either way.
        var d = try reader.readSSHString()
        if d.count == expectedScalarBytes + 1, d.first == 0x00 {
            d.removeFirst()
        }
        if d.count < expectedScalarBytes {
            d = Data(repeating: 0, count: expectedScalarBytes - d.count) + d
        }
        guard d.count == expectedScalarBytes else {
            throw ParseError.malformed("ecdsa scalar has unexpected length \(d.count)")
        }
        return try construct(d)
    }
}

private struct ByteReader {
    private let buffer: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.buffer = data
    }

    mutating func read(count: Int) throws -> Data {
        guard offset + count <= buffer.count else {
            throw OpenSSHPrivateKeyParser.ParseError.malformed("short read at \(offset)")
        }
        let slice = buffer.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(count: 4)
        return bytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> UInt32 in
            let b0 = UInt32(ptr[0]) << 24
            let b1 = UInt32(ptr[1]) << 16
            let b2 = UInt32(ptr[2]) << 8
            let b3 = UInt32(ptr[3])
            return b0 | b1 | b2 | b3
        }
    }

    mutating func readSSHString() throws -> Data {
        let length = try readUInt32()
        return try read(count: Int(length))
    }
}
