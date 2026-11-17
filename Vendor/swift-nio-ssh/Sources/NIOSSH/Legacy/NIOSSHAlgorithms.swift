//===----------------------------------------------------------------------===//
//
// Netdeck patch to SwiftNIO SSH (see PATCHES.md).
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

import NIOCore

/// The algorithm lists of this build, most preferred first. Modern algorithms come first, so a device that
/// supports them never ends up on an older one; the legacy ones are only chosen when a device offers
/// nothing better.
public enum NIOSSHAlgorithms {
    /// Every key exchange method, the default of `keyExchangeAlgorithms` on both configurations.
    public static var keyExchange: [String] {
        SSHKeyExchangeStateMachine.supportedKeyExchangeAlgorithms.map(String.init)
    }

    /// The host key algorithms a client accepts.
    public static var hostKey: [String] {
        SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms.map(String.init)
    }

    /// Algorithms kept only for older devices: SHA-1 key exchanges and signatures, the 1024-bit group,
    /// CBC ciphers and 3DES.
    public static let legacy: Set<String> = [
        "diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1", "ssh-rsa",
        "aes128-cbc", "aes192-cbc", "aes256-cbc", "3des-cbc", "hmac-sha1",
    ]

    #if canImport(CommonCrypto)
    /// Client transport protection: AES-GCM, then AES-CTR, AES-CBC and 3DES-CBC, each with HMAC-SHA2-256,
    /// HMAC-SHA2-512 or HMAC-SHA1.
    public static let clientTransportProtectionSchemes: [(NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type] =
        Constants.bundledTransportProtectionSchemes
        + schemes(AES256CTR.self) + schemes(AES192CTR.self) + schemes(AES128CTR.self)
        + schemes(AES256CBC.self) + schemes(AES192CBC.self) + schemes(AES128CBC.self)
        + schemes(TripleDESCBC.self)

    private static func schemes<Cipher: NIOSSHBlockCipher>(
        _: Cipher.Type
    ) -> [(NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type] {
        [
            NIOSSHCipherMACTransportProtection<Cipher, HMACSHA256>.self,
            NIOSSHCipherMACTransportProtection<Cipher, HMACSHA512>.self,
            NIOSSHCipherMACTransportProtection<Cipher, HMACSHA1>.self,
        ]
    }
    #endif
}

/// What a key exchange settled on, reported to `SSHClientConfiguration.algorithmsNegotiated`.
public struct NIOSSHNegotiatedAlgorithms: Hashable, Sendable {
    public var keyExchange: String
    public var hostKey: String
    public var cipher: String
    /// Nil for AEAD ciphers (AES-GCM), which don't use a separate MAC.
    public var mac: String?

    public init(keyExchange: String, hostKey: String, cipher: String, mac: String?) {
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.cipher = cipher
        self.mac = mac
    }

    /// The legacy algorithms among these, in negotiation order.
    public var legacyAlgorithms: [String] {
        [self.keyExchange, self.hostKey, self.cipher, self.mac].compactMap { $0 }
            .filter { NIOSSHAlgorithms.legacy.contains($0) }
    }
}

/// Entry points for Netdeck's tests of the legacy algorithms. Not for other use.
public enum _NIOSSHLegacyTesting {
    /// base^exponent mod modulus (big-endian magnitudes); nil for an even modulus or an unreduced base.
    public static func modularPower(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8]? {
        let b = SSHUnsignedInteger(bigEndianBytes: base)
        guard let m = SSHMontgomeryModulus(SSHUnsignedInteger(bigEndianBytes: modulus)), b < m.modulus else { return nil }
        return m.power(b, SSHUnsignedInteger(bigEndianBytes: exponent)).bigEndianBytes
    }

    /// Whether `key` (an RSA key) accepts `signature` made with `algorithm` over `message`.
    public static func isValidRSASignature(
        publicKey key: NIOSSHPublicKey,
        algorithm: String,
        signature: [UInt8],
        message: [UInt8]
    ) -> Bool {
        guard case .rsa(let rsa) = key.backingKey, let alg = NIOSSHRSASignatureAlgorithm(rawValue: algorithm) else {
            return false
        }
        return rsa.isValidSignature(NIOSSHRSASignature(algorithm: alg, bytes: signature), for: message)
    }

    /// The modulus of an RSA key, big-endian.
    public static func rsaModulus(_ key: NIOSSHPublicKey) -> [UInt8]? {
        guard case .rsa(let rsa) = key.backingKey else { return nil }
        return rsa.modulus.bigEndianBytes
    }

    /// Whether a Diffie-Hellman exchange accepts this e or f (the bytes of the mpint).
    public static func acceptsDiffieHellmanValue(_ bytes: [UInt8], keyExchange: String) -> Bool {
        let buffer = ByteBuffer(bytes: bytes)
        func check<Group: DiffieHellmanGroup>(_: Group.Type) -> Bool {
            (try? DiffieHellmanKeyExchange<Group>.validatedPublicValue(buffer)) != nil
        }
        switch keyExchange {
        case "diffie-hellman-group1-sha1": return check(DiffieHellmanGroup1SHA1.self)
        case "diffie-hellman-group14-sha1", "diffie-hellman-group14-sha256": return check(DiffieHellmanGroup14SHA1.self)
        case "diffie-hellman-group16-sha512": return check(DiffieHellmanGroup16SHA512.self)
        default: return false
        }
    }

    /// The prime p of a Diffie-Hellman method, big-endian.
    public static func diffieHellmanPrime(_ keyExchange: String) -> [UInt8]? {
        switch keyExchange {
        case "diffie-hellman-group1-sha1": return DiffieHellmanGroup1SHA1.modulus.modulus.bigEndianBytes
        case "diffie-hellman-group14-sha1", "diffie-hellman-group14-sha256":
            return DiffieHellmanGroup14SHA1.modulus.modulus.bigEndianBytes
        case "diffie-hellman-group16-sha512": return DiffieHellmanGroup16SHA512.modulus.modulus.bigEndianBytes
        default: return nil
        }
    }
}
