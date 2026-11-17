import Foundation

/// TrueNAS over JSON-RPC 2.0 on a WebSocket (`/api/current`, 25.04 and later) or REST v2.0 (older
/// releases). REST is deprecated since 25.04, raises an alert on the NAS from 25.10 and is removed in 27,
/// so the WebSocket is tried first and REST only when the device doesn't offer it.
/// HTTPS only: TrueNAS revokes an API key that was sent over plain HTTP.
actor TrueNASClient: APIBackend {
    private enum Mode {
        case rest(authorization: String)
        case rpc(URLSessionWebSocketTask)
    }

    /// A JSON-RPC error answer.
    struct RPCError: Error, Equatable {
        let code: Int
        let message: String
    }

    static let rpcPath = "/api/current"
    static let replyTimeout: Duration = .seconds(20)

    private let http: APIHTTP
    private var mode: Mode?
    private var nextID = 1
    private var credentials: (username: String, secret: String)?

    init(http: APIHTTP) { self.http = http }

    /// Recognised by its web UI page first (no API use, which newer releases flag in an alert), else by
    /// REST `system/state`, which answers without a login.
    static func answers(_ http: APIHTTP) async throws -> Bool {
        let page = try await http.send("GET", "/ui/")
        if page.status == 200 {
            let html = String(decoding: page.data.prefix(65_536), as: UTF8.self)
            if html.contains("TrueNAS") || html.contains("FreeNAS") { return true }
        }
        let state = try await http.send("GET", "/api/v2.0/system/state")
        return state.status == 200 && TrueNASParsers.isSystemState(state.json)
    }

    // MARK: Session

    func login(username: String, password: String) async throws {
        credentials = (username, password)
        let apiKey = TrueNASParsers.looksLikeAPIKey(password)
        if let task = try await openRPC(username: username, secret: password, apiKey: apiKey) {
            mode = .rpc(task)
            return
        }
        let authorization = apiKey ? "Bearer " + password : APIHTTP.basicAuth(username, password)
        let r = try await http.send("GET", "/api/v2.0/system/info", headers: ["Authorization": authorization])
        switch r.status {
        case 200: mode = .rest(authorization: authorization)
        case 401, 403: throw APIError.unauthorized
        case 404: throw DriverError.notSupported
        default: throw APIError.http(r.status)
        }
    }

    func logout() async {
        if case let .rpc(task)? = mode { task.cancel(with: .normalClosure, reason: nil) }
        mode = nil
    }

    /// Opens the WebSocket and logs in with `auth.login_ex`. nil when the device has no JSON-RPC API
    /// (the caller uses REST). Wrong credentials, a one-time code or a changed certificate throw.
    private func openRPC(username: String, secret: String, apiKey: Bool) async throws -> URLSessionWebSocketTask? {
        guard let task = http.webSocket(Self.rpcPath) else { return nil }
        task.maximumMessageSize = 32 << 20
        task.resume()
        let auth: [String: Any] = apiKey
            ? ["mechanism": "API_KEY_PLAIN", "username": username, "api_key": secret]
            : ["mechanism": "PASSWORD_PLAIN", "username": username, "password": secret]
        let result: APIJSON
        do {
            result = try await call(task, "auth.login_ex", [auth])
        } catch let e as APIError {
            task.cancel(with: .goingAway, reason: nil)
            switch e {
            case .certificateChanged, .tlsFailed: throw e
            // A refused upgrade can surface as "socket not connected"; REST tells whether the host is there.
            default: return nil
            }
        } catch is CancellationError {
            task.cancel(with: .goingAway, reason: nil)
            throw CancellationError()
        } catch {
            // Upgrade refused or method unknown: an older TrueNAS.
            task.cancel(with: .goingAway, reason: nil)
            return nil
        }
        switch result["response_type"].string?.uppercased() {
        case "SUCCESS":
            return task
        case "OTP_REQUIRED":
            task.cancel(with: .goingAway, reason: nil)
            throw APIError.twoFactorRequired
        case "EXPIRED":
            task.cancel(with: .goingAway, reason: nil)
            throw APIError.passwordChangeRequired
        case "AUTH_ERR":
            task.cancel(with: .goingAway, reason: nil)
            throw APIError.unauthorized
        default:
            task.cancel(with: .goingAway, reason: nil)
            throw APIError.badResponse(result["response_type"].string ?? "auth.login_ex")
        }
    }

    // MARK: Read

    func read(progress: @Sendable (LoadStep) -> Void) async throws -> ApplianceSnapshot {
        // The NAS closes idle WebSockets; open a new one rather than fail.
        if case let .rpc(task)? = mode, task.state != .running, let credentials {
            await logout()
            try await login(username: credentials.username, password: credentials.secret)
        }
        let steps = [t("Reading system info"), t("Reading storage"), t("Reading network interfaces"), t("Reading alerts")]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        step(0)
        let info = try await fetch(rest: "system/info", rpc: "system.info")
        var r = TrueNASParsers.Reading(info: info)

        step(1)
        try Task.checkCancellation()
        r.pools = (try? await fetch(rest: "pool", rpc: "pool.query")) ?? APIJSON(nil)
        r.disks = (try? await fetch(rest: "disk", rpc: "disk.query")) ?? APIJSON(nil)

        step(2)
        try Task.checkCancellation()
        r.interfaces = (try? await fetch(rest: "interface", rpc: "interface.query")) ?? APIJSON(nil)

        step(3)
        try Task.checkCancellation()
        r.alerts = (try? await fetch(rest: "alert/list", rpc: "alert.list")) ?? APIJSON(nil)

        return TrueNASParsers.snapshot(r)
    }

    /// The same data over whichever API the login used.
    private func fetch(rest path: String, rpc method: String) async throws -> APIJSON {
        switch mode {
        case let .rest(authorization)?:
            let r = try await http.send("GET", "/api/v2.0/" + path, headers: ["Authorization": authorization], timeout: 20)
            switch r.status {
            case 200...299: return r.json
            case 401, 403: throw APIError.unauthorized
            case 404: throw APIError.notFound
            default: throw APIError.http(r.status)
            }
        case let .rpc(task)?:
            do {
                return try await call(task, method, [])
            } catch let e as RPCError {
                // EACCES / ENOTAUTHENTICATED come back as JSON-RPC errors.
                let text = e.message.uppercased()
                if text.contains("NOT AUTHENTICATED") || text.contains("ENOTAUTHENTICATED") { throw APIError.unauthorized }
                throw APIError.badResponse(e.message)
            }
        case nil:
            throw APIError.unauthorized
        }
    }

    // MARK: JSON-RPC

    /// Sends one request and waits for the answer with the same id (other messages are skipped).
    private func call(_ task: URLSessionWebSocketTask, _ method: String, _ params: [Any]) async throws -> APIJSON {
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let encoded = try JSONSerialization.data(withJSONObject: request)
        let text = String(decoding: encoded, as: UTF8.self)
        do {
            try await task.send(.string(text))
        } catch {
            throw http.mapError(error)
        }
        while true {
            let message = try await receive(task)
            let reply = APIJSON(data: Data(message.utf8))
            guard reply["id"].int == id else { continue }
            if reply["error"].exists {
                let error = reply["error"]
                let reason = error["data"]["reason"].string ?? error["message"].string ?? method
                throw RPCError(code: error["code"].int ?? 0, message: reason)
            }
            return reply["result"]
        }
    }

    /// The next text message, or a timeout. `receive()` ignores task cancellation, so the timeout
    /// cancels the WebSocket itself to end it.
    private func receive(_ task: URLSessionWebSocketTask) async throws -> String {
        let http = self.http
        let timeout = Self.replyTimeout
        return try await withThrowingTaskGroup(of: String.self, returning: String.self) { group in
            group.addTask {
                do {
                    switch try await task.receive() {
                    case let .string(text): return text
                    case let .data(data): return String(decoding: data, as: UTF8.self)
                    @unknown default: return ""
                    }
                } catch {
                    throw http.mapError(error)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                task.cancel(with: .goingAway, reason: nil)
                throw APIError.unreachable(t("The device stopped answering."))
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw APIError.badResponse(t("no answer")) }
            return first
        }
    }
}
