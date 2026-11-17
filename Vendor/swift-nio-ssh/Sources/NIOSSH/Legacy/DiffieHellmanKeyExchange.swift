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

/// A fixed finite-field Diffie-Hellman group with generator 2 and the hash its SSH method uses
/// (RFC 4253 §8, RFC 8268).
protocol DiffieHellmanGroup: _NIOSSHSendableMetatype {
    associatedtype Hasher: HashFunction

    static var keyExchangeAlgorithmNames: [Substring] { get }

    static var modulus: SSHMontgomeryModulus { get }
}

enum DiffieHellmanGroup1SHA1: DiffieHellmanGroup {
    typealias Hasher = Insecure.SHA1
    static let keyExchangeAlgorithmNames: [Substring] = ["diffie-hellman-group1-sha1"]
    static var modulus: SSHMontgomeryModulus { DiffieHellmanPrimes.oakleyGroup2 }
}

enum DiffieHellmanGroup14SHA1: DiffieHellmanGroup {
    typealias Hasher = Insecure.SHA1
    static let keyExchangeAlgorithmNames: [Substring] = ["diffie-hellman-group14-sha1"]
    static var modulus: SSHMontgomeryModulus { DiffieHellmanPrimes.modp2048 }
}

enum DiffieHellmanGroup14SHA256: DiffieHellmanGroup {
    typealias Hasher = SHA256
    static let keyExchangeAlgorithmNames: [Substring] = ["diffie-hellman-group14-sha256"]
    static var modulus: SSHMontgomeryModulus { DiffieHellmanPrimes.modp2048 }
}

enum DiffieHellmanGroup16SHA512: DiffieHellmanGroup {
    typealias Hasher = SHA512
    static let keyExchangeAlgorithmNames: [Substring] = ["diffie-hellman-group16-sha512"]
    static var modulus: SSHMontgomeryModulus { DiffieHellmanPrimes.modp4096 }
}

/// Finite-field Diffie-Hellman key exchange. It reuses the ECDH message types: KEXDH_INIT/REPLY share their
/// numbers (30/31) and layout with KEX_ECDH_INIT/REPLY, and an mpint on the wire is an SSH string holding
/// the integer's two's-complement bytes, so `publicKey` carries e or f as an mpint body.
struct DiffieHellmanKeyExchange<Group: DiffieHellmanGroup>: EllipticCurveKeyExchangeProtocol {
    private var previousSessionIdentifier: ByteBuffer?
    private let ourRole: SSHConnectionRole
    private let privateExponent: SSHUnsignedInteger
    private let ourPublicValue: SSHUnsignedInteger

    init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        // 512 random bits, the floor OpenSSH uses (twice the 256-bit strength of the strongest cipher).
        var rng = CSPRNG()
        var limbs = (0..<8).map { _ in rng.next() }
        limbs[7] |= 1 << 63
        self.privateExponent = SSHUnsignedInteger(limbs: limbs)
        self.ourPublicValue = Group.modulus.power(SSHUnsignedInteger(2), self.privateExponent)
    }

    static var keyExchangeAlgorithmNames: [Substring] {
        Group.keyExchangeAlgorithmNames
    }

    func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> SSHMessage.KeyExchangeECDHInitMessage {
        precondition(self.ourRole.isClient, "Only clients may initiate the client side key exchange!")
        return .init(publicKey: Self.mpintBody(self.ourPublicValue, allocator: allocator))
    }

    mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage message: SSHMessage.KeyExchangeECDHInitMessage,
        serverHostKey: NIOSSHPrivateKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, SSHMessage.KeyExchangeECDHReplyMessage) {
        precondition(self.ourRole.isServer, "Only servers may receive a client key exchange packet!")
        let (result, exchangeHash) = try self.finalize(
            theirValueBytes: message.publicKey,
            initialExchangeBytes: &initialExchangeBytes,
            serverHostKey: serverHostKey.publicKey,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )
        let signature = try serverHostKey.sign(digest: exchangeHash)
        let reply = SSHMessage.KeyExchangeECDHReplyMessage(
            hostKey: serverHostKey.publicKey,
            publicKey: Self.mpintBody(self.ourPublicValue, allocator: allocator),
            signature: signature
        )
        return (result, reply)
    }

    mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage message: SSHMessage.KeyExchangeECDHReplyMessage,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        precondition(self.ourRole.isClient, "Only clients may receive a server key exchange packet!")
        let (result, exchangeHash) = try self.finalize(
            theirValueBytes: message.publicKey,
            initialExchangeBytes: &initialExchangeBytes,
            serverHostKey: message.hostKey,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )
        guard message.hostKey.isValidSignature(message.signature, for: exchangeHash) else {
            throw NIOSSHError.invalidExchangeHashSignature
        }
        return result
    }

    private func finalize(
        theirValueBytes: ByteBuffer,
        initialExchangeBytes: inout ByteBuffer,
        serverHostKey: NIOSSHPublicKey,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, Group.Hasher.Digest) {
        let theirValue = try Self.validatedPublicValue(theirValueBytes)
        let sharedSecret = Group.modulus.power(theirValue, self.privateExponent)
        let k = Self.mpint(sharedSecret)

        // H = HASH(V_C || V_S || I_C || I_S || K_S || e || f || K); the first four are already in place.
        initialExchangeBytes.writeCompositeSSHString { $0.writeSSHHostKey(serverHostKey) }
        let (e, f) =
            self.ourRole.isClient ? (self.ourPublicValue, theirValue) : (theirValue, self.ourPublicValue)
        initialExchangeBytes.writePositiveMPInt(e.bigEndianBytes)
        initialExchangeBytes.writePositiveMPInt(f.bigEndianBytes)

        var hasher = Group.Hasher()
        hasher.update(data: initialExchangeBytes.readableBytesView)
        hasher.update(data: k)
        let exchangeHash = hasher.finalize()

        let sessionID: ByteBuffer
        if let previous = self.previousSessionIdentifier {
            sessionID = previous
        } else {
            var bytes = allocator.buffer(capacity: Group.Hasher.Digest.byteCount)
            bytes.writeContiguousBytes(exchangeHash)
            sessionID = bytes
        }

        let keys = SSHKeyDerivation<Group.Hasher>(sharedSecretMPInt: k, exchangeHash: exchangeHash, sessionID: sessionID)
            .sessionKeys(role: self.ourRole, sizes: expectedKeySizes)
        return (KeyExchangeResult(sessionID: sessionID, keys: keys), exchangeHash)
    }

    /// RFC 4253 §8: e and f must lie in [1, p-1]; like OpenSSH we also refuse 1 and p-1, which would
    /// make the shared secret predictable.
    static func validatedPublicValue(_ bytes: ByteBuffer) throws -> SSHUnsignedInteger {
        let view = bytes.readableBytesView
        guard let first = view.first, first & 0x80 == 0 else {
            throw NIOSSHError.invalidSSHMessage(reason: "Diffie-Hellman value is empty or negative")
        }
        let value = SSHUnsignedInteger(bigEndianBytes: view)
        let pMinusOne = Group.modulus.modulus.subtracting(SSHUnsignedInteger(1))
        guard SSHUnsignedInteger(1) < value, value < pMinusOne else {
            throw NIOSSHError.invalidSSHMessage(reason: "Diffie-Hellman value out of range")
        }
        return value
    }

    /// The bytes an mpint string carries: the magnitude, with a zero byte in front if its top bit is set.
    static func mpintBody(_ value: SSHUnsignedInteger, allocator: ByteBufferAllocator) -> ByteBuffer {
        var magnitude = value.bigEndianBytes
        if let first = magnitude.first, first & 0x80 != 0 { magnitude.insert(0, at: 0) }
        var buffer = allocator.buffer(capacity: magnitude.count)
        buffer.writeBytes(magnitude)
        return buffer
    }

    /// A complete mpint: uint32 length, then the body.
    static func mpint(_ value: SSHUnsignedInteger) -> [UInt8] {
        var body = value.bigEndianBytes
        if let first = body.first, first & 0x80 != 0 { body.insert(0, at: 0) }
        let n = UInt32(body.count)
        return [UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
            + body
    }
}

