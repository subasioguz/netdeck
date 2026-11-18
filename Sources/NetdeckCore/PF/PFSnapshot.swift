import Foundation

/// Builds Netdeck's neutral snapshot from pfSense / OPNsense shell output. Pure, so it is unit-tested with captures.
///
/// Like a FortiGate, the unit routes; every network port is shown as a routed port with what rides on it: the
/// interface assigned to it (or to the LAGG it is in, or to a PPPoE link dialling out on it) and the VLAN
/// interfaces on top ("192.0.2.65/26 (SERVERS · VLAN 20)"). ARP neighbours go on a port when no other port shares
/// the interface they were seen on, and only on the ports (no MAC table, which would make it look like a switch).
public enum PFSnapshot {
    public struct Outputs: Sendable {
        public var identity = ""
        public var ifconfig = ""
        public var arp = ""
        /// `/conf/config.xml` (also what History & backups keeps); empty when the account can't read it.
        public var config = ""
        public init() {}
    }

    public static func build(_ o: Outputs, takenAt: Date = .now) -> SwitchSnapshot {
        let id = PFParsers.identity(o.identity)
        let platform = id.platform ?? .pfsense
        let ifaces = PFParsers.ifconfig(o.ifconfig)
        let byName = Dictionary(ifaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let cfg = PFParsers.config(o.config)
        let arp = PFParsers.arp(o.arp)

        // LAGG members from the configuration, else from ifconfig.
        var carrier: [String: String] = [:]
        for l in cfg.laggs { for m in l.members { carrier[m] = l.device } }
        for i in ifaces where !i.laggPorts.isEmpty { for m in i.laggPorts where carrier[m] == nil { carrier[m] = i.name } }

        let ports = ifaces.filter(PFParsers.isPort)
        let portsBehind = Dictionary(grouping: ports.map(\.name), by: { carrier[$0] ?? $0 })
        let assignedOn = Dictionary(grouping: cfg.interfaces, by: \.device)
        // VLANs: from the configuration, else from ifconfig (tag and parent).
        var vlans = cfg.vlans
        for i in ifaces where i.vlanTag != nil && !vlans.contains(where: { $0.device == i.name }) {
            if let tag = i.vlanTag, let parent = i.parent { vlans.append(PFConfig.VLAN(parent: parent, tag: tag, descr: i.description, device: i.name)) }
        }
        let vlansOn = Dictionary(grouping: vlans, by: \.parent)

        /// What an assigned interface carries: its address, or what ifconfig shows for DHCP / PPPoE.
        func addressText(_ a: PFConfig.Assigned) -> String? {
            let live = byName[a.device]?.addresses.first
            switch a.ipaddr {
            case "dhcp": return live.map { "\($0) (dhcp)" } ?? "dhcp"
            case "pppoe", "pptp", "l2tp": return live.map { "\($0) (\(a.ipaddr ?? ""))" } ?? a.ipaddr
            case let ip?:
                guard ip.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return live }
                return a.subnet.map { "\(ip)/\($0)" } ?? ip
            case nil: return live
            }
        }

        var neutral = JunosConfig()
        neutral.hostname = cfg.hostname ?? id.hostname
        var out: [SwitchPort] = []
        for (index, nic) in ports.enumerated() {
            let name = nic.name
            let via = carrier[name] ?? name
            let own = (assignedOn[via] ?? []) + cfg.ppps.filter { $0.ports.contains(via) }.flatMap { assignedOn[$0.device] ?? [] }
            var p = SwitchPort(slotKey: name, name: name)
            p.kind = PFParsers.isCage(media: nic.media) ? .sfp : .copper
            p.number = index + 1
            p.label = name
            p.description = own.first?.label ?? nic.description
            p.configDisabled = !own.isEmpty && own.allSatisfy { !$0.enabled }
            p.adminUp = nic.up && !p.configDisabled
            p.linkUp = nic.linkUp
            if p.linkUp { p.speed = PFParsers.speed(media: nic.media) }

            var addresses: [String] = []
            for a in own {
                guard let text = addressText(a) else { continue }
                // Through a LAGG: say so. A PPPoE link already says "(pppoe)".
                addresses.append(a.device == via && via != name ? "\(text) (\(via))" : text)
            }
            // Without the configuration (an account that can't read it), what ifconfig shows.
            if own.isEmpty, let live = byName[via]?.addresses {
                addresses += live.map { via == name ? $0 : "\($0) (\(via))" }
            }
            for v in (vlansOn[via] ?? []).sorted(by: { $0.tag < $1.tag }) {
                let assigned = assignedOn[v.device] ?? []
                for a in assigned {
                    guard let text = addressText(a) else { continue }
                    addresses.append("\(text) (\(a.label) · VLAN \(v.tag))")
                }
                if assigned.isEmpty {
                    let label = byName[v.device]?.description ?? v.descr ?? v.device
                    addresses += (byName[v.device]?.addresses ?? []).map { "\($0) (\(label) · VLAN \(v.tag))" }
                }
            }
            p.addresses = addresses

            if portsBehind[via]?.count == 1 {
                let seenOn = Set([via] + (vlansOn[via] ?? []).map(\.device))
                p.macs = arp.filter { seenOn.contains($0.interface) }.map { MACEntry(vlan: "—", mac: $0.mac, flags: "", interface: name) }
            }
            out.append(p)

            var c = JunosConfig.InterfaceConfig()
            c.description = p.description
            c.disabled = p.configDisabled
            c.inetAddresses = p.addresses
            neutral.interfaces[name] = c
        }

        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: neutral.hostname, model: id.model, junos: id.version),
            hardware: HardwareInfo(model: id.model, serial: id.serial),
            config: neutral,
            configText: o.config,
            statuses: out.map { InterfaceStatus(name: $0.name, adminUp: $0.adminUp, linkUp: $0.linkUp) },
            macTable: [],
            lldp: [],
            commits: [],
            platform: platform,
            explicitPorts: out,
            vendor: .none,
            readKind: .firewall
        )
    }
}
