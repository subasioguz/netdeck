import Foundation

/// Dell iDRAC Redfish resources → `ApplianceSnapshot`. Pure functions over decoded JSON.
///
/// Field notes: `SKU` is the Service Tag on Dell (`SerialNumber` is the board serial), the newest
/// spelling is `Oem.Dell.DellSystem.ChassisServiceTag`. iDRAC 8 names fans `FanName`. DMTF deprecated
/// `Thermal`/`Power` for `ThermalSubsystem`/`PowerSubsystem`, so both shapes are read.
enum RedfishParsers {
    typealias Health = ApplianceSnapshot.Health

    /// Everything one read collected. Resources the BMC didn't answer stay empty.
    struct Reading {
        var system: APIJSON
        var manager = APIJSON(nil)
        var thermal = APIJSON(nil)
        /// `ThermalSubsystem/Fans` members, when `Thermal` is gone.
        var subsystemFans: [APIJSON] = []
        /// `ThermalSubsystem/ThermalMetrics`, when `Thermal` is gone.
        var thermalMetrics = APIJSON(nil)
        var power = APIJSON(nil)
        /// `PowerSubsystem/PowerSupplies` members, when `Power` is gone.
        var subsystemPowerSupplies: [APIJSON] = []
        /// `Chassis/.../EnvironmentMetrics` (power draw), when `Power` is gone.
        var environment = APIJSON(nil)
        var ethernet: [APIJSON] = []
        /// The iDRAC's own network port.
        var managerNIC = APIJSON(nil)
        var controllers: [APIJSON] = []
        var drives: [APIJSON] = []
        var volumes: [APIJSON] = []
        /// One page of the system event log.
        var sel = APIJSON(nil)

        init(system: APIJSON) { self.system = system }
    }

    // MARK: Service root

    /// The service root of any Redfish service.
    static func isRedfish(_ root: APIJSON) -> Bool {
        root["RedfishVersion"].string != nil || (root.odataID?.hasPrefix("/redfish/v1") ?? false)
    }

    /// true for Dell, false for another vendor, nil when the root doesn't say (old firmware).
    static func isDell(root: APIJSON) -> Bool? {
        if let vendor = root["Vendor"].string { return vendor.lowercased().contains("dell") }
        if root["Oem"]["Dell"].exists { return true }
        if let product = root["Product"].string?.lowercased(), product.contains("dell") || product.contains("idrac") { return true }
        if !root["Oem"].keys.isEmpty { return false }
        return nil
    }

    /// Where sessions are created. Redfish < 1.6 firmware used `/redfish/v1/Sessions`; the root links it.
    static func sessionsPath(root: APIJSON) -> String {
        root["Links"]["Sessions"].odataID ?? "/redfish/v1/SessionService/Sessions"
    }

    static func memberLinks(_ collection: APIJSON) -> [String] {
        collection["Members"].array.compactMap(\.odataID)
    }

    /// The message of a Redfish error body.
    static func errorMessage(_ body: APIJSON) -> String? {
        body["error"]["@Message.ExtendedInfo"][0]["Message"].string ?? body["error"]["message"].string
    }

    // MARK: Snapshot

    static func snapshot(_ r: Reading, now: Date = .now) -> ApplianceSnapshot {
        var s = ApplianceSnapshot(takenAt: now, platform: .dellIDRAC, kind: .server)
        let sys = r.system
        s.model = sys["Model"].string
        s.serial = serviceTag(sys)
        s.hostname = sys["HostName"].string
        s.power = powerState(sys["PowerState"].string)
        s.health = Health(redfish: sys["Status"]["HealthRollup"].string ?? sys["Status"]["Health"].string)
        s.facts = systemFacts(sys)
        if let bios = sys["BiosVersion"].string { s.firmware.append(.init(label: "BIOS", value: bios)) }
        if let fw = r.manager["FirmwareVersion"].string {
            s.osVersion = "iDRAC " + fw
            s.firmware.append(.init(label: "iDRAC", value: fw))
        }

        s.sensors = r.thermal.exists ? sensors(thermal: r.thermal) : sensors(fans: r.subsystemFans, metrics: r.thermalMetrics)

        let draw: Double?
        if r.power.exists {
            s.components = powerSupplies(power: r.power)
            draw = r.power["PowerControl"][0]["PowerConsumedWatts"].double
        } else {
            s.components = r.subsystemPowerSupplies.compactMap(subsystemPowerSupply)
            draw = r.environment["PowerWatts"]["Reading"].double
        }
        if let draw, draw > 0 { s.facts.append(.init(label: t("Power draw"), value: APIFormat.number(draw) + " W")) }
        s.components += r.controllers.compactMap(controller)

        s.pools = r.volumes.compactMap(volume)
        let membership = volumeMembership(r.volumes)
        s.disks = r.drives.compactMap { drive in disk(drive, pool: drive.odataID.flatMap { membership[$0] }) }

        var nics = r.ethernet.compactMap { interface($0) }
        if let own = interface(r.managerNIC, name: "iDRAC") { nics.insert(own, at: 0) }
        s.interfaces = nics

        s.alerts = rollupAlerts(sys) + selAlerts(r.sel, now: now)

        s.sensors = APIFormat.uniqued(s.sensors, \.name)
        s.components = APIFormat.uniqued(s.components, \.name)
        s.pools = APIFormat.uniqued(s.pools, \.name)
        s.disks = APIFormat.uniqued(s.disks, \.name)
        s.interfaces = APIFormat.uniqued(s.interfaces, \.name)
        return s
    }

