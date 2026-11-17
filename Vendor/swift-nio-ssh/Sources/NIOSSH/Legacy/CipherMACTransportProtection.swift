//===----------------------------------------------------------------------===//
//
// Netdeck patch to SwiftNIO SSH (see PATCHES.md).
// Licensed under Apache License v2.0, like the rest of this package.
//
//===----------------------------------------------------------------------===//

#if canImport(CommonCrypto)
import CommonCrypto
import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat

/// A block cipher in CTR or CBC mode (RFC 4344, RFC 4253 §6.3), run by CommonCrypto.
public protocol NIOSSHBlockCipher {
    static var cipherName: String { get }
    static var keySize: Int { get }
    static var blockSize: Int { get }
    static var algorithm: CCAlgorithm { get }
    static var mode: CCMode { get }
}

/// An HMAC for encrypt-and-MAC transports (RFC 4253 §6.4, RFC 6668): MAC(key, uint32 seq || plaintext packet).
public protocol NIOSSHPacketMAC {
    static var macName: String { get }
    static var keySize: Int { get }
    static var outputSize: Int { get }
    static func code(key: SymmetricKey, sequenceNumber: UInt32, packet: UnsafeRawBufferPointer) -> [UInt8]
}

public enum AES128CTR: NIOSSHBlockCipher {
    public static let cipherName = "aes128-ctr"
    public static let keySize = 16
    public static let blockSize = 16
    public static var algorithm: CCAlgorithm { CCAlgorithm(kCCAlgorithmAES) }
    public static var mode: CCMode { CCMode(kCCModeCTR) }
}

public enum AES192CTR: NIOSSHBlockCipher {
    public static let cipherName = "aes192-ctr"
    public static let keySize = 24
    public static let blockSize = 16
    public static var algorithm: CCAlgorithm { CCAlgorithm(kCCAlgorithmAES) }
    public static var mode: CCMode { CCMode(kCCModeCTR) }
}

public enum AES256CTR: NIOSSHBlockCipher {
    public static let cipherName = "aes256-ctr"
    public static let keySize = 32
    public static let blockSize = 16
    public static var algorithm: CCAlgorithm { CCAlgorithm(kCCAlgorithmAES) }
    public static var mode: CCMode { CCMode(kCCModeCTR) }
}

public enum AES128CBC: NIOSSHBlockCipher {
    public static let cipherName = "aes128-cbc"
    public static let keySize = 16
    public static let blockSize = 16
    public static var algorithm: CCAlgorithm { CCAlgorithm(kCCAlgorithmAES) }
    public static var mode: CCMode { CCMode(kCCModeCBC) }
}

public enum AES192CBC: NIOSSHBlockCipher {
    public static let cipherName = "aes192-cbc"
    public static let keySize = 24
    public static let blockSize = 16
    public static var algorithm: CCAlgorithm { CCAlgorithm(kCCAlgorithmAES) }
    public static var mode: CCMode { CCMode(kCCModeCBC) }
}

public enum AES256CBC: NIOSSHBlockCipher {
    public static let cipherName = "aes256-cbc"
    public static let keySize = 32
    public static let blockSize = 16
    public static var algorithm: CCAlgorithm { CCAlgorithm(kCCAlgorithmAES) }
    public static var mode: CCMode { CCMode(kCCModeCBC) }
}

public enum TripleDESCBC: NIOSSHBlockCipher {
    public static let cipherName = "3des-cbc"
    public static let keySize = 24
    public static let blockSize = 8
    public static var algorithm: CCAlgorithm { CCAlgorithm(kCCAlgorithm3DES) }
    public static var mode: CCMode { CCMode(kCCModeCBC) }
}

public enum HMACSHA256: NIOSSHPacketMAC {
    public static let macName = "hmac-sha2-256"
    public static let keySize = 32
    public static let outputSize = 32
    public static func code(key: SymmetricKey, sequenceNumber: UInt32, packet: UnsafeRawBufferPointer) -> [UInt8] {
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: sequenceNumber.bigEndianBytes)
        hmac.update(data: packet)
        return Array(hmac.finalize())
    }
}

public enum HMACSHA512: NIOSSHPacketMAC {
    public static let macName = "hmac-sha2-512"
    public static let keySize = 64
    public static let outputSize = 64
    public static func code(key: SymmetricKey, sequenceNumber: UInt32, packet: UnsafeRawBufferPointer) -> [UInt8] {
        var hmac = HMAC<SHA512>(key: key)
        hmac.update(data: sequenceNumber.bigEndianBytes)
        hmac.update(data: packet)
        return Array(hmac.finalize())
    }
}

public enum HMACSHA1: NIOSSHPacketMAC {
    public static let macName = "hmac-sha1"
    public static let keySize = 20
    public static let outputSize = 20
    public static func code(key: SymmetricKey, sequenceNumber: UInt32, packet: UnsafeRawBufferPointer) -> [UInt8] {
        var hmac = HMAC<Insecure.SHA1>(key: key)
        hmac.update(data: sequenceNumber.bigEndianBytes)
        hmac.update(data: packet)
        return Array(hmac.finalize())
    }
}

extension UInt32 {
    fileprivate var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 8), UInt8(truncatingIfNeeded: self)]
    }
}

