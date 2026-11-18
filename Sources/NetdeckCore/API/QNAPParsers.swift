import Foundation

/// Answers of the QTS / QuTS hero web interface (`/cgi-bin/...`): XML under `<QDocRoot>`, values mostly in
/// CDATA. Pure, so they are unit-tested with captures.
enum QNAPParsers {
    typealias Health = ApplianceSnapshot.Health

    /// The answers one reading collects (each the `<QDocRoot>` element, nil when the call failed).
    struct Reading {
        /// `authLogin.cgi` (has `hero_model` on QuTS hero).
        var login: XMLElement?
        /// `manaRequest.cgi?subfunc=sysinfo&hd=no&multicpu=1`.
        var sysinfo: XMLElement?
        /// `manaRequest.cgi?subfunc=sysinfo&sysHealth=1`.
        var health: XMLElement?
        /// `chartReq.cgi?chart_func=disk_usage&disk_select=all&include=all`.
        var volumes: XMLElement?
        /// `disk/qsmart.cgi?func=all_hd_data`.
        var disks: XMLElement?
    }

    // MARK: XML

    /// The `<QDocRoot>` element of an answer, nil when it isn't one.
    static func root(_ data: Data) -> XMLElement? {
        guard let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement(), root.name == "QDocRoot" else { return nil }
        return root
    }

    static func root(_ text: String) -> XMLElement? { root(Data(text.utf8)) }

    /// The trimmed text at a path of child names ("func", "ownContent", "root", "cpu_usage"); nil when missing or empty.
    static func text(_ e: XMLElement?, _ path: String...) -> String? { text(e, path) }

