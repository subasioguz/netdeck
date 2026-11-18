import Foundation

/// VLAN settings of one front-panel port as configured, with VLAN numbers (AOS-CX commands use numbers;
/// Netdeck shows names).
public struct AOSCXPortConfig: Equatable, Sendable {
    /// A Layer 3 port (`routing`): no VLANs.
    public var routed: Bool
    public var mode: PortMode
    /// `vlan access`; 1 when not set.
    public var accessVLAN: Int
    /// `vlan trunk allowed`; nil = all VLANs.
    public var allowedVLANs: [Int]?
    /// `vlan trunk native`; 1 when not set.
    public var nativeVLAN: Int
    /// Member of `lag<N>`: its VLANs come from the LAG.
    public var lag: Int?

    public init(routed: Bool = false, mode: PortMode = .access, accessVLAN: Int = 1, allowedVLANs: [Int]? = nil,
                nativeVLAN: Int = 1, lag: Int? = nil) {
        self.routed = routed
        self.mode = mode
        self.accessVLAN = accessVLAN
        self.allowedVLANs = allowedVLANs
        self.nativeVLAN = nativeVLAN
        self.lag = lag
    }
}

/// Platform data the AOS-CX planner and driver need beyond `JunosConfig`.
public struct AOSCXState: Equatable, Sendable {
    /// Front-panel ports by name ("1/1/3").
    public var ports: [String: AOSCXPortConfig]
    /// "FL.10.13.1101"
    public var version: String?

    public init(ports: [String: AOSCXPortConfig] = [:], version: String? = nil) {
        self.ports = ports
        self.version = version
    }
}

/// Builds a `SwitchSnapshot` from the raw `show` outputs of an AOS-CX switch. Pure, so the whole read
/// path is testable without a device.
enum AOSCXSnapshotBuilder {
    struct Outputs: Sendable {
        var version = ""
        var system = ""
        var runningConfig = ""
        var interfaceBrief = ""
        var vlans = ""
        var macTable = ""
        var lldp = ""
    }