    // MARK: System

    /// Service Tag: `Oem.Dell.DellSystem.ChassisServiceTag`, else `SKU`. Never `SerialNumber` (board serial).
    static func serviceTag(_ sys: APIJSON) -> String? {
        sys["Oem"]["Dell"]["DellSystem"]["ChassisServiceTag"].string ?? sys["SKU"].string
    }

    /// Transitions count as where they are going.
    static func powerState(_ value: String?) -> ApplianceSnapshot.PowerState {
        switch value?.lowercased() {
        case "on", "poweringon": return .on
        case "off", "poweringoff": return .off
        default: return .unknown
        }
    }

    static func systemFacts(_ sys: APIJSON) -> [ApplianceSnapshot.Fact] {
        var facts: [ApplianceSnapshot.Fact] = []
        let cpus = sys["ProcessorSummary"]["Count"].int
        if let model = sys["ProcessorSummary"]["Model"].string {
            let name = APIFormat.cpuName(model)
            facts.append(.init(label: t("Processors"), value: cpus.map { t("%@× %@", String($0), name) } ?? name))
        } else if let cpus, cpus > 0 {
            facts.append(.init(label: t("Processors"), value: String(cpus)))
        }
        if let gib = memoryGiB(sys["MemorySummary"]["TotalSystemMemoryGiB"].double), gib > 0 {
            facts.append(.init(label: t("Memory"), value: APIFormat.memory(gib: gib)))
        }
        return facts
    }

    /// Some iDRAC firmware fills `TotalSystemMemoryGiB` with gigabytes divided by 1.073741824
    /// (256 GB reads 238.4185791015625); undo that when it lands on a whole number.
    static func memoryGiB(_ value: Double?) -> Double? {
        guard let v = value else { return nil }
        guard abs(v - v.rounded()) > 0.01 else { return v }
        let corrected = v * 1.073741824
        return abs(corrected - corrected.rounded()) < 0.05 ? corrected.rounded() : v
    }

    /// Dell's per-subsystem rollups that aren't OK, critical first.
    static func rollupAlerts(_ sys: APIJSON) -> [String] {
        let dell = sys["Oem"]["Dell"]["DellSystem"]
        let checks: [(key: String, label: String)] = [
            ("CPURollupStatus", t("Processors")),
            ("SysMemPrimaryStatus", t("Memory")),
            ("FanRollupStatus", t("Fans")),
            ("PSRollupStatus", t("Power supplies")),
            ("TempRollupStatus", t("Temperatures")),
            ("VoltRollupStatus", t("Voltages")),
            ("StorageRollupStatus", t("Storage")),
            ("BatteryRollupStatus", t("Batteries")),
            ("IntrusionRollupStatus", t("Chassis intrusion")),
        ]
        let found = checks.map { (label: $0.label, health: Health(redfish: dell[$0.key].string)) }
        let critical = found.filter { $0.health == .critical }.map { t("%@: critical", $0.label) }
        let warning = found.filter { $0.health == .warning }.map { t("%@: warning", $0.label) }
        return critical + warning
    }

    // MARK: Sensors

    private static func absent(_ j: APIJSON) -> Bool { j["Status"]["State"].string?.lowercased() == "absent" }

    private static func health(_ j: APIJSON) -> Health {
        Health(redfish: j["Status"]["Health"].string ?? j["Status"]["HealthRollup"].string)
    }