    static func text(_ e: XMLElement?, _ path: [String]) -> String? {
        guard let node = element(e, path),
              let v = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    static func element(_ e: XMLElement?, _ path: [String]) -> XMLElement? {
        var node = e
        for name in path { node = node?.elements(forName: name).first }
        return node
    }

    static func int(_ e: XMLElement?, _ path: String...) -> Int? { text(e, path).flatMap { Int($0) } }
    static func double(_ e: XMLElement?, _ path: String...) -> Double? {
        text(e, path).flatMap { Double($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: Login

    /// The session id of a login answer. `authPassed` 0 is a refused login; `need_2sv` asks for a one-time code.
    static func sessionID(_ root: XMLElement?) throws -> String {
        guard let root else { throw APIError.badResponse("authLogin.cgi") }
        if text(root, "need_2sv") == "1" { throw APIError.twoFactorRequired }
        guard text(root, "authPassed") == "1", let sid = text(root, "authSid") else { throw APIError.unauthorized }
        return sid
    }

    /// A data answer that says the session is gone (`authPassed` 0).
    static func sessionEnded(_ root: XMLElement?) -> Bool { text(root, "authPassed") == "0" }

    // MARK: Snapshot

    static func snapshot(_ r: Reading, now: Date = .now) -> ApplianceSnapshot {
        var s = ApplianceSnapshot(takenAt: now, platform: .qnap, kind: .storage, power: .on)
        // Every answer repeats the model, firmware and hostname.
        let any = [r.sysinfo, r.health, r.volumes, r.disks, r.login].compactMap { $0 }
        func first(_ path: String...) -> String? { any.lazy.compactMap { text($0, path) }.first }
        let sys = element(r.sysinfo, ["func", "ownContent", "root"])

        s.model = first("model", "displayModelName") ?? first("model", "modelName")
        s.hostname = first("hostname") ?? text(sys, "server_name")
        s.serial = text(sys, "serial_number")
        let hero = first("hero_model") == "1" || first("model", "is_zfs") == "1"
        let product = hero ? "QuTS hero" : "QTS"
        if let version = first("firmware", "version") {
            let full = [version, first("firmware", "number")].compactMap { $0 }.joined(separator: ".")
            s.osVersion = product + " " + full
            let build = first("firmware", "build").map { " build " + $0 } ?? ""
            s.firmware.append(.init(label: product, value: full + build))
        }
        if let bios = text(sys, "bios_version") { s.firmware.append(.init(label: "BIOS", value: bios)) }
        s.uptimeSeconds = uptime(sys)

        if let cpu = text(sys, "cpu_model") { s.facts.append(.init(label: t("Processor"), value: APIFormat.cpuName(cpu))) }
        if let mb = double(sys, "total_memory"), mb > 0 {
            s.facts.append(.init(label: t("Memory"), value: APIFormat.memory(megabytes: mb)))
        }

        s.sensors = sensors(sys)
        s.pools = pools(r.volumes)
        s.disks = disks(r.disks)
        s.interfaces = interfaces(sys)

        var problems: [(name: String, status: String, health: Health)] = []
        problems += s.pools.map { ($0.name, $0.status, $0.health) }
        problems += s.disks.map { d in (d.name, diskStatus(r.disks, name: d.name) ?? "—", d.health) }
        problems += s.sensors.map { ($0.name, sensorText($0), $0.health) }
        s.alerts = problems.filter { $0.health == .critical }.map { t("%@ status: %@", $0.name, $0.status) }
            + problems.filter { $0.health == .warning }.map { t("%@ status: %@", $0.name, $0.status) }
        if r.volumes == nil && r.disks == nil {
            s.alerts.append(t("This account can't read storage information. Use an administrator account to see volumes and disks."))
        }

        let system = systemHealth(text(r.health, "func", "ownContent", "sysHealth", "status"))
        s.health = APIFormat.worst([system] + s.pools.map(\.health) + s.disks.map(\.health) + s.sensors.map(\.health))
        s.pools = APIFormat.uniqued(s.pools, \.name)
        s.disks = APIFormat.uniqued(s.disks, \.name)
        s.interfaces = APIFormat.uniqued(s.interfaces, \.name)
        return s
    }

    static func uptime(_ sys: XMLElement?) -> Int? {
        let parts = ["uptime_day", "uptime_hour", "uptime_min", "uptime_sec"].map { int(sys, $0) }
        guard parts.contains(where: { $0 != nil }) else { return nil }
        let n = parts.map { $0 ?? 0 }
        return n[0] * 86_400 + n[1] * 3600 + n[2] * 60 + n[3]
    }

    /// `sysHealth` `status`: "good", or a word for trouble.
    static func systemHealth(_ status: String?) -> Health {
        switch status?.lowercased() {
        case nil: return .unknown
        case "good", "normal", "ok": return .ok
        case "warning", "warn", "attention": return .warning
        default: return .critical
        }
    }

    // MARK: Sensors

    /// CPU and system temperatures against the NAS's own warning and error limits, and the system fans.
    static func sensors(_ sys: XMLElement?) -> [ApplianceSnapshot.Sensor] {
        var out: [ApplianceSnapshot.Sensor] = []
        for (name, key, warn, error) in [("CPU", "cpu_tempc", "CPUTempWarnT", "CPUTempErrT"), ("System", "sys_tempc", "SysTempWarnT", "SysTempErrT")] {
            guard let c = double(sys, key), c > 0 else { continue }
            var h = Health.ok
            if let e = double(sys, error), c >= e { h = .critical } else if let w = double(sys, warn), c >= w { h = .warning }
            out.append(.init(name: name, kind: .temperature, reading: c, unit: "°C", health: h))
        }
        let alias = text(sys, "sysfan_alias") ?? "SYS FAN"
        let fans = int(sys, "sysfan_count") ?? 0
        for i in stride(from: 1, through: fans, by: 1) {
            guard let rpm = double(sys, "sysfan\(i)") else { continue }
            let failed = text(sys, "sysfan_fail\(i)") == "1" || text(sys, "sysfan\(i)_stat") == "-1"
            out.append(.init(name: "\(alias) \(i)", kind: .fan, reading: rpm, unit: "RPM", health: failed ? .critical : .ok))
        }
        return out
    }

    static func sensorText(_ s: ApplianceSnapshot.Sensor) -> String {
        guard let r = s.reading else { return "—" }
        return APIFormat.number(r) + " " + s.unit
    }

    // MARK: Storage

    /// Volumes with their RAID level and, from `volumeUseList`, size and use (bytes).
    static func pools(_ root: XMLElement?) -> [ApplianceSnapshot.StoragePool] {
        guard let root else { return [] }
        var use: [String: (total: Int64?, free: Int64?)] = [:]
        for u in element(root, ["volumeUseList"])?.elements(forName: "volumeUse") ?? [] {
            guard let id = text(u, "volumeValue") else { continue }
            use[id] = (text(u, "total_size").flatMap { Int64($0) }, text(u, "free_size").flatMap { Int64($0) })
        }
        return (element(root, ["volumeList"])?.elements(forName: "volume") ?? []).map { v in
            let id = text(v, "volumeValue") ?? "?"
            let code = text(v, "volumeStatus").flatMap { Int($0) }
            let total = use[id]?.total.flatMap { $0 > 0 ? $0 : nil }
            let used = total.flatMap { t in use[id]?.free.map { t - $0 } }
            return ApplianceSnapshot.StoragePool(
                name: text(v, "volumeLabel") ?? t("Volume %@", id),
                status: code.map { $0 == 0 ? "Ready" : "code \($0)" } ?? "—",
                health: code.map { $0 == 0 ? .ok : .warning } ?? .unknown,
                sizeBytes: total, usedBytes: used, layout: layout(text(v, "volumeStat")))
        }
    }

    /// `volumeStat`: "mirror" → "RAID 1", "raid5" → "RAID 5", "single" → "Single".
    static func layout(_ raw: String?) -> String? {
        guard let v = raw?.lowercased().replacingOccurrences(of: " ", with: "") else { return nil }
        switch v {
        case "mirror", "raid1": return "RAID 1"
        case "stripe", "raid0", "stripping", "striping": return "RAID 0"
        case "single", "static", "basic": return "Single"
        case "jbod", "linear": return "JBOD"
        case "triplemirror": return "Triple mirror"
        default:
            if v.hasPrefix("raid"), v.count > 4 { return "RAID " + String(v.dropFirst(4)).uppercased() }
            return raw
        }
    }

    /// `Disk_Info` entries: "Disk 3" for the NAS's own bays ("0:3"), "Disk 1:2" in an expansion unit.
    static func disks(_ root: XMLElement?) -> [ApplianceSnapshot.Disk] {
        (element(root, ["Disk_Info"])?.elements(forName: "entry") ?? []).compactMap { e in
            guard let no = text(e, "HDNo") else { return nil }
            return ApplianceSnapshot.Disk(
                name: diskName(no), model: text(e, "Model"), serial: text(e, "Serial"),
                sizeBytes: capacity(text(e, "Capacity")), type: text(e, "hd_is_ssd") == "1" ? "SSD" : "HDD",
                health: diskHealth(text(e, "Health")), temperature: double(e, "Temperature", "oC"), pool: nil)
        }
    }

    static func diskName(_ no: String) -> String {
        let parts = no.split(separator: ":")
        if parts.count == 2, parts[0] == "0" { return "Disk \(parts[1])" }
        return "Disk \(no)"
    }

    static func diskStatus(_ root: XMLElement?, name: String) -> String? {
        (element(root, ["Disk_Info"])?.elements(forName: "entry") ?? [])
            .first { text($0, "HDNo").map(diskName) == name }.flatMap { text($0, "Health") }
    }

    /// SMART summary: "OK" / "Good", "Warning", "Abnormal" / "Error".
    static func diskHealth(_ raw: String?) -> Health {
        switch raw?.lowercased() {
        case nil: return .unknown
        case "ok", "good", "normal": return .ok
        case "warning", "warn": return .warning
        default: return .critical
        }
    }

    /// "7.28 TB" → bytes (QTS counts in powers of 1024).
    static func capacity(_ raw: String?) -> Int64? {
        guard let c = raw.flatMap({ CiscoParsers.capture(#"^([\d.]+)\s*([KMGTP])B"#, in: $0) }), let n = Double(c[0]) else { return nil }
        let units: [String: Double] = ["K": 1, "M": 2, "G": 3, "T": 4, "P": 5]
        return Int64(n * pow(1024, units[c[1]] ?? 0))
    }

    // MARK: Network

    /// `ifnameN` / `dnameN` ("Adapter 1"), `eth_statusN` (1: link), `eth_max_speedN` (Mbps), address and MAC.
    static func interfaces(_ sys: XMLElement?) -> [ApplianceSnapshot.NetInterface] {
        let count = int(sys, "nic_cnt") ?? 0
        guard count > 0 else { return [] }
        return (1...count).compactMap { i in
            guard let name = text(sys, "dname\(i)") ?? text(sys, "ifname\(i)") else { return nil }
            let up = text(sys, "eth_status\(i)").map { $0 == "1" }
            var addresses: [String] = []
            if let ip = text(sys, "eth_ip\(i)"), ip != "0.0.0.0" { addresses.append(APIFormat.address(ip, mask: text(sys, "eth_mask\(i)"))) }
            return ApplianceSnapshot.NetInterface(name: name, mac: text(sys, "eth_mac\(i)")?.lowercased(), linkUp: up,
                                                  speedMbps: up == true ? int(sys, "eth_max_speed\(i)") : nil, addresses: addresses)
        }
    }
}
