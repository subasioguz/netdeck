import Foundation

/// VLAN membership of one port. AOS-S keeps membership on the VLAN side: a port is untagged in at most one
/// VLAN and tagged in any number. Netdeck shows "untagged only" as an access port and anything tagged as a
/// trunk whose untagged VLAN is the native one.
public struct AOSSPortConfig: Equatable, Sendable {
    public var untagged: Int?
    public var tagged: [Int]
    /// Member of a trunk group ("Trk1"): its VLANs come from the group.
    public var trunk: String?

    public init(untagged: Int? = nil, tagged: [Int] = [], trunk: String? = nil) {
        self.untagged = untagged
        self.tagged = tagged
        self.trunk = trunk
    }

    public var mode: PortMode { tagged.isEmpty ? .access : .trunk }
}

/// Platform data the AOS-S planner and driver need beyond `JunosConfig`.
public struct AOSSState: Equatable, Sendable {
    public var ports: [String: AOSSPortConfig]
    /// "WC.16.11.0028"
    public var softwareRevision: String?

    public init(ports: [String: AOSSPortConfig] = [:], softwareRevision: String? = nil) {
        self.ports = ports
        self.softwareRevision = softwareRevision
    }

    /// 16.05 and later restore a configuration without a reboot (`cfg-restore`), which the safety net needs.
    /// Unknown counts as unable.
    public var canRestoreWithoutReboot: Bool {
        guard let r = softwareRevision.flatMap(AOSSParsers.release) else { return false }
        return r.major > 16 || (r.major == 16 && r.minor >= 5)
    }
}

/// Builds a `SwitchSnapshot` from the raw `show` outputs of an AOS-S switch. Pure, so the whole read path
/// is testable without a device.
enum AOSSSnapshotBuilder {
    struct Outputs: Sendable {
        var version = ""
        var system = ""
        var modules = ""
        var runningConfig = ""
        var interfacesBrief = ""
        var vlans = ""
        var macTable = ""
        var lldp = ""
    }

