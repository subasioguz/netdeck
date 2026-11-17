import Foundation

/// Synology DSM (6.2 and 7) over its Web API (`/webapi/...`), session id passed as `_sid`.
actor SynologyClient: APIBackend {
    static let infoPath = "/webapi/query.cgi"
    static let session = "Netdeck"
    static let wanted = ["SYNO.API.Auth", "SYNO.DSM.Info", "SYNO.Core.System", "SYNO.Storage.CGI.Storage", "SYNO.DSM.Network"]

    /// A failed call: `error.code` of a `{"success": false}` answer.
    struct CallError: Error, Equatable { let code: Int }

    private let http: APIHTTP
    private var apis: [String: SynologyParsers.API] = [:]
    private var sid: String?

    init(http: APIHTTP) { self.http = http }

    /// A client when `SYNO.API.Info` (no login needed) lists the auth API, nil otherwise.
    static func probe(_ http: APIHTTP) async throws -> SynologyClient? {
        let query = APIHTTP.form([("api", "SYNO.API.Info"), ("version", "1"), ("method", "query"), ("query", "SYNO.API.Auth")])
        let r = try await http.send("GET", infoPath + "?" + query)
        guard r.status == 200, SynologyParsers.isSynology(r.json) else { return nil }
        return SynologyClient(http: http)
    }

    // MARK: Session

    func login(username: String, password: String) async throws {
        let query = APIHTTP.form([("api", "SYNO.API.Info"), ("version", "1"), ("method", "query"),
                                  ("query", Self.wanted.joined(separator: ","))])
        let info = try await http.send("GET", Self.infoPath + "?" + query)
        guard info.status == 200 else { throw APIError.http(info.status) }
        apis = SynologyParsers.apis(info.json["data"])
        guard let auth = apis["SYNO.API.Auth"] else { throw APIError.badResponse("SYNO.API.Auth") }

        // POST keeps the password out of URLs (and the device's access log).
        let body = APIHTTP.form([("api", "SYNO.API.Auth"), ("version", String(auth.version(7))), ("method", "login"),
                                 ("account", username), ("passwd", password), ("session", Self.session), ("format", "sid")])
        let r = try await http.send("POST", "/webapi/" + auth.path, body: Data(body.utf8),
                                    contentType: "application/x-www-form-urlencoded", timeout: 20)
        guard r.status == 200 else { throw APIError.http(r.status) }
        let json = r.json
        guard json["success"].bool == true, let sid = json["data"]["sid"].string else {
            throw SynologyParsers.loginError(code: json["error"]["code"].int)
        }
        self.sid = sid
    }

    func logout() async {
        guard let sid, let auth = apis["SYNO.API.Auth"] else { return }
        let query = APIHTTP.form([("api", "SYNO.API.Auth"), ("version", String(auth.version(7))), ("method", "logout"),
                                  ("session", Self.session), ("_sid", sid)])
        _ = try? await http.send("GET", "/webapi/" + auth.path + "?" + query, timeout: 5)
        self.sid = nil
    }

    // MARK: Read

    func read(progress: @Sendable (LoadStep) -> Void) async throws -> ApplianceSnapshot {
        let steps = [t("Reading system info"), t("Reading storage"), t("Reading network interfaces")]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }
        var r = SynologyParsers.Reading()

        step(0)
        do {
            r.info = try await call("SYNO.DSM.Info", "getinfo")
        } catch let e as CallError {
            // 106 timeout, 107 duplicate login, 119 unknown session: the session is gone.
            if [106, 107, 119].contains(e.code) { throw APIError.unauthorized }
        } catch APIError.notFound {
            // Not offered by this DSM; SYNO.Core.System has most of it.
        }
        r.system = (try? await call("SYNO.Core.System", "info")) ?? APIJSON(nil)
        guard r.info.exists || r.system.exists else { throw APIError.badResponse("SYNO.DSM.Info") }

        step(1)
        try Task.checkCancellation()
        do {
            r.storage = try await call("SYNO.Storage.CGI.Storage", "load_info", version: 1)
        } catch let e as CallError where e.code == 105 {
            r.storageDenied = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Storage is optional; show the rest.
        }

        step(2)
        try Task.checkCancellation()
        r.network = (try? await call("SYNO.DSM.Network", "list")) ?? APIJSON(nil)

        return SynologyParsers.snapshot(r)
    }

    /// One Web API call; returns its `data`.
    private func call(_ api: String, _ method: String, version: Int? = nil) async throws -> APIJSON {
        guard let info = apis[api] else { throw APIError.notFound }
        guard let sid else { throw APIError.unauthorized }
        let query = APIHTTP.form([("api", api), ("version", String(info.version(version))), ("method", method), ("_sid", sid)])
        let r = try await http.send("GET", "/webapi/" + info.path + "?" + query, timeout: 20)
        guard r.status == 200 else { throw APIError.http(r.status) }
        let json = r.json
        guard json["success"].bool == true else { throw CallError(code: json["error"]["code"].int ?? 0) }
        return json["data"]
    }
}