    /// `Chassis/.../Thermal`: `Temperatures[]` and `Fans[]` (`Name`, or `FanName` on iDRAC 8).
    static func sensors(thermal: APIJSON) -> [ApplianceSnapshot.Sensor] {
        var out: [ApplianceSnapshot.Sensor] = []
        for temp in thermal["Temperatures"].array where !absent(temp) {
            guard let name = temp["Name"].string else { continue }
            out.append(.init(name: name, kind: .temperature, reading: temp["ReadingCelsius"].double, unit: "°C", health: health(temp)))
        }
        for fan in thermal["Fans"].array where !absent(fan) {
            guard let name = fan["Name"].string ?? fan["FanName"].string else { continue }
            out.append(.init(name: name, kind: .fan, reading: fan["Reading"].double, unit: fanUnit(fan["ReadingUnits"].string), health: health(fan)))
        }
        return out
    }

    /// `ThermalSubsystem`: fan members with `SpeedPercent{Reading, SpeedRPM}`, temperatures from
    /// `ThermalMetrics.TemperatureReadingsCelsius[]` (no per-sensor health there).
    static func sensors(fans: [APIJSON], metrics: APIJSON) -> [ApplianceSnapshot.Sensor] {
        var out: [ApplianceSnapshot.Sensor] = []
        for temp in metrics["TemperatureReadingsCelsius"].array {
            guard let name = temp["DeviceName"].string ?? temp["DataSourceUri"].string.map({ ($0 as NSString).lastPathComponent }) else { continue }
            out.append(.init(name: name, kind: .temperature, reading: temp["Reading"].double, unit: "°C", health: .unknown))
        }
        for fan in fans where !absent(fan) {
            guard let name = fan["Name"].string ?? fan["Id"].string else { continue }
            let speed = fan["SpeedPercent"]
            if let rpm = speed["SpeedRPM"].double {
                out.append(.init(name: name, kind: .fan, reading: rpm, unit: "RPM", health: health(fan)))
            } else {
                out.append(.init(name: name, kind: .fan, reading: speed["Reading"].double, unit: "%", health: health(fan)))
            }
        }
        return out
    }

    private static func fanUnit(_ units: String?) -> String {
        guard let units else { return "RPM" }
        return units.lowercased() == "percent" ? "%" : units
    }

    // MARK: Power

    /// `Chassis/.../Power` → one component per power supply.
    static func powerSupplies(power: APIJSON) -> [ApplianceSnapshot.Component] {
        power["PowerSupplies"].array.compactMap { psu in
            guard let name = psu["Name"].string ?? psu["MemberId"].string else { return nil }
            if absent(psu) { return ApplianceSnapshot.Component(name: name, detail: t("Not installed"), health: .unknown) }
            var parts: [String] = []
            if let capacity = psu["PowerCapacityWatts"].double, capacity > 0 { parts.append(APIFormat.number(capacity) + " W") }
            if psu["LineInputVoltage"].double == 0 {
                parts.append(t("no input"))
            } else if let output = psu["LastPowerOutputWatts"].double ?? psu["PowerOutputWatts"].double {
                parts.append(t("%@ W now", APIFormat.number(output)))
            }
            return ApplianceSnapshot.Component(name: name, detail: parts.isEmpty ? nil : parts.joined(separator: " · "), health: health(psu))
        }
    }

    /// `PowerSubsystem/PowerSupplies` member.
    static func subsystemPowerSupply(_ psu: APIJSON) -> ApplianceSnapshot.Component? {
        guard let name = psu["Name"].string ?? psu["Id"].string else { return nil }
        if absent(psu) { return ApplianceSnapshot.Component(name: name, detail: t("Not installed"), health: .unknown) }
        var parts: [String] = []
        if let capacity = psu["PowerCapacityWatts"].double, capacity > 0 { parts.append(APIFormat.number(capacity) + " W") }
        if let input = psu["LineInputStatus"].string, input.lowercased().contains("loss") { parts.append(t("no input")) }
        return ApplianceSnapshot.Component(name: name, detail: parts.isEmpty ? nil : parts.joined(separator: " · "), health: health(psu))
    }

    // MARK: Network

    /// `EthernetInterfaces` member (host NIC port or partition, or the iDRAC's own port).
    static func interface(_ eth: APIJSON, name: String? = nil) -> ApplianceSnapshot.NetInterface? {
        guard eth.isObject, let id = name ?? eth["Id"].string, !absent(eth) else { return nil }
        let link: Bool? = eth["LinkStatus"].string.map { $0.lowercased() == "linkup" }
        let speed = eth["SpeedMbps"].int.flatMap { $0 > 0 ? $0 : nil }
        let addresses = eth["IPv4Addresses"].array.compactMap { a -> String? in
            guard let ip = a["Address"].string, ip != "0.0.0.0" else { return nil }
            return APIFormat.address(ip, mask: a["SubnetMask"].string)
        }
        return ApplianceSnapshot.NetInterface(name: id, mac: eth["MACAddress"].string ?? eth["PermanentMACAddress"].string,
                     linkUp: link, speedMbps: speed, addresses: addresses)
    }