    /// Sort key: stack member, slot letter (none first), port number.
    static func order(_ name: String) -> [Int] {
        guard let c = CiscoParsers.capture(#"^(?:(\d+)/)?([A-Z]?)(\d+)$"#, in: name) else { return [Int.max] }
        let letter = c[1].unicodeScalars.first.map { Int($0.value) - 64 } ?? 0
        return [Int(c[0]) ?? 0, letter, Int(c[2]) ?? 0]
    }

    /// "1000FDx" → "1G", "100FDx" → "100Mbps", "10GigFD" → "10G", "." → nil.
    static func speedLabel(_ mode: String) -> String? {
        guard let n = Int(mode.prefix { $0.isNumber }) else { return nil }
        if mode.contains("Gig") { return "\(n)G" }
        return n >= 1000 && n % 1000 == 0 ? "\(n / 1000)G" : "\(n)Mbps"
    }

    /// A pluggable cage: an SFP type ("SFP+SR", "SFP+DA3", "1000SX") or nothing (empty cage).
    static func isCage(_ type: String) -> Bool {
        let t = type.uppercased()
        if t.isEmpty || t.contains("SFP") || t.contains("GBIC") || t.contains("SX") || t.contains("LX") || t.contains("DA") || t.contains("SR") || t.contains("LR") {
            return true
        }
        return !(t.hasSuffix("T") || t.hasSuffix("TX") || t.contains("BASE-T"))
    }

    static func build(_ o: Outputs, takenAt: Date = .now) -> SwitchSnapshot {
        let system = AOSSParsers.system(o.system, modules: o.modules)
        let rc = AOSSParsers.runningConfig(o.runningConfig)
        let rows = AOSSParsers.interfacesBrief(o.interfacesBrief)
        let revision = system.softwareRevision ?? AOSSParsers.softwareRevision(o.version)
        var rowByPort: [String: AOSSPortRow] = [:]
        for r in rows { rowByPort[r.port] = r }

        // VLANs: `show vlans` lists them all; the running configuration has the same names.
        var vlanList = AOSSParsers.vlans(o.vlans)
        if vlanList.isEmpty {
            vlanList = rc.vlans.map { (id: $0.key, name: $0.value.name ?? ($0.key == 1 ? "DEFAULT_VLAN" : "VLAN\($0.key)")) }
        }
        vlanList.sort { $0.id < $1.id }
        var vlanNames: [Int: String] = [:]
        var used = Set<String>()
        for v in vlanList {
            let name = used.contains(v.name) ? "\(v.name) (\(v.id))" : v.name
            used.insert(name)
            vlanNames[v.id] = name
        }

        // Membership per port (or trunk group), from the VLAN side.
        var untaggedIn: [String: Int] = [:]
        var taggedIn: [String: [Int]] = [:]
        for (id, v) in rc.vlans.sorted(by: { $0.key < $1.key }) {
            for p in v.untagged { untaggedIn[p] = id }
            for p in v.tagged { taggedIn[p, default: []].append(id) }
        }
        func portConfig(_ name: String) -> AOSSPortConfig {
            let trunk = rowByPort[name]?.trunk ?? rc.trunkOf[name]
            let key = trunk ?? name
            return AOSSPortConfig(untagged: untaggedIn[key], tagged: taggedIn[key] ?? [], trunk: trunk)
        }
        func members(_ pc: AOSSPortConfig) -> [String] {
            (([pc.untagged].compactMap { $0 }) + pc.tagged).sorted().compactMap { vlanNames[$0] }
        }

        var config = JunosConfig()
        config.hostname = rc.hostname ?? system.name
        config.vlans = vlanList.compactMap { v in vlanNames[v.id].map { JunosConfig.VLAN(name: $0, vlanID: v.id) } }

        var seen = Set<String>()
        let candidates = rows.isEmpty ? Array(rc.interfaces.keys) + Array(untaggedIn.keys) : rows.map(\.port)
        let front = candidates.filter { $0.range(of: #"^(\d+/)?[A-Z]?\d+$"#, options: .regularExpression) != nil && seen.insert($0).inserted }

        let macs: [MACEntry] = AOSSParsers.macTable(o.macTable).map {
            MACEntry(vlan: $0.vlan.flatMap { vlanNames[$0] } ?? $0.vlan.map(String.init) ?? "", mac: $0.mac, flags: "", interface: $0.port)
        }
        let lldp = AOSSParsers.lldpNeighbors(o.lldp)

        var portConfigs: [String: AOSSPortConfig] = [:]
        var ports: [SwitchPort] = []
        for name in front {
            let row = rowByPort[name]
            let ifc = rc.interfaces[name]
            let pc = portConfig(name)
            portConfigs[name] = pc

            var ic = JunosConfig.InterfaceConfig()
            ic.description = ifc?.name
            ic.disabled = ifc?.disabled ?? !(row?.enabled ?? true)
            ic.hasEthernetSwitching = true
            ic.mode = pc.mode
            ic.vlanMembers = members(pc)
            ic.nativeVlanID = pc.mode == .trunk ? pc.untagged : nil
            config.interfaces[name] = ic

            var p = SwitchPort(slotKey: name, name: name)
            p.kind = isCage(row?.type ?? "") && row != nil ? .sfp : .copper
            p.number = order(name).last ?? 0
            p.label = name.contains("/") ? String(name.split(separator: "/").last ?? "") : name
            p.present = !(row.map { $0.type.isEmpty } ?? false)
            p.configDisabled = ic.disabled
            p.adminUp = row?.enabled ?? !ic.disabled
            p.linkUp = row?.up ?? false
            p.description = ifc?.name
            p.switching = true
            p.mode = pc.mode
            p.vlans = members(pc)
            p.nativeVlanID = pc.mode == .trunk ? pc.untagged : nil
            // MAC and LLDP entries of a trunk group are listed under "Trk1".
            p.macs = macs.filter { $0.interface == name }
            p.lldp = lldp.filter { $0.localInterface == name }
            if p.linkUp, let mode = row?.mode { p.speed = speedLabel(mode) }
            ports.append(p)
        }
        ports.sort { order($0.name).lexicographicallyPrecedes(order($1.name)) }

        var hardware = HardwareInfo()
        hardware.model = system.model ?? system.productNumber ?? rc.productNumber
        hardware.serial = system.serial

        let state = AOSSState(ports: portConfigs, softwareRevision: revision)
        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: config.hostname, model: hardware.model, junos: revision),
            hardware: hardware,
            config: config,
            configText: AOSSParsers.configText(o.runningConfig),
            statuses: rows.map { InterfaceStatus(name: $0.port, adminUp: $0.enabled, linkUp: $0.up) },
            macTable: macs,
            lldp: lldp,
            commits: [],
            platform: .arubaAOSS,
            explicitPorts: ports,
            vendor: .aoss(state),
            readKind: .switchDevice
        )
    }
}
