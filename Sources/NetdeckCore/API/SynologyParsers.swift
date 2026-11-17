import Foundation

/// Synology DSM Web API answers → `ApplianceSnapshot`. Pure functions over the `data` part of each answer.
///
/// `SYNO.API.Auth` is documented by Synology. `SYNO.DSM.Info`, `SYNO.Core.System`,
/// `SYNO.Storage.CGI.Storage` and `SYNO.DSM.Network` are not; their fields follow what DSM's own web UI and
/// community clients (py-synologydsm-api) use, so every field is optional.
enum SynologyParsers {
    typealias Health = ApplianceSnapshot.Health

    /// One API as `SYNO.API.Info` lists it.
    struct API: Equatable, Sendable {
        var path: String
        var minVersion: Int
        var maxVersion: Int

        /// `wanted` clamped to what the device offers.
        func version(_ wanted: Int? = nil) -> Int { max(minVersion, min(wanted ?? maxVersion, maxVersion)) }
    }

    struct Reading {
        /// `SYNO.DSM.Info` `getinfo`.
        var info = APIJSON(nil)
        /// `SYNO.Core.System` `info`.
        var system = APIJSON(nil)
        /// `SYNO.Storage.CGI.Storage` `load_info`.
        var storage = APIJSON(nil)
        /// `SYNO.DSM.Network` `list`.
        var network = APIJSON(nil)
        /// The account may not read storage (error 105: not an administrator).
        var storageDenied = false
    }

    // MARK: Discovery and login

    /// The answer of `query.cgi?api=SYNO.API.Info...&query=SYNO.API.Auth`.
    static func isSynology(_ answer: APIJSON) -> Bool {
        answer["success"].bool == true && answer["data"]["SYNO.API.Auth"].isObject
    }

    /// `SYNO.API.Info` `data` → API name → path and versions.
    static func apis(_ data: APIJSON) -> [String: API] {
        var out: [String: API] = [:]
        for name in data.keys {
            let entry = data[name]
            guard let path = entry["path"].string else { continue }
            out[name] = API(path: path, minVersion: entry["minVersion"].int ?? 1, maxVersion: entry["maxVersion"].int ?? 1)
        }
        return out
    }

    /// `SYNO.API.Auth` error codes. 400–402: bad account, disabled, no permission; 403/404/406: a
    /// one-time code is needed or enforced; 407: address blocked; 408–410: password expired.
    static func loginError(code: Int?) -> APIError {
        switch code {
        case 400, 401, 402: return .unauthorized
        case 403, 404, 406: return .twoFactorRequired
        case 407: return .blocked
        case 408, 409, 410: return .passwordChangeRequired
        case let c?: return .badResponse(t("login error %@", String(c)))
        case nil: return .badResponse(t("login failed"))
        }
    }

    // MARK: Snapshot

    static func snapshot(_ r: Reading, now: Date = .now) -> ApplianceSnapshot {
        var s = ApplianceSnapshot(takenAt: now, platform: .synologyDSM, kind: .storage, power: .on)
        let info = r.info, sys = r.system
        s.model = info["model"].string ?? sys["model"].string
        s.serial = info["serial"].string ?? sys["serial"].string
        s.osVersion = osVersion(info["version_string"].string ?? sys["firmware_ver"].string)
        s.uptimeSeconds = info["uptime"].int ?? uptime(sys["up_time"].string)
        s.hostname = r.network["hostname"].string ?? r.network["server_name"].string

        if let processor = cpu(sys) { s.facts.append(.init(label: t("Processor"), value: processor)) }
        if let mb = info["ram"].double ?? sys["ram_size"].double, mb > 0 {
            s.facts.append(.init(label: t("Memory"), value: APIFormat.memory(megabytes: mb)))
        }
        let temperature = info["temperature"].double ?? sys["sys_temp"].double
        if let temperature, temperature > 0 {
            s.facts.append(.init(label: t("Temperature"), value: APIFormat.number(temperature) + " °C"))
        }
        let hot = info["temperature_warn"].bool == true || sys["sys_tempwarn"].bool == true || sys["temperature_warning"].bool == true

        s.pools = pools(r.storage)
        s.disks = disks(r.storage)
        s.interfaces = interfaces(r.network)

        var alerts: [String] = []
        if r.storageDenied {
            alerts.append(t("This account can't read storage information. Use an administrator account to see volumes and disks."))
        }
        if hot { alerts.append(t("The system temperature is high.")) }
        var problems: [(name: String, status: String, health: Health)] = s.pools.map { (name: $0.name, status: $0.status, health: $0.health) }
        for disk in s.disks {
            problems.append((name: disk.name, status: diskStatusText(r.storage, name: disk.name), health: disk.health))
        }
        alerts += problems.filter { $0.health == .critical }.map { t("%@ status: %@", $0.name, $0.status) }
        alerts += problems.filter { $0.health == .warning }.map { t("%@ status: %@", $0.name, $0.status) }
        s.alerts = alerts

        var overall = APIFormat.worst(s.pools.map(\.health) + s.disks.map(\.health))
        if hot { overall = max(overall == .unknown ? .ok : overall, .warning) }
        s.health = overall

        s.pools = APIFormat.uniqued(s.pools, \.name)
        s.disks = APIFormat.uniqued(s.disks, \.name)
        s.interfaces = APIFormat.uniqued(s.interfaces, \.name)
        return s
    }