    // MARK: Storage

    /// The `Drives` links of a `Storage` member (a controller).
    static func driveLinks(_ controller: APIJSON) -> [String] {
        controller["Drives"].array.compactMap(\.odataID)
    }

    /// A controller that has drives or reports a health.
    static func controller(_ c: APIJSON) -> ApplianceSnapshot.Component? {
        guard let name = c["Name"].string ?? c["Id"].string, !absent(c) else { return nil }
        let h = health(c)
        guard !driveLinks(c).isEmpty || h != .unknown else { return nil }
        let firmware = c["StorageControllers"][0]["FirmwareVersion"].string
        return ApplianceSnapshot.Component(name: name, detail: firmware.map { t("Firmware %@", $0) }, health: h)
    }

    /// A virtual disk (RAID volume).
    static func volume(_ v: APIJSON) -> ApplianceSnapshot.StoragePool? {
        guard let name = v["Name"].string ?? v["Id"].string else { return nil }
        let status = v["Oem"]["Dell"]["DellVirtualDisk"]["RaidStatus"].string
            ?? v["Status"]["Health"].string ?? v["Status"]["State"].string ?? "—"
        return ApplianceSnapshot.StoragePool(name: name, status: status, health: health(v), sizeBytes: v["CapacityBytes"].int64,
                     usedBytes: nil, layout: raidLayout(v["RAIDType"].string ?? v["VolumeType"].string))
    }

    /// "RAID1" → "RAID 1", "RAID10" → "RAID 10"; anything else as sent.
    static func raidLayout(_ value: String?) -> String? {
        guard let v = value else { return nil }
        if v.uppercased().hasPrefix("RAID"), let level = Int(v.dropFirst(4)) { return "RAID \(level)" }
        return v
    }

    /// Drive link → name of the virtual disk it belongs to.
    static func volumeMembership(_ volumes: [APIJSON]) -> [String: String] {
        var map: [String: String] = [:]
        for v in volumes {
            guard let name = v["Name"].string ?? v["Id"].string else { continue }
            for link in v["Links"]["Drives"].array.compactMap(\.odataID) {
                map[link] = map[link].map { $0 + ", " + name } ?? name
            }
        }
        return map
    }

    static func disk(_ d: APIJSON, pool: String?) -> ApplianceSnapshot.Disk? {
        guard let name = d["Name"].string ?? d["Id"].string, !absent(d) else { return nil }
        let type = d["Protocol"].string?.lowercased() == "nvme" ? "NVMe" : d["MediaType"].string
        return ApplianceSnapshot.Disk(name: name, model: d["Model"].string, serial: d["SerialNumber"].string, sizeBytes: d["CapacityBytes"].int64,
                     type: type, health: health(d), pool: pool)
    }

    // MARK: Event log

    /// When the log lists oldest first and has more entries than one page, the `$skip` that reaches
    /// the newest page.
    static func selSkipToNewest(_ page: APIJSON) -> Int? {
        let members = page["Members"].array
        guard let count = page["Members@odata.count"].int, count > members.count, members.count > 1,
              let first = date(members.first?["Created"].string), let last = date(members.last?["Created"].string),
              first < last else { return nil }
        return count - members.count
    }

    /// Critical and warning entries of the last `days` days, newest first, one line per message,
    /// prefixed with the day. The SEL is history, so older entries are not current problems.
    static func selAlerts(_ page: APIJSON, now: Date, days: Int = 30, limit: Int = 10) -> [String] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let entries = page["Members"].array.compactMap { e -> (date: Date, message: String)? in
            guard let severity = e["Severity"].string?.lowercased(), severity == "critical" || severity == "warning",
                  let message = e["Message"].string, let created = date(e["Created"].string),
                  created >= since, created <= now.addingTimeInterval(86_400) else { return nil }
            return (date: created, message: message)
        }
        var seen = Set<String>()
        return entries.sorted { $0.date > $1.date }
            .filter { seen.insert($0.message).inserted }
            .prefix(limit)
            .map { APIFormat.day($0.date) + " · " + $0.message }
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