/// A non-AEAD transport: a CTR or CBC cipher with an encrypt-and-MAC HMAC. The packet length is encrypted,
/// so the first block is decrypted on its own to learn it.
public final class NIOSSHCipherMACTransportProtection<Cipher: NIOSSHBlockCipher, MAC: NIOSSHPacketMAC>:
    NIOSSHTransportProtection, _NIOSSHSendableMetatype
{
    public static var cipherName: String { Cipher.cipherName }
    public static var macName: String? { MAC.macName }
    public static var cipherBlockSize: Int { Cipher.blockSize }
    public static var keySizes: ExpectedKeySizes {
        ExpectedKeySizes(ivSize: Cipher.blockSize, encryptionKeySize: Cipher.keySize, macKeySize: MAC.keySize)
    }

    public var macBytes: Int { MAC.outputSize }
    public var lengthEncrypted: Bool { true }

    private var encryptor: SSHCryptor
    private var decryptor: SSHCryptor
    private var outboundMACKey: SymmetricKey
    private var inboundMACKey: SymmetricKey

    public required init(initialKeys: NIOSSHSessionKeys) throws {
        (self.encryptor, self.decryptor) = try Self.cryptors(initialKeys)
        self.outboundMACKey = initialKeys.outboundMACKey
        self.inboundMACKey = initialKeys.inboundMACKey
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        (self.encryptor, self.decryptor) = try Self.cryptors(newKeys)
        self.outboundMACKey = newKeys.outboundMACKey
        self.inboundMACKey = newKeys.inboundMACKey
    }

    private static func cryptors(_ keys: NIOSSHSessionKeys) throws -> (SSHCryptor, SSHCryptor) {
        guard keys.outboundEncryptionKey.bitCount == Cipher.keySize * 8,
            keys.inboundEncryptionKey.bitCount == Cipher.keySize * 8,
            keys.outboundMACKey.bitCount == MAC.keySize * 8, keys.inboundMACKey.bitCount == MAC.keySize * 8,
            keys.initialOutboundIV.count == Cipher.blockSize, keys.initialInboundIV.count == Cipher.blockSize
        else {
            throw NIOSSHError.invalidKeySize
        }
        return (
            try SSHCryptor(Cipher.self, encrypt: true, key: keys.outboundEncryptionKey, iv: keys.initialOutboundIV),
            try SSHCryptor(Cipher.self, encrypt: false, key: keys.inboundEncryptionKey, iv: keys.initialInboundIV)
        )
    }

    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        let index = source.readerIndex
        guard let block = source.getBytes(at: index, length: Cipher.blockSize) else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        source.setBytes(try self.decryptor.update(block), at: index)
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        // source: length (4) and the rest of the packet, the first block already in plaintext, then the MAC.
        let start = source.readerIndex
        let packetBytes = source.readableBytes - MAC.outputSize
        guard packetBytes >= Cipher.blockSize, packetBytes % Cipher.blockSize == 0 else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        if packetBytes > Cipher.blockSize {
            let rest = source.getBytes(at: start + Cipher.blockSize, length: packetBytes - Cipher.blockSize)!
            source.setBytes(try self.decryptor.update(rest), at: start + Cipher.blockSize)
        }

        let expected = source.withUnsafeReadableBytes {
            MAC.code(
                key: self.inboundMACKey,
                sequenceNumber: sequenceNumber,
                packet: UnsafeRawBufferPointer(rebasing: $0.prefix(packetBytes))
            )
        }
        let received = source.getBytes(at: start + packetBytes, length: MAC.outputSize)!
        // Constant time: fold every difference together.
        guard zip(expected, received).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw NIOSSHError.protocolViolation(protocolName: "transport", violation: "MAC verification failed")
        }

        // uint32 packet_length, byte padding_length, payload, padding (at least 4 bytes).
        guard let paddingLength = source.getInteger(at: start + 4, as: UInt8.self), paddingLength >= 4 else {
            throw NIOSSHError.insufficientPadding
        }
        let payloadLength = packetBytes - 5 - Int(paddingLength)
        guard payloadLength >= 0 else {
            throw NIOSSHError.excessPadding
        }
        source.moveReaderIndex(forwardBy: 5)
        let payload = source.readSlice(length: payloadLength)!
        source.moveReaderIndex(to: source.writerIndex)
        return payload
    }

    public func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        // destination: the whole plaintext packet, length field included.
        let start = destination.readerIndex
        let count = destination.readableBytes
        let mac = destination.withUnsafeReadableBytes {
            MAC.code(key: self.outboundMACKey, sequenceNumber: sequenceNumber, packet: $0)
        }
        let plaintext = destination.getBytes(at: start, length: count)!
        destination.setBytes(try self.encryptor.update(plaintext), at: start)
        destination.writeBytes(mac)
    }
}

/// A streaming CommonCrypto cryptor: the CTR counter or CBC chain carries over from one call to the next.
private final class SSHCryptor {
    private let ref: CCCryptorRef

    init<Cipher: NIOSSHBlockCipher>(_ cipher: Cipher.Type, encrypt: Bool, key: SymmetricKey, iv: [UInt8]) throws {
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), Cipher.mode, Cipher.algorithm,
                    CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, keyPtr.count, nil, 0, 0, 0,
                    &ref
                )
            }
        }
        guard status == kCCSuccess, let ref else {
            throw NIOSSHError.invalidKeySize
        }
        self.ref = ref
    }

    deinit {
        CCCryptorRelease(self.ref)
    }

    /// Whole blocks in, the same number of bytes out (CommonCrypto can't work in place for CBC).
    func update(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                CCCryptorUpdate(self.ref, inp.baseAddress, inp.count, out.baseAddress, out.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == input.count else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        return output
    }
}
#endif
