//===----------------------------------------------------------------------===//
//
// Netdeck patch to SwiftNIO SSH (see PATCHES.md).
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat

#if canImport(Security)
import Security
#endif

/// The signature algorithms of an RSA key: RFC 4253 "ssh-rsa" (SHA-1) and RFC 8332 "rsa-sha2-256/512".
enum NIOSSHRSASignatureAlgorithm: String, CaseIterable, Sendable {
    case sha512 = "rsa-sha2-512"
    case sha256 = "rsa-sha2-256"
    case sha1 = "ssh-rsa"

    /// The DER DigestInfo prefix of EMSA-PKCS1-v1_5 (RFC 8017 §9.2, note 1).
    fileprivate var digestInfoPrefix: [UInt8] {
        switch self {
        case .sha1:
            return [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2B, 0x0E, 0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14]
        case .sha256:
            return [
                0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00,
                0x04, 0x20,
            ]
        case .sha512:
            return [
                0x30, 0x51, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00,
                0x04, 0x40,
            ]
        }
    }

    fileprivate func hash<Bytes: DataProtocol>(_ message: Bytes) -> [UInt8] {
        switch self {
        case .sha1: return Array(Insecure.SHA1.hash(data: message))
        case .sha256: return Array(SHA256.hash(data: message))
        case .sha512: return Array(SHA512.hash(data: message))
        }
    }

    #if canImport(Security)
    fileprivate var secKeyAlgorithm: SecKeyAlgorithm {
        switch self {
        case .sha1: return .rsaSignatureMessagePKCS1v15SHA1
        case .sha256: return .rsaSignatureMessagePKCS1v15SHA256
        case .sha512: return .rsaSignatureMessagePKCS1v15SHA512
        }
    }
    #endif
}

/// An RSA public key ("ssh-rsa" blob: string "ssh-rsa", mpint e, mpint n), verify only.
struct NIOSSHRSAPublicKey: Hashable, Sendable {
    static let prefix = "ssh-rsa".utf8

    let modulus: SSHUnsignedInteger
    let publicExponent: SSHUnsignedInteger

    /// Old network gear still ships 512- and 768-bit host keys, so the floor is lower than OpenSSH's 1024.
    static let minimumModulusBits = 512
    static let maximumModulusBits = 16384

    init(modulus: SSHUnsignedInteger, publicExponent: SSHUnsignedInteger) throws {
        guard modulus.bitWidth >= Self.minimumModulusBits, modulus.bitWidth <= Self.maximumModulusBits,
            modulus.bit(0), publicExponent.bit(0), SSHUnsignedInteger(1) < publicExponent, publicExponent < modulus
        else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "unusable RSA key")
        }
        self.modulus = modulus
        self.publicExponent = publicExponent
    }

    /// Checks an EMSA-PKCS1-v1_5 signature over `message` by re-encoding the expected block and comparing it whole.
    func isValidSignature<Bytes: DataProtocol>(_ signature: NIOSSHRSASignature, for message: Bytes) -> Bool {
        let k = (self.modulus.bitWidth + 7) / 8
        // Some implementations drop leading zero bytes of the signature; it can never be longer than the modulus.
        guard signature.bytes.count <= k else { return false }
        let s = SSHUnsignedInteger(bigEndianBytes: signature.bytes)
        guard s < self.modulus, let context = SSHMontgomeryModulus(self.modulus),
            let encoded = context.power(s, self.publicExponent).bigEndianBytes(width: k)
        else { return false }

        let t = signature.algorithm.digestInfoPrefix + signature.algorithm.hash(message)
        guard k >= t.count + 11 else { return false }
        let expected = [0x00, 0x01] + [UInt8](repeating: 0xFF, count: k - t.count - 3) + [0x00] + t
        return encoded == expected
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writePositiveMPInt(self.publicExponent.bigEndianBytes)
            + buffer.writePositiveMPInt(self.modulus.bigEndianBytes)
    }

    /// Reads "mpint e, mpint n" (the part after the "ssh-rsa" string).
    static func read(from buffer: inout ByteBuffer) throws -> NIOSSHRSAPublicKey? {
        guard let e = buffer.readSSHString(), let n = buffer.readSSHString() else { return nil }
        for value in [e, n] where (value.readableBytesView.first ?? 0) & 0x80 != 0 {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "negative RSA parameter")
        }
        return try NIOSSHRSAPublicKey(
            modulus: SSHUnsignedInteger(bigEndianBytes: n.readableBytesView),
            publicExponent: SSHUnsignedInteger(bigEndianBytes: e.readableBytesView)
        )
    }
}

/// An RSA signature blob: string algorithm, string signature (big-endian, modulus length).
struct NIOSSHRSASignature: Hashable, Sendable {
    let algorithm: NIOSSHRSASignatureAlgorithm
    let bytes: [UInt8]

    static func algorithm<Bytes: Collection>(named name: Bytes) -> NIOSSHRSASignatureAlgorithm?
    where Bytes.Element == UInt8 {
        NIOSSHRSASignatureAlgorithm.allCases.first { name.elementsEqual($0.rawValue.utf8) }
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.algorithm.rawValue.utf8) + buffer.writeSSHString(self.bytes)
    }
}

#if canImport(Security)
/// An RSA host key held by Security.framework that signs with one fixed algorithm. Only an SSH server
/// (tests) needs this; the client merely verifies.
final class NIOSSHRSAPrivateKey: @unchecked Sendable {
    // SecKey is an immutable, thread-safe CF object.
    private let key: SecKey
    let algorithm: NIOSSHRSASignatureAlgorithm
    let publicKey: NIOSSHRSAPublicKey

    init(key: SecKey, algorithm: NIOSSHRSASignatureAlgorithm) throws {
        guard let pub = SecKeyCopyPublicKey(key),
            let der = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
            let (n, e) = Self.parsePKCS1PublicKey(Array(der))
        else {
            throw NIOSSHError.invalidOpenSSHPublicKey(reason: "not an RSA key")
        }
        self.key = key
        self.algorithm = algorithm
        self.publicKey = try NIOSSHRSAPublicKey(
            modulus: SSHUnsignedInteger(bigEndianBytes: n),
            publicExponent: SSHUnsignedInteger(bigEndianBytes: e)
        )
    }

    func sign<Bytes: DataProtocol>(_ message: Bytes) throws -> NIOSSHRSASignature {
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(self.key, self.algorithm.secKeyAlgorithm, Data(message) as CFData, &error)
                as Data?
        else {
            throw error?.takeRetainedValue() ?? NIOSSHError.invalidExchangeHashSignature
        }
        return NIOSSHRSASignature(algorithm: self.algorithm, bytes: Array(signature))
    }

    /// RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER } (DER).
    private static func parsePKCS1PublicKey(_ der: [UInt8]) -> (n: [UInt8], e: [UInt8])? {
        var index = 0
        func readLength() -> Int? {
            guard index < der.count else { return nil }
            let first = der[index]
            index += 1
            guard first & 0x80 != 0 else { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, index + count <= der.count else { return nil }
            var length = 0
            for _ in 0..<count {
                length = length << 8 | Int(der[index])
                index += 1
            }
            return length
        }
        func readInteger() -> [UInt8]? {
            guard index < der.count, der[index] == 0x02 else { return nil }
            index += 1
            guard let length = readLength(), index + length <= der.count else { return nil }
            defer { index += length }
            return Array(der[index..<(index + length)].drop(while: { $0 == 0 }))
        }
        guard der.first == 0x30 else { return nil }
        index = 1
        guard readLength() != nil, let n = readInteger(), let e = readInteger() else { return nil }
        return (n, e)
    }
}
#endif
