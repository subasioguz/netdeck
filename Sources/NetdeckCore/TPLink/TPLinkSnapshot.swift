import Foundation

/// VLAN membership of one port. TP-Link ports are all "general" ports: untagged in any number of VLANs,
/// tagged in others, with a PVID for untagged frames coming in. Netdeck shows "untagged in the PVID only" as
/// an access port and "tagged, plus at most the PVID untagged" as a trunk with that native VLAN; anything
/// else (several untagged VLANs, a PVID the port doesn't carry) is `unusual` and left alone.
public struct TPLinkPortConfig: Equatable, Sendable {
    public var untagged: [Int]
    public var tagged: [Int]
    public var pvid: Int
    /// Member of a LAG ("Po1"): its VLANs are set on the port-channel.
    public var lag: String?

    public init(untagged: [Int] = [1], tagged: [Int] = [], pvid: Int = 1, lag: String? = nil) {
        self.untagged = untagged
        self.tagged = tagged
        self.pvid = pvid
        self.lag = lag
    }

    /// Every port starts as an untagged member of VLAN 1 with PVID 1; the configuration lists changes to that.
    init(_ ic: TPLinkInterfaceConfig?, lag: String? = nil) {
        var untagged = (ic?.removedVLAN1 ?? false) || (ic?.tagged.contains(1) ?? false) ? [] : [1]
        untagged += (ic?.untagged ?? []).filter { !untagged.contains($0) }
        self.init(untagged: untagged.sorted(), tagged: (ic?.tagged ?? []).sorted(), pvid: ic?.pvid ?? 1, lag: lag)
    }

    public var unusual: Bool { untagged.count > 1 || (untagged.count == 1 && untagged[0] != pvid) }

    public var mode: PortMode? {
        if tagged.isEmpty && untagged.isEmpty { return nil }
        return tagged.isEmpty && untagged.count <= 1 ? .access : .trunk
    }

    /// The untagged VLAN of a trunk (its PVID when the port carries it untagged).
    public var native: Int? { mode == .trunk && untagged.contains(pvid) ? pvid : nil }

    /// "untagged 1, 10 · tagged 20 · PVID 10", for warnings about unusual ports.
    public var summary: String {
        var parts: [String] = []
        if !untagged.isEmpty { parts.append("untagged " + TPLinkParsers.vlanListString(untagged)) }
        if !tagged.isEmpty { parts.append("tagged " + TPLinkParsers.vlanListString(tagged)) }
        parts.append("PVID \(pvid)")
        return parts.joined(separator: " · ")
    }
}

/// Platform data the TP-Link planner and driver need beyond `JunosConfig`.
public struct TPLinkState: Equatable, Sendable {
    /// Keyed by the short port name ("Gi1/0/5").
    public var ports: [String: TPLinkPortConfig]
    /// Adopted by an Omada controller: the switch only takes `show` commands, and the controller owns the
    /// configuration.
    public var controllerManaged: Bool
    public var firmware: String?

    public init(ports: [String: TPLinkPortConfig] = [:], controllerManaged: Bool = false, firmware: String? = nil) {
        self.ports = ports
        self.controllerManaged = controllerManaged
        self.firmware = firmware
    }
}

/// Builds a `SwitchSnapshot` from the raw `show` outputs of a TP-Link switch. Pure, so the whole read path is
/// testable without a device.
enum TPLinkSnapshotBuilder {
    struct Outputs: Sendable {
        var systemInfo = ""
        var runningConfig = ""
        var vlans = ""
        var interfaceStatus = ""
        var macTable = ""
        var lldp = ""
    }

