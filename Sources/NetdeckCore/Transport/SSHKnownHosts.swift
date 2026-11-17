import CryptoKit
import Foundation

/// Trust on first use for SSH host keys of the embedded SSH client (`NIOSSHTransport`).
///
/// Stored in `<support directory>/ssh_known_hosts.json` as
/// `{"host:port": {"type": "ssh-ed25519", "fingerprint": "SHA256:..."}}`. The fingerprint has the same
/// form `ssh-keygen -lf` prints, so it can be compared with the device's own output. Every function takes
/// an optional `directory` that replaces the support directory (tests).
public enum SSHKnownHosts {
    public static let fileName = "ssh_known_hosts.json"

    public struct Entry: Codable, Equatable, Sendable {
        public var type: String
        public var fingerprint: String

        public init(type: String, fingerprint: String) {
            self.type = type
            self.fingerprint = fingerprint
        }
    }

    public enum Check: Equatable, Sendable {
        /// Nothing was stored for this host and port; the key is now remembered.
        case firstUse
        case matched
    }

    /// The stored key differs from the one the server offered.
    public struct Mismatch: Error, LocalizedError, Equatable, Sendable {
        public let host: String
        public let port: Int
        public let stored: Entry
        public let offered: Entry

        /// Starts like OpenSSH's message so `ConnectionFailure.classify` recognises it in any language.
        public var errorDescription: String? {
            "Host key verification failed: \(SSHKnownHosts.key(host: host, port: port)) offered "
                + "\(offered.type) \(offered.fingerprint), expected \(stored.type) \(stored.fingerprint)."
        }
    }

    /// "192.0.2.10:22", "switch.example.com:2222", "[2001:db8::1]:22".
    public static func key(host: String, port: Int) -> String {
        APIPins.key(host: host, port: port)
    }

    /// Key type and SHA-256 fingerprint ("SHA256:<base64 without padding>") of a public key in OpenSSH
    /// form ("ssh-ed25519 AAAA..."). Nil when the text isn't one.
    public static func entry(openSSHKey: String) -> Entry? {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return Entry(type: String(parts[0]), fingerprint: fingerprint(ofKeyBlob: blob))
    }

    public static func fingerprint(ofKeyBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public static func stored(host: String, port: Int, directory: URL? = nil) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? fileURL(directory) else { return nil }
        return load(url)[key(host: host, port: port)]
    }

    /// First use stores the key; later it must match or `Mismatch` is thrown.
    @discardableResult
    public static func check(_ offered: Entry, host: String, port: Int, directory: URL? = nil) throws -> Check {
        lock.lock()
        defer { lock.unlock() }
        // Without a support folder nothing can be remembered; that is not a key change.
        guard let url = try? fileURL(directory) else { return .firstUse }
        var hosts = load(url)
        let k = key(host: host, port: port)
        if let stored = hosts[k] {
            guard stored.type == offered.type, stored.fingerprint == offered.fingerprint else {
                throw Mismatch(host: host, port: port, stored: stored, offered: offered)
            }
            return .matched
        }
        hosts[k] = offered
        // Not being able to save only means the next connection is a first use again.
        try? save(hosts, to: url)
        return .firstUse
    }

    /// Forgets the key, so the next connection trusts whatever the device offers. The UI calls this only
    /// after the user confirmed that the device really got a new key.
    public static func forget(host: String, port: Int, directory: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? fileURL(directory) else { return }
        var hosts = load(url)
        guard hosts.removeValue(forKey: key(host: host, port: port)) != nil else { return }
        try? save(hosts, to: url)
    }

    // MARK: File

    private static let lock = NSLock()

    private static func fileURL(_ directory: URL?) throws -> URL {
        let dir = try directory ?? AppPaths.supportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private static func load(_ url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let hosts = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return hosts
    }

    private static func save(_ hosts: [String: Entry], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(hosts).write(to: url, options: .atomic)
    }
}
