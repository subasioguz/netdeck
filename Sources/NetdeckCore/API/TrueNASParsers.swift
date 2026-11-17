import Foundation

/// TrueNAS (CORE 13, SCALE / Community Edition) answers → `ApplianceSnapshot`. REST v2.0 and the
/// JSON-RPC methods return the same objects (`system/info` = `system.info`, `pool` = `pool.query`...).
///
/// Field notes: `system.info.model` is the CPU model; the hardware model is `system_product`.
/// CORE 13 pool entries have no `size`/`allocated`.
enum TrueNASParsers {
    typealias Health = ApplianceSnapshot.Health

    struct Reading {
        var info: APIJSON
        var pools = APIJSON(nil)
        var disks = APIJSON(nil)
        var interfaces = APIJSON(nil)
        var alerts = APIJSON(nil)

        init(info: APIJSON) { self.info = info }
    }

    /// A pool member disk: the pool it belongs to and its own state in the pool.
    typealias Membership = (pool: String, health: Health)

    // MARK: Credentials and detection

    /// TrueNAS API keys look like "1-" followed by 64 letters and digits. Those are sent as a key
    /// (Bearer / API_KEY_PLAIN) instead of a password.
    static func looksLikeAPIKey(_ secret: String) -> Bool {
        secret.range(of: #"^\d+-[A-Za-z0-9]{40,}$"#, options: .regularExpression) != nil
    }

    /// The answer of `GET /api/v2.0/system/state` (a JSON string).
    static func isSystemState(_ body: APIJSON) -> Bool {
        ["READY", "BOOTING", "SHUTTING_DOWN"].contains(body.string ?? "")
    }

    // MARK: Snapshot

    static func snapshot(_ r: Reading, now: Date = .now) -> ApplianceSnapshot {
        var s = ApplianceSnapshot(takenAt: now, platform: .truenas, kind: .storage, power: .on)
        let info = r.info
        s.hostname = info["hostname"].string
        s.model = hardware(info["system_product"].string)
        s.serial = hardware(info["system_serial"].string)
        s.osVersion = osVersion(info["version"].string)
        s.uptimeSeconds = info["uptime_seconds"].int
        s.facts = facts(info)

        s.pools = pools(r.pools)
        s.disks = disks(r.disks, membership: membership(r.pools))
        s.interfaces = interfaces(r.interfaces)
        let found = alerts(r.alerts)
        s.alerts = found.map { $0.text }

        var overall = APIFormat.worst(s.pools.map(\.health) + found.map { $0.health })
        if overall == .unknown, r.pools.exists || r.alerts.exists { overall = .ok }
        s.health = overall

        s.pools = APIFormat.uniqued(s.pools, \.name)
        s.disks = APIFormat.uniqued(s.disks, \.name)
        s.interfaces = APIFormat.uniqued(s.interfaces, \.name)
        return s
    }

    /// "TrueNAS-SCALE-24.10.2" → "TrueNAS SCALE 24.10.2", "TrueNAS-13.0-U6.1" → "TrueNAS 13.0-U6.1",
    /// "25.04.2" (newer releases send the bare version) → "TrueNAS 25.04.2".
    static func osVersion(_ raw: String?) -> String? {
        guard let v = raw else { return nil }
        let prefixes = [("TrueNAS-SCALE-", "TrueNAS SCALE "), ("TrueNAS-", "TrueNAS "), ("FreeNAS-", "FreeNAS ")]
        for (prefix, name) in prefixes where v.hasPrefix(prefix) {
            return name + String(v.dropFirst(prefix.count))
        }
        return v.lowercased().hasPrefix("truenas") ? v : "TrueNAS " + v
    }

    /// DMI fields with the board vendor's filler text read as nil.
    static func hardware(_ raw: String?) -> String? {
        guard let v = raw else { return nil }
        let fillers = ["to be filled by o.e.m.", "system product name", "system serial number", "default string",
                       "not specified", "not applicable", "none", "n/a", "0123456789", "123456789"]
        return fillers.contains(v.lowercased()) ? nil : v
    }

    static func facts(_ info: APIJSON) -> [ApplianceSnapshot.Fact] {
        var facts: [ApplianceSnapshot.Fact] = []
        if let cpu = info["model"].string {
            let name = APIFormat.cpuName(cpu)
            let cores = info["cores"].int
            facts.append(.init(label: t("Processor"), value: cores.map { name + " · " + t("%@ cores", String($0)) } ?? name))
        }
        if let bytes = info["physmem"].int64, bytes > 0 {
            let memory = APIFormat.memory(bytes: bytes)
            facts.append(.init(label: t("Memory"), value: info["ecc_memory"].bool == true ? memory + " ECC" : memory))
        }
        if let maker = hardware(info["system_manufacturer"].string) {
            facts.append(.init(label: t("Manufacturer"), value: maker))
        }
        return facts
    }

    // MARK: Pools and disks

    static func poolHealth(status: String?, healthy: Bool?) -> Health {
        switch status?.uppercased() {
        case "ONLINE": return healthy == false ? .warning : .ok
        case "DEGRADED": return .warning
        case "FAULTED", "UNAVAIL", "OFFLINE", "REMOVED": return .critical
        default:
            guard let healthy else { return .unknown }
            return healthy ? .ok : .warning
        }
    }

    static func pools(_ list: APIJSON) -> [ApplianceSnapshot.StoragePool] {
        list.array.compactMap { p in
            guard let name = p["name"].string else { return nil }
            let status = p["status"].string ?? "—"
            return ApplianceSnapshot.StoragePool(name: name, status: status, health: poolHealth(status: status, healthy: p["healthy"].bool),
                                                 sizeBytes: p["size"].int64, usedBytes: p["allocated"].int64, layout: layout(p["topology"]))
        }
    }

    /// The data vdevs: "RAIDZ1", "2× MIRROR", "STRIPE".
    static func layout(_ topology: APIJSON) -> String? {
        let data = topology["data"].array
        guard let type = data.first?["type"].string?.uppercased() else { return nil }
        if type == "DISK" { return "STRIPE" }
        return data.count > 1 ? t("%@× %@", String(data.count), type) : type
    }

    /// Disk name ("sda", "ada0") → pool and the disk's state there, from the pools' topology.
    static func membership(_ pools: APIJSON) -> [String: Membership] {
        var out: [String: Membership] = [:]
        for p in pools.array {
            guard let name = p["name"].string else { continue }
            for group in ["data", "cache", "log", "spare", "special", "dedup"] {
                for vdev in p["topology"][group].array { collect(vdev, pool: name, into: &out) }
            }
        }
        return out
    }

    private static func collect(_ node: APIJSON, pool: String, into out: inout [String: Membership]) {
        if let disk = node["disk"].string {
            var h = poolHealth(status: node["status"].string, healthy: nil)
            let stats = node["stats"]
            let errors = (stats["read_errors"].int ?? 0) + (stats["write_errors"].int ?? 0) + (stats["checksum_errors"].int ?? 0)
            if errors > 0, h == .ok { h = .warning }
            out[disk] = (pool: pool, health: h)
        }
        for child in node["children"].array { collect(child, pool: pool, into: &out) }
    }

    static func disks(_ list: APIJSON, membership: [String: Membership]) -> [ApplianceSnapshot.Disk] {
        list.array.compactMap { d in
            guard let name = d["name"].string ?? d["devname"].string else { return nil }
            let member = membership[name]
            let type = name.hasPrefix("nvme") ? "NVMe" : d["type"].string
            return ApplianceSnapshot.Disk(name: name, model: d["model"].string, serial: d["serial"].string, sizeBytes: d["size"].int64,
                                          type: type, health: member?.health ?? .unknown, pool: d["pool"].string ?? member?.pool)
        }
    }

    // MARK: Network

    /// Physical ports, plus bridges, LAGGs and VLANs that carry an address (that is where the IP lives
    /// when VMs or apps share a port).
    static func interfaces(_ list: APIJSON) -> [ApplianceSnapshot.NetInterface] {
        list.array.compactMap { i in
            guard let name = i["name"].string ?? i["id"].string else { return nil }
            let state = i["state"]
            var ips = addresses(state["aliases"])
            if ips.isEmpty { ips = addresses(i["aliases"]) }
            guard i["type"].string?.uppercased() == "PHYSICAL" || !ips.isEmpty else { return nil }
            let link: Bool? = state["link_state"].string.map { $0.uppercased() == "LINK_STATE_UP" }
            return ApplianceSnapshot.NetInterface(name: name, mac: state["link_address"].string, linkUp: link,
                                                  speedMbps: speed(state), addresses: ips)
        }
    }

    /// `aliases[]{type, address, netmask}` → "192.0.2.30/24". Link-local IPv6 is left out.
    static func addresses(_ aliases: APIJSON) -> [String] {
        aliases.array.compactMap { a -> String? in
            let type = a["type"].string?.uppercased() ?? "INET"
            guard type == "INET" || type == "INET6", let ip = a["address"].string, !ip.lowercased().hasPrefix("fe80") else { return nil }
            return APIFormat.address(ip, mask: a["netmask"].text)
        }
    }

    /// Link speed from `state.speed` (newer releases) or the media text ("1000Mb/s Twisted Pair",
    /// "10Gbase-T <full-duplex>", "1000baseT").
    static func speed(_ state: APIJSON) -> Int? {
        if let s = state["speed"].int, s > 0 { return s }
        guard let media = state["active_media_subtype"].string else { return nil }
        let patterns: [(String, Int)] = [(#"\d+\s*Mb/s"#, 1), (#"\d+\s*Gb/s"#, 1000), (#"\d+G[-]?base"#, 1000), (#"\d+base"#, 1)]
        for (pattern, factor) in patterns {
            if let r = media.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               let n = Int(media[r].prefix(while: \.isNumber)), n > 0 {
                return n * factor
            }
        }
        return nil
    }

    // MARK: Alerts

    /// Not dismissed, WARNING or worse, newest first.
    static func alerts(_ list: APIJSON) -> [(text: String, health: Health)] {
        var found: [(date: Double, text: String, health: Health)] = []
        for a in list.array where a["dismissed"].bool != true {
            let h: Health
            switch a["level"].string?.uppercased() {
            case "WARNING": h = .warning
            case "ERROR", "CRITICAL", "ALERT", "EMERGENCY": h = .critical
            default: continue
            }
            guard let text = a["formatted"].string ?? a["text"].string else { continue }
            let date = a["datetime"]["$date"].double ?? a["last_occurrence"]["$date"].double ?? 0
            found.append((date: date, text: APIFormat.plainText(text), health: h))
        }
        return found.sorted { $0.date > $1.date }.map { (text: $0.text, health: $0.health) }
    }
}