    /// Sort key: unit, slot, port.
    static func order(_ name: String) -> [Int] {
        guard let c = CiscoParsers.capture(#"(\d+)/(\d+)/(\d+)$"#, in: name) else { return [Int.max] }
        return c.map { Int($0) ?? 0 }
    }

    /// "1000M" → "1G", "100M" → "100Mbps", "2500M" → "2.5G", "10G" → "10G".
    static func speedLabel(_ s: String) -> String? {
        let u = s.uppercased()
        if u.hasSuffix("G"), let n = Double(u.dropLast()) { return n == n.rounded() ? "\(Int(n))G" : "\(n)G" }
        guard u.hasSuffix("M"), let n = Int(u.dropLast()) else { return nil }
        if n >= 1000 { return n % 1000 == 0 ? "\(n / 1000)G" : "\(Double(n) / 1000)G" }
        return "\(n)Mbps"
    }

    static func build(_ o: Outputs, takenAt: Date = .now) -> SwitchSnapshot {
        let info = TPLinkParsers.system(o.systemInfo)
        let rc = TPLinkParsers.runningConfig(o.runningConfig)
        let rows = TPLinkParsers.interfaceStatus(o.interfaceStatus)
        var rowByPort: [String: TPLinkPortRow] = [:]
        for r in rows { rowByPort[r.port] = r }

        // VLANs: `show vlan` has every VLAN with its name; the configuration only names the ones given a name.
        var list = TPLinkParsers.vlans(o.vlans)
        if list.isEmpty {
            list = rc.vlans.map { (id: $0.key, name: $0.value.isEmpty ? ($0.key == 1 ? "System-VLAN" : String(format: "VLAN%04d", $0.key)) : $0.value) }
        }
        if !list.contains(where: { $0.id == 1 }) { list.append((id: 1, name: rc.vlans[1].flatMap { $0.isEmpty ? nil : $0 } ?? "System-VLAN")) }
        list.sort { $0.id < $1.id }
        var vlanNames: [Int: String] = [:]
        var used = Set<String>()
        for v in list {
            let name = used.contains(v.name) ? "\(v.name) (\(v.id))" : v.name
            used.insert(name)
            vlanNames[v.id] = name
        }

        func portConfig(_ name: String) -> TPLinkPortConfig {
            let ic = rc.interfaces[name]
            if let g = ic?.channelGroup {
                let lag = "Po\(g)"
                return TPLinkPortConfig(rc.interfaces[lag], lag: lag)
            }
            return TPLinkPortConfig(ic)
        }
        func members(_ pc: TPLinkPortConfig) -> [String] {
            Array(Set(pc.untagged + pc.tagged)).sorted().compactMap { vlanNames[$0] ?? "VLAN\($0)" }
        }

        var config = JunosConfig()
        config.hostname = rc.hostname ?? info.name
        config.vlans = list.compactMap { v in vlanNames[v.id].map { JunosConfig.VLAN(name: $0, vlanID: v.id) } }

        var seen = Set<String>()
        let candidates = rows.isEmpty ? Array(rc.interfaces.keys) : rows.map(\.port)
        let front = candidates.filter { TPLinkParsers.isFrontPort($0) && seen.insert($0).inserted }

        let macs: [MACEntry] = TPLinkParsers.macTable(o.macTable).map {
            MACEntry(vlan: $0.vlan.flatMap { vlanNames[$0] } ?? $0.vlan.map(String.init) ?? "", mac: $0.mac, flags: "", interface: $0.port)
        }
        let lldp = TPLinkParsers.lldpNeighbors(o.lldp)

        var portConfigs: [String: TPLinkPortConfig] = [:]
        var ports: [SwitchPort] = []
        for name in front {
            let row = rowByPort[name]
            let ifc = rc.interfaces[name]
            let pc = portConfig(name)
            portConfigs[name] = pc

            var ic = JunosConfig.InterfaceConfig()
            ic.description = ifc?.description
            ic.disabled = ifc?.shutdown ?? false
            ic.hasEthernetSwitching = true
            ic.mode = pc.mode
            ic.vlanMembers = members(pc)
            ic.nativeVlanID = pc.native
            config.interfaces[name] = ic

            var p = SwitchPort(slotKey: name, name: name)
            let medium = row?.medium?.lowercased() ?? ""
            p.kind = medium.contains("fiber") || (name.hasPrefix("Te") && medium.isEmpty) ? .sfp : .copper
            p.number = order(name).last ?? 0
            p.label = String(p.number)
            p.configDisabled = ic.disabled
            p.adminUp = !ic.disabled
            p.linkUp = row?.linkUp ?? false
            p.description = ifc?.description
            p.switching = true
            p.mode = pc.mode
            p.vlans = members(pc)
            p.nativeVlanID = pc.native
            p.macs = macs.filter { $0.interface == name || ($0.interface == pc.lag && pc.lag != nil) }
            p.lldp = lldp.filter { $0.localInterface == name }
            if p.linkUp, let s = row?.speed { p.speed = speedLabel(s) }
            ports.append(p)
        }
        ports.sort { order($0.name).lexicographicallyPrecedes(order($1.name)) }

        var hardware = HardwareInfo()
        hardware.model = info.model ?? rc.model
        hardware.serial = info.serial

        let state = TPLinkState(ports: portConfigs, controllerManaged: rc.controllerManaged, firmware: info.firmware)
        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: config.hostname, model: hardware.model, junos: info.firmware),
            hardware: hardware,
            config: config,
            configText: TPLinkParsers.configText(o.runningConfig),
            statuses: front.map { InterfaceStatus(name: $0, adminUp: !(rc.interfaces[$0]?.shutdown ?? false), linkUp: rowByPort[$0]?.linkUp ?? false) },
            macTable: macs,
            lldp: lldp,
            commits: [],
            platform: .tplinkOmada,
            explicitPorts: ports,
            vendor: .tplink(state),
            readKind: .switchDevice
        )
    }
}
