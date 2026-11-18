import Foundation

/// Builds Netdeck's neutral snapshot from FortiOS command outputs. Pure, so it is unit-tested with captures.
///
/// A FortiGate routes and filters; it has no VLAN membership in Netdeck's sense. Every front port is shown
/// as a routed port with what rides on it: its own address, or that of the hardware switch, software
/// switch or aggregate it belongs to, plus the VLAN interfaces on top ("192.0.2.65/26 (vlan20 · VLAN 20)").
/// Devices from the ARP table are placed on a port when the interface they were seen on has exactly one
/// port behind it; a FortiGate can't tell which member of a switch interface a neighbour is on. They go on
/// the ports only, not in the snapshot's MAC table, which would make Netdeck treat the unit as a switch.
public enum FortiOSSnapshot {
    public struct Outputs: Sendable {
        public var status = ""
        public var physical = ""
        /// `show`: the whole configuration (also what History & backups keeps).
        public var config = ""
        public var arp = ""
        public init() {}
    }

    public static func build(_ o: Outputs, takenAt: Date = .now) -> SwitchSnapshot {
        let status = FortiOSParsers.status(o.status)
        let physical = FortiOSParsers.physical(o.physical)
        let interfaces = FortiOSParsers.interfaces(o.config)
        let byName = Dictionary(interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let hardSwitches = FortiOSParsers.virtualSwitches(o.config)
        let softSwitches = FortiOSParsers.softwareSwitches(o.config)
        let zones = FortiOSParsers.zones(o.config)
        let arp = FortiOSParsers.arp(o.arp)

        // The interface each port's traffic belongs to: a switch or aggregate it is a member of, else itself.
        var carrier: [String: String] = [:]
        for (name, members) in hardSwitches { for m in members { carrier[m] = name } }
        for (name, members) in softSwitches { for m in members where carrier[m] == nil { carrier[m] = name } }
        for i in interfaces where !i.members.isEmpty && !i.isVLAN {
            for m in i.members where carrier[m] == nil { carrier[m] = i.name }
        }

        // Front ports: what `get system interface physical` lists, minus switch interfaces themselves; ports of a
        // hardware switch the list doesn't show come from the configuration (link unknown, shown as down).
        let containers = Set(hardSwitches.keys).union(softSwitches.keys)
        var names: [String] = physical.map(\.name).filter { !containers.contains($0) && isFrontPort($0) }
        for (_, members) in hardSwitches.sorted(by: { $0.key < $1.key }) {
            for m in members where !names.contains(m) { names.append(m) }
        }
        if names.isEmpty {
            names = interfaces.filter { ($0.type ?? "") == "physical" && isFrontPort($0.name) }.map(\.name)
        }
        let rowByName = Dictionary(physical.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let vlansByParent = Dictionary(grouping: interfaces.filter(\.isVLAN), by: { $0.parent ?? "" })
        let portsBehind = Dictionary(grouping: names, by: { carrier[$0] ?? $0 })

        var neutral = JunosConfig()
        neutral.hostname = status.hostname
        var ports: [SwitchPort] = []
        for (index, name) in names.enumerated() {
            let cfg = byName[name]
            let row = rowByName[name]
            let via = carrier[name] ?? name
            var p = SwitchPort(slotKey: name, name: name)
            p.kind = isCage(name) ? .sfp : .copper
            p.number = index + 1
            p.label = name
            p.description = cfg?.alias ?? cfg?.description
            p.configDisabled = cfg?.down ?? false
            p.adminUp = !p.configDisabled
            p.linkUp = row?.linkUp ?? false
            if p.linkUp, let s = row?.speed { p.speed = speedLabel(s) }
            p.addresses = addresses(port: name, via: via, byName: byName, vlansByParent: vlansByParent)
            p.zone = zones.sorted { $0.key < $1.key }.first { $0.value.contains(name) || $0.value.contains(via) }?.key
            // Neighbours seen on this port's interface (or a VLAN on it), when no other port shares it.
            if portsBehind[via]?.count == 1 {
                let seenOn = Set([via] + (vlansByParent[via] ?? []).map(\.name))
                p.macs = arp.filter { seenOn.contains($0.interface) }.map {
                    MACEntry(vlan: "—", mac: $0.mac, flags: "", interface: name)
                }
            }
            ports.append(p)

            var c = JunosConfig.InterfaceConfig()
            c.description = p.description
            c.disabled = p.configDisabled
            c.inetAddresses = p.addresses
            neutral.interfaces[name] = c
        }
        neutral.zones = Dictionary(zones.flatMap { zone, members in members.map { ($0, zone) } }, uniquingKeysWith: { a, _ in a })

        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: status.hostname, model: status.model, junos: status.version),
            hardware: HardwareInfo(model: status.model, serial: status.serial),
            config: neutral,
            configText: o.config,
            statuses: ports.map { InterfaceStatus(name: $0.name, adminUp: $0.adminUp, linkUp: $0.linkUp) },
            macTable: [],
            lldp: [],
            commits: [],
            platform: .fortinetFortiOS,
            explicitPorts: ports,
            vendor: .none,
            readKind: .firewall
        )
    }

    /// The port's own address, or its switch's / aggregate's, then the addresses of the VLANs riding on it.
    static func addresses(port: String, via: String, byName: [String: FortiOSInterface],
                          vlansByParent: [String: [FortiOSInterface]]) -> [String] {
        var out: [String] = []
        if let own = byName[via]?.addressText { out.append(via == port ? own : "\(own) (\(via))") }
        for v in (vlansByParent[via] ?? []).sorted(by: { ($0.vlanID ?? 0) < ($1.vlanID ?? 0) }) {
            guard let a = v.addressText, let id = v.vlanID else { continue }
            out.append("\(a) (\(v.name) · VLAN \(id))")
        }
        return out
    }

    /// Internal links and pseudo ports that `get system interface physical` may list (NP6 inter-VDOM links,
    /// the 3G/4G modem, SSL VPN and tunnel interfaces).
    static func isFrontPort(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains(".") || n.hasPrefix("npu") || n == "modem" || n.hasPrefix("vsw.") { return false }
        return true
    }

    /// SFP / SFP+ cages: `x1`, `x2` (10G on FortiGate 100F and up) and ports named after their cage.
    static func isCage(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.range(of: #"^x\d+$"#, options: .regularExpression) != nil || n.contains("sfp")
    }

    /// "1000Mbps" → "1G", "2500Mbps" → "2.5G", "10000Mbps" → "10G", "100Mbps" → "100Mbps".
    static func speedLabel(_ s: String) -> String {
        guard let c = CiscoParsers.capture(#"^(\d+)Mbps$"#, in: s), let n = Int(c[0]), n >= 1000 else { return s }
        return n % 1000 == 0 ? "\(n / 1000)G" : "\(Double(n) / 1000)G"
    }
}
