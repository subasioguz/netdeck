import Foundation

/// A bidirectional byte stream to a device (serial console, SSH, ...).
public protocol Transport: AnyObject, Sendable {
    /// Human-readable target, e.g. "/dev/cu.usbserial-XYZ @ 9600" or "admin@192.0.2.10".
    var displayName: String { get }
    /// Opens the stream. `onData` is called in arrival order on a private queue.
    /// `onClose` is called once when the stream ends; the argument is an error description or nil.
    func open(
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) throws
    func send(_ data: Data) throws
    func close()
    /// The SSH algorithms the connection settled on, once known (embedded SSH client only).
    var sshAlgorithms: SSHAlgorithms? { get }
}

extension Transport {
    public var sshAlgorithms: SSHAlgorithms? { nil }
}

/// What an SSH key exchange settled on.
public struct SSHAlgorithms: Equatable, Sendable {
    public var keyExchange: String
    public var hostKey: String
    public var cipher: String
    /// Nil for AEAD ciphers such as AES-GCM.
    public var mac: String?
    /// The ones kept only for older devices (SHA-1, the 1024-bit group, CBC, 3DES).
    public var legacy: [String]

    public init(keyExchange: String, hostKey: String, cipher: String, mac: String?, legacy: [String]) {
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.cipher = cipher
        self.mac = mac
        self.legacy = legacy
    }

    /// "curve25519-sha256, ssh-ed25519, aes256-gcm@openssh.com"
    public var list: String {
        [keyExchange, hostKey, cipher, mac].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum TransportError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case writeFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return t("Could not open the connection: %@", m)
        case .writeFailed(let m): return t("Could not send data: %@", m)
        case .notOpen: return t("The connection is not open.")
        }
    }
}
