import Foundation

/// Dell iDRAC over Redfish (iDRAC 8 from firmware 2.30.30.30, iDRAC 9).
actor RedfishClient: APIBackend {
    static let systemPath = "/redfish/v1/Systems/System.Embedded.1"
    static let managerPath = "/redfish/v1/Managers/iDRAC.Embedded.1"
    static let chassisPath = "/redfish/v1/Chassis/System.Embedded.1"
    /// BMCs answer slowly; drive and log requests can take several seconds on iDRAC 8.
    static let timeout: TimeInterval = 20
    /// Requests in flight at once. More only makes the BMC slower.
    static let parallel = 4

    private let http: APIHTTP
    private let root: Data
    private var token: String?
    private var sessionURL: String?
    private var basic: String?

    init(http: APIHTTP, root: Data) {
        self.http = http
        self.root = root
    }

    /// A client when the address serves a Dell Redfish service root (which needs no login), nil when it
    /// isn't Redfish. Another vendor's BMC throws `DriverError.notSupported`.
    static func probe(_ http: APIHTTP) async throws -> RedfishClient? {
        let r = try await http.send("GET", "/redfish/v1/")
        let json = r.json
        guard r.status == 200, RedfishParsers.isRedfish(json) else { return nil }
        if RedfishParsers.isDell(root: json) == false { throw DriverError.notSupported }
        return RedfishClient(http: http, root: r.data)
    }

    private var headers: [String: String] {
        if let token { return ["X-Auth-Token": token] }
        if let basic { return ["Authorization": basic] }
        return [:]
    }

    // MARK: Session

    func login(username: String, password: String) async throws {
        let rootJSON = APIJSON(data: root)
        let body = try JSONSerialization.data(withJSONObject: ["UserName": username, "Password": password])
        let r = try await http.send("POST", RedfishParsers.sessionsPath(root: rootJSON), body: body, timeout: 30)
        switch r.status {
        case 200...299:
            guard let value = r.header("X-Auth-Token"), !value.isEmpty else {
                throw APIError.badResponse(t("no session token"))
            }
            token = value
            sessionURL = r.header("Location") ?? r.json.odataID
        case 401, 403:
            throw APIError.unauthorized
        case 404, 405:
            // No session service (very old firmware): HTTP Basic on every request.
            basic = APIHTTP.basicAuth(username, password)
            let check = try await http.send("GET", Self.systemPath, headers: headers, timeout: Self.timeout)
            guard check.isSuccess else {
                basic = nil
                throw check.status == 401 || check.status == 403 ? APIError.unauthorized : APIError.http(check.status)
            }
        default:
            throw APIError.badResponse(RedfishParsers.errorMessage(r.json) ?? "HTTP \(r.status)")
        }
        // A root that didn't name its vendor: an iDRAC has this manager.
        if RedfishParsers.isDell(root: rootJSON) == nil {
            let manager = try? await http.send("GET", Self.managerPath, headers: headers, timeout: Self.timeout)
            if manager?.isSuccess != true {
                await logout()
                throw DriverError.notSupported
            }
        }
    }

    func logout() async {
        if let token, let sessionURL {
            _ = try? await http.send("DELETE", sessionURL, headers: ["X-Auth-Token": token], timeout: 5)
        }
        token = nil
        sessionURL = nil
        basic = nil
    }

    // MARK: Read

    func read(progress: @Sendable (LoadStep) -> Void) async throws -> ApplianceSnapshot {
        let steps = [
            t("Reading system info"),
            t("Reading sensors"),
            t("Reading power supplies"),
            t("Reading network interfaces"),
            t("Reading storage"),
            t("Reading the event log"),
        ]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        step(0)
        let system = try await get(Self.systemPath)
        var r = RedfishParsers.Reading(system: system)
        r.manager = await tryGet(Self.managerPath)

        step(1)
        try Task.checkCancellation()
        r.thermal = await tryGet(Self.chassisPath + "/Thermal")
        if !r.thermal.exists {
            let sub = await tryGet(Self.chassisPath + "/ThermalSubsystem")
            if let fans = sub["Fans"].odataID {
                r.subsystemFans = await members(RedfishParsers.memberLinks(await tryGet(fans)), limit: 64)
            }
            if let metrics = sub["ThermalMetrics"].odataID { r.thermalMetrics = await tryGet(metrics) }
        }

        step(2)
        try Task.checkCancellation()
        r.power = await tryGet(Self.chassisPath + "/Power")
        if !r.power.exists {
            let sub = await tryGet(Self.chassisPath + "/PowerSubsystem")
            if let supplies = sub["PowerSupplies"].odataID {
                r.subsystemPowerSupplies = await members(RedfishParsers.memberLinks(await tryGet(supplies)), limit: 16)
            }
            r.environment = await tryGet(Self.chassisPath + "/EnvironmentMetrics")
        }

        step(3)
        try Task.checkCancellation()
        r.ethernet = await members(RedfishParsers.memberLinks(await tryGet(Self.systemPath + "/EthernetInterfaces")), limit: 64)
        r.managerNIC = await tryGet(Self.managerPath + "/EthernetInterfaces/NIC.1")

        step(4)
        try Task.checkCancellation()
        r.controllers = await members(RedfishParsers.memberLinks(await tryGet(Self.systemPath + "/Storage")), limit: 16)
        r.drives = await members(r.controllers.flatMap(RedfishParsers.driveLinks), limit: 64)
        let volumeCollections = await members(r.controllers.compactMap { $0["Volumes"].odataID }, limit: 16)
        r.volumes = await members(volumeCollections.flatMap(RedfishParsers.memberLinks), limit: 64)

        step(5)
        try Task.checkCancellation()
        let selPath = Self.managerPath + "/LogServices/Sel/Entries"
        r.sel = await tryGet(selPath)
        if let skip = RedfishParsers.selSkipToNewest(r.sel) {
            let newest = await tryGet(selPath + "?$skip=\(skip)")
            if newest.exists { r.sel = newest }
        }

        return RedfishParsers.snapshot(r)
    }

    // MARK: Requests

    private func get(_ path: String) async throws -> APIJSON {
        let r = try await http.send("GET", path, headers: headers, timeout: Self.timeout)
        switch r.status {
        case 200...299: return r.json
        case 401, 403: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default: throw APIError.http(r.status)
        }
    }

    /// A resource the snapshot can do without (older firmware lacks some). Empty when it failed.
    private func tryGet(_ path: String) async -> APIJSON {
        (try? await get(path)) ?? APIJSON(nil)
    }

    /// Fetches the links `parallel` at a time and returns the answers in link order, skipping failures.
    private func members(_ links: [String], limit: Int) async -> [APIJSON] {
        let wanted = Array(links.prefix(limit))
        guard !wanted.isEmpty else { return [] }
        let http = self.http
        let headers = self.headers
        let fetched = await withTaskGroup(of: (String, Data?).self, returning: [String: Data].self) { group in
            var results: [String: Data] = [:]
            var queue = wanted[...]
            for link in queue.prefix(Self.parallel) {
                group.addTask { (link, await Self.fetch(http, link, headers)) }
            }
            queue = queue.dropFirst(Self.parallel)
            while let done = await group.next() {
                if let data = done.1 { results[done.0] = data }
                if let link = queue.first {
                    queue = queue.dropFirst()
                    group.addTask { (link, await Self.fetch(http, link, headers)) }
                }
            }
            return results
        }
        return wanted.compactMap { link in fetched[link].map { APIJSON(data: $0) } }
    }

    private static func fetch(_ http: APIHTTP, _ path: String, _ headers: [String: String]) async -> Data? {
        guard let r = try? await http.send("GET", path, headers: headers, timeout: timeout), r.isSuccess else { return nil }
        return r.data
    }
}