/// Session keys from a finished key exchange (RFC 4253 §7.2), including the extension for keys longer than
/// the hash: K1 = HASH(K || H || X || session_id), Kn = HASH(K || H || K1 || ... || Kn-1).
struct SSHKeyDerivation<Hasher: HashFunction> {
    /// A hasher already fed K (as an mpint) and H.
    private let base: Hasher
    private let sessionID: ByteBuffer

    init(sharedSecretMPInt k: [UInt8], exchangeHash: Hasher.Digest, sessionID: ByteBuffer) {
        var base = Hasher()
        base.update(data: k)
        exchangeHash.withUnsafeBytes { base.update(bufferPointer: $0) }
        self.base = base
        self.sessionID = sessionID
    }

    init(base: Hasher, sessionID: ByteBuffer) {
        self.base = base
        self.sessionID = sessionID
    }

    func key(_ letter: Character, length: Int) -> [UInt8] {
        var first = self.base
        first.update(data: [letter.asciiValue!])
        first.update(data: self.sessionID.readableBytesView)
        var key = Array(first.finalize())
        while key.count < length {
            var next = self.base
            next.update(data: key)
            key += Array(next.finalize())
        }
        return Array(key.prefix(length))
    }

    func sessionKeys(role: SSHConnectionRole, sizes: ExpectedKeySizes) -> NIOSSHSessionKeys {
        let ivCS = self.key("A", length: sizes.ivSize)
        let ivSC = self.key("B", length: sizes.ivSize)
        let encCS = SymmetricKey(data: self.key("C", length: sizes.encryptionKeySize))
        let encSC = SymmetricKey(data: self.key("D", length: sizes.encryptionKeySize))
        let macCS = SymmetricKey(data: self.key("E", length: sizes.macKeySize))
        let macSC = SymmetricKey(data: self.key("F", length: sizes.macKeySize))
        if role.isClient {
            return NIOSSHSessionKeys(
                initialInboundIV: ivSC, initialOutboundIV: ivCS,
                inboundEncryptionKey: encSC, outboundEncryptionKey: encCS,
                inboundMACKey: macSC, outboundMACKey: macCS
            )
        } else {
            return NIOSSHSessionKeys(
                initialInboundIV: ivCS, initialOutboundIV: ivSC,
                inboundEncryptionKey: encCS, outboundEncryptionKey: encSC,
                inboundMACKey: macCS, outboundMACKey: macSC
            )
        }
    }
}

enum DiffieHellmanPrimes {
    /// 1024-bit MODP prime, RFC 2409 §6.2 (Oakley group 2).
    static let oakleyGroup2 = SSHMontgomeryModulus(
        SSHUnsignedInteger(
            hex: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF
            """
        )!
    )!

    /// 2048-bit MODP prime, RFC 3526 §3 (group 14).
    static let modp2048 = SSHMontgomeryModulus(
        SSHUnsignedInteger(
            hex: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
            98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
            9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
            3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF
            """
        )!
    )!

    /// 4096-bit MODP prime, RFC 3526 §5 (group 16).
    static let modp4096 = SSHMontgomeryModulus(
        SSHUnsignedInteger(
            hex: """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
            98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
            9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
            3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33
            A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
            ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864
            D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2
            08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7
            88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8
            DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2
            233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9
            93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF
            """
        )!
    )!
}
