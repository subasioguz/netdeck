import Foundation

/// A server BMC over Redfish: Dell iDRAC (iDRAC 8 from firmware 2.30.30.30, iDRAC 9) and other vendors'
/// BMCs (HPE iLO, Supermicro, Lenovo XCC). The system, manager and chassis are found through the
/// service's collections; Dell-only resources (SEL, `NIC.1`, Service Tag) are read only on a Dell.
actor RedfishClient: APIBackend {
    /// Dell's fixed resources, used when the collections don't answer (very old iDRAC firmware).
    static let dellSystemPath = "/redfish/v1/Systems/System.Embedded.1"
    static let dellManagerPath = "/redfish/v1/Managers/iDRAC.Embedded.1"
    static let dellChassisPath = "/redfish/v1/Chassis/System.Embedded.1"
    /// BMCs answer slowly; drive and log requests can take several seconds on iDRAC 8.
    static let timeout: TimeInterval = 20
    /// Requests in flight at once. More only makes the BMC slower.
    static let parallel = 4

    private let http: APIHTTP
    private let root: Data
    /// From the service root; nil when it doesn't say (old iDRAC firmware), settled after login.
    private var dell: Bool?
    private var paths: RedfishParsers.Paths?
    /// `ComputerSystem.Reset` target, from the last read of the system.
    private var resetTarget: String?
    private var token: String?
    private var sessionURL: String?
    private var basic: String?

    init(http: APIHTTP, root: Data) {
        self.http = http
        self.root = root
        self.dell = RedfishParsers.isDell(root: APIJSON(data: root))
    }

    /// A client when the address serves a Redfish service root (which needs no login), nil when it isn't Redfish.
    static func probe(_ http: APIHTTP) async throws -> RedfishClient? {
        let r = try await http.send("GET", "/redfish/v1/")
        guard r.status == 200, RedfishParsers.isRedfish(r.json) else { return nil }
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
            let check = try await http.send("GET", RedfishParsers.collectionPath(rootJSON, "Systems"), headers: headers, timeout: Self.timeout)
            guard check.isSuccess else {
                basic = nil
                throw check.status == 401 || check.status == 403 ? APIError.unauthorized : APIError.http(check.status)
            }
        default:
            throw APIError.badResponse(RedfishParsers.errorMessage(r.json) ?? "HTTP \(r.status)")
        }
        // A root that didn't name its vendor: an iDRAC has this manager.
        if dell == nil {
            let manager = try? await http.send("GET", Self.dellManagerPath, headers: headers, timeout: Self.timeout)
            dell = manager?.isSuccess == true
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
        let isDell = dell ?? false

        step(0)
        let systemPath = try await resolveSystemPath()
        let system = try await get(systemPath)
        let p = try await resolvePaths(system: system, systemPath: systemPath)
        var r = RedfishParsers.Reading(system: system)
        r.isDell = isDell
        if let manager = p.manager { r.manager = await tryGet(manager) }
        resetTarget = RedfishParsers.resetTarget(system)

        // Without a chassis there are no sensors or power supplies to read.
        step(1)
        try Task.checkCancellation()
        if let chassis = p.chassis {
            r.thermal = await tryGet(chassis + "/Thermal")
            if !r.thermal.exists {
                let sub = await tryGet(chassis + "/ThermalSubsystem")
                if let fans = sub["Fans"].odataID {
                    r.subsystemFans = await members(RedfishParsers.memberLinks(await tryGet(fans)), limit: 64)
                }
                if let metrics = sub["ThermalMetrics"].odataID { r.thermalMetrics = await tryGet(metrics) }
            }
        }

        step(2)
        try Task.checkCancellation()
        if let chassis = p.chassis {
            r.power = await tryGet(chassis + "/Power")
            if !r.power.exists {
                let sub = await tryGet(chassis + "/PowerSubsystem")
                if let supplies = sub["PowerSupplies"].odataID {
                    r.subsystemPowerSupplies = await members(RedfishParsers.memberLinks(await tryGet(supplies)), limit: 16)
                }
                r.environment = await tryGet(chassis + "/EnvironmentMetrics")
            }
        }

        step(3)
        try Task.checkCancellation()
        let ethernet = system["EthernetInterfaces"].odataID ?? p.system + "/EthernetInterfaces"
        r.ethernet = await members(RedfishParsers.memberLinks(await tryGet(ethernet)), limit: 64)
        if isDell, let manager = p.manager {
            r.managerNIC = await tryGet(manager + "/EthernetInterfaces/NIC.1")
        } else if let manager = p.manager {
            let nics = r.manager["EthernetInterfaces"].odataID ?? manager + "/EthernetInterfaces"
            if let first = RedfishParsers.memberLinks(await tryGet(nics)).first { r.managerNIC = await tryGet(first) }
        }

        step(4)
        try Task.checkCancellation()
        let storage = system["Storage"].odataID ?? p.system + "/Storage"
        r.controllers = await members(RedfishParsers.memberLinks(await tryGet(storage)), limit: 16)
        r.drives = await members(r.controllers.flatMap(RedfishParsers.driveLinks), limit: 64)
        let volumeCollections = await members(r.controllers.compactMap { $0["Volumes"].odataID }, limit: 16)
        r.volumes = await members(volumeCollections.flatMap(RedfishParsers.memberLinks), limit: 64)

        step(5)
        try Task.checkCancellation()
        if let entries = await logEntriesPath(system: system, paths: p, isDell: isDell) {
            r.sel = await tryGet(entries)
            if let skip = RedfishParsers.selSkipToNewest(r.sel) {
                let newest = await tryGet(entries + "?$skip=\(skip)")
                if newest.exists { r.sel = newest }
            }
        }

        return RedfishParsers.snapshot(r)
    }

    /// The system's resource: the first member of the Systems collection (a Dell's fixed path when
    /// the collection doesn't answer).
    private func resolveSystemPath() async throws -> String {
        if let paths { return paths.system }
        let systems = await tryGet(RedfishParsers.collectionPath(APIJSON(data: root), "Systems"))
        if let first = RedfishParsers.memberLinks(systems).first { return RedfishParsers.trimmed(first) }
        if dell == true { return Self.dellSystemPath }
        // A Redfish service without a computer system (a chassis or switch manager).
        throw DriverError.notSupported
    }

    /// Manager and chassis: the system's own links, else the first member of each collection.
    private func resolvePaths(system: APIJSON, systemPath: String) async throws -> RedfishParsers.Paths {
        if let paths { return paths }
        let rootJSON = APIJSON(data: root)
        var manager = RedfishParsers.managerLink(system)
        if manager == nil { manager = RedfishParsers.memberLinks(await tryGet(RedfishParsers.collectionPath(rootJSON, "Managers"))).first }
        var chassis = RedfishParsers.chassisLink(system)
        if chassis == nil { chassis = RedfishParsers.memberLinks(await tryGet(RedfishParsers.collectionPath(rootJSON, "Chassis"))).first }
        let found = RedfishParsers.Paths(
            system: systemPath,
            manager: manager.map(RedfishParsers.trimmed) ?? (dell == true ? Self.dellManagerPath : nil),
            chassis: chassis.map(RedfishParsers.trimmed) ?? (dell == true ? Self.dellChassisPath : nil))
        paths = found
        return found
    }

    /// Dell: the iDRAC's SEL. Others: the first log service under the system that has entries (HPE IML).
    private func logEntriesPath(system: APIJSON, paths p: RedfishParsers.Paths, isDell: Bool) async -> String? {
        if isDell { return p.manager.map { $0 + "/LogServices/Sel/Entries" } }
        let services = system["LogServices"].odataID ?? p.system + "/LogServices"
        let links = RedfishParsers.memberLinks(await tryGet(services))
        for link in links.prefix(4) {
            if let entries = await tryGet(link)["Entries"].odataID { return entries }
        }
        return nil
    }

    // MARK: Power

    /// POSTs `ComputerSystem.Reset`. The BMC accepts or refuses at once; the host changes state later.
    func power(_ action: ApplianceSnapshot.PowerAction) async throws {
        let target: String
        if let resetTarget {
            target = resetTarget
        } else {
            guard let found = RedfishParsers.resetTarget(try await get(try await resolveSystemPath())) else {
                throw DriverError.notSupported
            }
            target = found
        }
        let body = try JSONSerialization.data(withJSONObject: ["ResetType": action.rawValue])
        let r = try await http.send("POST", target, headers: headers, body: body, timeout: 30)
        switch r.status {
        case 200, 202, 204: return
        case 401, 403: throw APIError.unauthorized
        default: throw APIError.badResponse(RedfishParsers.errorMessage(r.json) ?? "HTTP \(r.status)")
        }
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
