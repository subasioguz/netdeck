import CryptoKit
import Foundation
import Security

/// Trust on first use for device certificates, like SSH `known_hosts`. BMCs and NAS boxes ship
/// self-signed certificates, so the system can't vouch for them; instead Netdeck remembers the
/// SHA-256 of the leaf certificate per "host:port" on the first connection and refuses a different one later.
///
/// Stored in `<support directory>/api_pins.json` as `{"host:port": "hex sha-256"}`. Every function takes
/// an optional `directory` that replaces the support directory (tests).
public enum APIPins {
    public static let fileName = "api_pins.json"

    public enum Check: Equatable, Sendable {
        /// Nothing was stored for this host and port; the certificate is now remembered.
        case firstUse
        case matched
    }

    /// "192.0.2.10:443", "nas.example.com:5001", "[2001:db8::1]:443".
    public static func key(host: String, port: Int) -> String {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return (h.contains(":") ? "[\(h)]" : h) + ":\(port)"
    }

    /// Lowercase hex SHA-256 of a certificate's DER bytes.
    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public static func pinned(host: String, port: Int, directory: URL? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? fileURL(directory) else { return nil }
        return load(url)[key(host: host, port: port)]
    }

    /// First use stores the fingerprint; later it must match or `APIError.certificateChanged` is thrown.
    @discardableResult
    public static func check(fingerprint: String, host: String, port: Int, directory: URL? = nil) throws -> Check {
        lock.lock()
        defer { lock.unlock() }
        // Without a support folder nothing can be remembered; that is not a certificate change.
        guard let url = try? fileURL(directory) else { return .firstUse }
        var pins = load(url)
        let k = key(host: host, port: port)
        if let stored = pins[k] {
            guard stored.lowercased() == fingerprint.lowercased() else { throw APIError.certificateChanged(host: host) }
            return .matched
        }
        pins[k] = fingerprint.lowercased()
        // Not being able to save only means the next connection is a first use again.
        try? save(pins, to: url)
        return .firstUse
    }

    /// Replaces the stored fingerprint (a certificate the system itself trusts was renewed).
    static func store(fingerprint: String, host: String, port: Int, directory: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? fileURL(directory) else { return }
        var pins = load(url)
        let k = key(host: host, port: port)
        guard pins[k] != fingerprint.lowercased() else { return }
        pins[k] = fingerprint.lowercased()
        try? save(pins, to: url)
    }

    /// Forgets the certificate, so the next connection trusts whatever the device presents. The UI calls
    /// this only after the user confirmed that the device really got a new certificate.
    public static func forget(host: String, port: Int, directory: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? fileURL(directory) else { return }
        var pins = load(url)
        guard pins.removeValue(forKey: key(host: host, port: port)) != nil else { return }
        try? save(pins, to: url)
    }

    /// Same as `forget(host:port:)` for the address stored in a device profile ("https://nas.local:5001").
    public static func forget(url: String, directory: URL? = nil) {
        guard let endpoint = try? APIEndpoint(url) else { return }
        forget(host: endpoint.host, port: endpoint.port, directory: directory)
        // Without an explicit port Netdeck may also have reached Synology's 5001.
        if !endpoint.explicitPort { forget(host: endpoint.host, port: 5001, directory: directory) }
    }

    // MARK: File

    private static let lock = NSLock()

    private static func fileURL(_ directory: URL?) throws -> URL {
        let dir = try directory ?? AppPaths.supportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return pins
    }

    private static func save(_ pins: [String: String], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(pins).write(to: url, options: .atomic)
    }
}

/// URLSession delegate of one `APIHTTP`: checks every server certificate against `APIPins` and keeps
/// redirects on the same HTTPS host (credentials travel with the request).
final class APIPinningDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let directory: URL?
    private let lock = NSLock()
    private var mismatch = false

    init(host: String, port: Int, directory: URL?) {
        self.host = host
        self.port = port
        self.directory = directory
    }

    /// True once a connection was refused because the certificate didn't match the stored one.
    var sawMismatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mismatch
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if accept(trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let target = request.url
        let sameHost = target?.scheme?.lowercased() == "https"
            && APIPins.key(host: target?.host ?? "", port: target?.port ?? 443) == APIPins.key(host: host, port: port)
        completionHandler(sameHost ? request : nil)
    }

    private func accept(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        let fp = APIPins.fingerprint(of: SecCertificateCopyData(leaf) as Data)
        // A certificate the system trusts for this name (Let's Encrypt on a NAS) is renewed every few
        // months; accept it and keep its pin current instead of warning on every renewal.
        if SecTrustEvaluateWithError(trust, nil) {
            APIPins.store(fingerprint: fp, host: host, port: port, directory: directory)
            return true
        }
        do {
            try APIPins.check(fingerprint: fp, host: host, port: port, directory: directory)
            return true
        } catch {
            lock.lock()
            mismatch = true
            lock.unlock()
            return false
        }
    }
}