    /// "DSM 7.2.1-69057 Update 5" (`version_string`, `firmware_ver`); a bare version gets the "DSM" prefix.
    static func osVersion(_ raw: String?) -> String? {
        guard let v = raw else { return nil }
        return v.uppercased().hasPrefix("DSM") ? v : "DSM " + v
    }

    /// `up_time` of `SYNO.Core.System` ("288:12:5" = hours:minutes:seconds; format not documented).
    static func uptime(_ raw: String?) -> Int? {
        guard let parts = raw?.split(separator: ":").map({ Int($0) }), parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.compactMap { $0 }
        switch n.count {
        case 3: return n[0] * 3600 + n[1] * 60 + n[2]
        case 4: return n[0] * 86_400 + n[1] * 3600 + n[2] * 60 + n[3]
        default: return nil
        }
    }

    /// "Intel Celeron J4125 · 4 cores".
    static func cpu(_ sys: APIJSON) -> String? {
        var vendor = sys["cpu_vendor"].string
        // "INTEL" → "Intel"; short names (AMD) stay as they are.
        if let v = vendor, v.count > 3, v == v.uppercased() { vendor = v.capitalized }
        let name = [vendor, sys["cpu_family"].string, sys["cpu_series"].string].compactMap { $0 }.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        guard let cores = sys["cpu_cores"].text, cores != "0" else { return name }
        return name + " · " + t("%@ cores", cores)
    }

    // MARK: Storage

    /// Volume or pool status → health.
    static func health(_ status: String?) -> Health {
        switch status?.lowercased() {
        case "normal", "healthy", "initialized", "not_initialized", "safe": return .ok
        case "attention", "degraded", "warning", "repairing", "system_partition_failed": return .warning
        case "crashed", "failing", "failed", "damage", "damaged": return .critical
        default: return .unknown
        }
    }

    /// Volumes, each with the layout of the storage pool it lives on ("Volume 1", "SHR").
    static func pools(_ storage: APIJSON) -> [ApplianceSnapshot.StoragePool] {
        let storagePools = storagePoolsByID(storage)
        return storage["volumes"].array.compactMap { v in
            guard v.isObject else { return nil }
            let pool = v["pool_path"].string.flatMap { storagePools[$0] }
            var status = v["status"].string ?? "—"
            var h = health(status)
            // A degraded storage pool under a "normal" volume is the news.
            if let pool, let poolStatus = pool["status"].string, health(poolStatus) > h {
                status = poolStatus
                h = health(poolStatus)
            }
            return ApplianceSnapshot.StoragePool(name: volumeName(v), status: status, health: h,
                         sizeBytes: v["size"]["total"].int64, usedBytes: v["size"]["used"].int64,
                         layout: layout(pool?["device_type"].string ?? v["device_type"].string ?? v["raid_type"].string))
        }
    }

    private static func storagePoolsByID(_ storage: APIJSON) -> [String: APIJSON] {
        var out: [String: APIJSON] = [:]
        for p in storage["storagePools"].array {
            if let id = p["id"].string { out[id] = p }
        }
        return out
    }

