import Foundation

/// QNAP QTS and QuTS hero over the web interface's own CGI calls (`/cgi-bin/...`, XML answers), the ones the
/// Home Assistant QNAP integration reads. Read only.
///
/// The login sends the password base64-encoded in a POST body (never in the URL, which the NAS logs); the
/// session id goes with every call as `sid`.
actor QNAPClient: APIBackend {
    static let loginPath = "/cgi-bin/authLogin.cgi"

    private let http: APIHTTP
    private var sid: String?
    private var login: XMLElement?

    init(http: APIHTTP) { self.http = http }

    /// A client when `authLogin.cgi` answers with a `<QDocRoot>` without a login, nil otherwise.
    static func probe(_ http: APIHTTP) async throws -> QNAPClient? {
        let r = try await http.send("GET", loginPath)
        guard r.status == 200, QNAPParsers.root(r.data) != nil else { return nil }
        return QNAPClient(http: http)
    }

    // MARK: Session

    func login(username: String, password: String) async throws {
        let body = APIHTTP.form([("user", username), ("pwd", Data(password.utf8).base64EncodedString())])
        let r = try await http.send("POST", Self.loginPath, body: Data(body.utf8),
                                    contentType: "application/x-www-form-urlencoded", timeout: 20)
        guard r.status == 200 else { throw APIError.http(r.status) }
        let root = QNAPParsers.root(r.data)
        sid = try QNAPParsers.sessionID(root)
        login = root
    }

    func logout() async {
        guard let sid else { return }
        _ = try? await http.send("GET", "/cgi-bin/authLogout.cgi?" + APIHTTP.form([("logout", "1"), ("sid", sid)]), timeout: 5)
        self.sid = nil
    }

    // MARK: Read

    func read(progress: @Sendable (LoadStep) -> Void) async throws -> ApplianceSnapshot {
        let steps = [t("Reading system info"), t("Reading storage"), t("Reading network interfaces")]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }
        var r = QNAPParsers.Reading()
        r.login = login

        step(0)
        r.sysinfo = try await call("/cgi-bin/management/manaRequest.cgi", [("subfunc", "sysinfo"), ("hd", "no"), ("multicpu", "1")])
        guard r.sysinfo != nil else { throw APIError.badResponse("manaRequest.cgi") }
        r.health = try? await call("/cgi-bin/management/manaRequest.cgi", [("subfunc", "sysinfo"), ("sysHealth", "1")])

        step(1)
        try Task.checkCancellation()
        r.volumes = try? await call("/cgi-bin/management/chartReq.cgi",
                                    [("chart_func", "disk_usage"), ("disk_select", "all"), ("include", "all")])
        r.disks = try? await call("/cgi-bin/disk/qsmart.cgi", [("func", "all_hd_data")])

        step(2)
        return QNAPParsers.snapshot(r)
    }

    /// One GET with the session id; the answer's `<QDocRoot>`. An answer saying the session is gone throws
    /// `unauthorized`, so `APIDriver` logs in again once.
    private func call(_ path: String, _ query: [(String, String)]) async throws -> XMLElement? {
        guard let sid else { throw APIError.unauthorized }
        let r = try await http.send("GET", path + "?" + APIHTTP.form(query + [("sid", sid)]), timeout: 20)
        guard r.status == 200 else { throw APIError.http(r.status) }
        guard let root = QNAPParsers.root(r.data) else { throw APIError.badResponse(path) }
        if QNAPParsers.sessionEnded(root) { throw APIError.unauthorized }
        return root
    }
}