    /// "1/1/3" (member/slot/port), not "lag1", "vlan1" or "mgmt".
    static func isFrontPort(_ name: String) -> Bool {
        name.range(of: #"^\d+/\d+/\d+$"#, options: .regularExpression) != nil
    }

    static func path(_ name: String) -> [Int] { name.split(separator: "/").compactMap { Int($0) } }

    static func build(_ o: Outputs, takenAt: Date = .now) -> SwitchSnapshot {
        let system = AOSCXParsers.system(o.system)
        let rc = AOSCXParsers.runningConfig(o.runningConfig)
        let rows = AOSCXParsers.interfaceBrief(o.interfaceBrief)
        let version = AOSCXParsers.osVersion(o.version) ?? system.version
        var configs: [String: AOSCXInterfaceConfig] = [:]
        for c in rc.interfaces { configs[c.name] = c }
        var rowByPort: [String: AOSCXInterfaceRow] = [:]
        for r in rows { rowByPort[r.port] = r }

        // VLANs: `show vlan` has the names of unnamed VLANs too ("VLAN99", "DEFAULT_VLAN_1").
        var vlanList = AOSCXParsers.vlans(o.vlans)
        if vlanList.isEmpty {
            vlanList = rc.vlans.map { (id: $0.key, name: $0.value.name ?? ($0.key == 1 ? "DEFAULT_VLAN_1" : "VLAN\($0.key)")) }
            if !vlanList.contains(where: { $0.id == 1 }) { vlanList.append((id: 1, name: "DEFAULT_VLAN_1")) }
        }
        vlanList.sort { $0.id < $1.id }
        // Netdeck identifies VLANs by name; keep names unique.
        var vlanNames: [Int: String] = [:]
        var used = Set<String>()
        for v in vlanList {
            let name = used.contains(v.name) ? "\(v.name) (\(v.id))" : v.name
            used.insert(name)
            vlanNames[v.id] = name
        }
        let allIDs = vlanList.map(\.id)
        func names(_ ids: [Int]) -> [String] { ids.compactMap { vlanNames[$0] } }

        /// The port's own VLAN settings, or those of its LAG.
        func portConfig(_ name: String) -> AOSCXPortConfig {
            let c = configs[name]
            if let lag = c?.lag {
                var pc = portConfig("lag\(lag)")
                pc.lag = lag
                return pc
            }
            let row = rowByPort[name]
            let routed: Bool = {
                if let row, row.mode == "routed" { return true }
                if let row, row.mode == "access" || row.mode == "trunk" { return false }
                if let r = c?.routing { return r }
                return !(c?.addresses.isEmpty ?? true)
            }()
            let trunk = (c?.isTrunk ?? false) || row?.mode == "trunk"
            return AOSCXPortConfig(routed: routed, mode: trunk ? .trunk : .access, accessVLAN: c?.accessVLAN ?? 1,
                                   allowedVLANs: c?.allowedAll == true ? nil : c?.trunkAllowed,
                                   nativeVLAN: c?.trunkNative ?? row?.nativeVLAN ?? 1)
        }
        func members(_ pc: AOSCXPortConfig) -> [String] {
            pc.mode == .access ? names([pc.accessVLAN]) : names(pc.allowedVLANs ?? allIDs)
        }

        var config = JunosConfig()
        config.hostname = rc.hostname ?? system.hostname
        config.vlans = vlanList.compactMap { v in
            vlanNames[v.id].map { JunosConfig.VLAN(name: $0, vlanID: v.id, description: rc.vlans[v.id]?.description) }
        }

        // Front-panel ports: those `show interface brief` lists, else those configured.
        var seen = Set<String>()
        let front = (rows.isEmpty ? rc.interfaces.map(\.name) : rows.map(\.port)).filter { isFrontPort($0) && seen.insert($0).inserted }

        let macs: [MACEntry] = AOSCXParsers.macTable(o.macTable).map {
            MACEntry(vlan: vlanNames[$0.vlan] ?? String($0.vlan), mac: $0.mac, flags: $0.type, interface: $0.port)
        }
        let lldp = AOSCXParsers.lldpNeighbors(o.lldp)

        var portConfigs: [String: AOSCXPortConfig] = [:]
        var ports: [SwitchPort] = []
        for name in front {
            let row = rowByPort[name]
            let c = configs[name]
            let pc = portConfig(name)
            portConfigs[name] = pc

            var ic = JunosConfig.InterfaceConfig()
            ic.description = c?.description
            ic.disabled = c?.shutdown ?? (row.map { !$0.enabled } ?? false)
            ic.inetAddresses = c?.addresses ?? []
            if !pc.routed {
                ic.hasEthernetSwitching = true
                ic.mode = pc.mode
                ic.vlanMembers = members(pc)
                ic.nativeVlanID = pc.mode == .trunk ? pc.nativeVLAN : nil
            }
            config.interfaces[name] = ic

            var p = SwitchPort(slotKey: name, name: name)
            let type = row?.type ?? ""
            p.kind = type.uppercased().contains("SFP") || type == "--" || (row?.reason.contains("XCVR") ?? false) ? .sfp : .copper
            p.number = path(name).last ?? 0
            p.label = String(p.number)
            p.present = !(row?.reason.contains("No XCVR") ?? false)
            p.configDisabled = ic.disabled
            p.adminUp = row?.enabled ?? !ic.disabled
            p.linkUp = row?.up ?? false
            p.description = c?.description ?? row?.description
            p.switching = !pc.routed
            if !pc.routed {
                p.mode = pc.mode
                p.vlans = members(pc)
                p.nativeVlanID = pc.mode == .trunk ? pc.nativeVLAN : nil
            }
            p.addresses = c?.addresses ?? []
            p.macs = macs.filter { $0.interface == name }
            p.lldp = lldp.filter { $0.localInterface == name }
            if p.linkUp, let s = row?.speed { p.speed = s >= 1000 && s % 1000 == 0 ? "\(s / 1000)G" : "\(s)Mbps" }
            ports.append(p)
        }
        // Stack member 1 first; per member the copper ports, then the cages.
        func order(_ p: SwitchPort) -> [Int] {
            let path = path(p.name)
            return [path.first ?? 0, p.kind == .copper ? 0 : 1, path.dropFirst().first ?? 0, p.number]
        }
        ports.sort { order($0).lexicographicallyPrecedes(order($1)) }

        var hardware = HardwareInfo()
        hardware.model = system.productName.map(AOSCXParsers.model(fromProduct:))
        hardware.serial = system.serial

        let state = AOSCXState(ports: portConfigs, version: version)
        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: config.hostname, model: hardware.model, junos: version),
            hardware: hardware,
            config: config,
            configText: AOSCXParsers.configText(o.runningConfig),
            statuses: rows.filter { isFrontPort($0.port) }.map { InterfaceStatus(name: $0.port, adminUp: $0.enabled, linkUp: $0.up) },
            macTable: macs,
            lldp: lldp,
            commits: [],
            platform: .arubaAOSCX,
            explicitPorts: ports,
            vendor: .aoscx(state),
            readKind: .switchDevice
        )
    }
}
