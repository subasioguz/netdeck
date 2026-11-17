import Foundation

/// A device's HTTPS address, from what the user typed ("nas.local", "192.0.2.10:8443",
/// "https://idrac.example.com/restgui/start.html"). Only scheme, host and port are kept.
public struct APIEndpoint: Equatable, Sendable {
    /// Lowercased, without IPv6 brackets.
    public let host: String
    public let port: Int
    /// The user typed a port. Without one Netdeck uses 443 and also tries Synology's 5001.
    public let explicitPort: Bool

    public init(_ text: String) throws {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw APIError.invalidURL(typed) }
        if typed.lowercased().hasPrefix("http://") { throw APIError.httpNotAllowed }
        let full = typed.contains("://") ? typed : "https://" + typed
        guard let c = URLComponents(string: full), c.scheme?.lowercased() == "https",
              let rawHost = c.host, !rawHost.isEmpty else { throw APIError.invalidURL(typed) }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.isEmpty, !host.contains(" "), !host.contains("/") else { throw APIError.invalidURL(typed) }
        if let p = c.port, !(1...65535).contains(p) { throw APIError.invalidURL(typed) }
        self.init(host: host, port: c.port ?? 443, explicitPort: c.port != nil)
    }

    init(host: String, port: Int, explicitPort: Bool) {
        self.host = host
        self.port = port
        self.explicitPort = explicitPort
    }

    func withPort(_ port: Int) -> APIEndpoint { APIEndpoint(host: host, port: port, explicitPort: true) }

    private var authority: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == 443 ? h : "\(h):\(port)"
    }

    /// "https://192.0.2.10", "https://nas.local:5001".
    public var base: String { "https://" + authority }

    /// A request URL on this endpoint. Absolute links the device sends (a Redfish `Location` header)
    /// are re-based here, so credentials never go to another host. Fragments are dropped.
    func url(_ pathOrURL: String) -> URL? {
        var p = pathOrURL
        if let hash = p.firstIndex(of: "#") { p = String(p[..<hash]) }
        if let scheme = p.range(of: "://") {
            let rest = p[scheme.upperBound...]
            p = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        if !p.hasPrefix("/") { p = "/" + p }
        return URL(string: base + p)
    }

    func webSocketURL(_ path: String) -> URL? {
        URL(string: "wss://" + authority + (path.hasPrefix("/") ? path : "/" + path))
    }
}

struct APIResponse: Sendable {
    var status: Int
    var data: Data
    /// Header names lowercased.
    var headers: [String: String]

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var json: APIJSON { APIJSON(data: data) }
    var isSuccess: Bool { (200...299).contains(status) }
}

/// The HTTPS connection to one device: an ephemeral URLSession (no cookies, cache or stored credentials)
/// whose certificate checks go through `APIPins`. Call `close()` when done; the session keeps its delegate alive.
final class APIHTTP: Sendable {
    let endpoint: APIEndpoint
    let session: URLSession
    let pinning: APIPinningDelegate

    init(endpoint: APIEndpoint, pinDirectory: URL? = nil) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 120
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = APIPinningDelegate(host: endpoint.host, port: endpoint.port, directory: pinDirectory)
        self.pinning = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil,
              contentType: String = "application/json", timeout: TimeInterval = 10) async throws -> APIResponse {
        guard let url = endpoint.url(path) else { throw APIError.badResponse(path) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw mapError(error)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw APIError.badResponse(t("not an HTTP answer")) }
        var lowered: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String { lowered[name.lowercased()] = "\(value)" }
        }
        return APIResponse(status: http.statusCode, data: result.0, headers: lowered)
    }

    func webSocket(_ path: String) -> URLSessionWebSocketTask? {
        endpoint.webSocketURL(path).map { session.webSocketTask(with: $0) }
    }

    /// URLSession errors in the terms the error cards use.
    func mapError(_ error: Error) -> Error {
        if pinning.sawMismatch { return APIError.certificateChanged(host: endpoint.host) }
        if error is APIError || error is CancellationError { return error }
        guard let u = error as? URLError else { return APIError.unreachable(error.localizedDescription) }
        switch u.code {
        case .cancelled:
            return CancellationError()
        case .cannotConnectToHost, .timedOut, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost,
             .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .resourceUnavailable:
            return APIError.unreachable(u.localizedDescription)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return APIError.tlsFailed(u.localizedDescription)
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return APIError.unauthorized
        default:
            return APIError.badResponse(u.localizedDescription)
        }
    }

    // MARK: Encoding

    /// `application/x-www-form-urlencoded`, also used for query strings. Everything but unreserved
    /// characters is escaped, so passwords with "&", "=" or "+" survive.
    static func form(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return pairs.map { esc($0.0) + "=" + esc($0.1) }.joined(separator: "&")
    }

    static func basicAuth(_ username: String, _ password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}