    /// "Volume 1" from `num_id`, `vol_path` ("/volume1") or `id` ("volume_1").
    static func volumeName(_ v: APIJSON) -> String {
        if let n = v["num_id"].int { return t("Volume %@", String(n)) }
        for key in ["vol_path", "id"] {
            if let raw = v[key].string, let r = raw.range(of: #"\d+$"#, options: .regularExpression) {
                return t("Volume %@", String(raw[r]))
            }
        }
        return v["id"].string ?? "—"
    }

    /// DSM `device_type`: "shr_without_disk_protect" → "SHR", "raid_5" → "RAID 5", "shr_2" → "SHR-2".
    static func layout(_ raw: String?) -> String? {
        guard let v = raw?.lowercased() else { return nil }
        if v.hasPrefix("shr") { return v.contains("2") ? "SHR-2" : "SHR" }
        if v.hasPrefix("raid_f") { return "RAID F" + String(v.dropFirst("raid_f".count)) }
        if v.hasPrefix("raid_") { return "RAID " + String(v.dropFirst("raid_".count)) }
        switch v {
        case "basic": return "Basic"
        case "jbod": return "JBOD"
        default: return raw
        }
    }

    /// Storage pool id → names of the volumes on it (for the disks' "pool").
    private static func volumeNamesByPool(_ storage: APIJSON) -> [String: String] {
        var out: [String: String] = [:]
        for v in storage["volumes"].array {
            guard let pool = v["pool_path"].string else { continue }
            let name = volumeName(v)
            out[pool] = out[pool].map { $0 + ", " + name } ?? name
        }
        return out
    }

    static func disks(_ storage: APIJSON) -> [ApplianceSnapshot.Disk] {
        let volumes = volumeNamesByPool(storage)
        return storage["disks"].array.compactMap { d in
            guard let id = d["id"].string else { return nil }
            let h = APIFormat.worst([health(d["status"].string), smartHealth(d["smart_status"].string)])
            let temperature = d["temp"].double.flatMap { $0 > 0 ? $0 : nil }
            return ApplianceSnapshot.Disk(name: d["name"].string ?? id, model: d["model"].string, serial: d["serial"].string,
                         sizeBytes: d["size_total"].int64, type: diskType(d), health: h, temperature: temperature,
                         pool: d["used_by"].string.flatMap { volumes[$0] })
        }
    }

    static func smartHealth(_ status: String?) -> Health {
        switch status?.lowercased() {
        case "normal", "safe", "healthy": return .ok
        case "warning", "abnormal", "attention": return .warning
        case "failing", "damage", "damaged", "failed": return .critical
        default: return .unknown
        }
    }

    private static func diskType(_ d: APIJSON) -> String? {
        let bus = d["diskType"].string
        if bus?.lowercased() == "nvme" || (d["id"].string?.hasPrefix("nvme") ?? false) { return "NVMe" }
        if let ssd = d["isSsd"].bool { return ssd ? "SSD" : "HDD" }
        return bus
    }

    /// The status words of a disk for its alert line ("crashed", "smart: failing").
    private static func diskStatusText(_ storage: APIJSON, name: String) -> String {
        guard let d = storage["disks"].array.first(where: { ($0["name"].string ?? $0["id"].string) == name }) else { return "—" }
        let status = d["status"].string
        let smart = d["smart_status"].string
        if let status, health(status) != .ok, health(status) != .unknown { return status }
        if let smart { return "S.M.A.R.T. " + smart }
        return status ?? "—"
    }

    // MARK: Network

    /// `SYNO.DSM.Network` `list`: `interfaces[]{id, mac, ip[]{address, netmask}}`. No link state there.
    static func interfaces(_ network: APIJSON) -> [ApplianceSnapshot.NetInterface] {
        network["interfaces"].array.compactMap { i in
            guard let id = i["id"].string ?? i["ifname"].string else { return nil }
            let addresses = i["ip"].array.compactMap { a -> String? in
                guard let ip = a["address"].string, ip != "0.0.0.0" else { return nil }
                return APIFormat.address(ip, mask: a["netmask"].text)
            }
            return ApplianceSnapshot.NetInterface(name: id, mac: i["mac"].string, addresses: addresses)
        }
    }
}
