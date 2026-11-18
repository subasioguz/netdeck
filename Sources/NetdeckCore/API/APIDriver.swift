import Foundation

/// Reads a server BMC (Redfish: Dell iDRAC, HPE iLO, Supermicro, Lenovo XCC) or a NAS (Synology DSM,
/// TrueNAS, QNAP) over HTTPS. Read-only apart from server power commands: the change operations keep the
/// protocol defaults and throw `DriverError.notSupported`.
public actor APIDriver: DeviceDriver {
    private let url: String
    private let platform: Platform
    private let pinDirectory: URL?
    private var http: APIHTTP?
    private var backend: (any APIBackend)?
    /// Kept in memory only, to log in again when the device ended an idle session (iDRAC after 30 minutes).
    private var credentials: (username: String, password: String)?

    /// `platform` is `.unknown` when the API should be detected (Redfish, Synology, TrueNAS).
    /// `pinDirectory` replaces the support folder for the certificate pins (tests).
    public init(url: String, platform: Platform, pinDirectory: URL? = nil) {
        self.url = url
        self.platform = platform
        self.pinDirectory = pinDirectory
    }

    deinit { http?.close() }

    public func connect(username: String, password: String?) async throws {
        await disconnect()
        let endpoint = try APIEndpoint(url)
        var candidates = [endpoint]
        // DSM listens on 5001 unless set up otherwise; only worth a try when the user gave no port.
        if !endpoint.explicitPort, platform == .unknown || platform == .synologyDSM {
            candidates.append(endpoint.withPort(5001))
        }
        var unreachable: APIError?
        var answered = false
        for candidate in candidates {
            let http = APIHTTP(endpoint: candidate, pinDirectory: pinDirectory)
            do {
                guard let found = try await Self.detect(platform, http: http) else {
                    // Something answers here, but not an API Netdeck reads.
                    http.close()
                    answered = true
                    continue
                }
                try await found.login(username: username, password: password ?? "")
                self.http = http
                self.backend = found
                self.credentials = (username, password ?? "")
                return
            } catch let e as APIError where e.isUnreachable {
                http.close()
                unreachable = unreachable ?? e
            } catch {
                http.close()
                throw error
            }
        }
        if !answered, let unreachable { throw unreachable }
        throw DriverError.notSupported
    }

    public func disconnect() async {
        if let backend { await backend.logout() }
        backend = nil
        credentials = nil
        http?.close()
        http = nil
    }

    public func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading {
        guard let backend else { throw TransportError.notOpen }
        do {
            return .appliance(try await backend.read(progress: progress))
        } catch APIError.unauthorized {
            // The device may have ended the session while Netdeck sat idle; log in again once.
            guard let credentials else { throw APIError.unauthorized }
            await backend.logout()
            try await backend.login(username: credentials.username, password: credentials.password)
            return .appliance(try await backend.read(progress: progress))
        }
    }

    /// Server power command. Only after the user confirmed it; never retried once the device took it.
    public func power(_ action: ApplianceSnapshot.PowerAction) async throws {
        guard let backend else { throw TransportError.notOpen }
        do {
            try await backend.power(action)
        } catch APIError.unauthorized {
            // A session the device ended while idle rejects the command before running it; log in again once.
            guard let credentials else { throw APIError.unauthorized }
            await backend.logout()
            try await backend.login(username: credentials.username, password: credentials.password)
            try await backend.power(action)
        }
    }

    // MARK: Detection

    /// The client for whichever API answers, or nil when none of the wanted ones does.
    static func detect(_ platform: Platform, http: APIHTTP) async throws -> (any APIBackend)? {
        switch platform {
        case .dellIDRAC, .redfish:
            // A BMC of another vendor than the one picked is still read (the snapshot says which).
            return try await RedfishClient.probe(http)
        case .synologyDSM:
            return try await SynologyClient.probe(http)
        case .truenas:
            // The user said TrueNAS: skip guessing, the login tells whether it is.
            return TrueNASClient(http: http)
        case .qnap:
            return try await QNAPClient.probe(http)
        case .unknown:
            if let found = try await RedfishClient.probe(http) { return found }
            if let found = try await SynologyClient.probe(http) { return found }
            if let found = try await QNAPClient.probe(http) { return found }
            if try await TrueNASClient.answers(http) { return TrueNASClient(http: http) }
            return nil
        default:
            return nil
        }
    }
}

/// One appliance API behind `APIDriver`.
protocol APIBackend: Actor {
    func login(username: String, password: String) async throws
    func read(progress: @Sendable (LoadStep) -> Void) async throws -> ApplianceSnapshot
    /// Ends the device-side session. Never throws.
    func logout() async
    /// Server power command; only Redfish BMCs have one.
    func power(_ action: ApplianceSnapshot.PowerAction) async throws
}

extension APIBackend {
    func power(_ action: ApplianceSnapshot.PowerAction) async throws { throw DriverError.notSupported }
}
